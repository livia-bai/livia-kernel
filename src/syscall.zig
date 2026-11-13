//! 系统调用。用户程序执行 ecall 陷入内核后，handleTrap 把它交给 dispatch。
//! 调用约定见 abi.zig。处理期间中断是关着的，系统调用都很短，不会长时间占着 CPU；
//! 要等待的（yield、sleep、read、write 管道、wait）在里面切回调度器，轮到这个进程时再从切走的地方返回。
//!
//! 每个系统调用是 handlers 里同名的一个函数，参数是解码好了的（见 dispatch）：fd 已经换成打开的文件，
//! 用户内存是 UserSlice，出错直接 `try`，dispatch 把错误换成错误码。
//!
//! 文件相关的调用（read、write、close、dup、pipe）照 xv6 的 sysfile.c：fd 是当前进程 fd 表的下标，
//! dispatch 查出 File，再交给 file.zig。

const std = @import("std");
const abi = @import("abi.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const pagecache = @import("pagecache.zig");
const sbi = @import("sbi.zig");
const proc = @import("proc.zig");
const file = @import("file.zig");
const bio = @import("bio.zig");
const fsys = @import("fsys.zig");
const fs = @import("fs.zig");
const kstack = @import("kstack.zig");
const kstat = @import("kstat.zig");
const kstat_mod = kstat; // handlers 里有个同名的 kstat 系统调用
const Fs = fsys.Fs;
const TrapFrame = @import("trap.zig").TrapFrame;

comptime {
    // 符号链接的目标、getcwd 的结果都是路径
    std.debug.assert(fs.max_symlink == abi.max_path);
}

// ---- 分发 ----

/// 用户内存里的一段（abi.Param 的 bytes：长度是字节数；array：长度是元素个数）。只是两个数，内核不能直接解引用，
/// 要经过 vm.copyFromUser、vm.pin* 这些查页表的函数。
const UserSlice = struct { ptr: usize, len: usize };

/// abi.Param 的 fd 解码出来的东西：处理函数要 fd 本身的（close）收这个，只要文件的收 *file.File。
const OpenFd = struct { fd: usize, file: *file.File };

/// exec 成功了：TrapFrame 已经换成新程序的（a0 = argc 由 proc.exec 设好），dispatch 不写 a0。
const Replaced = enum { replaced };

/// 处理调用号在 a7、参数在 a0..a5 的系统调用。返回要写回 a0 的值，null 表示不写（exec 成功）。
///
/// 对每个调用号，在编译期按 abi.params 和 handlers 里同名函数的参数类型生成解码的代码（inline for 展开）：
/// abi.params 说 a0..a5 里依次是什么（整数、fd、用户内存的一段……），处理函数的参数类型说要解码成什么，
/// 两边对不上（个数、种类）编译不过。用户程序的 sys.call 也按同一张 abi.params 放参数，所以参数的个数和顺序
/// 不可能两边不一致。处理函数返回的错误在这里换成错误码（errno）。
pub fn dispatch(frame: *TrapFrame) ?usize {
    kstat.inc(.syscalls);
    const number = frame.regs[17]; // a7
    const regs = frame.regs[10..16]; // a0..a5
    inline for (comptime std.meta.fieldNames(abi.Syscall)) |name| {
        if (number == @backingInt(@field(abi.Syscall, name))) return call(name, regs);
    }
    return abi.fail(.nosys);
}

fn call(comptime name: []const u8, regs: *const [6]usize) ?usize {
    if (!@hasDecl(handlers, name)) @compileError("syscall.handlers has no function for Syscall." ++ name);
    const handler = @field(handlers, name);
    const Args = std.meta.ArgsTuple(@TypeOf(handler));
    const params = comptime abi.paramsOf(name);
    const arg_types = @typeInfo(Args).@"struct".field_types;
    if (arg_types.len != params.len) @compileError(std.fmt.comptimePrint("syscall.handlers.{s} takes {d} parameters, abi.params says {d}", .{ name, arg_types.len, params.len }));
    var args: Args = undefined;
    comptime var reg = 0;
    inline for (params, 0..) |param, i| {
        const n = comptime param.regs();
        args[i] = decode(name, param, arg_types[i], regs[reg..][0..n]) catch |err| return abi.fail(errno(err));
        reg += n;
    }
    const Ret = @typeInfo(@TypeOf(handler)).@"fn".return_type.?;
    if (Ret == noreturn) return @call(.auto, handler, args);
    return result(@call(.auto, handler, args));
}

/// 把一个参数（在 words 这一两个寄存器里，按 param）解码成处理函数要的类型 T。
fn decode(comptime name: []const u8, comptime param: abi.Param, comptime T: type, words: *const [param.regs()]usize) error{ BadFd, InvalidArgument }!T {
    const ok = switch (param) {
        .int => @typeInfo(T) == .int,
        .fd => T == *file.File or T == OpenFd,
        .bytes, .array => T == UserSlice,
        .ptr => T == usize,
    };
    if (!ok) @compileError("syscall.handlers." ++ name ++ ": a parameter of type " ++ @typeName(T) ++ " cannot take abi.Param." ++ @tagName(param));
    const w = words[0];
    return switch (param) {
        .int => if (@typeInfo(T).int.signedness == .signed)
            @as(T, @truncate(@as(isize, @bitCast(w)))) // 有符号的按补码理解（sbrk 的增量、lseek 的偏移）
        else
            std.math.cast(T, w) orelse error.InvalidArgument, // 窄的无符号整数（设备号）：放不下是 EINVAL
        .fd => blk: {
            const f = fileOf(w) orelse return error.BadFd;
            break :blk if (T == OpenFd) OpenFd{ .fd = w, .file = f } else f;
        },
        .bytes, .array => UserSlice{ .ptr = w, .len = words[1] },
        .ptr => w,
    };
}

/// 处理函数的返回值换成 a0 的值：错误换成错误码，void 是 0，Replaced 是不写。
fn result(r: anytype) ?usize {
    const R = @TypeOf(r);
    return switch (@typeInfo(R)) {
        .error_union => result(r catch |err| return abi.fail(errno(err))),
        .void => 0,
        .bool => @intFromBool(r),
        .int => @intCast(r),
        .optional => if (r) |v| result(v) else 0,
        else => if (R == Replaced) null else @compileError("syscall: a handler cannot return " ++ @typeName(R)),
    };
}

// ---- 错误码 ----

/// 错误换成错误码。和 abi.Error 里的错误同名的（NotFound、BadAddress……）直接换成那个错误码（abi.errnoNamed）；
/// 内核里别的名字在 aliases 里说明换成哪个。两边都没有的错误编译不过：新加的错误不会悄悄变成 EIO
/// （在这个内核里 EIO 的意思是“磁盘上的数据不对”）。err 的错误集是什么都行。
fn errno(err: anytype) abi.Errno {
    switch (err) {
        inline else => |e| {
            const name = @errorName(e);
            if (comptime abi.errnoNamed(name)) |code| return code;
            if (!@hasField(@TypeOf(aliases), name)) @compileError("no errno for error." ++ name ++ ": add it to syscall.aliases");
            return @field(aliases, name);
        },
    }
}

/// 内核里和 abi.Error 不同名的错误换成哪个错误码。
const aliases = .{
    // 文件系统（fs.Error、ctree.Error）
    .InvalidName = .inval, // 空名字、"."、".."
    .NotSymlink = .inval, // readlink 的不是符号链接
    .IsDirLink = .perm, // 给目录建硬链接
    // 磁盘上的东西不对：校验和、结构（Corrupt），没有能用的超级块，块号超出磁盘（指针坏了），
    // 条目的数据太大（只能是树坏了：fs.zig 自己不会写这么大的条目）
    .Corrupt = .io,
    .NotFormatted = .io,
    .DiskTooLarge = .io,
    .OutOfRange = .io,
    .TooBig = .io,
    // 打开的文件（file.Error）：方向不对
    .NotReadable = .badf,
    .NotWritable = .badf,
    // exec
    .NoSuchProgram = .noent,
    // 保存的快照满了
    .TooManySnapshots = .nospc,
};

/// fd 对应的打开的文件，fd 超出范围或者没有打开时返回 null。
fn fileOf(fd: usize) ?*file.File {
    if (fd >= abi.max_fds) return null;
    return proc.current().?.files[fd];
}

/// 当前进程最小的空闲 fd，指向 f（f 的引用已经算好了）。fd 表满了是 TooManyOpenFiles，f 的引用放掉。
fn installFd(f: *file.File) error{TooManyOpenFiles}!usize {
    const files = &proc.current().?.files;
    for (files, 0..) |*slot, fd| {
        if (slot.* == null) {
            slot.* = f;
            return fd;
        }
    }
    file.close(f);
    return error.TooManyOpenFiles;
}

fn space() *vm.Space {
    return &proc.current().?.space;
}

/// 把用户给的路径复制进 buf。
fn userPath(p: UserSlice, buf: *[abi.max_path]u8) error{ NameTooLong, BadAddress }![]const u8 {
    if (p.len > buf.len) return error.NameTooLong;
    try vm.copyFromUser(space(), buf[0..p.len], p.ptr);
    return buf[0..p.len];
}

fn copyOut(ptr: usize, value: anytype) error{BadAddress}!void {
    try vm.copyToUser(space(), ptr, std.mem.asBytes(value));
}

/// 原始区域的第 blockno 块在磁盘上是第几块（fsys.raw_base 起）。块号超出原始区域是 InvalidArgument
/// （不是 OutOfRange：那是文件系统里的指针坏了，EIO）。通过了这里，bio 就不会再报 NoDevice、OutOfRange。
fn rawBlock(blockno: usize) error{ NoDevice, InvalidArgument }!u64 {
    if (fsys.raw_count == 0) return error.NoDevice;
    if (blockno >= fsys.raw_count) return error.InvalidArgument;
    return fsys.raw_base + blockno;
}

fn abiStat(s: fs.Stat) abi.Stat {
    return .{ .ino = s.ino, .size = s.size, .kind = @fromBackingInt(@backingInt(s.kind)), .major = s.major, .nlink = s.nlink };
}

/// 找到（或者建好、截断）要打开的 inode，返回它的 Stat。root 是读者的话 flags 里不会有要改文件系统的（见 open）。
/// 跟着符号链接走；没有并且带 open_create 时建文件，最后一段是悬空的符号链接的话建的是它指向的那个（createFollow）。
/// 正在运行的程序文件不能截断（TextBusy，见 fsys.hold）。
fn openPath(root: *Fs, cwd: u64, path: []const u8, flags: usize, writable: bool) (fs.Error || error{TextBusy})!fs.Stat {
    const ino = root.resolve(cwd, path) catch |err| switch (err) {
        error.NotFound => if (flags & abi.open_create != 0) return root.stat(try root.run(Fs.createFollow, .{ cwd, path })) else return err,
        else => return err,
    };
    const st = try root.stat(ino);
    if (st.kind == .dir and writable) return error.IsDir;
    if (flags & abi.open_trunc != 0 and writable and st.size > 0) { // 设备、目录的 size 是 0
        try fsys.beginModify(ino);
        defer fsys.endModify();
        try root.run(Fs.truncate, .{ino});
    }
    return st;
}

/// 只读地按路径找东西（lstat、readlink）：/.snap/编号/... 在那个快照上从根目录找（占住它），别的在最新的快照上从当前目录找。
const PathReader = struct {
    r: fsys.Reader,
    cwd: u64,
    path: []const u8,
    snap: ?u64,

    fn init(path: []const u8) !PathReader {
        if (fsys.snapPath(path)) |sp| {
            const s = try fsys.openSnap(sp.generation);
            return .{ .r = fsys.snapReader(s), .cwd = fs.root_ino, .path = if (sp.rest.len == 0) "/" else sp.rest, .snap = sp.generation };
        }
        return .{ .r = try fsys.reader(), .cwd = proc.current().?.cwd, .path = path, .snap = null };
    }

    fn end(p: *PathReader) void {
        p.r.end();
        if (p.snap) |g| fsys.releaseSnap(g);
    }
};

// ---- 每个系统调用 ----

/// abi.Syscall 的每个调用一个同名的函数，参数按 abi.params 解码好（见 dispatch）。
const handlers = struct {
    pub fn exit(code: usize) noreturn {
        proc.exit(@truncate(code)); // 和 Unix 一样只取低 8 位
    }

    pub fn getpid() usize {
        return proc.currentPid();
    }

    pub fn getppid() usize {
        return proc.parentPid();
    }

    pub fn uptime() u64 {
        return timer.uptimeMs();
    }

    pub fn yield() void {
        proc.yield();
    }

    /// 睡至少 ms 毫秒（饱和，ms 再大也不溢出）：按到期时刻排进 timer 的 sleepers，到期时的时钟中断叫醒（timer.sleepUntil）。
    /// 被 kill 了就提前返回，回到陷阱处理程序后结束。
    pub fn sleep(ms: usize) void {
        timer.sleepUntil(timer.now() +| timer.fromMs(ms));
    }

    /// 写 fd。中途遇到坏地址就停下，返回已经写出的字节数；一个字节都没写出才返回错误（见 file.write）。
    /// 用户内存是拿着锁（串口的输出锁、管道的锁、文件系统的写锁）复制的，那时不能缺页：先 pin 好能读的开头那一段。
    pub fn write(f: *file.File, data: UserSlice) file.Error!usize {
        return file.write(f, vm.pinSrcPrefix(space(), data.ptr, data.len), data.len);
    }

    /// 读 fd。先 pin 整个目标范围（检查可写、准备好每一页）：从串口的缓冲区取出来的字符放不回去，不能取出来之后才发现写不进去；
    /// 之后拿着锁写进去时也不能缺页。pin 之前先按文件的种类把长度截到这一次最多能读到的量（file.readLimit）：只准备真会写到的页。
    pub fn read(f: *file.File, buf: UserSlice) !usize {
        if (buf.len == 0) return 0;
        return file.read(f, try vm.pinDst(space(), buf.ptr, file.readLimit(f, buf.len)));
    }

    pub fn close(fd: OpenFd) void {
        proc.current().?.files[fd.fd] = null;
        file.close(fd.file);
    }

    pub fn dup(f: *file.File) !usize {
        return installFd(file.dup(f));
    }

    /// 创建管道，把读端、写端的 fd 写进 fds_ptr（两个 u32）。任何一步失败都把已经做了的撤销掉。
    pub fn pipe(fds_ptr: usize) !void {
        // 先 pin 好：fd 装进 fd 表以后再失败，就要再一个个撤销
        const dst = try vm.pinDst(space(), fds_ptr, 2 * @sizeOf(u32));
        const r, const w = try file.openPipe();
        const rfd = installFd(r) catch |err| {
            file.close(w);
            return err;
        };
        const wfd = installFd(w) catch |err| {
            close(.{ .fd = rfd, .file = r });
            return err;
        };
        const fds = [2]u32{ @intCast(rfd), @intCast(wfd) };
        dst.copyOut(0, std.mem.asBytes(&fds));
    }

    pub fn sbrk(increment: isize) !usize {
        return proc.sbrk(increment);
    }

    pub fn blockcount() u64 {
        return fsys.raw_count;
    }

    /// 读原始区域的一块到用户内存。拿着缓冲区的睡眠锁复制，所以先 pin 好目标。
    pub fn readblock(blockno: usize, ptr: usize) !void {
        const dst = try vm.pinDst(space(), ptr, abi.block_size);
        const b = bio.read(try rawBlock(blockno)) catch |err| switch (err) {
            error.IoError => return error.IoError,
            error.NoDevice, error.OutOfRange => unreachable, // rawBlock 检查过了
        };
        defer bio.release(b);
        dst.copyOut(0, b.data);
    }

    /// 用户内存的一块写到磁盘。整块覆盖，不用先读；先 pin 好来源：拿着缓冲区的睡眠锁复制，而且复制到一半失败的话
    /// 缓冲区里会留下半新半旧的内容。
    pub fn writeblock(blockno: usize, ptr: usize) !void {
        const src = try vm.pinSrc(space(), ptr, abi.block_size);
        const b = bio.get(try rawBlock(blockno)) catch unreachable; // rawBlock 检查过了
        defer bio.release(b);
        src.copyIn(0, b.data);
        b.valid = true;
        try bio.write(b);
    }

    /// 打开路径 path，返回 fd（见 abi.Syscall.open）。
    pub fn open(path_arg: UserSlice, flags: usize) !usize {
        const access = flags & 3;
        if (access == 3 or flags & ~(3 | abi.open_create | abi.open_trunc | abi.open_append) != 0) return error.InvalidArgument;
        const readable = access != abi.open_write;
        const writable = access != abi.open_read;
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        if (fsys.snapPath(path)) |sp| return openInSnap(sp.generation, sp.rest, flags, writable);
        const cwd = proc.current().?.cwd;
        // 可能要建文件、截断的才拿写锁，只是打开已有的文件在快照上找
        const modifies = flags & abi.open_create != 0 or (flags & abi.open_trunc != 0 and writable);
        const st = if (modifies) blk: {
            const root = try fsys.writer();
            defer fsys.unlock();
            break :blk try openPath(root, cwd, path, flags, writable);
        } else blk: {
            var r = try fsys.reader();
            defer r.end();
            break :blk try openPath(&r.fs, cwd, path, flags, writable);
        };
        // 占住 inode（之后删掉它的名字只会让它变成孤儿，fsys.hold），再在新的快照上确认它还在：
        // 找到它的那个快照可能已经旧了，在那之后它被删掉的话，占住它也没用
        try fsys.hold(st.ino, .open);
        {
            var r = fsys.reader() catch |err| {
                fsys.release(st.ino, .open);
                return err;
            };
            defer r.end();
            _ = r.fs.stat(st.ino) catch |err| {
                fsys.release(st.ino, .open);
                return err;
            };
        }
        // 设备文件：读写交给设备，文件系统里只有它的 inode。File 接过占用，最后一个 fd 关掉时放开（file.close）
        const f = (if (st.kind == .device)
            file.openDevice(st.ino, @fromBackingInt(st.major), readable, writable)
        else
            file.openInode(st.ino, readable, writable, flags & abi.open_append != 0, null)) catch |err| {
            fsys.release(st.ino, .open);
            return err;
        };
        return installFd(f);
    }

    /// 打开保存的快照 generation 里的 rest（/.snap/编号/...）：只读。占住这个快照，File 接过这份占用。
    fn openInSnap(generation: u64, rest: []const u8, flags: usize, writable: bool) !usize {
        if (writable or flags & (abi.open_create | abi.open_trunc | abi.open_append) != 0) return error.ReadOnly;
        const s = try fsys.openSnap(generation);
        const f = blk: {
            errdefer fsys.releaseSnap(generation);
            var r = fsys.snapReader(s);
            const ino = try r.fs.resolve(fs.root_ino, if (rest.len == 0) "/" else rest);
            if ((try r.fs.stat(ino)).kind == .device) return error.ReadOnly; // 设备文件只在当前的文件系统里打开
            break :blk try file.openInode(ino, true, false, false, s);
        };
        return installFd(f);
    }

    /// 把文件系统现在（最后一次提交）的样子保存成快照，返回编号。
    pub fn snapshot() !u64 {
        return fsys.createSnap();
    }

    /// 保存的快照的编号写进用户的 u64 数组，返回一共有几个。
    pub fn snaplist(out: UserSlice) !usize {
        var ids: [@import("ctree.zig").max_snaps]u64 = undefined;
        const n = try fsys.listSnaps(&ids);
        const m = @min(n, out.len, ids.len);
        try vm.copyToUser(space(), out.ptr, std.mem.sliceAsBytes(ids[0..m]));
        return n;
    }

    pub fn snapdel(generation: u64) !void {
        try fsys.deleteSnap(generation);
    }

    pub fn mkdir(path_arg: UserSlice) !void {
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        const root = try fsys.writer();
        defer fsys.unlock();
        _ = try root.run(Fs.create, .{ proc.current().?.cwd, path, .dir });
    }

    pub fn unlink(path_arg: UserSlice) !void {
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        const cwd = proc.current().?.cwd;
        const root = try fsys.writer();
        defer fsys.unlock();
        // 删掉最后一个名字时，还有人用着就留下孤儿（fsys.keepInUse），否则记下 removing：做完清掉
        defer fsys.endModify();
        try root.run(Fs.unlink, .{ cwd, path });
    }

    pub fn chdir(path_arg: UserSlice) !void {
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        const p = proc.current().?;
        var r = try fsys.reader();
        defer r.end();
        const ino = try r.fs.resolve(p.cwd, path);
        if ((try r.fs.stat(ino)).kind != .dir) return error.NotDir;
        p.cwd = ino;
    }

    /// 两个路径都先复制进内核，再拿着文件系统的写锁一个事务改名（fs.Fs.rename）。
    /// 新名字已经有了的话它被换掉，和 unlink 一样：还有人用着就留下孤儿。
    pub fn rename(old_arg: UserSlice, new_arg: UserSlice) !void {
        var old_buf: [abi.max_path]u8 = undefined;
        var new_buf: [abi.max_path]u8 = undefined;
        const old = try userPath(old_arg, &old_buf);
        const new = try userPath(new_arg, &new_buf);
        const cwd = proc.current().?.cwd;
        const root = try fsys.writer();
        defer fsys.unlock();
        defer fsys.endModify();
        try root.run(Fs.rename, .{ cwd, old, new });
    }

    /// 硬链接：两个路径都先复制进内核，再拿着写锁一个事务做完（fs.Fs.link）。
    pub fn link(old_arg: UserSlice, new_arg: UserSlice) !void {
        var old_buf: [abi.max_path]u8 = undefined;
        var new_buf: [abi.max_path]u8 = undefined;
        const old = try userPath(old_arg, &old_buf);
        const new = try userPath(new_arg, &new_buf);
        const root = try fsys.writer();
        defer fsys.unlock();
        try root.run(Fs.link, .{ proc.current().?.cwd, old, new });
    }

    /// 建设备文件。设备号是 u16（放不下 dispatch 就返回 EINVAL）、不能是 0；不认识的设备号也能建（打开时才报 ENXIO，和 Unix 一样）。
    pub fn mknod(path_arg: UserSlice, major: u16) !void {
        if (major == 0) return error.InvalidArgument;
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        const root = try fsys.writer();
        defer fsys.unlock();
        _ = try root.run(Fs.mknod, .{ proc.current().?.cwd, path, major });
    }

    /// 建符号链接：两个路径都先复制进内核，再拿着写锁一个事务做完（fs.Fs.symlink）。target 原样存下，不检查它在不在。
    pub fn symlink(target_arg: UserSlice, path_arg: UserSlice) !void {
        var target_buf: [abi.max_path]u8 = undefined;
        var path_buf: [abi.max_path]u8 = undefined;
        const target = try userPath(target_arg, &target_buf);
        const path = try userPath(path_arg, &path_buf);
        const root = try fsys.writer();
        defer fsys.unlock();
        _ = try root.run(Fs.symlink, .{ proc.current().?.cwd, target, path });
    }

    /// 符号链接的目标写进用户内存，放不下就截断（和 Linux 一样），返回写了几个字节。在快照上读。
    pub fn readlink(path_arg: UserSlice, out: UserSlice) !usize {
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        var at = try PathReader.init(path);
        defer at.end();
        const ino = try at.r.fs.resolveNoFollow(at.cwd, at.path);
        const r = &at.r;
        var target: [fs.max_symlink]u8 = undefined;
        const t = try r.fs.readlink(ino, &target);
        const n = @min(t.len, out.len);
        try vm.copyToUser(space(), out.ptr, t[0..n]);
        return n;
    }

    /// 当前目录的绝对路径（fs.Fs.dirPath，沿着 parent 往上找名字），在快照上找。
    pub fn getcwd(out: UserSlice) !usize {
        var r = try fsys.reader();
        defer r.end();
        var buf: [abi.max_path]u8 = undefined;
        const path = r.fs.dirPath(proc.current().?.cwd, &buf) catch |err| return switch (err) {
            error.NameTooLong => error.BufferTooSmall, // 比 max_path 还长：用户的缓冲区不会比它大，当作放不下
            else => err,
        };
        if (path.len > out.len) return error.BufferTooSmall;
        try vm.copyToUser(space(), out.ptr, path);
        return path.len;
    }

    /// path 自己（是符号链接的话不跟着走）的 Stat。
    pub fn lstat(path_arg: UserSlice, ptr: usize) !void {
        var buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &buf);
        var at = try PathReader.init(path);
        defer at.end();
        const ino = try at.r.fs.resolveNoFollow(at.cwd, at.path);
        try copyOut(ptr, &abiStat(try at.r.fs.stat(ino)));
    }

    pub fn lseek(f: *file.File, offset: i64, whence: usize) !u64 {
        return file.seek(f, offset, whence);
    }

    pub fn fstat(f: *file.File, ptr: usize) !void {
        var st: abi.Stat = .{ .ino = 0, .size = 0, .kind = if (f.open.target == .pipe) .pipe else .console };
        if (file.inodeOf(f)) |ino| {
            var r = try fsys.readerFor(switch (f.open.target) {
                .inode => |i| i.snap,
                else => null,
            });
            defer r.end();
            st = abiStat(try r.fs.stat(ino));
        }
        try copyOut(ptr, &st);
    }

    /// 目录 fd 的下一个目录项：读写位置 off 就是 fs.readdir 的 cookie。返回 true；列完了返回 false。
    /// 拿着 pos_lock 写进用户内存（先 pin 好），共用这个 fd 的进程不会拿到同一项；在快照上找。
    pub fn readdir(f: *file.File, ptr: usize) !bool {
        const dir = switch (f.open.target) {
            .inode => |*i| i,
            else => return error.NotDir,
        };
        const dst = try vm.pinDst(space(), ptr, @sizeOf(abi.Dirent));
        f.pos_lock.acquire();
        defer f.pos_lock.release();
        var r = try fsys.readerFor(dir.snap);
        defer r.end();
        var ent: abi.Dirent = undefined;
        const d = try r.fs.readdir(dir.ino, dir.off, &ent.name) orelse return false;
        ent.ino = d.ino;
        ent.kind = @fromBackingInt(@backingInt(d.kind));
        ent.name_len = @intCast(d.name_len);
        ent._pad = @splat(0);
        @memset(ent.name[d.name_len..], 0);
        dst.copyOut(0, std.mem.asBytes(&ent));
        dir.off = d.next;
        return true;
    }

    /// 检查整个文件系统（fs.Fs.check）。先作废缓冲区缓存：要核对的是磁盘上的内容，校验和只在读盘时核对。
    /// 拿着文件系统的写锁：没有做到一半的修改，当前的树就是已提交的树。读者照常读（它们只会把块读进缓存）。
    pub fn scrub(ptr: usize) !void {
        const dst = try vm.pinDst(space(), ptr, @sizeOf(abi.ScrubInfo));
        const root = try fsys.writer();
        defer fsys.unlock();
        bio.invalidate();
        const st = try root.check();
        const info: abi.ScrubInfo = .{
            .files = st.files,
            .devices = st.devices,
            .symlinks = st.symlinks,
            .dirs = st.dirs,
            .data_blocks = st.data_blocks,
            .nodes = st.tree.nodes,
            .items = st.tree.items,
            .height = st.tree.height,
            .free_blocks = root.vol.free_count,
            .blocks = root.vol.blocks,
            .generation = root.vol.generation,
            .orphans = st.orphans,
        };
        dst.copyOut(0, std.mem.asBytes(&info)); // 拿着写锁
    }

    pub fn fork() !usize {
        return proc.fork();
    }

    /// 把程序的路径和命令行参数都复制进内核（参数放在栈上的 buf 里），再交给 proc.exec：
    /// 参数在旧的地址空间里，换掉地址空间之前就要取出来。成功时 TrapFrame 已经换成新程序的，
    /// a0 = argc 也设好了（proc.startFrame），返回 Replaced，dispatch 不再写 a0。
    pub fn exec(path_arg: UserSlice, argv_arg: UserSlice) !Replaced {
        var path_buf: [abi.max_path]u8 = undefined;
        const path = try userPath(path_arg, &path_buf);
        const argc = argv_arg.len;
        if (argc > abi.max_args) return error.ArgsTooLong;
        var argv: [abi.max_args]abi.Arg = undefined;
        try vm.copyFromUser(space(), std.mem.sliceAsBytes(argv[0..argc]), argv_arg.ptr);
        var buf: [abi.max_arg_bytes]u8 = undefined;
        var args: [abi.max_args][]const u8 = undefined;
        var used: usize = 0;
        for (argv[0..argc], args[0..argc]) |a, *arg| {
            if (a.len > buf.len - used) return error.ArgsTooLong;
            const dst = buf[used..][0..a.len];
            try vm.copyFromUser(space(), dst, a.ptr);
            arg.* = dst;
            used += a.len;
        }
        try proc.exec(path, args[0..argc]);
        return .replaced;
    }

    /// 等子进程结束，把结束状态写进 status_ptr（不为 0 时），回收它，返回它的 pid（见 proc.wait）；nohang 时没有就是 0。
    /// 状态是拿着锁写的，所以先 pin 好；写不进去就是 -EFAULT，什么都没回收：子进程还在，可以再 wait 一次。
    pub fn wait(pid: usize, status_ptr: usize, options: usize) !usize {
        if (options & ~abi.wait_nohang != 0) return error.InvalidArgument;
        const status = if (status_ptr == 0) null else try vm.pinDst(space(), status_ptr, @sizeOf(u32));
        return try proc.wait(pid, options & abi.wait_nohang != 0, status) orelse 0;
    }

    pub fn kill(pid: usize) !void {
        try proc.kill(pid, "kill()");
    }

    pub fn setfg(pid: usize) !void {
        try proc.setForeground(pid);
    }

    /// 把进程表里每个在用的槽位写成一个 ProcInfo，最多写 out.len 个，返回进程总数（可能比 out.len 大）。
    /// 每个槽位单独拿锁取一份（proc.info），不是同一瞬间的快照：别的 hart 上的进程可能正在 fork、结束。
    pub fn procinfo(out: UserSlice) !usize {
        var count: usize = 0;
        for (0..proc.max_procs) |i| {
            const info = proc.info(i) orelse continue;
            if (count < out.len) {
                const va = std.math.add(usize, out.ptr, count * @sizeOf(abi.ProcInfo)) catch return error.BadAddress;
                try copyOut(va, &info);
            }
            count += 1;
        }
        return count;
    }

    pub fn meminfo(ptr: usize) !void {
        const c = pagecache.counts();
        try copyOut(ptr, &abi.MemInfo{ .free_pages = page.freePages() + c.reclaimable, .total_pages = page.total_pages, .page_size = page.size, .cached_pages = c.cached });
    }

    /// 内核的计数器和栈的高水位（kstat.zig、kstack.deepest）。
    pub fn kstat(ptr: usize) !void {
        const u = kstack.deepest();
        try copyOut(ptr, &abi.KStat{
            .counters = kstat_mod.sum(),
            .stack_process = u.process,
            .stack_process_size = kstack.Process.stack_size,
            .stack_boot = u.boot,
            .stack_boot_size = kstack.Boot.stack_size,
            .stack_trap = u.trap,
            .stack_trap_size = kstack.Trap.stack_size,
        });
    }

    /// 关机之前打印各种内核栈用到过的最深处（kstack.deepest），qemu_test.py 检查它们离栈底还有足够的余量。
    pub fn shutdown() noreturn {
        const u = kstack.deepest();
        uart.print("[stack] deepest use: process {d} of {d}, boot {d} of {d}, trap {d} of {d} bytes\n", .{
            u.process, kstack.Process.stack_size, u.boot, kstack.Boot.stack_size, u.trap, kstack.Trap.stack_size,
        });
        sbi.shutdown();
    }
};
