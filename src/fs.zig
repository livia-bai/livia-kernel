//! 文件系统：inode、目录、文件内容，都是写时复制 B 树（ctree.zig）里的条目，照 btrfs 的条目设计简化。
//! 这里只有文件系统本身的逻辑（不加锁、不知道进程），内核（syscall.zig）、mkfs、单元测试都用它。
//!
//! 条目（键是 (objectid, type, offset)，objectid 都是 inode 号，所以一个文件的所有条目在树里挨在一起）：
//!
//!   (ino, inode,  0)                  Inode：种类、链接数、设备号、长度、父目录
//!   (目录 ino, dir, 名字的散列 << 32 | 序号)   目录项：子 inode 号、种类、名字。散列相同的名字序号不同
//!   (ino, extent, 页号 * 4096)        文件第几页的内容：内联（数据直接放在条目里）或者指向一个数据块
//!   (0, orphan, ino)                  孤儿：名字都删掉了、还有人用着的 inode（链接数是 0），没有数据
//!
//! - 根目录的 inode 号是 1，新 inode 号是树里最大的 objectid + 1（挂载时算出来，之后递增）。
//! - 目录不存 "." 和 ".."：路径里遇到它们时直接用自己、Inode.parent。
//! - 硬链接：文件和设备可以有几个名字（link），Inode.nlink 记着有几个，最后一个名字删掉才删 inode。
//!   目录只有一个名字（它的 parent 才有意义）。
//! - 孤儿（btrfs 的 ORPHAN_ITEM）：删掉最后一个名字时，调用方说它还有人用着（keep：打开着的文件、正在运行的程序）的话，
//!   inode 留着、链接数记成 0，再插一个孤儿条目；用的人都放开之后调用方 reapOrphan 删掉它。掉电时孤儿条目还在的，
//!   挂载之后 reapOrphans 删掉。孤儿条目的 objectid 是 0（没有这个 inode 号），都排在树的最前面。
//! - 设备文件（mknod）：只有 inode，没有内容，Inode.major 说是哪个设备，打开它的读写交给内核的设备（file.zig）。
//! - 符号链接（symlink）：inode 的长度是目标路径的长度，目标内联在第 0 页的内容条目里（btrfs 也这样存）。
//!   解析路径时遇到它就换成目标接着走（最多 max_follows 次）；unlink、rename、link 对的是链接自己。
//! - 文件按 4 KiB 一页存。不超过 inline_max 字节的文件整个内联在第 0 页的条目里（btrfs 的 inline extent），
//!   省一个数据块；长大之后换成数据块。没有条目的页是“洞”，读出来是 0。长度之外的字节总是 0。
//! - 数据块也写时复制：改一页就分配一个新块、写好，再改条目指向它，旧块交给 Volume.freeData
//!   （属于已提交的树的要等提交之后才能再用）。条目里记着数据块的 crc32c，读盘时校验（btrfs 的数据校验和）。
//! - 一次操作就是 ctree 的一个事务的一部分：调用方成功之后 commit，出错 abort（见 Fs.run），
//!   所以每个操作要么全做了、要么什么都没做，掉电也一样。

const std = @import("std");
const btree = @import("btree.zig");
const ctree = @import("ctree.zig");
const bio = @import("bio.zig");
const Key = btree.Key;
const Volume = ctree.Volume;

pub const block_size = btree.block_size;
pub const root_ino: u64 = 1;
/// 名字最长多少字节
pub const max_name = 255;
/// 不超过这么多字节的文件内联在条目里
pub const inline_max = 512;
/// 文件最大多少（页号乘 4096 不能溢出，留够余量）
pub const max_file_size: u64 = 1 << 40;
/// 符号链接的目标最长多少字节（目标是一个路径，和 abi.max_path 一样长）
pub const max_symlink = 256;
/// 解析一个路径最多跟着走多少次符号链接，再多就当作有环（SymlinkLoop）。xv6 的 symlink 实验建议的也是 10
pub const max_follows = 10;

const type_inode: u8 = 1;
const type_dir: u8 = 2;
const type_extent: u8 = 3;
const type_orphan: u8 = 4;

/// inode 的种类。数值和 abi.FileKind 一样（3、4 是串口、管道，不在文件系统里）
pub const Kind = enum(u8) { file = 1, dir = 2, device = 5, symlink = 6, _ };

pub const Inode = extern struct {
    kind: Kind,
    _pad: u8 = 0,
    /// 设备文件是哪个设备（abi.Major），别的种类是 0
    major: u16 = 0,
    /// 有几个目录项指着它（硬链接）。目录总是 1
    nlink: u32 = 1,
    size: u64,
    /// 所在的目录（根目录是它自己）。路径里的 ".." 用它；只对目录有意义，文件可能有几个名字
    parent: u64,
};

/// 目录项的数据：这个头加上名字（不以 0 结尾）。
const DirHeader = extern struct {
    ino: u64,
    kind: Kind,
    name_len: u8,
    _pad: [6]u8 = @splat(0),
};

const ExtentKind = enum(u8) { inline_data = 1, block = 2, _ };

/// 文件内容的条目的数据：这个头，内联时后面跟着内容，指向数据块时后面是 BlockRef。
const ExtentHeader = extern struct {
    kind: ExtentKind,
    _pad: [3]u8 = @splat(0),
    /// 数据块的 crc32c（内联的不用：节点自己有校验和）
    csum: u32 = 0,
};

const BlockExtent = extern struct {
    head: ExtentHeader,
    blockno: u64,
    /// 写这个数据块的事务号，释放时用（Volume.freeData）
    generation: u64,
};

comptime {
    std.debug.assert(@sizeOf(Inode) == 24 and @sizeOf(DirHeader) == 16 and @sizeOf(BlockExtent) == 24);
    std.debug.assert(@sizeOf(DirHeader) + max_name <= btree.max_data and @sizeOf(ExtentHeader) + inline_max <= btree.max_data);
    std.debug.assert(max_symlink <= inline_max); // 符号链接的目标总是内联的
}

pub const Error = ctree.Error || error{
    /// 路径中间的某一段不是目录，或者对文件做目录的操作
    NotDir,
    /// 对目录做文件的操作（读写）
    IsDir,
    /// 删除的目录不是空的
    NotEmpty,
    NameTooLong,
    /// 空名字、"."、".."、含 '/'
    InvalidName,
    /// 读写的用户内存不对（out.put、in.get 返回的）
    BadAddress,
    FileTooBig,
    /// 给目录建硬链接
    IsDirLink,
    /// 链接数到上限了
    TooManyLinks,
    /// 解析路径时跟着走的符号链接太多（多半是有环）
    SymlinkLoop,
    /// readlink 的不是符号链接
    NotSymlink,
};

pub const Stat = struct {
    ino: u64,
    kind: Kind,
    size: u64,
    nlink: u32,
    major: u16,
};

pub const Dirent = struct {
    ino: u64,
    kind: Kind,
    name_len: usize,
    /// 下一次 readdir 从这里接着找
    next: u64,
};

const zeros: [block_size]u8 = @splat(0);

fn csum(data: *const [block_size]u8) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(data);
}

fn nameHash(name: []const u8) u64 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(name);
}

/// 挂载时 ctree 走树用：指向数据块的条目返回那个块。
fn dataRefs(key: Key, data: []const u8) ?ctree.DataRef {
    if (key.type != type_extent or data.len != @sizeOf(BlockExtent)) return null;
    const e = std.mem.bytesToValue(BlockExtent, data);
    if (e.head.kind != .block) return null;
    return .{ .blockno = e.blockno, .generation = e.generation };
}

