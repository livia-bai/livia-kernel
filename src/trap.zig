//! 陷阱（trap）处理。RISC-V 里异常（除零以外的各种错误、ebreak、ecall）和中断（时钟、外设）
//! 统一叫陷阱，发生时 CPU 跳到 stvec 指向的地址，并在 scause 里说明原因。
//! 相当于 x86 上 IDT 的角色。

const std = @import("std");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");
const timer = @import("timer.zig");
const proc = @import("proc.zig");
const vm = @import("vm.zig");
const ipi = @import("ipi.zig");
const virtio_disk = @import("virtio_disk.zig");
const syscall = @import("syscall.zig");
const spinlock = @import("spinlock.zig");
const kstack = @import("kstack.zig");
const hart = @import("hart.zig");

/// 陷阱发生时被打断的上下文。regs[i] 就是寄存器 xi（x0 恒为 0，它的槽位不用）。
/// 布局必须和 trapEntry、trapExit 里的汇编一致。
pub const TrapFrame = extern struct {
    regs: [32]usize,
    sepc: usize,
    sstatus: riscv.Sstatus,
    /// 回到 U 模式时内核的 tp（当前 hart 的编号，见 hart.zig），下次从 U 模式陷入时换回来
    kernel_tp: usize = 0,
    /// 处理完这个陷阱、回到被打断的地方时 sscratch 要恢复成什么（见 trapEntry 的 sscratch 约定）：
    /// 来自 U 模式的，是回到 U 模式时内核的 sscratch（这个 hart 的陷阱栈顶），下次陷入时换回来，和 kernel_tp 一样；
    /// 来自 S 模式的，是陷入前的 sscratch（陷阱栈顶，或者嵌套时的 0）。
    /// 它也让 TrapFrame 的大小是 16 的倍数：TrapFrame 放在栈顶，它的下沿就是 handleTrap 开始用的 sp，要 16 字节对齐
    kernel_sscratch: usize = 0,
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) % 16 == 0);
}

/// scause 最高位为 1 时，低位是中断编号。
const Interrupt = enum(usize) {
    supervisor_software = 1,
    supervisor_timer = 5,
    supervisor_external = 9,
    _,
};

/// scause 最高位为 0 时，低位是异常编号。
const Exception = enum(usize) {
    instruction_misaligned = 0,
    instruction_access_fault = 1,
    illegal_instruction = 2,
    breakpoint = 3,
    load_misaligned = 4,
    load_access_fault = 5,
    store_misaligned = 6,
    store_access_fault = 7,
    ecall_from_u = 8,
    ecall_from_s = 9,
    instruction_page_fault = 12,
    load_page_fault = 13,
    store_page_fault = 15,
    _,
};

/// 每个 hart 启动时调用一次（stvec、sscratch 都是每个 hart 自己的）。
pub fn init() void {
    // stvec 低 2 位是模式，0 = Direct：所有陷阱都进同一个入口。
    // trapEntry 按 4 字节对齐，所以地址低 2 位天然是 0。
    riscv.write(.stvec, @intFromPtr(&trapEntry));
    // 在内核里（不在处理 S 模式的陷阱时）sscratch 是这个 hart 的陷阱栈顶（见 trapEntry）。固件不保证它的初值
    riscv.write(.sscratch, kstack.trap[hart.id()].top());
}

// ---- sscratch、tp 约定的检查 ----
//
// 这两个约定（见 docs/trap.md）原来只写在注释里：trapEntry、trapExit 的汇编哪里换错了一个寄存器，
// 多半要等到另一个 hart、另一个进程上才出事，症状离原因很远。现在三个地方各检查一次，违反了马上 panic：
// 启动时每个 hart（checkBoot）、每次进陷阱处理程序（checkEntry）、调度器每一轮（checkIdle）。
// 都只读一两个 CSR、比几个地址，代价可以忽略。tp 没法直接核对（hart.id() 就是读它），
// 就核对靠它找到的东西：启动栈、陷阱栈、当前进程的 TrapFrame 都得是这个 hart 的。

fn conventionBroken(comptime what: []const u8, args: anytype) noreturn {
    std.debug.panic("trap convention broken: " ++ what, args);
}

