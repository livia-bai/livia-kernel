//! 核间中断（IPI，inter-processor interrupt）：一个 hart 打断另一个 hart。
//!
//! S 模式自己发不了核间中断（要写 M 模式才能访问的 CLINT），所以请 OpenSBI 代发（sbi.sendIpi），
//! 目标 hart 收到的是 S 模式软件中断（scause = 中断 1），sip.SSIP 被置 1，处理时自己清掉。
//! 软件中断不带任何信息，只是让目标 hart 进一次陷阱处理程序。两种用途：
//!
//! - 叫醒空闲的 hart：调度器扫完一圈没有可运行的进程就 wfi，原来要等自己的下一个时钟中断（最多 10 ms）
//!   才会再扫。wakeup、kill、fork 让一个进程变成 runnable 时，给一个空闲的 hart 发核间中断，
//!   它的 wfi 立刻返回、马上去运行这个进程（wakeIdle）。
//! - 催正在运行被杀进程的 hart：kill 一个正在别的 hart 的 U 模式里运行的进程时，给那个 hart 发核间中断，
//!   它马上陷入内核，回到 U 模式之前在 checkKilled 里结束这个进程（send）。
//!
//! 哪些 hart 空闲记在 idle 里（每个 hart 一位）。调度器每一轮扫描之前置上自己那一位，挑中进程时清掉；
//! wakeIdle 用 cmpxchg 清掉一个 hart 的位再给它发：清掉了就说明“叫醒它”这件事归自己，
//! 两个 hart 同时叫醒进程时不会都去叫同一个空闲的 hart。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");
const kstat = @import("kstat.zig");
const sbi = @import("sbi.zig");
const hart = @import("hart.zig");

comptime {
    std.debug.assert(hart.max <= @bitSizeOf(usize));
}

/// 第 i 位为 1：hart i 的调度器正在扫描、或者已经扫完了正要 wfi，没在运行进程。
var idle: std.atomic.Value(usize) = .init(0);

/// 每个 hart 调用一次：在 sie 里使能软件中断，核间中断才会被接收（没使能的话 sip.SSIP 只是挂着）。
pub fn initHart() void {
    riscv.set(.sie, .{ .ssi = true });
}

/// 调度器调用：这一轮要开始扫描了（true），或者挑中了一个进程（false）。
///
/// 必须在扫描之前置位：别的 hart 把一个进程改成 runnable（拿着它的锁改）之后才读 idle。
/// 这个 hart 扫到那个进程时要拿同一把锁，所以要么扫的时候已经看到它是 runnable，
/// 要么那个 hart 读 idle 时一定看得到这一位（置位在放开那把锁之前），会发核间中断过来：
/// 中断挂在 sip 里，接下来的 wfi 立刻返回，不会白睡一觉。
pub fn setIdle(on: bool) void {
    const bit = @as(usize, 1) << @intCast(hart.id());
    if (on) {
        _ = idle.fetchOr(bit, .seq_cst);
    } else {
        _ = idle.fetchAnd(~bit, .seq_cst);
    }
}

/// 叫醒最多 n 个空闲的 hart（不算自己：自己的调度器反正会再扫一遍）。有进程变成 runnable 之后调用，
/// 调用方可以拿着锁。
pub fn wakeIdle(n: usize) void {
    var left = n;
    while (left > 0) : (left -= 1) {
        while (true) {
            const mask = idle.load(.seq_cst);
            const others = mask & ~(@as(usize, 1) << @intCast(hart.id()));
            if (others == 0) return;
            const bit = others & (~others +% 1); // 最低的一位
            if (idle.cmpxchgWeak(mask, mask & ~bit, .seq_cst, .seq_cst) == null) {
                send(@ctz(bit));
                break;
            }
        }
    }
}

/// 给 hart id 发一个核间中断。单元测试在主机上运行，什么也不做。
pub fn send(id: usize) void {
    kstat.inc(.ipis_sent);
    if (comptime !builtin.cpu.arch.isRISCV()) return;
    std.debug.assert(id != hart.id());
    const err = sbi.sendIpi(1, id);
    if (err != 0) std.debug.panic("cannot send an IPI to hart {d}: SBI error {d}", .{ id, err });
}

/// S 模式软件中断的处理：清掉 sip.SSIP，否则一开中断又会进来。别的什么都不用做：
/// 被叫醒的调度器接着扫描；被打断的进程回到 U 模式之前，handleTrap 末尾的 checkKilled 会看到它被杀了。
pub fn onInterrupt() void {
    riscv.clear(.sip, .{ .ssi = true });
}

test "wakeIdle 每次认领一个别的空闲 hart，不叫自己" {
    idle.store(0, .seq_cst);
    defer idle.store(0, .seq_cst);
    setIdle(true); // 主机上 hart.id() 总是 0
    idle.store(idle.load(.seq_cst) | 0b1010, .seq_cst); // hart 1、3 也空闲
    wakeIdle(1);
    try std.testing.expectEqual(0b1001, idle.load(.seq_cst)); // 认领了 hart 1
    wakeIdle(5);
    try std.testing.expectEqual(0b0001, idle.load(.seq_cst)); // 只剩自己
    setIdle(false);
    try std.testing.expectEqual(0, idle.load(.seq_cst));
}
