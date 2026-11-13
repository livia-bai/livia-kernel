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
//! - 正在用的 inode（打开着的、正在运行的程序文件）记在 users 里（hold、release）。删掉它的最后一个名字时
//!   只删名字，inode 变成孤儿，最后一个使用者放开时才删（和 Unix 一样）。正在运行的程序文件不能改内容：
//!   改它的一方（beginModify）得到 TextBusy（和 Linux 的 ETXTBSY 一样）；正在被改的文件也不能开始运行。

const std = @import("std");
const abi = @import("abi.zig");
const fs = @import("fs.zig");
const ctree = @import("ctree.zig");
const bio = @import("bio.zig");
const uart = @import("uart.zig");
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
    root.keep = keepInUse;
    // 上次关机、掉电时还有人用着的孤儿：现在没人用了，删掉
    const orphans = root.run(Fs.reapOrphans, .{}) catch |err| blk: {
        uart.print("[warn] fs: could not remove orphan inodes: {s}\n", .{@errorName(err)});
        break :blk 0;
    };
    if (orphans > 0) uart.print("[ok] file system: removed {d} orphan inode{s}\n", .{ orphans, if (orphans == 1) "" else "s" });
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

// ---- 正在用的 inode：打开的文件、正在运行的程序文件 ----
//
// 两种使用者：
// - 打开的文件（file.File 的 .inode、.device）：每个 File 一份，最后一个 fd 关掉时放开（file.close）。
// - 正在运行的程序文件（vm.Backing.file）：按需分页在进程运行期间从它读页，exec 占住（hold(.text)）、fork 多占一份，
//   进程结束、exec 换掉地址空间时放开（vm.releaseBacking）。
//
// 删除：删掉一个 inode 的最后一个名字时（fs.Fs.remove 调用 keepInUse），它还有使用者的话只删名字，inode 留着，
// 链接数记成 0、树里记一个孤儿条目（fs.zig），这里记下 orphan；最后一个使用者放开时才真正删掉它（reapOrphan）。
// 和 Unix 一样：打开后马上删掉的临时文件照常能读写，正在运行的程序也可以删。没人用的话照常马上删掉，
// 这时记下 removing，删除提交之前别人不能再占住它（open、exec 看到的是 NotFound）。
//
// 修改内容（write、截断）：改之前 beginModify：有进程在运行它就是 TextBusy（和 Linux 的 ETXTBSY 一样，
// 不然之后读进来的页和 exec 时读的文件头不是同一个版本）；没有就记下 modifying，改完 endModify。
// 这段时间里 exec 它也是 TextBusy。
//
// 都拿着 use_lock 查、改，所以“占住之后再拿快照看一眼”看到的就是之后读到的版本：占住之前开始的修改、删除
// 要么还没 endModify（占住失败），要么已经提交了（快照里看得到）；占住之后开始的删除只会把它变成孤儿。

pub const Use = enum { open, text };

/// 保护 users、modifying、removing。叶子锁
var use_lock: Spinlock = .init("fs users", .leaf);
/// 每个正在用的 inode 一项。最多：每个 File 一个，加上每个地址空间一个（每个进程一个，再加上正在 exec 的新建的那个）
var users: [@import("file.zig").max_files + 2 * abi.max_procs]struct {
    ino: u64 = 0,
    opens: u32 = 0,
    texts: u32 = 0,
    /// 名字都删掉了（只剩孤儿条目），最后一个使用者放开时删掉它
    orphan: bool = false,
} = @splat(.{});
/// 修改的一方正在改内容的 inode、正在删掉的 inode，0 表示没有。修改都拿着 write_lock，同一时刻各最多一个
var modifying: u64 = 0;
var removing: u64 = 0;

fn userOf(ino: u64) ?*@TypeOf(users[0]) {
    for (&users) |*u| {
        if (u.opens + u.texts > 0 and u.ino == ino) return u;
    }
    return null;
}