/// 启动时（trap.init 之后）：tp 是固件给的 hart 编号，sscratch 是这个 hart 的陷阱栈顶，sp 在这个 hart 的启动栈里。
/// hartid 是固件交过来的编号（kmain 的参数）；别的 hart 上没有独立的来源，传 hart.id()，只核对 sp 和 sscratch。
pub fn checkBoot(hartid: usize) void {
    const h = hart.id();
    if (h != hartid or h >= hart.max) conventionBroken("tp is {d}, the firmware says hart {d}", .{ h, hartid });
    checkIdle();
    const sp = asm volatile ("mv %[sp], sp"
        : [sp] "=r" (-> usize),
    );
    const stack = &kstack.boot[h].stack;
    if (sp <= @intFromPtr(stack) or sp > @intFromPtr(stack) + stack.len) conventionBroken("sp 0x{x} is not on the boot stack of hart {d}", .{ sp, h });
}

/// 在内核里、不在处理陷阱时（调度器每一轮）：sscratch 是这个 hart 的陷阱栈顶。
pub fn checkIdle() void {
    const h = hart.id();
    const ss = riscv.read(.sscratch);
    if (ss != kstack.trap[h].top()) conventionBroken("sscratch is 0x{x} on hart {d}, expected its trap stack top 0x{x}", .{ ss, h, kstack.trap[h].top() });
}

/// 刚进陷阱处理程序：来自 S 模式的，sscratch 是 0（处理期间再陷入就压在当时的栈上）；来自 U 模式的，trapEntry 已经把
/// sscratch 换回这个 hart 的陷阱栈顶、tp 换回内核的，TrapFrame 就是这个 hart 上当前进程的（proc.frameOf）。
fn checkEntry(frame: *TrapFrame, from_user: bool) void {
    const h = hart.id();
    if (h >= hart.max) conventionBroken("tp is {d}, not a hart id", .{h});
    if (!from_user) {
        const ss = riscv.read(.sscratch);
        if (ss != 0) conventionBroken("sscratch is 0x{x} while handling a trap from S-mode on hart {d}", .{ ss, h });
        return;
    }
    checkIdle();
    const p = proc.current() orelse conventionBroken("trap from U-mode on hart {d} with no current process", .{h});
    if (frame != proc.frameOf(p)) conventionBroken("trap from U-mode on hart {d}: TrapFrame at 0x{x}, the current process's is at 0x{x}", .{ h, @intFromPtr(frame), @intFromPtr(proc.frameOf(p)) });
}

/// 在编译期生成保存/恢复 x1、x3..x31 的 30 条指令（x0 恒为 0 不用存，sp 单独处理）。
fn regsAsm(comptime op: []const u8) []const u8 {
    var s: []const u8 = "";
    for (1..32) |i| {
        if (i == 2) continue;
        s = s ++ std.fmt.comptimePrint("{s} x{d}, {d}(sp)\n", .{ op, i, i * @sizeOf(usize) });
    }
    return s;
}

const save_regs = regsAsm("sd");
const restore_regs = regsAsm("ld");

const asm_offsets = .{
    .size = @sizeOf(TrapFrame),
    .sp = 2 * @sizeOf(usize),
    .sepc = @offsetOf(TrapFrame, "sepc"),
    .sstatus = @offsetOf(TrapFrame, "sstatus"),
    .kernel_tp = @offsetOf(TrapFrame, "kernel_tp"),
    .kernel_sscratch = @offsetOf(TrapFrame, "kernel_sscratch"),
};

