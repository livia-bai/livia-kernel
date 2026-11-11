//! 管道，照 xv6 的 pipe.c 写：一个环形缓冲区，一端写、一端读，读写两端各是一个打开的文件（见 file.zig）。
//!
//! - 读：缓冲区空着时睡在 &nread 上等写端写进来；写端都关了、缓冲区也空了，返回 0（读到结尾）。
//! - 写：写满了就叫醒读的进程，自己睡在 &nwrite 上等它读走；写完全部字节才返回。
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
    /// 读端、写端是否还开着（对应的 File 的引用数还没减到 0）
    read_open: bool = true,
    write_open: bool = true,
    data: [size]u8 = undefined,
};

comptime {
    std.debug.assert(@sizeOf(Pipe) <= page.size);
}

pub const Error = error{ BadAddress, BrokenPipe };

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
        proc.wakeup(&p.nread);
    } else {
        p.read_open = false;
        proc.wakeup(&p.nwrite);
    }
    const unused = !p.read_open and !p.write_open;
    p.lock.release();
    if (unused) page.free(@ptrCast(@alignCast(p)));
}

/// 把用户地址空间 space 里 [ptr, ptr+len) 的字节写进管道，写满了就等。返回写进去的字节数：
/// 正常情况下是 len；中途读端关了、遇到坏地址、被 kill 了，返回已经写进去的字节数
/// （一个字节都没写进去时返回对应的错误，被 kill 时返回 0）。
pub fn write(p: *Pipe, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    p.lock.acquire();
    defer p.lock.release();
    var done: usize = 0;
    // 写进了东西就叫醒读的进程（在放开锁之前：defer 按相反的顺序执行）
    defer if (done > 0) proc.wakeup(&p.nread);
    while (done < len) {
        if (!p.read_open) return if (done == 0) error.BrokenPipe else done;
        if (proc.isKilled()) return done;
        if (p.nwrite - p.nread == size) {
            // 满了：叫醒读的进程，等它读走一些
            proc.wakeup(&p.nread);
            proc.sleep(&p.nwrite, &p.lock);
            continue;
        }
        // 一次复制一段：不超过缓冲区的空位、不越过缓冲区末尾（环形）、不跨用户页
        // （跨页的话，一段复制失败时说不清前面写进去了多少）
        const va = ptr + done;
        const start = p.nwrite % size;
        const n = @min(len - done, size - (p.nwrite - p.nread), size - start, page.size - va % page.size);
        vm.copyFromUser(space, p.data[start..][0..n], va) catch return if (done == 0) error.BadAddress else done;
        p.nwrite += n;
        done += n;
    }
    return done;
}

/// 从管道读最多 len 个字节到用户地址空间 space 的 ptr。缓冲区空着、写端还开着时等；
/// 有多少读多少，不等凑满 len。返回 0 表示读到结尾（或者被 kill 了）。
pub fn read(p: *Pipe, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    p.lock.acquire();
    defer p.lock.release();
    while (p.nread == p.nwrite and p.write_open) {
        if (proc.isKilled()) return 0;
        proc.sleep(&p.nread, &p.lock);
    }
    var done: usize = 0;
    defer if (done > 0) proc.wakeup(&p.nwrite);
    while (done < len and p.nread != p.nwrite) {
        const start = p.nread % size;
        const n = @min(len - done, p.nwrite - p.nread, size - start);
        // 复制成功了才算读走：失败的这一段留在管道里
        vm.copyToUser(space, ptr + done, p.data[start..][0..n]) catch return if (done == 0) error.BadAddress else done;
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

    const p = try create();
    // 写 1500 字节、读 1000 字节，再写 1500 字节：第二次写越过了缓冲区末尾
    for (buf[0..1500], 0..) |*b, i| b.* = @truncate(i);
    try expectEqual(1500, try write(p, space, vm.user_base, 1500));
    try expectEqual(1000, try read(p, space, vm.user_base + 2000, 1000));
    try expectEqual(1500, try write(p, space, vm.user_base, 1500));
    try expectEqual(2000, p.nwrite - p.nread);
    // 有多少读多少：剩下的 500 + 1500 字节，要 3000 也只给 2000
    try expectEqual(2000, try read(p, space, vm.user_base + 2000, 2000 + 1000));
    try std.testing.expectEqualSlices(u8, buf[1000..1500], buf[2000..2500]);
    try std.testing.expectEqualSlices(u8, buf[0..1500], buf[2500..4000]);

    // 坏地址：一个字节都没读写，返回 BadAddress，管道里的数据不动
    try expectEqual(error.BadAddress, write(p, space, vm.user_base + page.size, 10));
    try expectEqual(10, try write(p, space, vm.user_base, 10));
    try expectEqual(error.BadAddress, read(p, space, 0x8020_0000, 10));
    try expectEqual(10, p.nwrite - p.nread);

    // 写端关了：先读完剩下的，再读到结尾
    close(p, true);
    try expectEqual(10, try read(p, space, vm.user_base, 100));
    try expectEqual(0, try read(p, space, vm.user_base, 100));
    close(p, false);
    try expectEqual(before, page.freePages());

    // 读端关了，写返回 BrokenPipe
    const q = try create();
    close(q, false);
    try expectEqual(error.BrokenPipe, write(q, space, vm.user_base, 1));
    close(q, true);
    try expectEqual(before, page.freePages());
    vm.destroyUserSpace(space);
}
