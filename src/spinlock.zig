//! 自旋锁，照 xv6 的 spinlock.c 写。几个 hart 同时访问的共享数据（进程表、页分配器、文件表、管道、
//! 串口）都由自旋锁保护。
//!
//! 约定：
//! - 拿着锁时中断必须是关着的。否则中断处理程序在同一个 hart 上去拿同一把锁，就会永远自旋下去。
//!   内核代码本来就关着中断运行（见 docs/trap.md），所以 acquire 只检查，不负责关中断（xv6 的 push_off）。
//! - 不能拿着锁回到 U 模式。切换进程（sched）时只能拿着这个进程自己的锁（proc.zig），别的锁都要先放开；
//!   要拿着锁等待的，用 proc.WaitQueue 的 wait(lock)：它在睡下之后放开锁，醒来再重新拿上。
//! - 同一个 hart 重复拿同一把锁是死锁，直接 panic。
//! - **加锁顺序由等级（Rank）检查**：每把锁在创建时给一个等级，拿一把锁时，这个 hart 已经拿着的锁的等级都必须更低
//!   （只有 bucket 这一级允许同时拿几把，见 Rank）。违反了就 panic，说出是哪两把锁。所以一次正常的运行就能发现
//!   顺序错误，不用等两个 hart 恰好交叉、真的死锁。等级怎么分、为什么这样分见 docs/process.md 的“锁”一节。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");
const hart = @import("hart.zig");
const kstat = @import("kstat.zig");

const no_hart = std.math.maxInt(usize);

/// 锁的等级，从低到高。拿着一把锁时只能再拿等级更高的锁。
pub const Rank = enum(u8) {
    /// proc.wait_lock：父子关系。它在最前面：拿着它要看、要改各个进程（进程锁），还要叫醒父进程
    wait,
    /// 保护某个等待条件和对应的 proc.WaitQueue、拿着它 wait / wakeAll 的锁：管道、timer.lock、uart.rx_lock、virtio_disk.lock、
    /// bio.evict_lock、Volume.snap_lock、睡眠锁里的自旋锁。wait 拿着它再拿自己的进程锁，wakeAll 拿着它拿排着的进程的锁，
    /// 所以都比进程锁低；它们之间不嵌套
    cond,
    /// bio 的桶。换块的一方拿着 evict_lock（cond）找最久没用的缓冲区时，会同时拿着两个桶的锁：
    /// 只有拿着 evict_lock 的才这样做，所以同一等级拿几把也不会互相等
    bucket,
    /// 每个进程的锁
    proc,
    /// 串口的输出锁：拿着进程锁、条件的锁时都可能打印
    uart_out,
    /// 叶子锁：拿着它们不再拿别的锁。页分配器（每个 hart 一把）、File.lock、fsys.text_lock
    leaf,

    /// 同一等级的锁能不能同时拿几把
    fn nests(r: Rank) bool {
        return r == .bucket;
    }
};

/// 一个 hart 同时最多拿几把锁（wait_lock、进程锁、叶子锁……实际最深五六把）
const max_held = 16;

/// 每个 hart 拿着的锁，按拿的顺序。只有这个 hart 自己读写自己那一项
const Held = struct {
    locks: [max_held]*Spinlock = undefined,
    n: usize = 0,
};
var held: [hart.max]Held = @splat(.{});

pub const Spinlock = struct {
    /// 调试用的名字，panic 信息里会打印
    name: []const u8,
    rank: Rank,
    locked: std.atomic.Value(bool) = .init(false),
    /// 拿着锁的 hart，用来发现重复加锁。只在拿着锁时写，所以不用原子操作
    hart: usize = no_hart,

    pub fn init(name: []const u8, rank: Rank) Spinlock {
        return .{ .name = name, .rank = rank };
    }

    pub fn acquire(l: *Spinlock) void {
        assertInterruptsOff();
        jitterSpin();
        if (l.holding()) std.debug.panic("acquire: lock {s} is already held by this hart", .{l.name});
        if (orderViolation(l)) |other| std.debug.panic("lock order: acquiring {s} ({s}) while holding {s} ({s})", .{
            l.name, @tagName(l.rank), other.name, @tagName(other.rank),
        });
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
        const h = &held[hart.id()];
        if (h.n == max_held) @panic("acquire: too many spinlocks held");
        h.locks[h.n] = l;
        h.n += 1;
    }

    pub fn release(l: *Spinlock) void {
        if (!l.holding()) std.debug.panic("release: lock {s} is not held by this hart", .{l.name});
        l.hart = no_hart;
        forget(l);
        // release 语义保证临界区里的访存都在放开锁之前完成
        l.locked.store(false, .release);
        jitterSpin(); // 放开之后停一会儿，别的 hart 更可能在这时插进来
    }

    /// 当前 hart 是否拿着这把锁。别的 hart 拿着时，hart 字段不会等于当前 hart 的编号，
    /// 所以不拿锁读它也不会误判。
    pub fn holding(l: *const Spinlock) bool {
        return l.locked.load(.monotonic) and l.hart == hart.id();
    }
};

