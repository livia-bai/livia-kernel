//! 内核里的文件系统：唯一的一个 Volume，第一个进程启动时挂载（xv6 在 forkret 里调用 fsinit）。
//! 文件系统本身的逻辑在 fs.zig；这里是内核这一侧：加锁、用户内存、错误码、打开的文件（file.zig 的 .inode）。
//!
//! - **读**（read、fstat、lstat、readdir、readlink、getcwd、lseek、chdir、不建不截的 open、exec 加载程序）不拿锁：reader() 拿一个
//!   已提交的树的快照（ctree 的 beginRead），在它上面读，读完 end()。几个读者、读者和修改的一方都同时进行；
//!   读者看到的是开始读时最近一次提交的样子，修改的一方做到一半的东西看不到。
//! - **修改**（write、mkdir、unlink、rename、link、symlink、mknod、建文件、截断、scrub）拿 write_lock（睡眠锁）：
//!   B 树同一时刻只能有一个事务，所以修改之间还是一个一个来。每个修改是一个事务（fs.Fs.run）：
//!   成功就提交，出错就作废。
//! - 加锁顺序：File.pos_lock → write_lock → 缓冲区的睡眠锁。拿着快照时不能去等 pos_lock、write_lock：
//!   修改的一方可能拿着它们在等旧树的读者读完（ctree 的 limbo）。
//! - 磁盘的前一部分是文件系统（超级块里记着它有多少块），后一部分是原始区域，
//!   readblock/writeblock 系统调用只能读写原始区域（块号从原始区域的开头算），碰不到文件系统。
//!   磁盘上没有文件系统时整个磁盘都是原始区域。
//! - 正在运行的程序文件（按需分页从它读页）不能改、不能删：holdText 占住它，改它的一方（beginModify）
//!   得到 TextBusy（和 Linux 的 ETXTBSY 一样）；正在被改的文件也不能开始运行。

const std = @import("std");
const abi = @import("abi.zig");
const fs = @import("fs.zig");
const ctree = @import("ctree.zig");
const bio = @import("bio.zig");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const Sleeplock = @import("sleeplock.zig").Sleeplock;
const Spinlock = @import("spinlock.zig").Spinlock;

pub const Fs = fs.Fs;

var vol: ctree.Volume = .{};
/// 挂载好的文件系统（修改的一方用它）。mounted 为 false 时没有。
/// 两者都只在 init 里写一次，那时别的进程还没有，之后只读，所以读者不拿锁读它们
var root: fs.Fs = undefined;
pub var mounted = false;
/// 修改的一方拿着它（见文件开头），也保护 root.next_ino
var write_lock: Sleeplock = .init("fs write", .fs_write);

/// 原始区域：磁盘上文件系统之后的块
pub var raw_base: u64 = 0;
pub var raw_count: u64 = 0;

/// 挂载磁盘上的文件系统。第一个进程（init）第一次进入 U 模式之前调用一次（proc.forkretC）：
/// 读盘要睡着等，只有进程能做，kmain 不行。
pub fn init() void {
    raw_count = bio.blockCount();
    if (raw_count == 0) return;
    write_lock.acquire();
    defer write_lock.release();
    root = Fs.mount(&vol) catch |err| {
        uart.print("[warn] no file system on the disk: {s}\n", .{@errorName(err)});
        return;
    };
    mounted = true;
    raw_base = vol.blocks;
    raw_count -= vol.blocks;
    uart.print("[ok] file system: {d} of {d} blocks free, generation {d}\n", .{ vol.free_count, vol.blocks, vol.generation });
}

/// 读者：一个快照上的只读 Fs。用完调用 end。
pub const Reader = struct {
    fs: Fs,
    snap: ctree.Snapshot,

    pub fn end(r: *Reader) void {
        vol.endRead(r.snap);
    }
};

/// 开始读：拿最近一次提交的快照。没挂载是 NoDevice。
pub fn reader() error{NoDevice}!Reader {
    if (!mounted) return error.NoDevice;
    const snap = vol.beginRead();
    return .{ .fs = .{ .vol = &vol, .next_ino = 0, .view = snap.root }, .snap = snap };
}

/// 开始修改：拿着 write_lock、确认挂载了，返回文件系统。调用方用完 unlock。
pub fn writer() error{NoDevice}!*Fs {
    if (!mounted) return error.NoDevice;
    write_lock.acquire();
    return &root;
}

pub fn unlock() void {
    write_lock.release();
}

/// fs.read 的 out：写进内核内存。
pub const KernelOut = struct {
    buf: []u8,
    pub fn put(o: KernelOut, at: usize, bytes: []const u8) error{}!void {
        @memcpy(o.buf[at..][0..bytes.len], bytes);
    }
};

/// fs.read 的 out：写进用户地址空间 space 的 ptr 开始的地方。
pub const UserOut = struct {
    space: *vm.Space,
    ptr: usize,
    pub fn put(o: UserOut, at: usize, bytes: []const u8) error{BadAddress}!void {
        const va = std.math.add(usize, o.ptr, at) catch return error.BadAddress;
        try vm.copyToUser(o.space, va, bytes);
    }
};