/// 陷阱入口。在 TrapFrame 里保存被打断的上下文，然后调用 handleTrap。
///
/// 陷阱可能来自 U 模式（用户程序），也可能来自 S 模式（内核自己）。TrapFrame 压在哪块栈上，由 sscratch 决定：
/// - 在 U 模式运行时，sscratch 是当前进程的内核栈顶：TrapFrame 总在进程内核栈的最顶上（proc.frameOf）。
/// - 在内核里（系统调用、调度器……）运行时，sscratch 是这个 hart 的陷阱栈顶（kstack.trap）：S 模式的陷阱
///   都在陷阱栈上处理，不用被打断的那块栈。内核栈溢出、撞到保护页时，被打断的 sp 已经在保护页里了，
///   再往它下面压 TrapFrame 又会缺页、无限循环下去；换到陷阱栈上，handleTrap 才能报出是哪块栈溢出了。
/// - 正在处理 S 模式的陷阱时，sscratch 为 0：再来的陷阱（只可能是处理程序自己出错）压在当前的栈上，
///   不会盖掉陷阱栈顶上正在用的 TrapFrame。
/// 入口先交换 sp 和 sscratch：交换后 sp 不为 0 就用它（进程内核栈顶或者陷阱栈顶）；为 0 是嵌套的陷阱，
/// 原来的 sp 在 sscratch 里，取回来接着用。三种情况下 sscratch 最后都存着被打断时的 sp，保存进 TrapFrame 之后
/// 清零，处理期间保持 0；来自 U 模式的，再换成 kernel_sscratch（trapExit 回到 U 模式时留下的陷阱栈顶），
/// 系统调用里内核自己出的错就在陷阱栈上处理。来自 S 模式的，在 kernel_sscratch 里记下陷入前的 sscratch，
/// trapExit 回去时恢复：TrapFrame 压在陷阱栈顶的（frame + size 不等于被打断的 sp）是陷阱栈顶，嵌套的是 0。
///
/// 内核用 tp 存当前 hart 的编号（hart.zig）。来自 U 模式时 tp 是用户程序的，存进 TrapFrame 之后
/// 换成 trapExit 回到 U 模式时留下的 kernel_tp；来自内核时 tp 本来就是对的，不动。
/// 内核不使用 gp（不做 gp 相对寻址），用户程序留在里面的值不用换掉。
fn trapEntry() align(4) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\csrrw sp, sscratch, sp
            \\bnez sp, 1f
            \\csrr sp, sscratch
            \\1:
            \\addi sp, sp, -{[size]d}
            \\
        ++ save_regs ++
            \\csrrw t0, sscratch, zero
            \\sd t0, {[sp]d}(sp)
            \\csrr t1, sepc
            \\sd t1, {[sepc]d}(sp)
            \\csrr t1, sstatus
            \\sd t1, {[sstatus]d}(sp)
            \\andi t1, t1, %[spp]
            \\bnez t1, 2f
            \\ld tp, {[kernel_tp]d}(sp)
            \\ld t1, {[kernel_sscratch]d}(sp)
            \\csrw sscratch, t1
            \\j 4f
            \\2:
            \\addi t1, sp, {[size]d}
            \\bne t1, t0, 3f
            \\li t1, 0
            \\3:
            \\sd t1, {[kernel_sscratch]d}(sp)
            \\4:
            \\mv a0, sp
            \\call %[handleTrap]
            \\tail %[trapExit]
        , asm_offsets)
        :
        : [handleTrap] "X" (&handleTrap),
          [trapExit] "X" (&trapExit),
          [spp] "i" (comptime riscv.bits(riscv.Sstatus{ .spp = .supervisor })),
    );
}

/// 按 sp 指向的 TrapFrame 恢复上下文，执行 sret 回到被打断的地方。
/// 除了陷阱返回，新进程第一次被调度时也从这里进入 U 模式（见 proc.forkret）。
///
/// 先写回 sstatus：其中 SIE 为 0，之后不会再被中断打断；SPP 决定 sret 回到哪个特权级。
/// 如果要回到 U 模式，先把内核现在的 sscratch（这个 hart 的陷阱栈顶）存进 kernel_sscratch、内核的 tp 存进 kernel_tp，
/// 下次陷入时换回来；再把这个 TrapFrame 的上沿（也就是内核栈顶）存进 sscratch，
/// 下次从 U 模式陷入时 trapEntry 就从这里开始用内核栈。进程可能在别的 hart 上被调度过，所以每次回到 U 模式都要重新存。
/// 回到 S 模式的话，sscratch 恢复成 trapEntry 记下的值。
pub fn trapExit() callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\ld t0, {[sstatus]d}(sp)
            \\csrw sstatus, t0
            \\andi t0, t0, %[spp]
            \\bnez t0, 1f
            \\csrr t0, sscratch
            \\sd t0, {[kernel_sscratch]d}(sp)
            \\sd tp, {[kernel_tp]d}(sp)
            \\addi t0, sp, {[size]d}
            \\csrw sscratch, t0
            \\j 2f
            \\1:
            \\ld t0, {[kernel_sscratch]d}(sp)
            \\csrw sscratch, t0
            \\2:
            \\ld t0, {[sepc]d}(sp)
            \\csrw sepc, t0
            \\
        ++ restore_regs ++
            \\ld sp, {[sp]d}(sp)
            \\sret
        , asm_offsets)
        :
        : [spp] "i" (comptime riscv.bits(riscv.Sstatus{ .spp = .supervisor })),
    );
}