pub const Fs = struct {
    vol: *Volume,
    /// 下一个新 inode 的号（只有修改的一方用）
    next_ino: u64,
    /// 读者的快照：不为 null 时只读，所有查找都在这棵已提交的树上做（ctree 的 beginRead）；
    /// 为 null 时是修改的一方，在当前事务的树上做
    view: ?ctree.Root = null,
    /// 删掉一个文件（不是目录）的最后一个名字时问一声：返回 true 表示还有人用着，留下孤儿而不是删掉 inode。
    /// 内核里是 fsys.keepInUse；mkfs、单元测试里没人用着，null 就是都删掉
    keep: ?*const fn (ino: u64) bool = null,

    /// 在磁盘上建一个只有空的根目录的文件系统。
    pub fn format(vol: *Volume, blocks: u64) Error!void {
        try Volume.format(blocks);
        vol.data_refs = dataRefs;
        try vol.mount();
        try vol.insert(Key.init(root_ino, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .size = 0, .parent = root_ino }));
        try vol.commit();
    }

    pub fn mount(vol: *Volume) Error!Fs {
        vol.data_refs = dataRefs;
        try vol.mount();
        var fs: Fs = .{ .vol = vol, .next_ino = 0 };
        const root = try fs.getInode(root_ino);
        if (root.kind != .dir) return error.Corrupt;
        const last = try vol.lastKey() orelse return error.Corrupt;
        fs.next_ino = last.objectid + 1;
        return fs;
    }

    /// 做一个操作：成功就提交，出错就作废这个事务（之前做了一半的都不算）。读者不能用。
    pub fn run(fs: *Fs, comptime op: anytype, args: anytype) Error!@typeInfo(@typeInfo(@TypeOf(op)).@"fn".return_type.?).error_union.payload {
        std.debug.assert(fs.view == null);
        const result = @call(.auto, op, .{fs} ++ args) catch |err| {
            try fs.vol.abort();
            return err;
        };
        try fs.vol.commit();
        return result;
    }

    // ---- 查找：读者在快照上，修改的一方在当前的树上 ----

    fn lookup(fs: *Fs, key: Key, out: ?[]u8) Error!?usize {
        return fs.vol.lookupAt(fs.view orelse fs.vol.root, key, out);
    }

    fn next(fs: *Fs, key: Key, out: ?[]u8) Error!?ctree.Volume.Found {
        return fs.vol.nextAt(fs.view orelse fs.vol.root, key, out);
    }

    // ---- inode ----

    fn getInode(fs: *Fs, ino: u64) Error!Inode {
        var ind: Inode = undefined;
        const size = try fs.lookup(Key.init(ino, type_inode, 0), std.mem.asBytes(&ind)) orelse return error.NotFound;
        if (size != @sizeOf(Inode)) return error.Corrupt;
        return ind;
    }

    fn putInode(fs: *Fs, ino: u64, ind: Inode) Error!void {
        try fs.vol.update(Key.init(ino, type_inode, 0), std.mem.asBytes(&ind));
    }

    pub fn stat(fs: *Fs, ino: u64) Error!Stat {
        const ind = try fs.getInode(ino);
        return .{ .ino = ino, .kind = ind.kind, .size = ind.size, .nlink = ind.nlink, .major = ind.major };
    }

    // ---- 目录 ----

    const Found = struct { ino: u64, kind: Kind, offset: u64 };

    /// 在目录 dir 里找 name。返回找到的目录项（没有就是 null），以及插入这个名字时该用的序号。
    fn scan(fs: *Fs, dir: u64, name: []const u8) Error!struct { ?Found, u64 } {
        const h = nameHash(name);
        var buf: [@sizeOf(DirHeader) + max_name]u8 = undefined;
        var k = Key.init(dir, type_dir, h << 32);
        var next_seq: u64 = 0;
        while (try fs.next(k, &buf)) |f| {
            if (f.key.objectid != dir or f.key.type != type_dir or f.key.offset >> 32 != h) break;
            if (f.size < @sizeOf(DirHeader)) return error.Corrupt;
            const head = std.mem.bytesToValue(DirHeader, buf[0..@sizeOf(DirHeader)]);
            if (@sizeOf(DirHeader) + @as(usize, head.name_len) != f.size) return error.Corrupt; // name_len 是 u8，先扩宽再加
            if (std.mem.eql(u8, buf[@sizeOf(DirHeader)..f.size], name)) return .{ .{ .ino = head.ino, .kind = head.kind, .offset = f.key.offset }, 0 };
            next_seq = (f.key.offset & 0xffff_ffff) + 1;
            k = f.key.successor() orelse break;
        }
        return .{ null, next_seq };
    }

    fn checkName(name: []const u8) Error!void {
        if (name.len > max_name) return error.NameTooLong;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
            std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidName;
    }

    /// 路径对应的 inode 号，跟着符号链接走（最后一段是符号链接的话，返回它指向的东西）。
    /// 以 '/' 开头的从根目录找，否则从 cwd 找；多个 '/' 当一个，"." 和 ".." 照常。
    pub fn resolve(fs: *Fs, cwd: u64, path: []const u8) Error!u64 {
        return fs.walk(cwd, path, true);
    }

    /// 和 resolve 一样，但最后一段是符号链接的话返回链接自己（lstat、readlink、link 用）。中间的符号链接照样跟着走。
    pub fn resolveNoFollow(fs: *Fs, cwd: u64, path: []const u8) Error!u64 {
        return fs.walk(cwd, path, false);
    }

    /// 一段一段地走路径。遇到符号链接（不是不跟的最后一段）就把“目标 + 还没走的部分”拼成新的路径接着走：
    /// 目标是绝对路径的从根目录重新开始，相对的从链接所在的目录开始。拼好的路径放在 buf 里，
    /// 不递归，栈上只多一个 buf。跟着走超过 max_follows 次是 SymlinkLoop，拼出来超过 buf 是 NameTooLong。
    /// 符号链接后面的 ".." 是目标的父目录（按 Inode.parent），不是链接所在的目录（和 Unix 一样）。
    fn walk(fs: *Fs, cwd: u64, path0: []const u8, follow_last: bool) Error!u64 {
        if (path0.len == 0) return error.NotFound;
        var buf: [max_symlink]u8 = undefined;
        var path = path0;
        var pos: usize = 0;
        var ino = if (path[0] == '/') root_ino else cwd;
        var follows: usize = 0;
        while (true) {
            while (pos < path.len and path[pos] == '/') pos += 1;
            if (pos == path.len) return ino;
            const end = std.mem.indexOfScalarPos(u8, path, pos, '/') orelse path.len;
            const part = path[pos..end];
            pos = end;
            const ind = try fs.getInode(ino);
            if (ind.kind != .dir) return error.NotDir;
            if (std.mem.eql(u8, part, ".")) continue;
            if (std.mem.eql(u8, part, "..")) {
                ino = ind.parent;
                continue;
            }
            if (part.len > max_name) return error.NameTooLong;
            const found, _ = try fs.scan(ino, part);
            const e = found orelse return error.NotFound;
            const rest = path[pos..]; // 以 '/' 开头，或者是空的
            const last = std.mem.trimStart(u8, rest, "/").len == 0;
            if (e.kind != .symlink or (last and !follow_last)) {
                ino = e.ino;
                continue;
            }
            follows += 1;
            if (follows > max_follows) return error.SymlinkLoop;
            // 先把还没走的部分挪到目标后面（它可能就在 buf 里，所以用 memmove），再把目标读到 buf 的开头
            const size = (try fs.getInode(e.ino)).size;
            if (size == 0 or size > max_symlink) return error.Corrupt;
            const n: usize = @intCast(size);
            if (n + rest.len > buf.len) return error.NameTooLong;
            @memmove(buf[n..][0..rest.len], rest);
            _ = try fs.readlink(e.ino, &buf);
            path = buf[0 .. n + rest.len];
            pos = 0;
            if (path[0] == '/') ino = root_ino; // 相对的目标从链接所在的目录（还是 ino）开始
        }
    }

    /// 路径的父目录和最后一段名字（创建、删除用）。最后一段不能是 "."、".."，父目录必须是目录。
    fn resolveParent(fs: *Fs, cwd: u64, path: []const u8) Error!struct { u64, []const u8 } {
        const trimmed = std.mem.trimEnd(u8, path, "/");
        if (trimmed.len == 0) return error.InvalidName; // "" 或者 "/"
        const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
        const name = if (slash) |i| trimmed[i + 1 ..] else trimmed;
        try checkName(name);
        const dir = if (slash) |i| try fs.resolve(cwd, if (i == 0) "/" else trimmed[0..i]) else cwd;
        if ((try fs.getInode(dir)).kind != .dir) return error.NotDir;
        return .{ dir, name };
    }

    /// 新建一个空文件或空目录，返回它的 inode 号。已经有这个名字时返回 Exists。
    pub fn create(fs: *Fs, cwd: u64, path: []const u8, kind: Kind) Error!u64 {
        std.debug.assert(kind == .file or kind == .dir);
        return fs.makeNode(cwd, path, kind, 0, 0);
    }

    /// 新建一个设备文件，返回它的 inode 号（mknod）。major 是哪个设备，文件系统不管它是不是真有这个设备。
    pub fn mknod(fs: *Fs, cwd: u64, path: []const u8, major: u16) Error!u64 {
        return fs.makeNode(cwd, path, .device, major, 0);
    }

    /// 新建一个符号链接 path，指向 target，返回它的 inode 号。target 不用存在（可以以后再建，也可以永远不存在），
    /// 原样存下，用到时才解析。target 是空的是 NotFound（和 Linux 一样），超过 max_symlink 字节是 NameTooLong。
    pub fn symlink(fs: *Fs, cwd: u64, target: []const u8, path: []const u8) Error!u64 {
        if (target.len == 0) return error.NotFound;
        if (target.len > max_symlink) return error.NameTooLong;
        const ino = try fs.makeNode(cwd, path, .symlink, 0, target.len);
        const h = @sizeOf(ExtentHeader);
        var buf: [h + max_symlink]u8 = undefined;
        @memcpy(buf[0..h], std.mem.asBytes(&ExtentHeader{ .kind = .inline_data }));
        @memcpy(buf[h..][0..target.len], target);
        try fs.vol.insert(extentKey(ino, 0), buf[0 .. h + target.len]);
        return ino;
    }

    /// 符号链接 ino 的目标，复制进 out，返回那一段。不是符号链接是 NotSymlink。
    pub fn readlink(fs: *Fs, ino: u64, out: *[max_symlink]u8) Error![]u8 {
        const ind = try fs.getInode(ino);
        if (ind.kind != .symlink) return error.NotSymlink;
        if (ind.size == 0 or ind.size > max_symlink) return error.Corrupt;
        const n: usize = @intCast(ind.size);
        const h = @sizeOf(ExtentHeader);
        var buf: [h + max_symlink]u8 = undefined;
        const size = try fs.lookup(extentKey(ino, 0), &buf) orelse return error.Corrupt;
        if (size != h + n or std.mem.bytesToValue(ExtentHeader, buf[0..h]).kind != .inline_data) return error.Corrupt;
        @memcpy(out[0..n], buf[h..][0..n]);
        return out[0..n];
    }

    fn makeNode(fs: *Fs, cwd: u64, path: []const u8, kind: Kind, major: u16, size: u64) Error!u64 {
        const dir, const name = try fs.resolveParent(cwd, path);
        const found, const seq = try fs.scan(dir, name);
        if (found != null) return error.Exists;
        return fs.newNode(dir, name, seq, kind, major, size);
    }

    /// 在目录 dir 里建名字是 name（scan 过、没有）的新 inode，seq 是 scan 给的序号。
    fn newNode(fs: *Fs, dir: u64, name: []const u8, seq: u64, kind: Kind, major: u16, size: u64) Error!u64 {
        const ino = fs.next_ino;
        fs.next_ino += 1;
        try fs.vol.insert(Key.init(ino, type_inode, 0), std.mem.asBytes(&Inode{ .kind = kind, .major = major, .size = size, .parent = dir }));
        try fs.addEntry(dir, nameHash(name) << 32 | seq, ino, kind, name);
        return ino;
    }

    /// open(O_CREATE) 用：path 跟着符号链接走到的文件，没有就建一个空文件，返回 inode 号。
    /// 最后一段是指向不存在的东西的符号链接时，建的是它指向的那个文件（和 Unix 一样）；中间缺的目录不建（NotFound）。
    pub fn createFollow(fs: *Fs, cwd: u64, path: []const u8) Error!u64 {
        var buf: [max_symlink]u8 = undefined;
        var at = cwd;
        var p = path;
        for (0..max_follows + 1) |_| {
            const dir, const name = try fs.resolveParent(at, p);
            const found, const seq = try fs.scan(dir, name);
            const e = found orelse return fs.newNode(dir, name, seq, .file, 0, 0);
            if (e.kind != .symlink) return e.ino;
            p = try fs.readlink(e.ino, &buf); // 相对的目标从链接所在的目录开始
            at = dir;
        }
        return error.SymlinkLoop;
    }

    /// 目录 ino 从根目录开始的路径（getcwd），写在 out 的末尾，返回那一段。沿着 parent 往上走，
    /// 在每一层的父目录里找指向它的目录项（目录只有一个名字）。out 放不下是 NameTooLong。
    /// 走的是真实的目录（parent），所以经过符号链接 cd 进来的目录，得到的是它真正的位置。
    pub fn dirPath(fs: *Fs, ino: u64, out: []u8) Error![]u8 {
        var at = ino;
        var ind = try fs.getInode(at);
        if (ind.kind != .dir) return error.NotDir;
        var start = out.len;
        var name: [max_name]u8 = undefined;
        while (at != root_ino) {
            const parent = ind.parent;
            const n = try fs.nameOf(parent, at, &name);
            if (n + 1 > start) return error.NameTooLong; // 磁盘上有环的话也停在这里
            start -= n;
            @memcpy(out[start..][0..n], name[0..n]);
            start -= 1;
            out[start] = '/';
            at = parent;
            ind = try fs.getInode(at);
        }
        if (start == out.len) {
            if (start == 0) return error.NameTooLong;
            start -= 1;
            out[start] = '/';
        }
        return out[start..];
    }

    /// 目录 dir 里指向 child 的目录项的名字，返回长度。没有是 Corrupt（child 的 parent 是 dir，dir 里却没有它）。
    fn nameOf(fs: *Fs, dir: u64, child: u64, name: *[max_name]u8) Error!usize {
        var cookie: u64 = 0;
        while (try fs.readdir(dir, cookie, name)) |d| {
            if (d.ino == child) return d.name_len;
            cookie = d.next;
        }
        return error.Corrupt;
    }

    /// 在目录 dir 里插一个目录项：键的 offset 是 offset，指向 ino。
    fn addEntry(fs: *Fs, dir: u64, offset: u64, ino: u64, kind: Kind, name: []const u8) Error!void {
        var buf: [@sizeOf(DirHeader) + max_name]u8 = undefined;
        const head: DirHeader = .{ .ino = ino, .kind = kind, .name_len = @intCast(name.len) };
        @memcpy(buf[0..@sizeOf(DirHeader)], std.mem.asBytes(&head));
        @memcpy(buf[@sizeOf(DirHeader)..][0..name.len], name);
        try fs.vol.insert(Key.init(dir, type_dir, offset), buf[0 .. @sizeOf(DirHeader) + name.len]);
    }

    /// 硬链接：给 old 指着的文件（或设备）再起一个名字 new，链接数加 1。目录不行（IsDirLink），
    /// new 已经有了是 Exists。两个名字是同一个 inode：改了内容两边都看得到，删掉一个另一个照常。
    /// old 是符号链接的话，链接的是符号链接自己（和 Linux 的 link 一样，不跟着走）。
    pub fn link(fs: *Fs, cwd: u64, old: []const u8, new: []const u8) Error!void {
        const ino = try fs.resolveNoFollow(cwd, old);
        var ind = try fs.getInode(ino);
        if (ind.kind == .dir) return error.IsDirLink;
        if (ind.nlink == std.math.maxInt(u32)) return error.TooManyLinks;
        const dir, const name = try fs.resolveParent(cwd, new);
        const found, const seq = try fs.scan(dir, name);
        if (found != null) return error.Exists;
        try fs.addEntry(dir, nameHash(name) << 32 | seq, ino, ind.kind, name);
        ind.nlink += 1;
        try fs.putInode(ino, ind);
    }

    /// 删掉一个名字。是 inode 的最后一个名字的话，inode 也删掉（文件的内容一起释放），除非 keep 说它还有人用着：
    /// 那样它变成孤儿，用的人放开之后 reapOrphan。目录必须是空的；目录总是马上删掉，以它为当前目录的进程之后
    /// 再用它会得到 NotFound。
    pub fn unlink(fs: *Fs, cwd: u64, path: []const u8) Error!void {
        const dir, const name = try fs.resolveParent(cwd, path);
        const found, _ = try fs.scan(dir, name);
        try fs.remove(dir, found orelse return error.NotFound);
    }

    /// 删掉目录 dir 里的目录项 e（unlink、rename 换掉已有的名字）。e 指向的 inode 还有别的名字的话
    /// 只把链接数减 1；还有人用着（keep）的话链接数记成 0、变成孤儿；否则 inode 也删掉。目录必须是空的。
    fn remove(fs: *Fs, dir: u64, e: Found) Error!void {
        if (e.kind == .dir) {
            if (try fs.next(Key.init(e.ino, type_dir, 0), null)) |f| {
                if (f.key.objectid == e.ino and f.key.type == type_dir) return error.NotEmpty;
            }
        } else {
            var ind = try fs.getInode(e.ino);
            if (ind.nlink > 1 or (if (fs.keep) |keep| keep(e.ino) else false)) {
                ind.nlink -= 1;
                try fs.putInode(e.ino, ind);
                if (ind.nlink == 0) try fs.vol.insert(Key.init(0, type_orphan, e.ino), &.{});
                return fs.vol.delete(Key.init(dir, type_dir, e.offset));
            }
        }
        try fs.deleteInode(e.ino);
        try fs.vol.delete(Key.init(dir, type_dir, e.offset));
    }

    /// inode 号为 ino 的所有条目：inode 和文件内容（数据块一起释放）。
    fn deleteInode(fs: *Fs, ino: u64) Error!void {
        while (try fs.next(Key.init(ino, 0, 0), null)) |f| {
            if (f.key.objectid != ino) break;
            try fs.dropItem(f.key);
        }
    }

    /// 把已提交的文件系统保存成一个快照（ctree.Volume.createSnap），返回它的编号（事务号）。事务里第一个操作。
    pub fn snapshot(fs: *Fs) Error!u64 {
        return fs.vol.createSnap();
    }

    /// 删掉编号为 generation 的快照（提交之后它独占的块空出来）。
    pub fn deleteSnapshot(fs: *Fs, generation: u64) Error!void {
        return fs.vol.deleteSnap(generation);
    }

    /// 删掉孤儿 ino（用它的人都放开了）。没有它的孤儿条目（删名字的事务作废了、已经删过了）就什么都不做。
    pub fn reapOrphan(fs: *Fs, ino: u64) Error!void {
        const key = Key.init(0, type_orphan, ino);
        if (try fs.lookup(key, null) == null) return;
        if ((try fs.getInode(ino)).nlink != 0) return error.Corrupt;
        try fs.deleteInode(ino);
        try fs.vol.delete(key);
    }

    /// 删掉所有孤儿（挂载之后：上次关机或者掉电时还有人用着的那些，现在不会有人用了）。返回删了几个。
    pub fn reapOrphans(fs: *Fs) Error!u64 {
        var n: u64 = 0;
        while (try fs.next(Key.init(0, type_orphan, 0), null)) |f| {
            if (f.key.objectid != 0 or f.key.type != type_orphan) break;
            try fs.reapOrphan(f.key.offset);
            n += 1;
        }
        return n;
    }

    /// 把 old 改名成 new，可以换到别的目录。一个事务做完（调用方用 run），所以要么改好了、要么什么都没变，
    /// 掉电也一样。inode 号不变：打开着它的 fd、以它（或者它下面的目录）为当前目录的进程都照常。
    ///
    /// new 已经有了的话换掉它（和 Unix 的 rename 一样）：文件换掉文件，目录换掉空目录（不空是 NotEmpty）；
    /// 目录换文件是 NotDir，文件换目录是 IsDir。换掉的那个和 unlink 一样处理（最后一个名字才连内容一起删掉）。
    /// old 和 new 是同一个 inode（同一个名字，或者同一个文件的两个硬链接）时什么都不做。
    /// 目录不能挪进它自己或者它下面（InvalidName）。
    pub fn rename(fs: *Fs, cwd: u64, old: []const u8, new: []const u8) Error!void {
        const odir, const oname = try fs.resolveParent(cwd, old);
        const found, _ = try fs.scan(odir, oname);
        const e = found orelse return error.NotFound;
        const ndir, const nname = try fs.resolveParent(cwd, new);
        const target, const seq = try fs.scan(ndir, nname);
        if (target) |t| {
            if (t.ino == e.ino) return;
            if (e.kind == .dir and t.kind != .dir) return error.NotDir;
            if (e.kind != .dir and t.kind == .dir) return error.IsDir;
        }
        if (e.kind == .dir) {
            // 新的父目录和它的祖先里不能有 e 自己，不然这一串就和根目录断开、成了环。
            // 走的步数比 inode 号还多说明磁盘上已经有环了（check 会报 Corrupt），不能一直走下去
            var at = ndir;
            var steps: u64 = 0;
            while (true) : ({
                at = (try fs.getInode(at)).parent;
                steps += 1;
            }) {
                if (at == e.ino) return error.InvalidName;
                if (at == root_ino) break;
                if (steps >= fs.next_ino) return error.Corrupt;
            }
        }
        // 换掉已有的名字时用它原来的键（名字一样，散列也一样）；否则用 scan 给的序号
        const offset = if (target) |t| t.offset else nameHash(nname) << 32 | seq;
        if (target) |t| try fs.remove(ndir, t);
        try fs.vol.delete(Key.init(odir, type_dir, e.offset));
        try fs.addEntry(ndir, offset, e.ino, e.kind, nname);
        if (odir != ndir) {
            var ind = try fs.getInode(e.ino);
            ind.parent = ndir;
            try fs.putInode(e.ino, ind);
        }
    }

    /// 删掉一个条目；是指向数据块的内容条目的话，数据块也释放。
    fn dropItem(fs: *Fs, key: Key) Error!void {
        var buf: [@sizeOf(BlockExtent)]u8 = undefined;
        const size = try fs.lookup(key, &buf) orelse return error.NotFound;
        if (dataRefs(key, buf[0..@min(size, buf.len)])) |d| {
            if (size == @sizeOf(BlockExtent)) fs.vol.freeData(d.blockno, d.generation);
        }
        try fs.vol.delete(key);
    }

    /// 目录 dir 里键 >= cookie 的第一个目录项，名字写进 name。没有了返回 null。从 0 开始，每次用返回的 next。
    pub fn readdir(fs: *Fs, dir: u64, cookie: u64, name: *[max_name]u8) Error!?Dirent {
        if ((try fs.getInode(dir)).kind != .dir) return error.NotDir;
        var buf: [@sizeOf(DirHeader) + max_name]u8 = undefined;
        const f = try fs.next(Key.init(dir, type_dir, cookie), &buf) orelse return null;
        if (f.key.objectid != dir or f.key.type != type_dir) return null;
        if (f.size < @sizeOf(DirHeader)) return error.Corrupt;
        const head = std.mem.bytesToValue(DirHeader, buf[0..@sizeOf(DirHeader)]);
        if (@sizeOf(DirHeader) + @as(usize, head.name_len) != f.size) return error.Corrupt; // name_len 是 u8，先扩宽再加
        @memcpy(name[0..head.name_len], buf[@sizeOf(DirHeader)..f.size]);
        return .{ .ino = head.ino, .kind = head.kind, .name_len = head.name_len, .next = f.key.offset + 1 };
    }

    // ---- 文件内容 ----

    fn extentKey(ino: u64, page: u64) Key {
        return Key.init(ino, type_extent, page * block_size);
    }

    /// 从文件 ino 的 off 处读最多 len 字节，交给 out.put(在这次读里的位置, 字节)。返回读了多少（到文件末尾为止）。
    pub fn read(fs: *Fs, ino: u64, off: u64, len: usize, out: anytype) Error!usize {
        const ind = try fs.getInode(ino);
        if (ind.kind != .file) return error.IsDir;
        if (off >= ind.size) return 0;
        const n: usize = @intCast(@min(len, ind.size - off));
        var done: usize = 0;
        while (done < n) {
            const pos = off + done;
            const a: usize = @intCast(pos % block_size);
            const m = @min(block_size - a, n - done);
            try fs.readPage(ino, pos / block_size, a, m, out, done);
            done += m;
        }
        return n;
    }

    fn readPage(fs: *Fs, ino: u64, page: u64, a: usize, m: usize, out: anytype, at: usize) Error!void {
        var ebuf: [@sizeOf(ExtentHeader) + inline_max]u8 = undefined;
        const size = try fs.lookup(extentKey(ino, page), &ebuf) orelse return out.put(at, zeros[0..m]); // 洞
        if (size < @sizeOf(ExtentHeader) or size > ebuf.len) return error.Corrupt;
        const head = std.mem.bytesToValue(ExtentHeader, ebuf[0..@sizeOf(ExtentHeader)]);
        switch (head.kind) {
            .inline_data => {
                const data = ebuf[@sizeOf(ExtentHeader)..size];
                const have = data[@min(a, data.len)..@min(a + m, data.len)];
                try out.put(at, have);
                if (have.len < m) try out.put(at + have.len, zeros[0 .. m - have.len]);
            },
            .block => {
                if (size != @sizeOf(BlockExtent)) return error.Corrupt;
                const e = std.mem.bytesToValue(BlockExtent, ebuf[0..size]);
                const b = try fs.readData(e);
                defer bio.release(b);
                try out.put(at, b.data[a..][0..m]);
            },
            _ => return error.Corrupt,
        }
    }

    /// 读一个数据块，拿着它的缓冲区返回。从磁盘读进来的核对校验和。
    fn readData(fs: *Fs, e: BlockExtent) Error!*bio.Buf {
        if (e.blockno < 2 or e.blockno >= fs.vol.blocks) return error.Corrupt;
        const b = try bio.get(e.blockno);
        const fresh = bio.load(b) catch |err| {
            bio.release(b);
            return err;
        };
        if (fresh and csum(b.data) != e.head.csum) {
            b.valid = false;
            bio.release(b);
            return error.Corrupt;
        }
        return b;
    }

    /// 从 in.get(在这次写里的位置, 目标) 取 len 字节，写到文件 ino 的 off 处，文件不够长就变长（中间留洞）。
    pub fn write(fs: *Fs, ino: u64, off: u64, len: usize, in: anytype) Error!usize {
        var ind = try fs.getInode(ino);
        if (ind.kind != .file) return error.IsDir;
        if (len == 0) return 0;
        const end = std.math.add(u64, off, len) catch return error.FileTooBig;
        if (end > max_file_size) return error.FileTooBig;
        if (end <= inline_max and (ind.size == 0 or try fs.page0Inline(ino))) {
            try fs.writeInline(ino, ind.size, off, end, in);
        } else {
            if (ind.size > 0 and try fs.page0Inline(ino)) try fs.unInline(ino);
            var done: usize = 0;
            while (done < len) {
                const pos = off + done;
                const a: usize = @intCast(pos % block_size);
                const m = @min(block_size - a, len - done);
                try fs.writePage(ino, pos / block_size, a, m, in, done);
                done += m;
            }
        }
        ind.size = @max(ind.size, end);
        try fs.putInode(ino, ind);
        return len;
    }

    fn page0Inline(fs: *Fs, ino: u64) Error!bool {
        var head: ExtentHeader = undefined;
        _ = try fs.lookup(extentKey(ino, 0), std.mem.asBytes(&head)) orelse return false;
        return head.kind == .inline_data;
    }

    /// 内联的文件写完之后还不超过 inline_max：整个内容在条目里改。内联条目的数据长度就是文件长度。
    fn writeInline(fs: *Fs, ino: u64, size: u64, off: u64, end: u64, in: anytype) Error!void {
        const h = @sizeOf(ExtentHeader);
        var buf: [h + inline_max]u8 = undefined;
        const old: usize = @intCast(size);
        if (old > 0) {
            const got = try fs.lookup(extentKey(ino, 0), &buf) orelse return error.Corrupt;
            if (got != h + old) return error.Corrupt;
        } else {
            @memcpy(buf[0..h], std.mem.asBytes(&ExtentHeader{ .kind = .inline_data }));
        }
        const new: usize = @intCast(@max(size, end));
        @memset(buf[h + old .. h + new], 0);
        try in.get(0, buf[h + @as(usize, @intCast(off)) .. h + @as(usize, @intCast(end))]);
        if (old > 0) try fs.vol.update(extentKey(ino, 0), buf[0 .. h + new]) else try fs.vol.insert(extentKey(ino, 0), buf[0 .. h + new]);
    }

    /// 内联的内容搬进一个数据块（文件要长到 inline_max 以上了）。
    fn unInline(fs: *Fs, ino: u64) Error!void {
        const h = @sizeOf(ExtentHeader);
        var buf: [h + inline_max]u8 = undefined;
        const size = try fs.lookup(extentKey(ino, 0), &buf) orelse return error.Corrupt;
        const blk = try fs.vol.allocData();
        const b = try bio.get(blk);
        defer bio.release(b);
        @memset(b.data, 0);
        @memcpy(b.data[0 .. size - h], buf[h..size]);
        const e = try fs.writeData(b, blk);
        try fs.vol.update(extentKey(ino, 0), std.mem.asBytes(&e));
    }

    /// 算校验和、写下数据块，返回指向它的条目。
    fn writeData(fs: *Fs, b: *bio.Buf, blk: u64) Error!BlockExtent {
        b.valid = true;
        try bio.write(b);
        return .{ .head = .{ .kind = .block, .csum = csum(b.data) }, .blockno = blk, .generation = fs.vol.transid };
    }

    /// 改第 page 页的 [a, a + m)：分配一个新块，不是整页覆盖的话先复制旧内容（没有旧的就是 0），
    /// 再从 in 取新内容，写下去，条目改成指向新块，旧块释放。
    fn writePage(fs: *Fs, ino: u64, page: u64, a: usize, m: usize, in: anytype, at: usize) Error!void {
        const key = extentKey(ino, page);
        var old: ?BlockExtent = null;
        var ebuf: [@sizeOf(BlockExtent)]u8 = undefined;
        if (try fs.lookup(key, &ebuf)) |size| {
            const head = std.mem.bytesToValue(ExtentHeader, ebuf[0..@sizeOf(ExtentHeader)]);
            if (size != @sizeOf(BlockExtent) or head.kind != .block) return error.Corrupt;
            old = std.mem.bytesToValue(BlockExtent, &ebuf);
        }
        const blk = try fs.vol.allocData();
        const b = try bio.get(blk);
        defer bio.release(b);
        if (a != 0 or m != block_size) {
            if (old) |e| {
                const ob = try fs.readData(e);
                defer bio.release(ob);
                @memcpy(b.data, ob.data);
            } else {
                @memset(b.data, 0);
            }
        }
        try in.get(at, b.data[a..][0..m]);
        const e = try fs.writeData(b, blk);
        if (old) |o| {
            fs.vol.freeData(o.blockno, o.generation);
            try fs.vol.update(key, std.mem.asBytes(&e));
        } else {
            try fs.vol.insert(key, std.mem.asBytes(&e));
        }
    }

    /// 把文件截成 0 字节，释放它的所有内容。
    pub fn truncate(fs: *Fs, ino: u64) Error!void {
        var ind = try fs.getInode(ino);
        if (ind.kind != .file) return error.IsDir;
        while (try fs.next(extentKey(ino, 0), null)) |f| {
            if (f.key.objectid != ino or f.key.type != type_extent) break;
            try fs.dropItem(f.key);
        }
        ind.size = 0;
        try fs.putInode(ino, ind);
    }

    pub const CheckStats = struct {
        tree: ctree.Volume.Stats,
        files: u64 = 0,
        dirs: u64 = 0,
        devices: u64 = 0,
        symlinks: u64 = 0,
        /// 孤儿（名字都删掉了、还有人用着的 inode）
        orphans: u64 = 0,
        /// 读过、校验和对得上的数据块
        data_blocks: u64 = 0,
    };

    /// 检查整个文件系统（scrub 系统调用、单元测试）。不对就返回 Corrupt，什么都不改。
    ///
    /// - B 树：结构、每个节点的校验和、空闲空间的位图（ctree 的 check）。
    /// - 每个数据块都读一遍，核对校验和。只有从磁盘读进来的才核对（readData），
    ///   要核对磁盘上的内容的话，调用方先作废缓存（bio.invalidate）。
    /// - 条目之间对得上：每个条目前面都有它的 inode；目录项只在目录里，内容条目只在文件里；
    ///   目录项的名字合法、散列对得上，指向的 inode 存在、种类相同、parent 就是这个目录；
    ///   内容条目在文件长度之内，内联的只能是第 0 页、长度就是文件长度、后面没有别的内容条目；
    ///   根目录的 parent 是自己，别的目录沿着 parent 能走到根目录（没有和根目录断开的环）。
    /// - 除了根目录，每个 inode 正好有 nlink 个目录项指着它（目录正好一个，parent 就是那个目录）：
    ///   目录项的个数、指向的 inode 号之和、之和的散列版本，都和每个 inode 按 nlink 次算的一样
    ///   （一个 inode 多一个名字、另一个少一个，这三个同时对上的概率可以忽略）。
    /// - 设备文件没有内容、长度是 0；只有设备文件的 major 不是 0。
    /// - 符号链接的长度是 1..max_symlink，正好有一个内联在第 0 页的内容条目（目标），长度就是 inode 的长度。
    /// - 链接数是 0 的 inode 正好就是孤儿条目指着的那些，而且不是目录。
    pub fn check(fs: *Fs) Error!CheckStats {
        var stats: CheckStats = .{ .tree = try fs.vol.check() };
        var buf: [btree.max_data]u8 = undefined;
        var cur: ?Inode = null; // 正在看的 inode（条目按 inode 号排，同一个 inode 的条目挨在一起，inode 条目在最前）
        var cur_ino: u64 = 0;
        var cur_inline = false;
        var names: Tally = .{};
        var inodes: Tally = .{};
        var orphans: Tally = .{}; // 孤儿条目指着的
        var unlinked: Tally = .{}; // 链接数是 0 的
        var k = Key.init(0, 0, 0);
        while (try fs.next(k, &buf)) |f| : (k = f.key.successor() orelse break) {
            const ino = f.key.objectid;
            const data = buf[0..f.size]; // ctree 的 check 保证了不超过 max_data
            if (ino >= fs.next_ino) return error.Corrupt;
            if (f.key.type == type_orphan) {
                if (ino != 0 or data.len != 0 or f.key.offset == root_ino or f.key.offset >= fs.next_ino) return error.Corrupt;
                orphans.add(f.key.offset);
                stats.orphans += 1;
                continue;
            }
            if (f.key.type != type_inode and (cur == null or cur_ino != ino)) return error.Corrupt; // 没有 inode 的条目
            switch (f.key.type) {
                type_inode => {
                    if (missingTarget(cur, cur_inline)) return error.Corrupt;
                    if (f.key.offset != 0 or data.len != @sizeOf(Inode)) return error.Corrupt;
                    const ind = std.mem.bytesToValue(Inode, data);
                    if ((ind.kind != .device and ind.major != 0) or ind._pad != 0) return error.Corrupt;
                    if (ind.nlink == 0) {
                        if (ino == root_ino or ind.kind == .dir) return error.Corrupt;
                        unlinked.add(ino);
                    }
                    switch (ind.kind) {
                        .file => stats.files += 1,
                        .dir => {
                            if (ind.nlink != 1) return error.Corrupt;
                            stats.dirs += 1;
                            try fs.checkReachesRoot(ino, ind);
                        },
                        .device => {
                            if (ind.size != 0) return error.Corrupt;
                            stats.devices += 1;
                        },
                        .symlink => {
                            if (ind.size == 0 or ind.size > max_symlink) return error.Corrupt;
                            stats.symlinks += 1;
                        },
                        _ => return error.Corrupt,
                    }
                    if (ino == root_ino) {
                        if (ind.kind != .dir) return error.Corrupt;
                    } else {
                        inodes.addTimes(ino, ind.nlink);
                    }
                    cur = ind;
                    cur_ino = ino;
                    cur_inline = false;
                },
                type_dir => {
                    if (cur.?.kind != .dir or data.len < @sizeOf(DirHeader)) return error.Corrupt;
                    const head = std.mem.bytesToValue(DirHeader, data[0..@sizeOf(DirHeader)]);
                    const name = data[@sizeOf(DirHeader)..];
                    if (name.len != head.name_len or f.key.offset >> 32 != nameHash(name)) return error.Corrupt;
                    checkName(name) catch return error.Corrupt;
                    if (head.ino == root_ino) return error.Corrupt;
                    const child = fs.getInode(head.ino) catch |err| return if (err == error.NotFound) error.Corrupt else err;
                    if (child.kind != head.kind or (child.kind == .dir and child.parent != ino)) return error.Corrupt;
                    names.add(head.ino);
                },
                type_extent => {
                    const ind = cur.?;
                    if ((ind.kind != .file and ind.kind != .symlink) or f.key.offset % block_size != 0 or f.key.offset >= ind.size or
                        cur_inline or data.len < @sizeOf(ExtentHeader)) return error.Corrupt;
                    const head = std.mem.bytesToValue(ExtentHeader, data[0..@sizeOf(ExtentHeader)]);
                    switch (head.kind) {
                        .inline_data => {
                            if (f.key.offset != 0 or data.len - @sizeOf(ExtentHeader) != ind.size or ind.size > inline_max) return error.Corrupt;
                            cur_inline = true;
                        },
                        .block => {
                            if (data.len != @sizeOf(BlockExtent) or ind.kind == .symlink) return error.Corrupt;
                            const b = try fs.readData(std.mem.bytesToValue(BlockExtent, data));
                            bio.release(b);
                            stats.data_blocks += 1;
                        },
                        _ => return error.Corrupt,
                    }
                },
                else => return error.Corrupt,
            }
        }
        if (missingTarget(cur, cur_inline) or stats.dirs == 0 or !std.meta.eql(names, inodes) or !std.meta.eql(orphans, unlinked)) return error.Corrupt;
        return stats;
    }

    /// check 用：刚看完的 inode 是符号链接，却没有内联的目标
    fn missingTarget(ind: ?Inode, has_inline: bool) bool {
        const i = ind orelse return false;
        return i.kind == .symlink and !has_inline;
    }

    /// 目录 ino（inode 是 ind）沿着 parent 往上走得到根目录。一路上都得是目录；走的步数比 inode 号的个数还多就是有环。
    fn checkReachesRoot(fs: *Fs, ino: u64, ind: Inode) Error!void {
        var at = ino;
        var parent = ind.parent;
        var steps: u64 = 0;
        while (at != root_ino) : (steps += 1) {
            if (steps >= fs.next_ino or parent == at) return error.Corrupt;
            const p = fs.getInode(parent) catch |err| return if (err == error.NotFound) error.Corrupt else err;
            if (p.kind != .dir) return error.Corrupt;
            at = parent;
            parent = p.parent;
        }
        if (parent != root_ino) return error.Corrupt; // 根目录的 parent 是自己
    }

    /// 一组 inode 号的“指纹”：个数、和、散列之和（都是回绕的加法，和顺序无关）。
    const Tally = struct {
        count: u64 = 0,
        sum: u64 = 0,
        mixed: u64 = 0,

        fn add(t: *Tally, ino: u64) void {
            t.addTimes(ino, 1);
        }

        /// 记 n 次 ino（坏的 nlink 可能很大，不能一次一次地加）
        fn addTimes(t: *Tally, ino: u64, n: u64) void {
            t.count +%= n;
            t.sum +%= ino *% n;
            // splitmix64 的最后一步：把 ino 的每一位搅到所有位上
            var z = ino +% 0x9e37_79b9_7f4a_7c15;
            z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
            z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
            t.mixed +%= (z ^ (z >> 31)) *% n;
        }
    };
};

