//! 时钟中断：每个 hart 每 10ms 触发一次。用来计时，也用来让 U 模式的进程让出 CPU。
//!
//! 每个 hart 有自己的定时器（SBI 的 set_timer 只设置当前 hart 的），各自预约自己的下一次中断。
//! 计时的 ticks 只有一份，只由启动 hart（kmain 所在的 hart）的时钟中断加 1，和 xv6 只让 cpu 0 加 ticks 一样：
//! 每个 hart 都加的话，ticks 就会快几倍。

const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");
const hart = @import("hart.zig");
const proc = @import("proc.zig");
const kstat = @import("kstat.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const tick_hz = 100;

/// time CSR 每秒增加的次数，来自设备树 /cpus 的 timebase-frequency（QEMU virt 上是 10MHz）。
var timebase_hz: u64 = undefined;

/// 每个 hart 的下一次时钟中断预约在 time CSR 的哪个值。只有这个 hart 自己读写自己那一项。
var deadline: [hart.max]u64 = undefined;

/// 由哪个 hart 的时钟中断给 ticks 加 1。
var timekeeper: usize = undefined;

/// 保护 ticks（xv6 的 tickslock）。sleep 系统调用拿着它检查时间、睡在 &ticks 上。
pub var lock: Spinlock = .init("ticks");
/// 开机以来的 tick 数。读写都要拿着 lock。
pub var ticks: u64 = 0;

/// 启动 hart 调用一次，在 initHart 之前。
pub fn init(hz: u64) void {
    timebase_hz = hz;
    timekeeper = hart.id();
}

/// 每个 hart 调用一次：预约第一次时钟中断，在 sie 里使能时钟中断。
pub fn initHart() void {
    deadline[hart.id()] = riscv.read(.time);
    arm();
    riscv.set(.sie, riscv.sie_stie);
}

/// 预约当前 hart 的下一次时钟中断：在上一次的预约时刻上加一个周期，而不是在“现在”上加。
/// 中断从到期到被处理总有延迟，按“现在”算的话，每个 tick 都会把这段延迟丢掉，
/// 实测计时比 time CSR 慢 2%～3%。处理晚了超过一个周期时，新的预约时刻已经过去，
/// 中断会立刻再来一次，ticks 自己追上。
fn arm() void {
    const d = &deadline[hart.id()];
    d.* += timebase_hz / tick_hz;
    sbi.setTimer(d.*);
}

/// 时钟中断处理：预约下一次。启动 hart 上还要给 ticks 加 1，叫醒 sleep 系统调用里的进程，
/// 它们自己数时间到了没有（xv6 的 clockintr）。
pub fn onInterrupt() void {
    kstat.inc(.timer_interrupts);
    arm();
    if (hart.id() != timekeeper) return;
    lock.acquire();
    defer lock.release();
    ticks += 1;
    proc.wakeup(&ticks);
}

/// 开机以来的毫秒数（从打开时钟中断算起），精度是一个 tick。
pub fn uptimeMs() u64 {
    lock.acquire();
    defer lock.release();
    return ticks * 1000 / tick_hz;
}