fn handleTrap(frame: *TrapFrame) callconv(.c) void {
    const scause = riscv.read(.scause);
    const code = scause.code;
    const from_user = frame.sstatus.spp == .user;
    checkEntry(frame, from_user);

    if (scause.interrupt) {
        const interrupt: Interrupt = @fromBackingInt(code);
        switch (interrupt) {
            .supervisor_timer => {
                // 叫醒到期的 sleep；这一片用完了的话，打断的是 U 模式时让它让出 CPU
                const expired = timer.onInterrupt();
                if (from_user and expired) {
                    // 时间片用完了，让出 CPU（xv6 的 usertrap 也是这样）。用户程序就算在 U 模式里死循环，
                    // 时钟中断也会把 CPU 交回内核。下次轮到它时（可能在别的 hart 上）返回，经 trapExit 回到 U 模式。
                    // 放在中断处理全部完成之后：可能很久以后才返回。
                    // （内核代码都是关着中断执行的，所以中断打断的要么是 U 模式，要么是调度器。）
                    proc.yieldTimeslice();
                }
            },
            .supervisor_external => handleExternal(),
            // 核间中断：别的 hart 叫醒这个空闲的 hart，或者杀了正在这里运行的进程（末尾的 checkKilled 结束它）
            .supervisor_software => ipi.onInterrupt(),
            else => std.debug.panic("unexpected interrupt {d}", .{code}),
        }
    } else if (from_user) {
        const exception: Exception = @fromBackingInt(code);
        switch (exception) {
            .ecall_from_u => {
                // sepc 指向 ecall 本身（固定 4 字节，没有压缩形式），返回时要跳过它
                frame.sepc += 4;
                // 返回值写进 a0；exec 成功时 TrapFrame 已经换成新程序的，不写（dispatch 返回 null）
                if (syscall.dispatch(frame)) |ret| frame.regs[10] = ret;
            },
            // 缺页：按需分页（还没分配的页，段里的从程序文件读）、写时复制（写了 fork 之后和别的进程共用的页），
            // 见 vm.fault。处理完回到原来的地方重新执行这条指令。地址不该有页（没有映射的地址、保护页）、
            // 或者不允许这样访问（写只读的段、执行数据）的，照常结束进程。这里没拿着锁，可以睡着等读盘
            .load_page_fault, .store_page_fault, .instruction_page_fault => {
                const stval = riscv.read(.stval);
                const access: vm.Access = switch (exception) {
                    .load_page_fault => .read,
                    .store_page_fault => .write,
                    else => .exec,
                };
                vm.fault(&proc.current().?.space, stval, access) catch |err| switch (err) {
                    error.BadAddress => killForFault(frame, exception),
                    error.OutOfMemory => proc.killCurrent("out of memory (demand paging) at 0x{x}, stval=0x{x}", .{ frame.sepc, stval }),
                    error.CowOutOfMemory => proc.killCurrent("out of memory (copy-on-write) at 0x{x}, stval=0x{x}", .{ frame.sepc, stval }),
                    error.IoError => proc.killCurrent("cannot read the program file (demand paging) at 0x{x}, stval=0x{x}", .{ frame.sepc, stval }),
                };
            },
            else => killForFault(frame, exception),
        }
    } else {
        const exception: Exception = @fromBackingInt(code);
        switch (exception) {
            .breakpoint => {
                uart.print("[trap] breakpoint at 0x{x}, skipping it\n", .{frame.sepc});
                // sepc 指向 ebreak 本身，跳过它才不会无限循环
                frame.sepc += instructionLength(frame.sepc);
            },
            // 内核碰到了栈下面的保护页：栈溢出了。这个陷阱是在陷阱栈上处理的（见 trapEntry），所以还能报出来。
            // 启动时的自检（probeGuard）是故意碰的，跳过那条指令
            .load_page_fault, .store_page_fault, .instruction_page_fault => if (kstack.guardOwner(riscv.read(.stval))) |owner| {
                if (!probing) stackOverflow(owner, frame);
                probe_hit = true;
                frame.sepc += instructionLength(frame.sepc);
            } else unhandled(exception, code, frame),
            else => unhandled(exception, code, frame),
        }
    }
    // 回到 U 模式之前：先看内核栈溢出了没有（溢出会踩坏相邻进程的 TrapFrame，见 canary.zig）。
    // 被 kill 了（比如在 yield、sleep 里等着的时候，或者刚才的串口中断是 Ctrl-C）就在这里结束
    if (from_user) {
        proc.checkStack();
        proc.checkKilled();
        proc.assertNoLocksHeld();
    }
}

