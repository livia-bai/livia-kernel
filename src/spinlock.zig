//! 自旋锁，照 xv6 的 spinlock.c 写。几个 hart 同时访问的共享数据（进程表、页分配器、文件表、管道、
//! 串口）都由自旋锁保护。
//!
//! 约定：
//! - 拿着锁时中断必须是关着的。否则中断处理程序在同一个 hart 上去拿同一把锁，就会永远自旋下去。
//!   内核代码本来就关着中断运行（见 docs/trap.md），所以 acquire 只检查，不负责关中断（xv6 的 push_off）。
//! - 不能拿着锁回到 U 模式。切换进程（sched）时只能拿着这个进程自己的锁（proc.zig），别的锁都要先放开；
//!   要拿着锁等待的，用 proc.sleep(chan, lock)：它在睡下之后放开锁，醒来再重新拿上。
//! - 同一个 hart 重复拿同一把锁是死锁，直接 panic。
//! - 要同时拿几把锁时按固定的顺序拿，见 docs/process.md 的“锁”一节。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");
const hart = @import("hart.zig");
const kstat = @import("kstat.zig");

const no_hart = std.math.maxInt(usize);

/// 每个 hart 拿着几把锁。只有这个 hart 自己读写自己那一项。
var held: [hart.max]usize = @splat(0);

pub const Spinlock = struct {
    /// 调试用的名字，panic 信息里会打印
    name: []const u8,
    locked: std.atomic.Value(bool) = .init(false),
    /// 拿着锁的 hart，用来发现重复加锁。只在拿着锁时写，所以不用原子操作
    hart: usize = no_hart,

    pub fn init(name: []const u8) Spinlock {
        return .{ .name = name };
    }

    pub fn acquire(l: *Spinlock) void {
        assertInterruptsOff();
        if (l.holding()) std.debug.panic("acquire: lock {s} is already held by this hart", .{l.name});
        // amoswap.w.aq：换进 true，换出来的是 false 才算拿到。acquire 语义保证临界区里的访存
        // 不会被提前到拿到锁之前。等锁时顺便看看是不是有别的 hart 在 panic：
        // 锁可能在已经停下的 hart 手里，永远等不到
        if (l.locked.swap(true, .acquire)) {
            kstat.inc(.lock_contended);
            while (l.locked.swap(true, .acquire)) {
                hart.checkPanic();
                std.atomic.spinLoopHint();
            }
        }
        l.hart = hart.id();
        held[hart.id()] += 1;
    }

    pub fn release(l: *Spinlock) void {
        if (!l.holding()) std.debug.panic("release: lock {s} is not held by this hart", .{l.name});
        l.hart = no_hart;
        held[hart.id()] -= 1;
        // release 语义保证临界区里的访存都在放开锁之前完成
        l.locked.store(false, .release);
    }

    /// 当前 hart 是否拿着这把锁。别的 hart 拿着时，hart 字段不会等于当前 hart 的编号，
    /// 所以不拿锁读它也不会误判。
    pub fn holding(l: *const Spinlock) bool {
        return l.locked.load(.monotonic) and l.hart == hart.id();
    }
};

/// 当前 hart 拿着几把锁。
pub fn heldCount() usize {
    return held[hart.id()];
}

/// 回到 U 模式之前调用：这时不能拿着任何锁。
pub fn assertNoneHeld() void {
    if (heldCount() != 0) std.debug.panic("{d} spinlock(s) still held", .{heldCount()});
}

fn assertInterruptsOff() void {
    // 单元测试在主机上运行，没有 sstatus
    if (comptime builtin.cpu.arch.isRISCV()) {
        if (riscv.read(.sstatus) & riscv.sstatus_sie != 0) @panic("acquire: interrupts are enabled");
    }
}

test "拿锁、放锁，记录拿着几把锁" {
    var a = Spinlock.init("a");
    var b = Spinlock.init("b");
    const before = heldCount();
    a.acquire();
    b.acquire();
    try std.testing.expect(a.holding() and b.holding());
    try std.testing.expectEqual(before + 2, heldCount());
    b.release();
    a.release();
    try std.testing.expect(!a.holding());
    try std.testing.expectEqual(before, heldCount());
}
