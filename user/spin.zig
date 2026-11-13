//! 演示抢占：进入死循环，不再做任何系统调用。即便如此，每个时间片（10 ms）用完，时钟中断都会把 CPU 交回内核，
//! 别的进程和 shell 照样能运行；前台运行时按 Ctrl-C 结束它，后台运行时用 kill 结束它。

const sys = @import("sys");

pub fn main() u8 {
    sys.print("pid {d} spinning in U-mode without making syscalls\n", .{sys.getpid()});
    while (true) {}
}
