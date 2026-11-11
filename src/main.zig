//! 内核入口。OpenSBI 只启动一个 hart（启动 hart），以 S 模式跳到 _start，此时 a0 = 它的 hart 编号，
//! a1 = 设备树（DTB）地址；分页关闭（虚拟地址 = 物理地址），中断关闭，还没有栈。
//! 别的 hart 由 kmain 用 SBI 的 HSM 扩展启动，从 secondaryEntry 进来。

const std = @import("std");
const riscv = @import("riscv.zig");
const sbi = @import("sbi.zig");
const uart = @import("uart.zig");
const trap = @import("trap.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const dtb = @import("dtb.zig");
const page = @import("page.zig");
const vm = @import("vm.zig");
const proc = @import("proc.zig");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");
const virtio_disk = @import("virtio_disk.zig");
const bio = @import("bio.zig");
const kstack = @import("kstack.zig");

/// 替换标准库默认的 panic 处理。@panic、std.debug.panic 以及
/// Debug 模式下的安全检查失败（整数溢出、数组越界等）都会走到这里。
pub const panic = std.debug.FullPanic(kernelPanic);

fn kernelPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    riscv.disableInterrupts();
    // 别的 hart 下一次输出、等锁或者调度时会看到，自己停下
    hart.beginPanic();
    uart.print("\n!!! KERNEL PANIC on hart {d}: {s}\n", .{ hart.id(), msg });
    // 调用栈：返回地址，用 llvm-symbolizer -e zig-out/bin/kernel 换成函数名和行号（qemu_test.py 会自动换）。
    // 安全检查失败时 first_trace_addr 是出错的地方，先打印它；然后从这里沿帧指针往上走
    var frames: [24]usize = undefined;
    uart.write("backtrace:");
    if (first_trace_addr) |a| uart.print(" 0x{x}", .{a});
    for (kstack.backtrace(@frameAddress(), &kstack.contains, &frames)) |ra| uart.print(" 0x{x}", .{ra});
    uart.write("\nsystem halted.\n");
    hart.halt();
}

// 每个 hart 的启动栈（kstack.boot，32 KiB，下面一页是保护页），按 hart 编号下标。kmain / kmainSecondary 在上面运行，
// 之后归这个 hart 的调度器用。最底下放着金丝雀（canary.zig），kmain 一开始给所有 hart 写上（kstack.paintAll），调度器每一轮检查。
// 导出成符号 boot_stacks，汇编里按名字取地址：用 "X" 约束传进去的话，编译器会先把地址算进一个寄存器（这里占了 a0）。
// 导出要写在根文件里（docs/zig-0.17.md）。
comptime {
    @export(&kstack.boot, .{ .name = "boot_stacks" });
}

/// 把 a0（hart 编号）放进 tp（见 hart.zig），sp 指向这个 hart 的启动栈的顶端：
/// boot_stacks + (a0 + 1) * 一块的大小（保护页 + 栈，36 KiB 不是 2 的幂，用乘法）。
const enter_asm =
    \\mv tp, a0
    \\la sp, boot_stacks
    \\addi t0, a0, 1
    \\li t1, %[slot]
    \\mul t0, t0, t1
    \\add sp, sp, t0
    \\
;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
    // hart 编号太大的话没有启动栈可用，停在这里（QEMU virt 的编号从 0 开始，不会走到这里）
        \\li t0, %[max]
        \\bgeu a0, t0, 3f
        // 清零 .bss：初值为 0 的全局变量都在这里，ELF 文件里不占空间，需要自己清。
        // 启动栈也在 .bss 里，所以先清零、再用栈。只有启动 hart 做这件事，别的 hart 从 secondaryEntry 进来
        \\la t0, __bss_start
        \\la t1, __bss_end
        \\1:
        \\bgeu t0, t1, 2f
        \\sd zero, 0(t0)
        \\addi t0, t0, 8
        \\j 1b
        \\2:
    ++ enter_asm ++
        // a0、a1 没动过，原样作为参数传给 kmain
        \\tail %[kmain]
        \\3:
        \\wfi
        \\j 3b
        :
        : [kmain] "X" (&kmain),
          [slot] "i" (@sizeOf(kstack.Boot)),
          [max] "i" (hart.max),
    );
}

/// 别的 hart 的入口：SBI 的 hart_start 让它从这里开始执行，a0 = 它的 hart 编号，
/// 分页关闭、中断关闭（见 startHarts）。
fn secondaryEntry() callconv(.naked) noreturn {
    asm volatile (enter_asm ++
            \\tail %[kmainSecondary]
        :
        : [kmainSecondary] "X" (&kmainSecondary),
          [slot] "i" (@sizeOf(kstack.Boot)),
    );
}