// ---- 单元测试：内存当磁盘，可以掉电（和 ctree.zig 的测试一样的办法） ----

/// 测试里读写用的“用户内存”：就是一个切片。
const SliceOut = struct {
    buf: []u8,
    fn put(o: SliceOut, at: usize, bytes: []const u8) error{BadAddress}!void {
        @memcpy(o.buf[at..][0..bytes.len], bytes);
    }
};

const SliceIn = struct {
    data: []const u8,
    fn get(i: SliceIn, at: usize, dst: []u8) error{BadAddress}!void {
        @memcpy(dst, i.data[at..][0..dst.len]);
    }
};

/// 读到一半“用户内存”坏了：第二次 get 失败。
const FailingIn = struct {
    calls: *usize,
    fn get(i: FailingIn, at: usize, dst: []u8) error{BadAddress}!void {
        _ = at;
        i.calls.* += 1;
        if (i.calls.* > 1) return error.BadAddress;
        @memset(dst, 'x');
    }
};

var test_disk: [][block_size]u8 = &.{};
var test_budget: ?usize = null;
var test_crashed = false;
var test_writes: usize = 0;
var test_vol: Volume = .{};

fn testTransfer(block: u64, data: *[block_size]u8, write_: bool) bio.IoError!void {
    if (!write_) {
        data.* = test_disk[block];
        return;
    }
    test_writes += 1;
    if (test_crashed) return;
    if (test_budget) |*left| {
        if (left.* == 0) {
            test_crashed = true;
            return;
        }
        left.* -= 1;
    }
    test_disk[block] = data.*;
}

