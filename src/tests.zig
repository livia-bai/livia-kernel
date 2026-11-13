//! 单元测试的入口（zig build test）。在主机上运行，只测不碰硬件的纯逻辑：
//! 设备树解析、页分配器、页表、ELF 加载器、系统调用返回值的编码。
//! 内核的其余部分（陷阱、进出 U 模式、中断、硬件的权限检查）只能在 QEMU 里测，见 tools/qemu_test.py。

test {
    _ = @import("abi.zig");
    _ = @import("dtb.zig");
    _ = @import("page.zig");
    _ = @import("vm.zig");
    _ = @import("proc.zig");
    _ = @import("spinlock.zig");
    _ = @import("pipe.zig");
    _ = @import("file.zig");
    _ = @import("ipi.zig");
    _ = @import("sleeplock.zig");
    _ = @import("bio.zig");
    _ = @import("btree.zig");
    _ = @import("ctree.zig");
    _ = @import("fs.zig");
    _ = @import("canary.zig");
    _ = @import("kstack.zig");
    _ = @import("kstat.zig");
    _ = @import("loader.zig");
    _ = @import("pagecache.zig");
}
