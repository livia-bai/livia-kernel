//! 管道，照 xv6 的 pipe.c 写：一个环形缓冲区，一端写、一端读，读写两端各是一个打开的文件（见 file.zig）。
//!
//! - 读：缓冲区空着时排在 readers 里睡下，等写端写进来；写端都关了、缓冲区也空了，返回 0（读到结尾）。
//! - 写：写满了就叫醒读的进程，自己排在 writers 里睡下，等它读走；写完全部字节才返回。
//!   读端都关了，再写就返回 BrokenPipe（Linux 的 EPIPE）。
//! - nread、nwrite 是读走、写进的总字节数，只增不减（64 位，不会回绕），
//!   两者之差就是缓冲区里的字节数，下标是它们对缓冲区大小取模。
//!
//! 每个管道占一页（page.alloc），两端都关了才释放。所有字段由 lock 保护：
//! 多核时读写两端的进程可能在不同的 hart 上同时运行。

const std = @import("std");
const page = @import("page.zig");
const vm = @import("vm.zig");
const proc = @import("proc.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

/// 缓冲区的大小。整个 Pipe 要放得进一页。
pub const size = 2048;

pub const Pipe = struct {
    lock: Spinlock = .init("pipe", .cond),
    nread: usize = 0,
    nwrite: usize = 0,
    /// lock。等数据的读者、等空位的写者
    readers: proc.WaitQueue = .{},
    writers: proc.WaitQueue = .{},
    /// 读端、写端是否还开着（对应的 File 的引用数还没减到 0）
    read_open: bool = true,
    write_open: bool = true,
    data: [size]u8 = undefined,
};

comptime {
    std.debug.assert(@sizeOf(Pipe) <= page.size);
}

pub const Error = error{BrokenPipe};

pub fn create() error{OutOfMemory}!*Pipe {
    const p: *Pipe = @ptrCast(try page.alloc());
    p.* = .{};
    return p;
}

/// 关掉一端（writable 为 true 时是写端），叫醒等在另一端的进程：读的会读到结尾，写的会得到 BrokenPipe。
/// 两端都关了就释放这一页。
pub fn close(p: *Pipe, writable: bool) void {
    p.lock.acquire();
    if (writable) {
        p.write_open = false;
        p.readers.wakeAll(&p.lock);
    } else {
        p.read_open = false;
        p.writers.wakeAll(&p.lock);
    }
    const unused = !p.read_open and !p.write_open;
    p.lock.release();
    if (unused) page.free(@ptrCast(@alignCast(p)));
}

/// 把用户内存 src（pin 好的：拿着管道锁复制，不能缺页）写进管道，写满了就等。返回写进去的字节数：
/// 正常情况下是 src.len；中途读端关了、被 kill 了，返回已经写进去的字节数
/// （一个字节都没写进去时读端关了是 BrokenPipe，被 kill 是 0）。
pub fn write(p: *Pipe, src: vm.PinnedSrc) Error!usize {
    const len = src.len;
    p.lock.acquire();
    defer p.lock.release();
    var done: usize = 0;
    // 写进了东西就叫醒读的进程（在放开锁之前：defer 按相反的顺序执行）
    defer if (done > 0) p.readers.wakeAll(&p.lock);
    while (done < len) {
        if (!p.read_open) return if (done == 0) error.BrokenPipe else done;
        if (proc.isKilled()) return done;
        if (p.nwrite - p.nread == size) {
            // 满了：叫醒读的进程，等它读走一些
            p.readers.wakeAll(&p.lock);
            p.writers.wait(&p.lock);
            continue;
        }
        // 一次复制一段：不超过缓冲区的空位、不越过缓冲区末尾（环形）
        const start = p.nwrite % size;
        const n = @min(len - done, size - (p.nwrite - p.nread), size - start);
        src.copyIn(done, p.data[start..][0..n]);
        p.nwrite += n;
        done += n;
    }
    return done;
}

/// 从管道读最多 dst.len 个字节到用户内存 dst（pin 好的）。缓冲区空着、写端还开着时等；
/// 有多少读多少，不等凑满。返回 0 表示读到结尾（或者被 kill 了）。
pub fn read(p: *Pipe, dst: vm.PinnedDst) Error!usize {
    const len = dst.len;
    p.lock.acquire();
    defer p.lock.release();
    while (p.nread == p.nwrite and p.write_open) {
        if (proc.isKilled()) return 0;
        p.readers.wait(&p.lock);
    }
    var done: usize = 0;
    defer if (done > 0) p.writers.wakeAll(&p.lock);
    while (done < len and p.nread != p.nwrite) {
        const start = p.nread % size;
        const n = @min(len - done, p.nwrite - p.nread, size - start);
        dst.copyOut(done, p.data[start..][0..n]);
        p.nread += n;
        done += n;
    }
    return done;
}

// 单元测试只走不需要等待的路径：等待要切换进程，只能在 QEMU 里测（user/tests/t_pipe.zig）。

var test_memory: [16 * page.size]u8 align(page.size) = undefined;

test "管道：环形缓冲区回绕、读到结尾、读端关了写返回 BrokenPipe，两端都关了释放" {
    const expectEqual = std.testing.expectEqual;
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    var user = try vm.createUserSpace();
    const space = &user;
    const buf = try vm.allocUserPage(space.root, vm.user_base, .{ .r = true, .w = true });
    const before = page.freePages();

    // 测试里拿用户地址空间的第一页当缓冲区，src/dst 是 pin 好的一段
    const Range = struct {
        space: *vm.Space,
        fn src(r: @This(), off: usize, len: usize) vm.PinnedSrc {
            return vm.pinSrc(r.space, vm.user_base + off, len) catch unreachable;
        }
        fn dst(r: @This(), off: usize, len: usize) vm.PinnedDst {
            return vm.pinDst(r.space, vm.user_base + off, len) catch unreachable;
        }
    };
    const u: Range = .{ .space = space };

    const p = try create();
    // 写 1500 字节、读 1000 字节，再写 1500 字节：第二次写越过了缓冲区末尾
    for (buf[0..1500], 0..) |*b, i| b.* = @truncate(i);
    try expectEqual(1500, try write(p, u.src(0, 1500)));
    try expectEqual(1000, try read(p, u.dst(2000, 1000)));
    try expectEqual(1500, try write(p, u.src(0, 1500)));
    try expectEqual(2000, p.nwrite - p.nread);
    // 有多少读多少：剩下的 500 + 1500 字节，要 2096 也只给 2000
    try expectEqual(2000, try read(p, u.dst(2000, 2096)));
    try std.testing.expectEqualSlices(u8, buf[1000..1500], buf[2000..2500]);
    try std.testing.expectEqualSlices(u8, buf[0..1500], buf[2500..4000]);

    // 写端关了：先读完剩下的，再读到结尾
    try expectEqual(10, try write(p, u.src(0, 10)));
    close(p, true);
    try expectEqual(10, try read(p, u.dst(0, 100)));
    try expectEqual(0, try read(p, u.dst(0, 100)));
    close(p, false);
    try expectEqual(before, page.freePages());

    // 读端关了，写返回 BrokenPipe
    const q = try create();
    close(q, false);
    try expectEqual(error.BrokenPipe, write(q, u.src(0, 1)));
    close(q, true);
    try expectEqual(before, page.freePages());
    vm.destroyUserSpace(space);
}
