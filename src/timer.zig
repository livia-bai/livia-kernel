//! 时钟：计时、sleep 系统调用、时间片。没有固定频率的 tick（tickless）：
//!
//! - 计时直接读 time CSR（每秒增加 timebase_hz 次，QEMU virt 上是 10 MHz），不数时钟中断。
//! - sleep 的进程按到期时刻排在 sleepers 里（Sleeper 放在它自己的内核栈上），只在最早的那个到期时才有中断。
//! - 时间片：hart 切到一个进程时记下这一片的结束时刻（slice_ms 之后），中断来了、过了这个时刻才让它让出 CPU。
//!
//! 每个 hart 有自己的定时器（SBI 的 set_timer 只设置当前 hart 的）。每个 hart 什么时候要中断由 arm 决定：
//! 在运行进程的话是“这一片的结束”和“最早的 sleeper 到期”中早的那个；空闲（在调度器里）的话只看最早的 sleeper，
//! 没有 sleeper 就不预约，wfi 一直睡到别的中断（核间中断、串口、磁盘）。原来每个 hart 固定每秒 100 次时钟中断，
//! 空闲的 hart 也一样；sleep 的进程每 10 ms 被叫醒一次，自己数时间到了没有。
//!
//! 为什么不会漏掉一个 sleeper：调度器每一轮都重新 arm（切到进程之前、wfi 之前），时钟中断处理完也重新 arm，
//! 而 arm 总是带上当时最早的 sleeper。新的 sleeper 是它所在的 hart 排进去的，这个 hart 接着就切回调度器、
//! 重新 arm，所以至少它的定时器盖住了新的最早时刻；到期时处理它的 hart 叫醒它之后重新 arm，带上下一个最早的。
//! 几个 hart 可能都预约了同一个时刻，先拿到 lock 的叫醒，别的发现没有到期的，各自重新 arm。

const std = @import("std");
const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");
const hart = @import("hart.zig");
const proc = @import("proc.zig");
const kstat = @import("kstat.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

/// 时间片的长度
pub const slice_ms = 10;

/// time CSR 每秒增加的次数，来自设备树 /cpus 的 timebase-frequency（QEMU virt 上是 10MHz）。
var timebase_hz: u64 = undefined;
/// 打开时钟时 time CSR 的值，uptime 从这里算起
var boot_time: u64 = undefined;

/// 每个 hart 正在运行的进程的这一片在 time 的哪个值结束；在调度器里时没有。只有这个 hart 自己读写自己那一项
var slice_end: [hart.max]?u64 = @splat(null);

/// 保护 sleepers 和每个 Sleeper。
pub var lock: Spinlock = .init("timer", .cond);
/// lock。sleep 系统调用里的进程，按到期时刻从早到晚排好
var sleepers: ?*Sleeper = null;
/// 最早的 sleeper 的到期时刻，没有就是 maxInt。拿着 lock 写；arm 不拿锁读（见文件开头：读到旧值时，
/// 新的最早时刻由排进它的那个 hart 盖住）
var earliest: std.atomic.Value(u64) = .init(never);

const never = std.math.maxInt(u64);

/// 一个在 sleep 里的进程：放在它自己的内核栈上（sleepUntil 的局部变量），睡着的期间一直在。
const Sleeper = struct {
    deadline: u64,
    next: ?*Sleeper = null,
    /// 还在 sleepers 里（到期时 onInterrupt 摘下来，被 kill 叫醒的自己摘）
    linked: bool = false,
    /// 只有这个进程排在里面
    queue: proc.WaitQueue = .{},
};

/// 启动 hart 调用一次，在 initHart 之前。
pub fn init(hz: u64) void {
    timebase_hz = hz;
    boot_time = riscv.read(.time);
}

/// 每个 hart 调用一次：在 sie 里使能时钟中断。先不预约，调度器第一轮会 arm。
pub fn initHart() void {
    sbi.setTimer(never);
    riscv.set(.sie, .{ .sti = true });
}

/// 现在的 time CSR。
pub fn now() u64 {
    return riscv.read(.time);
}

/// time CSR 走 ms 毫秒是多少（饱和，ms 再大也不溢出）。
pub fn fromMs(ms: u64) u64 {
    return (ms *| timebase_hz) / 1000;
}

/// time CSR 的差值换成毫秒。
pub fn toMs(t: u64) u64 {
    return t / (timebase_hz / 1000);
}

/// 开机以来的毫秒数（从打开时钟算起）。
pub fn uptimeMs() u64 {
    return toMs(now() - boot_time);
}

/// 调度器切到一个进程之前调用：这一片从现在开始。
pub fn startSlice() void {
    slice_end[hart.id()] = now() + fromMs(slice_ms);
    arm();
}

/// 进程切回调度器之后调用：这一片结束了（不预约，下一次 startSlice 或 stopSlice 时再说）。
pub fn endSlice() void {
    slice_end[hart.id()] = null;
}

/// 调度器里没有可运行的进程、要 wfi 之前调用：只为 sleeper 预约。
pub fn stopSlice() void {
    slice_end[hart.id()] = null;
    arm();
}

/// 预约当前 hart 的下一次时钟中断：这一片的结束和最早的 sleeper 中早的那个，都没有就不预约。
/// 预约的时刻已经过去的话中断马上就来。
fn arm() void {
    const e = earliest.load(.acquire);
    const t = if (slice_end[hart.id()]) |s| @min(s, e) else e;
    sbi.setTimer(t);
}

/// 时钟中断处理：叫醒到期的 sleeper，重新预约。返回这一片是不是用完了（陷阱处理程序据此让 U 模式的进程让出 CPU）。
pub fn onInterrupt() bool {
    kstat.inc(.timer_interrupts);
    const t = now();
    if (earliest.load(.acquire) <= t) {
        lock.acquire();
        defer lock.release();
        while (sleepers) |s| {
            if (s.deadline > t) break;
            sleepers = s.next;
            s.linked = false;
            s.queue.wakeAll(&lock);
        }
        updateEarliest();
    }
    const slice = &slice_end[hart.id()];
    const expired = if (slice.*) |s| s <= t else false;
    // 用完了的这一片不再算进预约：不然预约的时刻已经过去，进程让出 CPU 之后，调度器一开中断就又是一次中断，
    // 处理完又预约这个过去的时刻……调度器就卡在开中断的那一条指令上
    if (expired) slice.* = null;
    arm();
    return expired;
}

/// 当前进程睡到 time 到 deadline（或者被 kill）。sleep 系统调用用。
pub fn sleepUntil(deadline: u64) void {
    lock.acquire();
    defer lock.release();
    var me: Sleeper = .{ .deadline = deadline };
    if (deadline <= now()) return;
    insert(&me);
    while (me.linked and !proc.isKilled()) me.queue.wait(&lock);
    if (me.linked) remove(&me); // 被 kill 叫醒的
}

/// 按到期时刻插进 sleepers。调用方拿着 lock。
fn insert(s: *Sleeper) void {
    var link = &sleepers;
    while (link.*) |x| : (link = &x.next) {
        if (x.deadline > s.deadline) break;
    }
    s.next = link.*;
    link.* = s;
    s.linked = true;
    updateEarliest();
}

fn remove(s: *Sleeper) void {
    var link = &sleepers;
    while (link.*) |x| : (link = &x.next) {
        if (x == s) {
            link.* = s.next;
            s.linked = false;
            updateEarliest();
            return;
        }
    }
    unreachable; // linked 为 true 就一定在 sleepers 里
}

fn updateEarliest() void {
    earliest.store(if (sleepers) |s| s.deadline else never, .release);
}