/// 占住 inode ino（打开它、或者开始运行它）。正在被删掉是 NotFound；要运行的正在被改是 TextBusy。
/// 调用方之后要拿一个新的快照确认它还在（之前找到它的快照可能已经旧了，见上面）。
pub fn hold(ino: u64, use: Use) error{ NotFound, TextBusy }!void {
    use_lock.acquire();
    defer use_lock.release();
    if (removing == ino) return error.NotFound;
    if (use == .text and modifying == ino) return error.TextBusy;
    const u = userOf(ino) orelse for (&users) |*u| {
        if (u.opens + u.texts == 0) {
            u.* = .{ .ino = ino };
            break u;
        }
    } else @panic("fsys: too many inodes in use"); // 表比 File 和地址空间加起来还多，不会满
    switch (use) {
        .open => u.opens += 1,
        .text => u.texts += 1,
    }
}

/// 已经占着的 inode 再占一份（fork 复制地址空间）。
pub fn dup(ino: u64, use: Use) void {
    use_lock.acquire();
    defer use_lock.release();
    const u = userOf(ino) orelse std.debug.panic("fsys: inode {d} is not in use", .{ino});
    switch (use) {
        .open => u.opens += 1,
        .text => u.texts += 1,
    }
}

/// 放开一份。它是孤儿、这是最后一个使用者的话，删掉它（要读写磁盘、拿 write_lock：调用方不能拿着锁）。
/// 删不掉（读写失败）的留着孤儿条目，下次挂载时删。
pub fn release(ino: u64, use: Use) void {
    const reap = blk: {
        use_lock.acquire();
        defer use_lock.release();
        const u = userOf(ino) orelse std.debug.panic("fsys: inode {d} is not in use", .{ino});
        switch (use) {
            .open => u.opens -= 1,
            .text => u.texts -= 1,
        }
        break :blk u.opens + u.texts == 0 and u.orphan;
    };
    if (!reap) return;
    const w = writer() catch return;
    defer unlock();
    w.run(Fs.reapOrphan, .{ino}) catch |err| uart.print("[warn] fs: could not remove orphan inode {d}: {s}\n", .{ ino, @errorName(err) });
}

/// fs.Fs.remove 删掉 inode ino 的最后一个名字时调用（拿着 write_lock，在事务里）：返回 true 表示它还有使用者，
/// 只删名字、留下孤儿；false 表示连 inode 一起删掉，这时记下 removing，事务做完 endModify 之前别人占不住它。
/// 事务后来作废了也没关系：orphan 记早了，到时候 reapOrphan 发现没有孤儿条目，什么都不做。
fn keepInUse(ino: u64) bool {
    std.debug.assert(write_lock.holding());
    use_lock.acquire();
    defer use_lock.release();
    if (userOf(ino)) |u| {
        u.orphan = true;
        return true;
    }
    removing = ino;
    return false;
}

/// 要改 inode ino 的内容之前调用（拿着 write_lock）。有进程在运行它就是 TextBusy。成功之后改完要 endModify。
pub fn beginModify(ino: u64) error{TextBusy}!void {
    std.debug.assert(write_lock.holding());
    use_lock.acquire();
    defer use_lock.release();
    if (userOf(ino)) |u| if (u.texts > 0) return error.TextBusy;
    modifying = ino;
}

/// 改内容、删除的事务做完了（提交了或者作废了）：清掉 modifying、removing。unlink、rename 之后也要调用。
pub fn endModify() void {
    use_lock.acquire();
    defer use_lock.release();
    modifying = 0;
    removing = 0;
}

/// 按需分页：从程序文件 ino 的 off 处读 dst.len 个字节（vm.fault 调用，要睡着等磁盘）。
/// 文件被占着（hold），内容不会变，所以每次拿一个新的快照读就行，读完就放开，不挡着别人。
pub fn readText(ino: u64, off: u64, dst: []u8) error{IoError}!void {
    var r = reader() catch return error.IoError;
    defer r.end();
    const n = r.fs.read(ino, off, dst.len, KernelOut{ .buf = dst }) catch return error.IoError;
    if (n != dst.len) return error.IoError;
}