fn testReboot() void {
    test_budget = null;
    test_crashed = false;
    bio.init(.{ .blocks = test_disk.len, .transfer = testTransfer });
}

fn testSetup(blocks: usize) !Fs {
    if (test_disk.len != blocks) {
        std.testing.allocator.free(test_disk);
        test_disk = try std.testing.allocator.alloc([block_size]u8, blocks);
    }
    for (test_disk) |*b| @memset(b, 0);
    test_writes = 0;
    testReboot();
    try Fs.format(&test_vol, blocks);
    return Fs.mount(&test_vol);
}

fn testFree() void {
    std.testing.allocator.free(test_disk);
    test_disk = &.{};
}

fn readAll(fs: *Fs, path: []const u8, buf: []u8) ![]u8 {
    const ino = try fs.resolve(root_ino, path);
    const n = try fs.read(ino, 0, buf.len, SliceOut{ .buf = buf });
    return buf[0..n];
}

fn writeAt(fs: *Fs, ino: u64, off: u64, data: []const u8) !void {
    _ = try fs.run(Fs.write, .{ ino, off, data.len, SliceIn{ .data = data } });
}

test "目录：创建、查找、路径（. ..、多余的 /）、各种错误" {
    var fs = try testSetup(256);
    defer testFree();
    const a = try fs.run(Fs.create, .{ root_ino, "/a", Kind.dir });
    const b = try fs.run(Fs.create, .{ root_ino, "a/b", Kind.dir });
    const f = try fs.run(Fs.create, .{ b, "../f", Kind.file });
    try std.testing.expectEqual(a, try fs.resolve(root_ino, "a"));
    try std.testing.expectEqual(b, try fs.resolve(root_ino, "//a///b/"));
    try std.testing.expectEqual(f, try fs.resolve(b, "../f"));
    try std.testing.expectEqual(f, try fs.resolve(b, "/a/./b/../f"));
    try std.testing.expectEqual(root_ino, try fs.resolve(b, "../../.."));
    try std.testing.expectEqual(root_ino, try fs.resolve(f, "/"));
    try std.testing.expectEqual(Kind.dir, (try fs.stat(b)).kind);

    try std.testing.expectError(error.Exists, fs.run(Fs.create, .{ root_ino, "/a/f", Kind.file }));
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, "/a/x"));
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, ""));
    try std.testing.expectError(error.NotDir, fs.resolve(root_ino, "/a/f/x"));
    try std.testing.expectError(error.NotDir, fs.run(Fs.create, .{ root_ino, "/a/f/x", Kind.file }));
    try std.testing.expectError(error.NotFound, fs.run(Fs.create, .{ root_ino, "/nope/x", Kind.file }));
    for ([_][]const u8{ "/", "", "/a/.", "/a/..", ".." }) |p| {
        try std.testing.expectError(error.InvalidName, fs.run(Fs.create, .{ root_ino, p, Kind.file }));
    }
    const long: [max_name + 1]u8 = @splat('x');
    try std.testing.expectError(error.NameTooLong, fs.run(Fs.create, .{ root_ino, &long, Kind.file }));
    // 最长的名字（255 字节）：找得到、列得出来、删得掉（目录项的长度不能按 u8 算）
    const longest = try fs.run(Fs.create, .{ root_ino, long[0..max_name], Kind.file });
    try std.testing.expectEqual(longest, try fs.resolve(root_ino, long[0..max_name]));
    var listed = false;
    var name: [max_name]u8 = undefined;
    var cookie: u64 = 0;
    while (try fs.readdir(root_ino, cookie, &name)) |d| : (cookie = d.next) {
        if (d.ino == longest) listed = d.name_len == max_name and std.mem.eql(u8, name[0..max_name], long[0..max_name]);
    }
    try std.testing.expect(listed);
    try fs.run(Fs.unlink, .{ root_ino, long[0..max_name] });
    try std.testing.expectError(error.IsDir, fs.read(a, 0, 1, SliceOut{ .buf = &.{} }));

    // 删除：目录不空不行；删了之后找不到；inode 号不重用
    try std.testing.expectError(error.NotEmpty, fs.run(Fs.unlink, .{ root_ino, "/a" }));
    try fs.run(Fs.unlink, .{ root_ino, "/a/f" });
    try fs.run(Fs.unlink, .{ root_ino, "/a/b" });
    try fs.run(Fs.unlink, .{ root_ino, "a" });
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, "/a"));
    try std.testing.expectError(error.NotFound, fs.run(Fs.unlink, .{ root_ino, "/a" }));
    try std.testing.expectError(error.InvalidName, fs.run(Fs.unlink, .{ root_ino, "/" }));
    try std.testing.expect(try fs.run(Fs.create, .{ root_ino, "/a", Kind.file }) > f);
    _ = try fs.check();
}