/// probeGuard 正在故意碰保护页。只在启动 hart 的 kmain 里用，那时别的 hart 还没启动
var probing = false;
var probe_hit = false;

/// 启动时的自检：模拟一次内核栈溢出。把 sp 挪到 stack_bottom（一块栈的底，也就是它的保护页的上沿），
/// 往栈上压一个字：这时 sp 已经越过了栈底，和栈溢出时一样。trapEntry 要在陷阱栈上处理这个缺页
/// （handleTrap 看到 probing，跳过这条指令），回来之后恢复 sp。返回缺页有没有发生。
/// trapEntry 要是往被打断的栈（保护页）上压 TrapFrame，就会一直缺页下去，启动停在这里。
pub fn probeGuard(stack_bottom: usize) bool {
    probing = true;
    defer probing = false;
    probe_hit = false;
    // 用固定的寄存器：t0 存原来的 sp，stack_bottom 在 a0，编译器不会把它们分给别的
    asm volatile (
        \\mv t0, sp
        \\mv sp, a0
        \\sd zero, -8(sp)
        \\mv sp, t0
        :
        : [bottom] "{a0}" (stack_bottom),
        : .{ .t0 = true, .memory = true });
    return probe_hit;
}

fn unhandled(exception: Exception, code: usize, frame: *TrapFrame) noreturn {
    std.debug.panic("unhandled exception: {s} (scause={d}), sepc=0x{x}, stval=0x{x}", .{
        std.enums.tagName(Exception, exception) orelse "unknown",
        code,
        frame.sepc,
        riscv.read(.stval),
    });
}

fn stackOverflow(owner: kstack.Owner, frame: *TrapFrame) noreturn {
    const stval = riscv.read(.stval);
    switch (owner) {
        .boot => |h| std.debug.panic("kernel stack overflow: boot stack of hart {d} hit its guard page at 0x{x}, sepc=0x{x}", .{ h, stval, frame.sepc }),
        .trap => |h| std.debug.panic("kernel stack overflow: trap stack of hart {d} hit its guard page at 0x{x}, sepc=0x{x}", .{ h, stval, frame.sepc }),
        .process => |slot| {
            // 不拿锁读 pid、name：就要 panic 了，锁可能在别人手里
            const p = &proc.table[slot];
            std.debug.panic("kernel stack overflow: pid {d} ({s}) hit its guard page at 0x{x}, sepc=0x{x}", .{ p.pid, p.name.slice(), stval, frame.sepc });
        },
    }
}

/// 来自 U 模式的异常（系统调用和能处理的缺页以外的）都是用户程序自己的错：访问了没有映射或没有权限的地址、
/// 执行了非法指令等等。结束这个进程，内核照常运行。
fn killForFault(frame: *TrapFrame, exception: Exception) noreturn {
    proc.killCurrent("{s} at 0x{x}, stval=0x{x}", .{
        std.enums.tagName(Exception, exception) orelse "unknown exception",
        frame.sepc,
        riscv.read(.stval),
    });
}

fn handleExternal() void {
    const irq = plic.claim();
    switch (irq) {
        0 => return, // 没有待处理的中断
        plic.uart0_irq => {
            // 和 xv6 的 consoleintr 一样在中断里直接处理：Ctrl-C 杀掉前台进程，叫醒等输入的进程
            if (uart.onInterrupt()) proc.interruptForeground();
            uart.rx_lock.acquire();
            uart.rx_waiters.wakeAll(&uart.rx_lock);
            uart.rx_lock.release();
        },
        else => if (irq == virtio_disk.irq) {
            // 磁盘做完了请求：叫醒等它的进程
            virtio_disk.onInterrupt();
        } else {
            uart.print("[trap] unexpected external interrupt {d}\n", .{irq});
        },
    }
    plic.complete(irq);
}

/// 低 2 位为 0b11 的是 4 字节标准指令，否则是 2 字节压缩指令（C 扩展）。
fn instructionLength(addr: usize) usize {
    const half: *const u16 = @ptrFromInt(addr);
    return if (half.* & 0b11 == 0b11) 4 else 2;
}
