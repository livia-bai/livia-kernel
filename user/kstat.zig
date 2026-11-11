//! kstat：打印内核的计数器（开机以来的累计值，所有 hart 加起来）和各种内核栈用到过的最深处。
//! 计数器的名字就是 abi.Counters 的字段名，这里按字段逐个打印，内核加了计数器这里不用改。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const k = sys.kstat();
    inline for (comptime std.meta.fieldNames(sys.abi.Counters)) |name| {
        sys.print("{s:<18} {d}\n", .{ name, @field(k.counters, name) });
    }
    sys.print("{s:<18} {d} of {d} bytes\n", .{ "stack_process", k.stack_process, k.stack_process_size });
    sys.print("{s:<18} {d} of {d} bytes\n", .{ "stack_boot", k.stack_boot, k.stack_boot_size });
    sys.print("{s:<18} {d} of {d} bytes\n", .{ "stack_trap", k.stack_trap, k.stack_trap_size });
    return 0;
}