test "readdir 列出所有名字；名字的散列相同时也分得开" {
    var fs = try testSetup(512);
    defer testFree();
    // 两个 crc32c 相同的名字（事先找好的：按 "n<数字>" 依次试，第一对撞上的）
    const n0 = "n1371838";
    const n1 = "n2000402";
    try std.testing.expectEqual(nameHash(n0), nameHash(n1));
    const ino0 = try fs.run(Fs.create, .{ root_ino, n0, Kind.file });
    const ino1 = try fs.run(Fs.create, .{ root_ino, n1, Kind.dir });
    try std.testing.expectEqual(ino0, try fs.resolve(root_ino, n0));
    try std.testing.expectEqual(ino1, try fs.resolve(root_ino, n1));
    // 再加 60 个普通名字，readdir 一个不少、不重复
    for (0..60) |j| {
        var buf: [16]u8 = undefined;
        _ = try fs.run(Fs.create, .{ root_ino, try std.fmt.bufPrint(&buf, "file{d}", .{j}), Kind.file });
    }
    var cookie: u64 = 0;
    var count: usize = 0;
    var found: [2]bool = @splat(false);
    var name: [max_name]u8 = undefined;
    while (try fs.readdir(root_ino, cookie, &name)) |d| : (cookie = d.next) {
        const nm = name[0..d.name_len];
        if (std.mem.eql(u8, nm, n0)) found[0] = true;
        if (std.mem.eql(u8, nm, n1)) found[1] = d.kind == .dir;
        try std.testing.expectEqual(d.ino, try fs.resolve(root_ino, nm));
        count += 1;
    }
    try std.testing.expectEqual(62, count);
    try std.testing.expect(found[0] and found[1]);
    // 删掉第一个，第二个还在
    try fs.run(Fs.unlink, .{ root_ino, n0 });
    try std.testing.expectEqual(ino1, try fs.resolve(root_ino, n1));
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, n0));
    try std.testing.expectError(error.NotDir, fs.readdir(try fs.resolve(root_ino, "file1"), 0, &name));
    _ = try fs.check();
}

test "rename：改名、换目录、换掉已有的文件和空目录，各种错误；inode 号不变，失败时什么都不变" {
    const expectError = std.testing.expectError;
    const expectEqual = std.testing.expectEqual;
    var fs = try testSetup(256);
    defer testFree();
    const a = try fs.run(Fs.create, .{ root_ino, "/a", Kind.dir });
    const b = try fs.run(Fs.create, .{ root_ino, "/a/b", Kind.dir });
    const f = try fs.run(Fs.create, .{ root_ino, "/a/f", Kind.file });
    try writeAt(&fs, f, 0, "content of f");
    var buf: [64]u8 = undefined;

    // 同一个目录里改名
    try fs.run(Fs.rename, .{ root_ino, "/a/f", "/a/g" });
    try expectError(error.NotFound, fs.resolve(root_ino, "/a/f"));
    try expectEqual(f, try fs.resolve(root_ino, "/a/g"));
    // 换到别的目录（相对路径），parent 跟着改：".." 走到新的目录
    try fs.run(Fs.rename, .{ a, "g", "b/h" });
    try expectEqual(f, try fs.resolve(root_ino, "/a/b/h"));
    try expectEqual(b, (try fs.getInode(f)).parent);
    try std.testing.expectEqualStrings("content of f", try readAll(&fs, "/a/b/h", &buf));
    // 目录连着下面的东西一起挪
    try fs.run(Fs.rename, .{ root_ino, "/a/b", "/b2" });
    try expectEqual(f, try fs.resolve(root_ino, "/b2/h"));
    try expectEqual(root_ino, try fs.resolve(b, ".."));
    _ = try fs.check();

    // 换掉已有的文件：旧的那个的内容一起删掉，块都还回来
    const other = try fs.run(Fs.create, .{ root_ino, "/other", Kind.file });
    var big: [3 * block_size]u8 = @splat(7);
    try writeAt(&fs, other, 0, &big);
    const free_before = fs.vol.free_count;
    const victim = try fs.run(Fs.create, .{ root_ino, "/victim", Kind.file });
    try writeAt(&fs, victim, 0, &big);
    try fs.run(Fs.rename, .{ root_ino, "/other", "/victim" });
    try expectEqual(other, try fs.resolve(root_ino, "/victim"));
    try expectError(error.NotFound, fs.resolve(root_ino, "/other"));
    try expectError(error.NotFound, fs.stat(victim));
    try expectEqual(free_before, fs.vol.free_count);
    // 换掉空目录可以，不空的不行
    _ = try fs.run(Fs.create, .{ root_ino, "/empty", Kind.dir });
    try fs.run(Fs.rename, .{ root_ino, "/b2", "/empty" });
    try expectEqual(f, try fs.resolve(root_ino, "/empty/h"));
    _ = try fs.run(Fs.create, .{ root_ino, "/d2", Kind.dir });
    try expectError(error.NotEmpty, fs.run(Fs.rename, .{ root_ino, "/d2", "/empty" }));
    _ = try fs.check();

    // 出错的情况：都不改任何东西
    const gen = fs.vol.generation;
    try expectError(error.NotFound, fs.run(Fs.rename, .{ root_ino, "/nope", "/x" }));
    try expectError(error.NotFound, fs.run(Fs.rename, .{ root_ino, "/victim", "/nope/x" }));
    try expectError(error.NotDir, fs.run(Fs.rename, .{ root_ino, "/d2", "/victim" })); // 目录换文件
    try expectError(error.IsDir, fs.run(Fs.rename, .{ root_ino, "/victim", "/d2" })); // 文件换目录
    try expectError(error.InvalidName, fs.run(Fs.rename, .{ root_ino, "/empty", "/empty/h2" })); // 挪进自己下面
    try expectError(error.InvalidName, fs.run(Fs.rename, .{ root_ino, "/d2", "/d2/x" }));
    try expectError(error.InvalidName, fs.run(Fs.rename, .{ root_ino, "/", "/x" }));
    try expectError(error.InvalidName, fs.run(Fs.rename, .{ root_ino, "/victim", "/" }));
    try expectError(error.InvalidName, fs.run(Fs.rename, .{ root_ino, "/victim", "/a/.." }));
    try expectError(error.NotDir, fs.run(Fs.rename, .{ root_ino, "/victim", "/victim/x" }));
    const long: [max_name + 1]u8 = @splat('x');
    try expectError(error.NameTooLong, fs.run(Fs.rename, .{ root_ino, "/victim", &long }));
    try expectEqual(gen, fs.vol.generation);
    // 改成自己：什么都不做
    try fs.run(Fs.rename, .{ root_ino, "/victim", "//victim/" });
    try expectEqual(other, try fs.resolve(root_ino, "/victim"));
    // 名字最长 255 字节
    try fs.run(Fs.rename, .{ root_ino, "/victim", long[0..max_name] });
    try expectEqual(other, try fs.resolve(root_ino, long[0..max_name]));
    _ = try fs.check();
}

test "文件内容：内联、长大换成数据块、跨页、洞、覆盖、截断、删除后块都还回来" {
    var fs = try testSetup(512);
    defer testFree();
    try fs.vol.commit();
    const baseline = fs.vol.free_count;
    const f = try fs.run(Fs.create, .{ root_ino, "/f", Kind.file });
    var buf: [5 * block_size]u8 = undefined;

    // 内联：小文件不占数据块
    try writeAt(&fs, f, 0, "hello");
    try writeAt(&fs, f, 3, "LO world");
    try std.testing.expectEqualStrings("helLO world", try readAll(&fs, "/f", &buf));
    try writeAt(&fs, f, 20, "!"); // 中间补 0
    try std.testing.expectEqualStrings("helLO world\x00\x00\x00\x00\x00\x00\x00\x00\x00!", try readAll(&fs, "/f", &buf));
    try std.testing.expect(try fs.page0Inline(f));
    // 正好 inline_max 字节还是内联
    const fill: [inline_max]u8 = @splat('i');
    try writeAt(&fs, f, 21, fill[0 .. inline_max - 21]);
    try std.testing.expectEqual(inline_max, (try fs.stat(f)).size);
    try std.testing.expect(try fs.page0Inline(f));
    // 再长一个字节：换成数据块，内容不变
    try writeAt(&fs, f, inline_max, "+");
    try std.testing.expect(!try fs.page0Inline(f));
    const got = try readAll(&fs, "/f", &buf);
    try std.testing.expectEqual(inline_max + 1, got.len);
    try std.testing.expectEqualStrings("helLO world", got[0..11]);
    try std.testing.expectEqual('+', got[inline_max]);

    // 跨页的写，和中间的洞：写第 0 页末尾到第 1 页开头，再写第 4 页
    var data: [block_size + 100]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 7);
    try writeAt(&fs, f, block_size - 50, &data);
    try writeAt(&fs, f, 4 * block_size + 10, "end");
    try std.testing.expectEqual(4 * block_size + 13, (try fs.stat(f)).size);
    const all = try readAll(&fs, "/f", &buf);
    try std.testing.expectEqualSlices(u8, &data, all[block_size - 50 ..][0..data.len]);
    try std.testing.expect(std.mem.allEqual(u8, all[2 * block_size + 50 .. 4 * block_size + 10], 0)); // 洞
    try std.testing.expectEqualStrings("end", all[4 * block_size + 10 ..]);
    // 第 3 页是洞，不占块（第 2 页写了开头的 50 字节）；读到末尾之后返回 0
    try std.testing.expectEqual(null, try fs.vol.lookup(Fs.extentKey(f, 3), null));
    try std.testing.expect(try fs.vol.lookup(Fs.extentKey(f, 2), null) != null);
    try std.testing.expectEqual(0, try fs.read(f, 10 * block_size, 10, SliceOut{ .buf = &buf }));
    try std.testing.expectEqual(3, try fs.read(f, 4 * block_size + 10, 100, SliceOut{ .buf = &buf }));
    _ = try fs.check();

    // 写到一半“用户内存”坏了：整个写作废，文件不变
    const before = try fs.stat(f);
    var calls: usize = 0;
    try std.testing.expectError(error.BadAddress, fs.run(Fs.write, .{ f, 0, 3 * block_size, FailingIn{ .calls = &calls } }));
    try std.testing.expectEqual(before.size, (try fs.stat(f)).size);
    try std.testing.expectEqualSlices(u8, all, try readAll(&fs, "/f", buf[0..all.len]));
    try std.testing.expectError(error.FileTooBig, fs.run(Fs.write, .{ f, max_file_size, 1, SliceIn{ .data = "x" } }));

    // 截断、再写：又从内联开始；删除文件之后块全还回来
    try fs.run(Fs.truncate, .{f});
    try std.testing.expectEqual(0, (try fs.stat(f)).size);
    try writeAt(&fs, f, 0, "again");
    try std.testing.expect(try fs.page0Inline(f));
    try std.testing.expectEqualStrings("again", try readAll(&fs, "/f", &buf));
    try writeAt(&fs, f, 0, &data);
    try fs.run(Fs.unlink, .{ root_ino, "/f" });
    _ = try fs.check();
    try std.testing.expectEqual(baseline, fs.vol.free_count);
}

