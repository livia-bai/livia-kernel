//! QEMU virt 机器上的 NS16550A 串口驱动，同时承担“屏幕”和“键盘”：
//! 输出用轮询，输入用中断——收到字符时串口经 PLIC 发来外部中断，中断处理程序把字符放进环形缓冲区。
//!
//! 输出由 tx_lock 保护：几个 hart 同时输出时，每次 print / write 整段输出，不会和别的 hart 的输出
//! 交错在一行里。panic 的 hart 不拿锁（锁可能就在它自己手里），别的 hart 一输出就停下（hart.checkPanic）。

const std = @import("std");
const hart = @import("hart.zig");
const Spinlock = @import("spinlock.zig").Spinlock;
const proc = @import("proc.zig");

pub const base: usize = 0x1000_0000;
pub const mmio_size: usize = 0x100;

const Reg = enum(usize) {
    rbr_thr = 0, // 读：接收缓冲；写：发送保持
    ier = 1, // 中断使能
    fcr = 2, // FIFO 控制
    lcr = 3, // 线路控制
    lsr = 5, // 线路状态
};

const lsr_data_ready: u8 = 1 << 0;
const lsr_thr_empty: u8 = 1 << 5;

fn reg(r: Reg) *volatile u8 {
    return @ptrFromInt(base + @backingInt(r));
}

pub fn init() void {
    reg(.ier).* = 0x00; // 配置期间先关掉串口中断
    reg(.lcr).* = 0x03; // 8 位数据、无校验、1 位停止位
    reg(.fcr).* = 0x07; // 启用并清空收发 FIFO
    reg(.ier).* = 0x01; // 收到数据时产生中断
}

fn putRaw(c: u8) void {
    while (reg(.lsr).* & lsr_thr_empty == 0) {}
    reg(.rbr_thr).* = c;
}

fn putc(c: u8) void {
    // 别的 hart 在 panic 的话停下，让它的 panic 信息完整地输出
    hart.checkPanic();
    // 终端需要 \r\n 才会回到行首
    if (c == '\n') putRaw('\r');
    putRaw(c);
}

/// 保护输出：拿着它输出的一段不会和别的 hart 的输出交错。
var tx_lock: Spinlock = .init("uart tx", .uart_out);

/// 拿着输出锁的一段输出，由 lockOutput 开始，unlock 结束。
pub const Output = struct {
    /// 是否拿了 tx_lock：panic 的 hart 不拿
    locked: bool,

    pub fn write(o: Output, bytes: []const u8) void {
        _ = o;
        for (bytes) |c| putc(c);
    }

    pub fn unlock(o: Output) void {
        if (o.locked) tx_lock.release();
    }
};

/// 开始一段不被别的 hart 打断的输出（file.zig 的 consoleWrite 用它把一次 write 系统调用整段输出）。
/// 拿着它时不能再调用 print、write（同一个 hart 重复拿锁会 panic）。
pub fn lockOutput() Output {
    if (hart.isPanicking()) return .{ .locked = false };
    tx_lock.acquire();
    return .{ .locked = true };
}

pub fn write(bytes: []const u8) void {
    const out = lockOutput();
    defer out.unlock();
    out.write(bytes);
}

fn getc() ?u8 {
    if (reg(.lsr).* & lsr_data_ready == 0) return null;
    return reg(.rbr_thr).*;
}

// 接收环形缓冲区：中断处理程序写入，read 系统调用读出（file.consoleRead）。
// 索引用 u8，+% 回绕正好对应 256 字节的缓冲区。
var rx_buf: [256]u8 = undefined;
var rx_head: u8 = 0;
var rx_tail: u8 = 0;

/// 接收缓冲区最多装几个字符（rx_head 追上 rx_tail 前一格就算满了）。一次 read 最多读到这么多
pub const rx_capacity = rx_buf.len - 1;

/// 保护接收缓冲区。中断处理程序也要拿它：拿着它的代码都关着中断，同一个 hart 上不会被中断打断，
/// 所以不会自己等自己；多核时串口中断可能在另一个 hart 上处理。
pub var rx_lock: Spinlock = .init("uart rx", .cond);

/// rx_lock。等键盘输入的进程排在这里，收到字符后陷阱处理程序叫醒它们。
pub var rx_waiters: proc.WaitQueue = .{};

/// Ctrl-C（ASCII 0x03）不进缓冲区，陷阱处理程序据此结束前台进程。
const ctrl_c = 0x03;

/// 串口中断处理：把硬件 FIFO 里的字符全部搬进环形缓冲区，满了就丢弃。返回这次有没有按过 Ctrl-C。
pub fn onInterrupt() bool {
    rx_lock.acquire();
    defer rx_lock.release();
    var ctrl_c_pressed = false;
    while (getc()) |c| {
        if (c == ctrl_c) {
            ctrl_c_pressed = true;
            continue;
        }
        if (rx_head +% 1 == rx_tail) continue;
        rx_buf[rx_head] = c;
        rx_head +%= 1;
    }
    return ctrl_c_pressed;
}

/// 缓冲区里有没有字符。调用方要拿着 rx_lock，下同。
pub fn hasInput() bool {
    std.debug.assert(rx_lock.holding());
    return rx_tail != rx_head;
}

/// 看一眼下一个字符，不取出来。
pub fn peek() ?u8 {
    std.debug.assert(rx_lock.holding());
    if (rx_tail == rx_head) return null;
    return rx_buf[rx_tail];
}

/// 取出一个已收到的字符。
pub fn read() ?u8 {
    const c = peek() orelse return null;
    rx_tail +%= 1;
    return c;
}

/// 接入 std.Io.Writer 接口，这样就能用标准库的格式化输出（{d}、{x}、{s} 等）。
/// buffer 为空，所以每次写入都直接走 drain，不需要 flush。
var writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    const out: Output = .{ .locked = false }; // print 已经拿着锁了
    var n: usize = 0;
    for (data[0 .. data.len - 1]) |bytes| {
        out.write(bytes);
        n += bytes.len;
    }
    // 最后一段要重复 splat 次（用于填充对齐等）
    const pattern = data[data.len - 1];
    for (0..splat) |_| out.write(pattern);
    return n + pattern.len * splat;
}

/// 格式化输出。整条输出拿着 tx_lock：格式化时 drain 会被调用好几次（每个参数、每段字面量各一次），
/// 只在 drain 里拿锁的话，别的 hart 的输出会插进一行的中间。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const out = lockOutput();
    defer out.unlock();
    writer.print(fmt, args) catch {};
}
