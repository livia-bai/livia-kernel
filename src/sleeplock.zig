//! 睡眠锁，照 xv6 的 sleeplock.c 写。和自旋锁的区别：等锁的进程睡下（proc.sleep），不占着 CPU 空转；
//! 拿着它可以睡觉、切换进程。用来保护要等磁盘 I/O 的东西（缓冲区缓存里的每一块，见 bio.zig）：
//! 拿着锁的进程可能正在等磁盘，拿着自旋锁等的话，别的 hart 上想要同一把锁的进程都得陪着空转。
//!
//! 约定：
//! - 只有进程能拿（要能睡下），调度器、kmain、中断处理程序都不能拿。
//! - 不能拿着它回到 U 模式（handleTrap 末尾检查当前进程拿着几把，proc.Process.sleeplocks）。
//! - 拿它之前可以拿着别的睡眠锁，但不能拿着自旋锁（会睡下：sched 只允许拿着自己的进程锁）。acquire 一开始就检查。
//! - 睡眠锁之间的顺序和自旋锁一样由等级（Rank）检查：进程拿着的睡眠锁的等级都必须比要拿的低
//!   （缓冲区这一级可以同时拿几把）。每个进程记着自己拿着每一级的几把（proc.Process.sleeplocks）。

const std = @import("std");
const proc = @import("proc.zig");
const spinlock = @import("spinlock.zig");
const Spinlock = spinlock.Spinlock;

/// 睡眠锁的等级，从低到高。
pub const Rank = enum(u8) {
    /// File.pos_lock：读写位置。读写文件系统里的文件、lseek、readdir 的整个过程拿着它
    file_pos,
    /// fsys.write_lock：文件系统的修改一个一个来
    fs_write,
    /// 缓冲区缓存的每一块。B 树的操作同时拿着一整条路径（从根到叶子，最多 8 层加上分裂出来的），
    /// 所以这一级可以同时拿几把；它们之间不会互相等，是因为拿着几把的只有修改的一方（拿着 fs_write），读者一次只拿一把
    buf,
};

/// 一个进程拿着每一级的睡眠锁各几把。
pub const Held = struct {
    counts: [std.meta.fieldNames(Rank).len]u16 = @splat(0),

    pub fn total(h: *const Held) u32 {
        var n: u32 = 0;
        for (h.counts) |c| n += c;
        return n;
    }

    /// 拿 rank 这一级的锁会违反顺序的话，返回挡住它的那一级（拿着的、不比它低的）。
    pub fn violation(h: *const Held, rank: Rank) ?Rank {
        var i = h.counts.len;
        while (i > @backingInt(rank)) {
            i -= 1;
            if (h.counts[i] > 0 and (i > @backingInt(rank) or rank != .buf)) return @fromBackingInt(@as(u8, @intCast(i)));
        }
        return null;
    }
};

pub const Sleeplock = struct {
    /// 调试用的名字
    name: []const u8,
    rank: Rank,
    /// 保护 locked 和 holder；等锁的进程拿着它睡在这把睡眠锁上
    lk: Spinlock,
    locked: bool = false,
    /// 拿着它的进程（单元测试在主机上运行，没有当前进程，是 null）
    holder: ?*proc.Process = null,

    pub fn init(name: []const u8, rank: Rank) Sleeplock {
        return .{ .name = name, .rank = rank, .lk = .init("sleeplock", .cond) };
    }

    pub fn acquire(l: *Sleeplock) void {
        if (spinlock.heldCount() != 0) std.debug.panic("acquire: sleeplock {s} while holding a spinlock", .{l.name});
        if (proc.heldSleeplocks()) |h| {
            if (h.violation(l.rank)) |r| std.debug.panic("lock order: acquiring sleeplock {s} ({s}) while holding a {s} sleeplock", .{
                l.name, @tagName(l.rank), @tagName(r),
            });
        }
        l.lk.acquire();
        defer l.lk.release();
        // 自己已经拿着的话，睡下去就永远醒不来了（和自旋锁一样，直接 panic）
        if (l.locked and l.holder == proc.current()) std.debug.panic("acquire: sleeplock {s} is already held by this process", .{l.name});
        while (l.locked) proc.sleep(l, &l.lk);
        l.locked = true;
        l.holder = proc.current();
        if (proc.heldSleeplocks()) |h| h.counts[@backingInt(l.rank)] += 1;
    }

    pub fn release(l: *Sleeplock) void {
        l.lk.acquire();
        defer l.lk.release();
        if (!l.locked or l.holder != proc.current()) std.debug.panic("release: sleeplock {s} is not held by this process", .{l.name});
        l.locked = false;
        l.holder = null;
        if (proc.heldSleeplocks()) |h| h.counts[@backingInt(l.rank)] -= 1;
        proc.wakeup(l);
    }

    /// 当前进程是否拿着它。
    pub fn holding(l: *Sleeplock) bool {
        l.lk.acquire();
        defer l.lk.release();
        return l.locked and l.holder == proc.current();
    }
};

test "睡眠锁的等级：只能往更高的等级拿，缓冲区可以拿几把" {
    var h: Held = .{};
    try std.testing.expectEqual(null, h.violation(.file_pos));
    h.counts[@backingInt(Rank.fs_write)] = 1;
    try std.testing.expectEqual(Rank.fs_write, h.violation(.file_pos).?);
    try std.testing.expectEqual(Rank.fs_write, h.violation(.fs_write).?);
    try std.testing.expectEqual(null, h.violation(.buf));
    h.counts[@backingInt(Rank.buf)] = 3;
    try std.testing.expectEqual(null, h.violation(.buf));
    try std.testing.expectEqual(Rank.buf, h.violation(.fs_write).?);
    try std.testing.expectEqual(4, h.total());
}

test "睡眠锁：拿、放、holding" {
    var l = Sleeplock.init("test", .buf);
    try std.testing.expect(!l.holding());
    l.acquire();
    try std.testing.expect(l.holding());
    l.release();
    try std.testing.expect(!l.holding());
}