/// 拉大竞争窗口（zig build -Dlock-jitter=true，qemu_test.py --jitter）：拿锁之前、放锁之后，大约四次里有一次
/// 空转 0..1023 圈。竞争类的错误常常要两个 hart 在几条指令的窗口里恰好交叉才出现，多跑几遍也不一定撞上；
/// 在每个加锁的地方随机停一停，交叉的方式就多得多。伪随机数每个 hart 一份（xorshift64），种子来自 time，
/// 所以每次运行都不一样。只在内核里有：单元测试、mkfs 的根文件没有 lock_jitter。
const jitter = blk: {
    const root = @import("root");
    break :blk @hasDecl(root, "lock_jitter") and root.lock_jitter;
};
var jitter_state: [hart.max]u64 = @splat(0);

fn jitterSpin() void {
    if (comptime !jitter) return;
    const s = &jitter_state[hart.id()];
    if (s.* == 0) s.* = (riscv.read(.time) ^ (@as(u64, hart.id()) << 32)) | 1;
    var x = s.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    s.* = x;
    if (x & 3 != 0) return;
    for (0..(x >> 16) % 1024) |_| std.atomic.spinLoopHint();
}

/// 拿 l 会违反加锁顺序的话，返回当前 hart 拿着的、挡住它的那把锁（等级不比 l 低）。
fn orderViolation(l: *const Spinlock) ?*Spinlock {
    const h = &held[hart.id()];
    for (h.locks[0..h.n]) |other| {
        const o = @backingInt(other.rank);
        const r = @backingInt(l.rank);
        if (o > r or (o == r and !l.rank.nests())) return other;
    }
    return null;
}

/// 从这个 hart 拿着的锁里去掉 l。放锁的顺序不一定和拿的相反（sleep 先拿进程锁、再放条件的锁），从后往前找。
fn forget(l: *Spinlock) void {
    const h = &held[hart.id()];
    var i = h.n;
    while (i > 0) {
        i -= 1;
        if (h.locks[i] == l) {
            std.mem.copyForwards(*Spinlock, h.locks[i .. h.n - 1], h.locks[i + 1 .. h.n]);
            h.n -= 1;
            return;
        }
    }
    unreachable; // holding() 说拿着
}

/// 当前 hart 拿着几把锁。
pub fn heldCount() usize {
    return held[hart.id()].n;
}

/// 回到 U 模式之前调用：这时不能拿着任何锁。
pub fn assertNoneHeld() void {
    const h = &held[hart.id()];
    if (h.n != 0) std.debug.panic("{d} spinlock(s) still held, the first is {s}", .{ h.n, h.locks[0].name });
}

fn assertInterruptsOff() void {
    // 单元测试在主机上运行，没有 sstatus
    if (comptime builtin.cpu.arch.isRISCV()) {
        if (riscv.interruptsEnabled()) @panic("acquire: interrupts are enabled");
    }
}

test "拿锁、放锁，记录拿着几把锁" {
    var a = Spinlock.init("a", .cond);
    var b = Spinlock.init("b", .leaf);
    const before = heldCount();
    a.acquire();
    b.acquire();
    try std.testing.expect(a.holding() and b.holding());
    try std.testing.expectEqual(before + 2, heldCount());
    // 不按相反的顺序放也行
    a.release();
    try std.testing.expect(!a.holding() and b.holding());
    b.release();
    try std.testing.expectEqual(before, heldCount());
}

test "加锁顺序：只能往更高的等级拿；同一等级只有 bucket 能拿几把" {
    var wait = Spinlock.init("wait", .wait);
    var cond = Spinlock.init("cond", .cond);
    var proc = Spinlock.init("proc", .proc);
    var proc2 = Spinlock.init("proc2", .proc);
    var b1 = Spinlock.init("b1", .bucket);
    var b2 = Spinlock.init("b2", .bucket);

    wait.acquire();
    proc.acquire();
    try std.testing.expectEqual(&proc, orderViolation(&cond).?); // cond 比 proc 低
    try std.testing.expectEqual(&proc, orderViolation(&proc2).?); // 两把进程锁
    try std.testing.expectEqual(null, orderViolation(&Spinlock.init("leaf", .leaf)));
    proc.release();
    try std.testing.expectEqual(null, orderViolation(&cond));
    cond.acquire();
    b1.acquire();
    try std.testing.expectEqual(null, orderViolation(&b2)); // bucket 可以同时拿两把
    b2.acquire();
    var cond2 = Spinlock.init("cond2", .cond);
    try std.testing.expectEqual(&cond, orderViolation(&cond2).?); // 挡住它的第一把
    b2.release();
    b1.release();
    cond.release();
    wait.release();
}