test "数据块的校验和：磁盘上的内容坏了读出来是 Corrupt；重新挂载后内容还在" {
    var fs = try testSetup(256);
    defer testFree();
    const f = try fs.run(Fs.create, .{ root_ino, "/big", Kind.file });
    var data: [2 * block_size]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 3);
    try writeAt(&fs, f, 0, &data);
    testReboot();
    fs = try Fs.mount(&test_vol);
    var buf: [2 * block_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &data, try readAll(&fs, "/big", &buf));
    _ = try fs.check();
    // 找到第 1 页的数据块，在磁盘上改一个字节
    var e: BlockExtent = undefined;
    _ = try fs.vol.lookup(Fs.extentKey(f, 1), std.mem.asBytes(&e));
    test_disk[e.blockno][7] ^= 1;
    testReboot();
    fs = try Fs.mount(&test_vol); // 挂载不读数据块
    try std.testing.expectError(error.Corrupt, readAll(&fs, "/big", &buf));
    try std.testing.expectEqual(block_size, try fs.read(f, 0, block_size, SliceOut{ .buf = &buf })); // 第 0 页没坏
}

test "check：数清文件、目录、数据块；磁盘上的数据块坏了，作废缓存之后才查得出来" {
    var fs = try testSetup(256);
    defer testFree();
    _ = try fs.run(Fs.create, .{ root_ino, "/d", Kind.dir });
    _ = try fs.run(Fs.create, .{ root_ino, "/d/e", Kind.dir });
    const small = try fs.run(Fs.create, .{ root_ino, "/d/small", Kind.file });
    const big = try fs.run(Fs.create, .{ root_ino, "/d/e/big", Kind.file });
    _ = try fs.run(Fs.create, .{ root_ino, "/empty", Kind.file });
    try writeAt(&fs, small, 0, "tiny");
    var data: [3 * block_size]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 7);
    try writeAt(&fs, big, 0, &data);
    try writeAt(&fs, big, 10 * block_size, "after a hole"); // 中间是洞
    const st = try fs.check();
    try std.testing.expectEqual(3, st.files);
    try std.testing.expectEqual(3, st.dirs); // 根目录、d、e
    try std.testing.expectEqual(4, st.data_blocks);

    var e: BlockExtent = undefined;
    _ = try fs.vol.lookup(Fs.extentKey(big, 2), std.mem.asBytes(&e));
    test_disk[e.blockno][100] ^= 0x40;
    _ = try fs.check(); // 缓存里还是好的
    bio.invalidate();
    try std.testing.expectError(error.Corrupt, fs.check());
    test_disk[e.blockno][100] ^= 0x40;
    bio.invalidate();
    _ = try fs.check();

    // 树的节点坏了也查得出来（根节点）
    test_disk[fs.vol.root.blockno][200] ^= 1;
    bio.invalidate();
    try std.testing.expectError(error.Corrupt, fs.check());
    test_disk[fs.vol.root.blockno][200] ^= 1;
    bio.invalidate();
    _ = try fs.check();
}

test "硬链接：几个名字一个 inode，删到最后一个才删内容；设备文件只有 inode" {
    const expectEqual = std.testing.expectEqual;
    var fs = try testSetup(256);
    defer testFree();
    const d = try fs.run(Fs.create, .{ root_ino, "/d", Kind.dir });
    const a = try fs.run(Fs.create, .{ root_ino, "/a", Kind.file });
    var data: [3 * block_size]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 7);
    try writeAt(&fs, a, 0, &data);
    const free_with_one = fs.vol.free_count;

    // 链接到另一个目录里：同一个 inode，链接数 2，内容一样，改了两边都看得到
    try fs.run(Fs.link, .{ root_ino, "/a", "/d/b" });
    try expectEqual(a, try fs.resolve(root_ino, "/d/b"));
    try expectEqual(2, (try fs.stat(a)).nlink);
    try writeAt(&fs, a, 5, "XY");
    var buf: [4 * block_size]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "XY", (try readAll(&fs, "/d/b", &buf))[5..7]);
    try expectEqual(free_with_one, fs.vol.free_count); // 链接不复制内容
    _ = try fs.check();

    // 错误：目录不能链接，新名字已经有了，旧名字没有，新名字的目录没有
    try std.testing.expectError(error.IsDirLink, fs.run(Fs.link, .{ root_ino, "/d", "/d2" }));
    try std.testing.expectError(error.Exists, fs.run(Fs.link, .{ root_ino, "/a", "/d/b" }));
    try std.testing.expectError(error.NotFound, fs.run(Fs.link, .{ root_ino, "/nope", "/x" }));
    try std.testing.expectError(error.NotFound, fs.run(Fs.link, .{ root_ino, "/a", "/nope/x" }));
    try std.testing.expectError(error.InvalidName, fs.run(Fs.link, .{ root_ino, "/a", "/d/.." }));

    // rename 到同一个 inode 的另一个名字：什么都不做（和 Unix 一样）
    try fs.run(Fs.rename, .{ root_ino, "/a", "/d/b" });
    try expectEqual(a, try fs.resolve(root_ino, "/a"));
    try expectEqual(2, (try fs.stat(a)).nlink);

    // 删掉一个名字，另一个照常，内容不动
    try fs.run(Fs.unlink, .{ root_ino, "/a" });
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, "/a"));
    try expectEqual(1, (try fs.stat(a)).nlink);
    try expectEqual(data.len, (try readAll(&fs, "/d/b", &buf)).len);
    _ = try fs.check();

    // rename 换掉一个有两个名字的文件：被换掉的只少一个名字
    const c = try fs.run(Fs.create, .{ root_ino, "/c", Kind.file });
    try fs.run(Fs.link, .{ root_ino, "/d/b", "/e" });
    try fs.run(Fs.rename, .{ root_ino, "/c", "/d/b" });
    try expectEqual(c, try fs.resolve(root_ino, "/d/b"));
    try expectEqual(a, try fs.resolve(root_ino, "/e"));
    try expectEqual(1, (try fs.stat(a)).nlink);
    _ = try fs.check();

    // 最后一个名字删掉：inode 和数据块都没了
    try fs.run(Fs.unlink, .{ root_ino, "/e" });
    try std.testing.expectError(error.NotFound, fs.stat(a));
    try std.testing.expect(fs.vol.free_count > free_with_one); // 数据块在 pending 里，提交之后空出来了
    _ = try fs.check();

    // 设备文件：只有 inode，长度 0，可以链接、改名、删除
    const dev = try fs.run(Fs.mknod, .{ root_ino, "/d/null", 2 });
    const st = try fs.stat(dev);
    try expectEqual(Kind.device, st.kind);
    try expectEqual(2, st.major);
    try expectEqual(0, st.size);
    try expectEqual(1, st.nlink);
    try std.testing.expectError(error.Exists, fs.run(Fs.mknod, .{ root_ino, "/d/null", 3 }));
    try std.testing.expectError(error.IsDir, fs.read(dev, 0, 1, SliceOut{ .buf = &buf })); // 读写设备由内核做，不经过文件系统
    try fs.run(Fs.link, .{ root_ino, "/d/null", "/null2" });
    try expectEqual(2, (try fs.stat(dev)).nlink);
    _ = try fs.check();
    try fs.run(Fs.unlink, .{ root_ino, "/d/null" });
    try fs.run(Fs.unlink, .{ root_ino, "/null2" });
    try std.testing.expectError(error.NotFound, fs.stat(dev));
    _ = try fs.check();
    try expectEqual(d, try fs.resolve(root_ino, "/d"));

    // 链接数在重新挂载之后还在
    _ = try fs.run(Fs.create, .{ root_ino, "/p", Kind.file });
    try fs.run(Fs.link, .{ root_ino, "/p", "/q" });
    testReboot();
    fs = try Fs.mount(&test_vol);
    try expectEqual(2, (try fs.stat(try fs.resolve(root_ino, "/q"))).nlink);
    _ = try fs.check();
}

