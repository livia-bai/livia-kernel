//! PLIC（Platform-Level Interrupt Controller）：把外设中断（这里只有串口）路由给 CPU。
//! 寄存器布局见 RISC-V PLIC 规范，地址和中断号来自 QEMU virt 机器。

const riscv = @import("riscv.zig");
const hart = @import("hart.zig");

pub const base: usize = 0x0c00_0000;
/// 寄存器区域的大小，见设备树 plic 节点的 reg。分页时要整块映射。
pub const mmio_size: usize = 0x60_0000;

pub const uart0_irq: u32 = 10;

/// 要接收的中断源（第 i 位是 i 号源）。init 设好，每个 hart 的 initHart 照着打开。
var enabled: u32 = 0;

/// 当前 hart 的 S 模式上下文。QEMU virt 上每个 hart 有两个 PLIC 上下文：2*hart 是 M 模式，2*hart+1 是 S 模式。
fn context() usize {
    return 2 * hart.id() + 1;
}

fn reg(offset: usize) *volatile u32 {
    return @ptrFromInt(base + offset);
}

fn priority(irq: u32) *volatile u32 {
    return reg(4 * irq);
}

fn enable() *volatile u32 {
    return reg(0x2000 + 0x80 * context());
}

fn threshold() *volatile u32 {
    return reg(0x20_0000 + 0x1000 * context());
}

fn claimComplete() *volatile u32 {
    return reg(0x20_0004 + 0x1000 * context());
}

/// 全局的设置，启动 hart 调用一次：打开串口，以及 disk_irq（virtio 磁盘的中断源，没有磁盘时是 0）。
pub fn init(disk_irq: u32) void {
    for ([_]u32{ uart0_irq, disk_irq }) |irq| {
        if (irq == 0) continue;
        priority(irq).* = 1; // 优先级为 0 表示“永不触发”，所以至少设成 1
        enabled |= @as(u32, 1) << @intCast(irq);
    }
}

/// 每个 hart 调用一次：串口、磁盘中断发给每个 hart（和 xv6 一样），谁先 claim 到谁处理，
/// 别的 hart 再 claim 时拿到 0。
pub fn initHart() void {
    enable().* = enabled;
    threshold().* = 0; // 接收所有优先级 > 0 的中断
    riscv.set(.sie, .{ .sei = true });
}

/// 领取当前优先级最高的待处理中断，返回中断号；0 表示没有。
pub fn claim() u32 {
    return claimComplete().*;
}

/// 告诉 PLIC 这个中断处理完了，之后它才会再次投递同一个中断。
pub fn complete(irq: u32) void {
    claimComplete().* = irq;
}