fn kmain(hartid: usize, dtb_addr: usize) callconv(.c) noreturn {
    // 所有的栈都写上金丝雀的图案（canary.zig）：每块栈最底下的金丝雀由此写好，之后调度器每一轮检查启动栈的；
    // 栈从没用到的地方也保持图案，shutdown 时量出每种栈用到过多深（kstack.deepest）。
    // kmain 那一串初始化是启动栈用得最深的地方，越早写上越好
    kstack.paintAll(hartid);
    // OpenSBI 交过来时 FS 是 Dirty，浮点单元开着。这个内核不支持浮点（陷阱处理不保存浮点寄存器），
    // 关掉它：否则用户程序能直接用浮点寄存器，里面的值还会留给下一个进程
    riscv.clear(.sstatus, riscv.sstatus_fs);
    uart.init();
    uart.write("\nHello from a Zig kernel on RISC-V!\n");
    const version = sbi.specVersion();
    uart.print("SBI: {s}, spec v{d}.{d} | hart {d} | device tree at 0x{x}\n", .{
        sbi.implName(), version.major, version.minor, hartid, dtb_addr,
    });

    trap.init();
    uart.write("[ok] trap vector installed\n");
    // 自检：主动触发一次断点异常，确认陷阱能进能出
    asm volatile ("ebreak");

    const info = dtb.parse(dtb_addr) catch |err| {
        std.debug.panic("cannot parse device tree at 0x{x}: {s}", .{ dtb_addr, @errorName(err) });
    };
    uart.print("[ok] device tree: {d} MiB RAM at 0x{x}, timebase {d} Hz\n", .{
        info.memory.size >> 20, info.memory.base, info.timebase_hz,
    });

    page.init(vm.kernelEnd(), info.memory.end(), info.reserved());
    const free_pages = page.freePages();
    uart.print("[ok] page allocator: {d} free pages ({d} KiB)\n", .{ free_pages, free_pages * page.size / 1024 });

    const guards = kstack.guardPages();
    vm.init(info.memory, &guards) catch |err| std.debug.panic("cannot set up paging: {s}", .{@errorName(err)});
    uart.print("[ok] Sv39 paging enabled: kernel mapped 1:1, text r-x, rodata r--, data rw-, {d} stack guard pages unmapped\n", .{guards.len});
    // 自检：模拟一次内核栈溢出（sp 越过启动栈的底），缺页要在陷阱栈上处理（trap.probeGuard）
    if (!trap.probeGuard(@intFromPtr(&kstack.boot[hartid].stack))) @panic("stack guard page is mapped");
    uart.write("[ok] stack overflow check: hitting a guard page traps onto the trap stack\n");

    // 找磁盘（要访问 MMIO，所以在开分页之后），PLIC 要知道它的中断号
    virtio_disk.init();
    bio.init(if (virtio_disk.blocks > 0) .{ .blocks = virtio_disk.blocks, .transfer = virtio_disk.rw, .flush = virtio_disk.flush } else null);

    plic.init(virtio_disk.irq);
    plic.initHart();
    timer.init(info.timebase_hz);
    timer.initHart();
    ipi.initHart();
    uart.print("[ok] interrupt sources enabled: timer at {d} Hz, keyboard via UART + PLIC, IPIs{s}\n", .{
        timer.tick_hz, if (virtio_disk.irq != 0) ", disk" else "",
    });

    startHarts(hartid, info.harts(), info.timebase_hz);

    // 和 xv6 的 main 一样：建好第一个进程 init，然后启动栈就交给调度器，永远不回来。
    // init 再启动 shell（user/init.zig、user/sh.zig）。别的 hart 已经在各自的调度器里等着了，
    // init 可能在任何一个 hart 上运行。
    // 全局的中断开关 sstatus.SIE 这里不开：内核代码都关着中断运行（拿锁时也要求这样，见 spinlock.zig），
    // 调度器每一轮开头才开一下。
    proc.userinit() catch |err| std.debug.panic("cannot start init: {s}", .{@errorName(err)});
    proc.scheduler(&kstack.boot[hartid].stack);
}

/// 做完了自己那份初始化、进了调度器的 hart 数（不算启动 hart）。
var harts_online: std.atomic.Value(usize) = .init(0);

/// 用 SBI 的 HSM 扩展启动设备树里列出的其他 hart，一个一个来：等上一个报到了再启动下一个，
/// 这样启动日志的顺序是固定的。每个最多等一秒，等不到就 panic。
fn startHarts(self: usize, ids: []const u32, timebase_hz: u64) void {
    var started: usize = 0;
    for (ids) |id| {
        if (id == self) continue;
        if (id >= hart.max) {
            uart.print("[warn] hart {d} not started: at most {d} harts are supported\n", .{ id, hart.max });
            continue;
        }
        // 新的 hart 要看到这个 hart 之前写的所有东西（页表、页分配器、各个模块的初始化）。
        // SBI 规范没有说 hart_start 本身会保证这一点，所以先自己做一次 fence
        asm volatile ("fence rw, rw" ::: .{ .memory = true });
        const err = sbi.hartStart(id, @intFromPtr(&secondaryEntry), 0);
        if (err != 0) {
            uart.print("[warn] cannot start hart {d}: SBI error {d}\n", .{ id, err });
            continue;
        }
        started += 1;
        const deadline = riscv.read(.time) + timebase_hz;
        while (harts_online.load(.acquire) < started) {
            if (riscv.read(.time) > deadline) std.debug.panic("hart {d} did not come online", .{id});
            std.atomic.spinLoopHint();
        }
    }
    const n = started + 1;
    uart.print("[ok] {d} hart{s} running, booted on hart {d}\n", .{ n, if (n == 1) "" else "s", self });
}

/// 其他 hart 的初始化（kmain 的每个 hart 一份的部分），然后进入调度器。全局的东西启动 hart 都已经做好了。
fn kmainSecondary() callconv(.c) noreturn {
    riscv.clear(.sstatus, riscv.sstatus_fs); // 见 kmain
    trap.init();
    vm.initHart();
    plic.initHart();
    timer.initHart();
    ipi.initHart();
    _ = harts_online.fetchAdd(1, .release);
    proc.scheduler(&kstack.boot[hart.id()].stack);
}