/// fs.write 的 in：从用户地址空间 space 的 ptr 开始的地方取。
pub const UserIn = struct {
    space: *vm.Space,
    ptr: usize,
    pub fn get(i: UserIn, at: usize, dst: []u8) error{BadAddress}!void {
        const va = std.math.add(usize, i.ptr, at) catch return error.BadAddress;
        try vm.copyFromUser(i.space, dst, va);
    }
};

// ---- 正在运行的程序文件 ----
//
// 按需分页：进程运行期间才从它的程序文件里读页（vm.Backing.file），所以程序文件在有地址空间用着它的时候
// 不能改、不能删，不然之后读进来的页和 exec 时读的文件头就不是同一个版本了。
// exec 占住（holdText）、fork 多占一份（dupText），进程结束、exec 换掉地址空间时放开（releaseText，见 vm.releaseBacking）。
// 改文件的一方拿着 write_lock，改之前 beginModify：文件被占着就是 TextBusy；没被占着就记下“正在改它”，
// 改完（事务提交或者作废之后）endModify。这段时间里 exec 它也是 TextBusy。
// 两边都拿着 text_lock 查、改，所以“exec 占住之后再拿快照读文件头”看到的，就是之后按需分页读到的版本：
// 占住之前开始的修改要么还没 endModify（exec 失败），要么已经提交了（快照里看得到）。

/// 保护 texts、modifying。叶子锁
var text_lock: Spinlock = .init("fs text", .leaf);
/// 一个地址空间占一份。地址空间最多是每个进程一个，再加上正在 exec 的进程新建的那个
var texts: [2 * abi.max_procs]struct { ino: u64 = 0, refs: u32 = 0 } = @splat(.{});
/// 修改的一方正在改的 inode，0 表示没有。修改都拿着 write_lock，同一时刻只有一个
var modifying: u64 = 0;

pub fn holdText(ino: u64) error{TextBusy}!void {
    text_lock.acquire();
    defer text_lock.release();
    if (modifying == ino) return error.TextBusy;
    var free: ?usize = null;
    for (&texts, 0..) |*t, i| {
        if (t.refs > 0 and t.ino == ino) {
            t.refs += 1;
            return;
        }
        if (t.refs == 0 and free == null) free = i;
    }
    // 每个地址空间最多占一份，表比地址空间多，不会满
    const t = &texts[free orelse @panic("fsys: too many program files in use")];
    t.* = .{ .ino = ino, .refs = 1 };
}

/// 已经占着的程序文件再占一份（fork）。
pub fn dupText(ino: u64) void {
    text_lock.acquire();
    defer text_lock.release();
    textOf(ino).refs += 1;
}

pub fn releaseText(ino: u64) void {
    text_lock.acquire();
    defer text_lock.release();
    textOf(ino).refs -= 1;
}

fn textOf(ino: u64) *@TypeOf(texts[0]) {
    for (&texts) |*t| {
        if (t.refs > 0 and t.ino == ino) return t;
    }
    std.debug.panic("fsys: program file {d} is not in use", .{ino});
}

/// 要改 inode ino 的内容、或者删掉它的最后一个名字之前调用（拿着 write_lock）。有进程在运行它就是 TextBusy。
/// 成功之后改完要 endModify。
pub fn beginModify(ino: u64) error{TextBusy}!void {
    std.debug.assert(write_lock.holding());
    text_lock.acquire();
    defer text_lock.release();
    for (texts) |t| {
        if (t.refs > 0 and t.ino == ino) return error.TextBusy;
    }
    modifying = ino;
}

pub fn endModify() void {
    text_lock.acquire();
    defer text_lock.release();
    modifying = 0;
}

/// 要删掉 path（不跟着最后一段的符号链接走）这个名字、或者换掉它（rename 的目标）之前调用（拿着 write_lock）：
/// 它是文件、并且这是它的最后一个名字的话，内容会被删掉，按 beginModify 检查。返回 true 表示调用了 beginModify，
/// 做完要 endModify。名字不存在等等的错误不在这里报，交给接下来的操作自己报。
pub fn beginRemove(w: *Fs, cwd: u64, path: []const u8) error{TextBusy}!bool {
    const ino = w.resolveNoFollow(cwd, path) catch return false;
    const st = w.stat(ino) catch return false;
    if (st.kind != .file or st.nlink != 1) return false;
    try beginModify(ino);
    return true;
}

/// 按需分页：从程序文件 ino 的 off 处读 dst.len 个字节（vm.fault 调用，要睡着等磁盘）。
/// 文件被占着（holdText），内容不会变，所以每次拿一个新的快照读就行，读完就放开，不挡着别人。
pub fn readText(ino: u64, off: u64, dst: []u8) error{IoError}!void {
    var r = reader() catch return error.IoError;
    defer r.end();
    const n = r.fs.read(ino, off, dst.len, KernelOut{ .buf = dst }) catch return error.IoError;
    if (n != dst.len) return error.IoError;
}
