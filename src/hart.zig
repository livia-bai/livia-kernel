//! 多核：每个 hart 的编号，panic 时让所有 hart 停下。
//!
//! RISC-V 的 S 模式读不到自己的 hart 编号（mhartid 只有 M 模式能读），所以照 xv6 的做法，
//! 启动时把 OpenSBI 交过来的编号放进 tp，之后内核里 id() 直接读 tp。tp 在内核里专门干这个：
//! 从 U 模式陷入时 trapEntry 把它换回内核的值，回到 U 模式时 trapExit 再换成用户程序的（见 trap.zig）。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");

/// 最多支持几个 hart。编号 >= max 的 hart 不启动（每个 hart 的状态都是按编号下标的静态数组）。
pub const max = 8;

/// 当前 hart 的编号。单元测试在主机上运行，总是 0。
pub inline fn id() usize {
    if (comptime !builtin.cpu.arch.isRISCV()) return 0;
    return asm volatile ("mv %[ret], tp"
        : [ret] "=r" (-> usize),
    );
}

const nobody = std.math.maxInt(usize);

/// 正在 panic 的 hart，没有的话是 nobody。
var panicking: std.atomic.Value(usize) = .init(nobody);

/// panic 开始时调用：记下是这个 hart 在 panic。已经有别的 hart 在 panic 了，就直接停下，
/// 不再输出（两份 panic 信息交错在一起谁也看不清）。
pub fn beginPanic() void {
    if (panicking.cmpxchgStrong(nobody, id(), .acq_rel, .acquire)) |other| {
        if (other != id()) halt();
    }
}

/// 是不是当前 hart 在 panic。是的话输出不用拿锁（锁可能就在自己手里，或者在已经停下的 hart 手里）。
pub fn isPanicking() bool {
    return panicking.load(.acquire) == id();
}

/// 别的 hart 在 panic 的话就停下。在输出、自旋等锁、调度器每一轮里调用，
/// 这样一个 hart panic 之后，别的 hart 很快都会停下，不会继续输出、改数据。
pub fn checkPanic() void {
    const who = panicking.load(.acquire);
    if (who != nobody and who != id()) halt();
}

/// 停机：关中断，把 sie 也清零再 wfi。时钟中断没人再预约，会一直挂着，它在 sie 里还使能的话，
/// wfi 每次都立刻返回，停机就成了忙等（QEMU 占满一个 CPU 核）。
pub fn halt() noreturn {
    if (comptime !builtin.cpu.arch.isRISCV()) @panic("halt() in a unit test");
    riscv.disableInterrupts();
    riscv.write(.sie, .{});
    while (true) riscv.wfi();
}