test "符号链接：解析路径时跟着走，unlink/rename/link 对链接自己，环、太长、悬空" {
    const expectEqual = std.testing.expectEqual;
    const expectError = std.testing.expectError;
    var fs = try testSetup(256);
    defer testFree();
    const a = try fs.run(Fs.create, .{ root_ino, "/a", Kind.dir });
    const b = try fs.run(Fs.create, .{ root_ino, "/a/b", Kind.dir });
    const f = try fs.run(Fs.create, .{ root_ino, "/a/b/f", Kind.file });
    try writeAt(&fs, f, 0, "content");
    var buf: [64]u8 = undefined;
    var tbuf: [max_symlink]u8 = undefined;

    // 绝对的、相对的目标；最后一段跟着走，NoFollow 停在链接上
    const l1 = try fs.run(Fs.symlink, .{ root_ino, "/a/b/f", "/abs" });
    const l2 = try fs.run(Fs.symlink, .{ a, "b/f", "rel" }); // 在 /a 里，相对于 /a
    try expectEqual(f, try fs.resolve(root_ino, "/abs"));
    try expectEqual(f, try fs.resolve(root_ino, "/a/rel"));
    try expectEqual(l1, try fs.resolveNoFollow(root_ino, "/abs"));
    try expectEqual(l2, try fs.resolveNoFollow(b, "../rel"));
    try std.testing.expectEqualStrings("content", try readAll(&fs, "/a/rel", &buf));
    try std.testing.expectEqualStrings("b/f", try fs.readlink(l2, &tbuf));
    const st = try fs.stat(l2);
    try expectEqual(Kind.symlink, st.kind);
    try expectEqual(3, st.size);
    try expectError(error.NotSymlink, fs.readlink(f, &tbuf));
    try expectError(error.IsDir, fs.read(l1, 0, 1, SliceOut{ .buf = &buf })); // 读写由调用方先跟着走

    // 中间一段是链接：指向目录，后面接着走；链接后面的 .. 是目标的父目录
    const tob = try fs.run(Fs.symlink, .{ root_ino, "a/b", "/tob" });
    try expectEqual(f, try fs.resolve(root_ino, "/tob/f"));
    try expectEqual(f, try fs.resolve(root_ino, "tob//./f/"));
    try expectEqual(a, try fs.resolve(root_ino, "/tob/.."));
    try expectEqual(tob, try fs.resolveNoFollow(root_ino, "/tob/")); // 后面只有 '/' 也算最后一段
    // 链接的链：/c -> /tob -> a/b
    _ = try fs.run(Fs.symlink, .{ root_ino, "/tob", "/c" });
    try expectEqual(f, try fs.resolve(root_ino, "/c/f"));
    // 在链接后面建东西（resolveParent 跟着走）
    const g = try fs.run(Fs.create, .{ root_ino, "/c/g", Kind.file });
    try expectEqual(b, (try fs.getInode(g)).parent);

    // 悬空的链接：解析是 NotFound，NoFollow 找得到；建文件时建的是它指向的那个
    const d = try fs.run(Fs.symlink, .{ root_ino, "/a/new", "/dangling" });
    try expectError(error.NotFound, fs.resolve(root_ino, "/dangling"));
    try expectEqual(d, try fs.resolveNoFollow(root_ino, "/dangling"));
    const made = try fs.run(Fs.createFollow, .{ root_ino, "/dangling" });
    try expectEqual(made, try fs.resolve(root_ino, "/a/new"));
    try expectEqual(made, try fs.run(Fs.createFollow, .{ root_ino, "/dangling" })); // 有了就返回它
    _ = try fs.run(Fs.symlink, .{ root_ino, "/nodir/x", "/d2" });
    try expectError(error.NotFound, fs.run(Fs.createFollow, .{ root_ino, "/d2" }));
    try expectError(error.Exists, fs.run(Fs.create, .{ root_ino, "/dangling", Kind.file })); // 不跟着走的 create

    // 环：自己指自己、两个互指；跟 max_follows 次可以，多一次不行
    _ = try fs.run(Fs.symlink, .{ root_ino, "/self", "/self" });
    _ = try fs.run(Fs.symlink, .{ root_ino, "/p2", "/p1" });
    _ = try fs.run(Fs.symlink, .{ root_ino, "/p1", "/p2" });
    try expectError(error.SymlinkLoop, fs.resolve(root_ino, "/self"));
    try expectError(error.SymlinkLoop, fs.resolve(root_ino, "/p1/x"));
    try expectError(error.SymlinkLoop, fs.run(Fs.createFollow, .{ root_ino, "/p1" }));
    try expectError(error.SymlinkLoop, fs.run(Fs.create, .{ root_ino, "/p1/x", Kind.file }));
    var name: [8]u8 = undefined;
    var target: [8]u8 = undefined;
    for (0..max_follows + 1) |i| { // /s0 -> /s1 -> ... -> /s10 -> /a/b/f
        const t = if (i == max_follows) "/a/b/f" else try std.fmt.bufPrint(&target, "/s{d}", .{i + 1});
        _ = try fs.run(Fs.symlink, .{ root_ino, t, try std.fmt.bufPrint(&name, "/s{d}", .{i}) });
    }
    try expectEqual(f, try fs.resolve(root_ino, "/s1"));
    try expectError(error.SymlinkLoop, fs.resolve(root_ino, "/s0"));

    // 目标的长度：空的、超长的不行，正好 max_symlink 可以；拼出来的路径超过 max_symlink 是 NameTooLong
    try expectError(error.NotFound, fs.run(Fs.symlink, .{ root_ino, "", "/e" }));
    const long: [max_symlink + 1]u8 = @splat('/');
    try expectError(error.NameTooLong, fs.run(Fs.symlink, .{ root_ino, &long, "/e" }));
    const lmax = try fs.run(Fs.symlink, .{ root_ino, long[0..max_symlink], "/e" });
    try expectEqual(max_symlink, (try fs.readlink(lmax, &tbuf)).len);
    try expectEqual(root_ino, try fs.resolve(root_ino, "/e"));
    try expectError(error.NameTooLong, fs.resolve(root_ino, "/e/a"));
    try expectError(error.Exists, fs.run(Fs.symlink, .{ root_ino, "/x", "/abs" }));
    try expectError(error.InvalidName, fs.run(Fs.symlink, .{ root_ino, "/x", "/" }));
    _ = try fs.check();

    // unlink、rename 对的是链接自己，目标不动；link 链接的也是链接自己
    try fs.run(Fs.rename, .{ root_ino, "/abs", "/a/abs2" });
    try expectEqual(f, try fs.resolve(root_ino, "/a/abs2"));
    try fs.run(Fs.link, .{ root_ino, "/a/abs2", "/hard" });
    try expectEqual(l1, try fs.resolveNoFollow(root_ino, "/hard"));
    try expectEqual(2, (try fs.stat(l1)).nlink);
    try fs.run(Fs.unlink, .{ root_ino, "/a/abs2" });
    try fs.run(Fs.unlink, .{ root_ino, "/hard" });
    try expectError(error.NotFound, fs.stat(l1));
    try expectEqual(1, (try fs.stat(f)).nlink);
    try fs.run(Fs.unlink, .{ root_ino, "/tob" }); // 指向目录的链接像文件一样删，不管目录空不空
    try expectEqual(b, try fs.resolve(root_ino, "/a/b"));
    try expectError(error.NotFound, fs.resolve(root_ino, "/c")); // 链里断了一环
    const stats = try fs.check();
    try expectEqual(19, stats.symlinks); // rel、c、dangling、d2、self、p1、p2、s0..s10、e

    // 重新挂载之后还在
    testReboot();
    fs = try Fs.mount(&test_vol);
    try expectEqual(f, try fs.resolve(root_ino, "/a/rel"));
    try std.testing.expectEqualStrings("b/f", try fs.readlink(l2, &tbuf));
    _ = try fs.check();
}

test "dirPath：目录的路径（getcwd）" {
    var fs = try testSetup(256);
    defer testFree();
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/", try fs.dirPath(root_ino, &out));
    const x = try fs.run(Fs.create, .{ root_ino, "/x", Kind.dir });
    const y = try fs.run(Fs.create, .{ root_ino, "/x/yy", Kind.dir });
    const f = try fs.run(Fs.create, .{ root_ino, "/x/f", Kind.file });
    _ = try fs.run(Fs.create, .{ root_ino, "/x/zz", Kind.dir }); // 同一个目录里别的名字
    try std.testing.expectEqualStrings("/x", try fs.dirPath(x, &out));
    try std.testing.expectEqualStrings("/x/yy", try fs.dirPath(y, &out));
    try std.testing.expectError(error.NotDir, fs.dirPath(f, &out));
    // 经过符号链接到的目录：路径是它真正的位置
    _ = try fs.run(Fs.symlink, .{ root_ino, "/x/yy", "/l" });
    try std.testing.expectEqualStrings("/x/yy", try fs.dirPath(try fs.resolve(root_ino, "/l"), &out));
    // 改名之后跟着变；放不下是 NameTooLong（正好放得下可以）
    try fs.run(Fs.rename, .{ root_ino, "/x", "/renamed" });
    try std.testing.expectEqualStrings("/renamed/yy", try fs.dirPath(y, &out));
    try std.testing.expectError(error.NameTooLong, fs.dirPath(y, out[0..10]));
    try std.testing.expectEqualStrings("/renamed/yy", try fs.dirPath(y, out[0..11]));
    try std.testing.expectError(error.NameTooLong, fs.dirPath(root_ino, out[0..0]));
    // 删掉了的目录
    try fs.run(Fs.unlink, .{ root_ino, "/renamed/yy" });
    try std.testing.expectError(error.NotFound, fs.dirPath(y, &out));
}

/// 测试用的 keep：test_keep_all 为 true 时，每个被删掉最后一个名字的 inode 都“还有人用着”。
var test_keep_all = false;
fn testKeep(ino: u64) bool {
    _ = ino;
    return test_keep_all;
}

test "孤儿：删掉还有人用着的文件只删名字，按 inode 号照常读写；reapOrphan 之后块都还回来；挂载后 reapOrphans" {
    const expectEqual = std.testing.expectEqual;
    var fs = try testSetup(256);
    defer testFree();
    defer test_keep_all = false;
    fs.keep = testKeep;
    const free_empty = fs.vol.free_count;
    const a = try fs.run(Fs.create, .{ root_ino, "/a", Kind.file });
    var data: [3 * block_size]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i * 5);
    try writeAt(&fs, a, 0, &data);
    // 没人用着：照常马上删掉
    try fs.run(Fs.unlink, .{ root_ino, "/a" });
    try std.testing.expectError(error.NotFound, fs.stat(a));
    try expectEqual(free_empty, fs.vol.free_count);

    // 有人用着：只删名字，inode 变成孤儿（链接数 0），按 inode 号还能读写，check 认得它
    test_keep_all = true;
    const b = try fs.run(Fs.create, .{ root_ino, "/b", Kind.file });
    try writeAt(&fs, b, 0, &data);
    try fs.run(Fs.unlink, .{ root_ino, "/b" });
    try std.testing.expectError(error.NotFound, fs.resolve(root_ino, "/b"));
    try expectEqual(0, (try fs.stat(b)).nlink);
    try writeAt(&fs, b, 2 * block_size, "tail");
    var buf: [3 * block_size]u8 = undefined;
    try expectEqual(data.len, try fs.read(b, 0, data.len, SliceOut{ .buf = &buf }));
    try std.testing.expectEqualSlices(u8, "tail", buf[2 * block_size ..][0..4]);
    try expectEqual(1, (try fs.check()).orphans);

    // rename 换掉一个有人用着的文件也一样（/c 原来的 inode 变成孤儿，/c 现在是 e 的第二个名字）；
    // 有两个名字的删掉一个，链接数减 1，不是孤儿
    const c = try fs.run(Fs.create, .{ root_ino, "/c", Kind.file });
    const e = try fs.run(Fs.create, .{ root_ino, "/e", Kind.file });
    try fs.run(Fs.link, .{ root_ino, "/e", "/e2" });
    try fs.run(Fs.link, .{ root_ino, "/e", "/e3" });
    try fs.run(Fs.rename, .{ root_ino, "/e2", "/c" });
    try fs.run(Fs.unlink, .{ root_ino, "/e3" });
    try expectEqual(0, (try fs.stat(c)).nlink);
    try expectEqual(2, (try fs.stat(e)).nlink);
    try expectEqual(2, (try fs.check()).orphans);

    // 用的人放开了：删掉；再删一次、删一个不是孤儿的什么都不做
    try fs.run(Fs.reapOrphan, .{b});
    try std.testing.expectError(error.NotFound, fs.stat(b));
    try fs.run(Fs.reapOrphan, .{b});
    try fs.run(Fs.reapOrphan, .{e});
    try expectEqual(2, (try fs.stat(e)).nlink);
    try expectEqual(1, (try fs.check()).orphans);

    // 重新挂载（上次关机时还有人用着 c）：孤儿还在，reapOrphans 删掉它
    testReboot();
    fs = try Fs.mount(&test_vol);
    try expectEqual(1, (try fs.check()).orphans);
    try expectEqual(1, try fs.run(Fs.reapOrphans, .{}));
    try expectEqual(0, try fs.run(Fs.reapOrphans, .{}));
    try std.testing.expectError(error.NotFound, fs.stat(c));
    try expectEqual(0, (try fs.check()).orphans);
    // 重新挂载得到的 Fs 没有 keep：删掉就是真删
    try fs.run(Fs.unlink, .{ root_ino, "/e" });
    try fs.run(Fs.unlink, .{ root_ino, "/c" });
    try expectEqual(free_empty, fs.vol.free_count);
}

test "check：条目之间对不上的都是 Corrupt" {
    var fs = try testSetup(256);
    defer testFree();
    const d = try fs.run(Fs.create, .{ root_ino, "/d", Kind.dir });
    const f = try fs.run(Fs.create, .{ root_ino, "/d/f", Kind.file });
    const e = try fs.run(Fs.create, .{ root_ino, "/d/e", Kind.dir });
    const dev = try fs.run(Fs.mknod, .{ root_ino, "/d/dev", 2 });
    try writeAt(&fs, f, 0, "hello");
    try fs.run(Fs.link, .{ root_ino, "/d/f", "/f2" });
    const sym = try fs.run(Fs.symlink, .{ root_ino, "f", "/d/sym" });
    _ = try fs.check();
    const v = fs.vol;
    const n = fs.next_ino;
    fs.next_ino += 10;

    // 每一种坏法：在当前事务里改，check 报 Corrupt，再 abort 退回好的状态
    const Bad = enum {
        orphan_inode,
        dangling_entry,
        wrong_parent,
        stray_item,
        extent_past_end,
        two_names,
        missing_link,
        dir_two_links,
        zero_links,
        device_content,
        file_major,
        cycle,
        entry_in_file,
        symlink_no_target,
        symlink_wrong_size,
        symlink_in_block,
        orphan_with_name,
        orphan_dir,
        orphan_missing,
    };
    for (std.enums.values(Bad)) |bad| {
        var entry: [@sizeOf(DirHeader) + 1]u8 = undefined;
        const dirEntry = struct {
            fn make(buf: *[@sizeOf(DirHeader) + 1]u8, ino: u64, kind: Kind) []const u8 {
                @memcpy(buf[0..@sizeOf(DirHeader)], std.mem.asBytes(&DirHeader{ .ino = ino, .kind = kind, .name_len = 1 }));
                buf[@sizeOf(DirHeader)] = 'x';
                return buf;
            }
        }.make;
        const x_key = Key.init(d, type_dir, nameHash("x") << 32);
        switch (bad) {
            // 没有名字的 inode
            .orphan_inode => try v.insert(Key.init(n, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .file, .size = 0, .parent = d })),
            // 目录项指向不存在的 inode
            .dangling_entry => try v.insert(x_key, dirEntry(&entry, n, .file)),
            // 目录的 parent 不是装着它的目录（文件的 parent 不核对：它可能有几个名字）
            .wrong_parent => try v.update(Key.init(e, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .size = 0, .parent = root_ino })),
            // 没有 inode 的条目
            .stray_item => try v.insert(Fs.extentKey(n, 0), std.mem.asBytes(&ExtentHeader{ .kind = .inline_data })),
            // 内容条目在文件长度之外
            .extent_past_end => try v.update(Key.init(f, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .file, .nlink = 2, .size = 0, .parent = d })),
            // 名字比链接数多：f 有两个名字，再加一个
            .two_names => try v.insert(x_key, dirEntry(&entry, f, .file)),
            // 名字比链接数少：f 的链接数改成 3
            .missing_link => try v.update(Key.init(f, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .file, .nlink = 3, .size = 5, .parent = d })),
            // 目录有两个名字（链接数和名字对得上也不行）
            .dir_two_links => {
                try v.update(Key.init(e, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .nlink = 2, .size = 0, .parent = d }));
                try v.insert(Key.init(root_ino, type_dir, nameHash("x") << 32), dirEntry(&entry, e, .dir));
            },
            // 链接数是 0
            .zero_links => try v.update(Key.init(dev, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .device, .major = 2, .nlink = 0, .size = 0, .parent = d })),
            // 设备文件有内容
            .device_content => try v.insert(Fs.extentKey(dev, 0), std.mem.asBytes(&ExtentHeader{ .kind = .inline_data })),
            // 普通文件带着设备号
            .file_major => try v.update(Key.init(f, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .file, .major = 1, .nlink = 2, .size = 5, .parent = d })),
            // 两个目录互为 parent，和根目录断开
            .cycle => {
                try v.insert(Key.init(n, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .size = 0, .parent = n + 1 }));
                try v.insert(Key.init(n + 1, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .size = 0, .parent = n }));
                try v.insert(Key.init(n, type_dir, nameHash("x") << 32), dirEntry(&entry, n + 1, .dir));
                try v.insert(Key.init(n + 1, type_dir, nameHash("x") << 32), dirEntry(&entry, n, .dir));
            },
            // 文件里有目录项
            .entry_in_file => try v.insert(Key.init(f, type_dir, nameHash("x") << 32), dirEntry(&entry, d, .dir)),
            // 符号链接没有目标
            .symlink_no_target => try v.delete(Fs.extentKey(sym, 0)),
            // 符号链接的长度和目标对不上
            .symlink_wrong_size => try v.update(Key.init(sym, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .symlink, .size = 2, .parent = d })),
            // 符号链接的目标在数据块里
            .symlink_in_block => try v.update(Fs.extentKey(sym, 0), std.mem.asBytes(&BlockExtent{ .head = .{ .kind = .block }, .blockno = 2, .generation = 1 })),
            // 孤儿条目指着一个还有名字的 inode
            .orphan_with_name => try v.insert(Key.init(0, type_orphan, f), &.{}),
            // 目录不能是孤儿（链接数 0、有孤儿条目也不行）
            .orphan_dir => {
                try v.update(Key.init(e, type_inode, 0), std.mem.asBytes(&Inode{ .kind = .dir, .nlink = 0, .size = 0, .parent = d }));
                try v.delete(Key.init(d, type_dir, (try fs.scan(d, "e"))[0].?.offset));
                try v.insert(Key.init(0, type_orphan, e), &.{});
            },
            // 孤儿条目指着不存在的 inode
            .orphan_missing => try v.insert(Key.init(0, type_orphan, n), &.{}),
        }
        std.testing.expectError(error.Corrupt, fs.check()) catch |err| {
            std.debug.print("not detected: {s}\n", .{@tagName(bad)});
            return err;
        };
        try v.abort();
        _ = try fs.check();
    }
}

/// 掉电测试：一串随机的文件系统操作（每个操作提交一次），在每一次写盘之后掉电，重新挂载后
/// 检查通过，所有文件的内容正好是某一个操作做完之后的样子，并且不早于最后一个做完了的操作。
/// 有硬链接，几个名字可能是同一个文件：names[i] 是名字 i 指着的文件（files 的下标），没有这个名字是 null。
const FsModel = struct {
    files: [5]std.ArrayListUnmanaged(u8) = @splat(.empty),
    names: [5]?usize = @splat(null),

    fn deinit(m: *FsModel) void {
        for (&m.files) |*f| f.deinit(std.testing.allocator);
    }

    fn clone(m: *const FsModel) !FsModel {
        var c: FsModel = .{ .names = m.names };
        for (&c.files, m.files) |*d, s| d.* = try s.clone(std.testing.allocator);
        return c;
    }

    /// 没有名字指着的文件槽位（名字只有 5 个，一定有）
    fn freeFile(m: *const FsModel) usize {
        for (0..m.files.len) |k| {
            if (std.mem.indexOfScalar(?usize, &m.names, k) == null) return k;
        }
        unreachable;
    }
};

fn fsPath(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "/d/f{d}", .{i}) catch unreachable;
}

const FsCrashRun = struct {
    snapshots: std.ArrayListUnmanaged(FsModel) = .empty,
    completed: u64 = 0,

    fn deinit(r: *FsCrashRun) void {
        for (r.snapshots.items) |*m| m.deinit();
        r.snapshots.deinit(std.testing.allocator);
    }

    /// 事务号 g 对应 snapshots[g - first_gen]
    var first_gen: u64 = 0;

    fn run(r: *FsCrashRun, budget: ?usize) !void {
        var fs = try testSetup(96);
        fs.keep = testKeep;
        _ = try fs.run(Fs.create, .{ root_ino, "/d", Kind.dir });
        var model: FsModel = .{};
        defer model.deinit();
        first_gen = fs.vol.generation;
        try r.snapshots.append(std.testing.allocator, try model.clone());
        r.completed = fs.vol.generation;
        test_budget = budget;
        var prng = std.Random.DefaultPrng.init(9);
        const rng = prng.random();
        var data: [3 * block_size]u8 = undefined;
        for (0..25) |step_no| {
            const i = rng.uintLessThan(usize, model.files.len);
            var pbuf: [16]u8 = undefined;
            const path = fsPath(&pbuf, i);
            // 先记下这一步之后的内容（掉电在提交的那一刻的话，这一步可能算做了）
            var next = try model.clone();
            const gen_before = fs.vol.generation;
            const result = step(&fs, &next, i, path, rng, step_no, &data);
            if (test_crashed) {
                // 这一步的提交可能写下去了
                if (fs.vol.dirty or fs.vol.generation != gen_before) try r.snapshots.append(std.testing.allocator, next) else next.deinit();
                return;
            }
            result catch |err| switch (err) {
                error.NoSpace => {
                    next.deinit();
                    continue;
                },
                else => return err,
            };
            if (fs.vol.generation == gen_before) {
                next.deinit(); // 什么都没改（比如截断一个空文件）
            } else {
                try r.snapshots.append(std.testing.allocator, next);
            }
            model.deinit();
            model = try r.snapshots.items[r.snapshots.items.len - 1].clone();
            r.completed = fs.vol.generation;
        }
    }
};

/// 对名字 i 做一个随机操作（不存在就创建；否则删除、截断、改名成另一个名字 j（j 有的话换掉它）、
/// 给它建一个硬链接（链接到一个还没有的名字），或者在随机位置写一段），同时改 next。
fn step(fs: *Fs, next: *FsModel, i: usize, path: []const u8, rng: std.Random, step_no: usize, data: []u8) !void {
    // 有孤儿的那一遍：时不时把孤儿都删掉（用的人放开了），名字都不变
    if (test_keep_all and step_no % 4 == 3) {
        _ = try fs.run(Fs.reapOrphans, .{});
        return;
    }
    const k = next.names[i] orelse {
        const free = next.freeFile();
        next.files[free].clearRetainingCapacity();
        next.names[i] = free;
        _ = try fs.run(Fs.create, .{ root_ino, path, Kind.file });
        return;
    };
    const ino = try fs.resolve(root_ino, path);
    const f = &next.files[k];
    const j = (i + 1 + rng.uintLessThan(usize, next.names.len - 1)) % next.names.len;
    var jbuf: [16]u8 = undefined;
    switch (rng.uintLessThan(u8, 6)) {
        0 => {
            next.names[i] = null;
            try fs.run(Fs.unlink, .{ root_ino, path });
        },
        4 => {
            next.names[j] = k;
            next.names[i] = null;
            try fs.run(Fs.rename, .{ root_ino, path, fsPath(&jbuf, j) });
        },
        5 => {
            // 链接到一个还没有的名字（都有了就什么都不做）
            const free = std.mem.indexOfScalar(?usize, &next.names, null) orelse return;
            next.names[free] = k;
            try fs.run(Fs.link, .{ root_ino, path, fsPath(&jbuf, free) });
        },
        1 => {
            f.clearRetainingCapacity();
            try fs.run(Fs.truncate, .{ino});
        },
        else => {
            const off = rng.uintAtMost(usize, 2 * block_size);
            const len = 1 + rng.uintLessThan(usize, data.len);
            for (data[0..len], 0..) |*c, x| c.* = @truncate(step_no * 31 + x);
            if (f.items.len < off + len) {
                const old = f.items.len;
                try f.resize(std.testing.allocator, off + len);
                @memset(f.items[old..], 0);
            }
            @memcpy(f.items[off..][0..len], data[0..len]);
            _ = try fs.run(Fs.write, .{ ino, off, len, SliceIn{ .data = data[0..len] } });
        },
    }
}

/// 每个名字的内容和 model 一样；指着同一个文件的名字是同一个 inode，链接数就是名字的个数。
fn fsExpect(fs: *Fs, m: *const FsModel) !void {
    var buf: [6 * block_size]u8 = undefined;
    for (m.names, 0..) |name, i| {
        var pbuf: [16]u8 = undefined;
        const path = fsPath(&pbuf, i);
        const k = name orelse {
            try std.testing.expectError(error.NotFound, fs.resolve(root_ino, path));
            continue;
        };
        try std.testing.expectEqualSlices(u8, m.files[k].items, try readAll(fs, path, &buf));
        const st = try fs.stat(try fs.resolve(root_ino, path));
        try std.testing.expectEqual(std.mem.count(?usize, &m.names, &.{k}), st.nlink);
        for (m.names, 0..) |other, x| {
            if (other != k) continue;
            var obuf: [16]u8 = undefined;
            try std.testing.expectEqual(st.ino, try fs.resolve(root_ino, fsPath(&obuf, x)));
        }
    }
}

test "掉电：文件系统操作之间、写数据块、写节点、写超级块的任何时候掉电，重新挂载后都是某一步做完的样子" {
    try fsCrashAll();
}

test "掉电（删掉的文件都还有人用着）：孤儿和删掉孤儿的事务也一样，重新挂载后 reapOrphans 把块都还回来" {
    test_keep_all = true;
    defer test_keep_all = false;
    try fsCrashAll();
}

/// 完整跑一遍 FsCrashRun 数写了几次盘，再对每一个 N 在第 N 次写之后掉电、重新挂载、核对。
fn fsCrashAll() !void {
    defer testFree();
    var full: FsCrashRun = .{};
    defer full.deinit();
    try full.run(null);
    const total = test_writes;
    try std.testing.expect(total > 60);
    for (0..total + 1) |budget| {
        var r: FsCrashRun = .{};
        defer r.deinit();
        try r.run(budget);
        testReboot();
        var fs = Fs.mount(&test_vol) catch |err| {
            std.debug.print("crash after {d} of {d} writes: mount failed: {s}\n", .{ budget, total, @errorName(err) });
            return err;
        };
        _ = try fs.check();
        const gen = fs.vol.generation;
        try std.testing.expect(gen >= r.completed);
        const idx = gen - FsCrashRun.first_gen;
        try std.testing.expect(idx < r.snapshots.items.len);
        fsExpect(&fs, &r.snapshots.items[idx]) catch |err| {
            std.debug.print("crash after {d} of {d} writes: generation {d}: contents differ\n", .{ budget, total, gen });
            return err;
        };
        // 挂载之后接着写一个新文件：挂载时算漏了哪个块（当成了空闲块），这里就会分配到它、改写它
        const ino = fs.run(Fs.create, .{ root_ino, "/new", Kind.file }) catch |err| switch (err) {
            error.NoSpace => continue,
            else => return err,
        };
        var data: [3 * block_size]u8 = @splat(0xee);
        _ = fs.run(Fs.write, .{ ino, 0, data.len, SliceIn{ .data = &data } }) catch |err| switch (err) {
            error.NoSpace => continue,
            else => return err,
        };
        _ = try fs.check();
        try fsExpect(&fs, &r.snapshots.items[idx]);
    }
}
