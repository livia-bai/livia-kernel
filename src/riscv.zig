//! RISC-V 特权架构相关的辅助函数：读写 CSR、开关中断、刷新 TLB。
//! 有位定义的 CSR（sstatus、sie、sip、scause、satp）读写的是 packed struct，字段名就是规范里的位名，
//! 和 vm.Pte 一样：不会把 sstatus 的掩码用到 sie 上（两个寄存器的第 1 位意思不一样），也不用手工移位。

/// 内核会用到的 S 模式 CSR。枚举名就是汇编里的寄存器名。
pub const Csr = enum {
    sstatus,
    sie,
    sip,
    stvec,
    sscratch,
    sepc,
    scause,
    stval,
    satp,
    time,
};

/// 特权级（sstatus.SPP）
pub const Privilege = enum(u1) { user = 0, supervisor = 1 };

/// sstatus：S 模式的状态。字段名就是规范里的位名（小写），没用到的位也有名字（_9 这样），
/// 读出来、改几个字段、再写回去时它们原样保留。
pub const Sstatus = packed struct(u64) {
    _0: u1 = 0,
    /// S 模式全局中断使能
    sie: bool = false,
    _2: u3 = 0,
    /// 陷入前的 SIE，sret 时恢复到 SIE
    spie: bool = false,
    _6: u2 = 0,
    /// 陷入前的特权级；sret 回到这个特权级
    spp: Privilege = .user,
    _9: u4 = 0,
    /// 浮点单元状态：0 = Off，这时浮点指令都是非法指令
    fs: u2 = 0,
    _15: u49 = 0,
};

/// sie（中断使能）和 sip（中断挂起）：三类 S 模式中断各一位，两个寄存器的位置一样。
pub const Interrupts = packed struct(u64) {
    _0: u1 = 0,
    /// 软件中断（核间中断：别的 hart 经 SBI 把 sip.ssip 置 1，处理时要自己清掉）
    ssi: bool = false,
    _2: u3 = 0,
    /// 时钟中断
    sti: bool = false,
    _6: u3 = 0,
    /// 外部中断（来自 PLIC）
    sei: bool = false,
    _10: u54 = 0,
};

/// scause：最高位说明是中断还是异常，低位是编号（trap.Interrupt、trap.Exception）。
pub const Scause = packed struct(u64) {
    code: u63,
    interrupt: bool,
};

/// satp：MODE 是 8 表示 Sv39，PPN 是根页表的物理页号。ASID 不用，是 0。
pub const Satp = packed struct(u64) {
    ppn: u44,
    asid: u16 = 0,
    mode: enum(u4) { bare = 0, sv39 = 8, _ },
};

/// 每个 CSR 读出来、写进去的类型：有位定义的是上面的结构体，别的（地址、计数）是 usize。
fn Type(comptime csr: Csr) type {
    return switch (csr) {
        .sstatus => Sstatus,
        .sie, .sip => Interrupts,
        .scause => Scause,
        .satp => Satp,
        .stvec, .sscratch, .sepc, .stval, .time => usize,
    };
}

/// 位在 CSR 里的掩码（set、clear、汇编里的立即数用）：Sstatus{ .sie = true } 这样的值换成整数。
pub fn bits(value: anytype) u64 {
    return @bitCast(value);
}

pub inline fn read(comptime csr: Csr) Type(csr) {
    const v = asm volatile ("csrr %[ret], " ++ @tagName(csr)
        : [ret] "=r" (-> usize),
    );
    return @bitCast(v);
}

pub inline fn write(comptime csr: Csr, value: Type(csr)) void {
    asm volatile ("csrw " ++ @tagName(csr) ++ ", %[value]"
        :
        : [value] "r" (@as(usize, @bitCast(value))),
        : .{ .memory = true });
}

/// 把 mask 里为 1 的位置 1（原子地读改写这个 CSR），比如 set(.sie, .{ .sti = true })。
pub inline fn set(comptime csr: Csr, mask: Type(csr)) void {
    asm volatile ("csrs " ++ @tagName(csr) ++ ", %[mask]"
        :
        : [mask] "r" (@as(usize, @bitCast(mask))),
        : .{ .memory = true });
}

/// 把 mask 里为 1 的位清 0。
pub inline fn clear(comptime csr: Csr, mask: Type(csr)) void {
    asm volatile ("csrc " ++ @tagName(csr) ++ ", %[mask]"
        :
        : [mask] "r" (@as(usize, @bitCast(mask))),
        : .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    set(.sstatus, .{ .sie = true });
}

pub inline fn disableInterrupts() void {
    clear(.sstatus, .{ .sie = true });
}

/// 中断现在是不是开着（sstatus.SIE）。
pub inline fn interruptsEnabled() bool {
    return read(.sstatus).sie;
}

/// 让 CPU 休眠直到有中断待处理。
/// 只要中断在 sie 里被使能，即使 sstatus.SIE 为 0，wfi 也会被唤醒。
pub inline fn wfi() void {
    asm volatile ("wfi" ::: .{ .memory = true });
}

/// 清空整个 TLB（页表缓存）。改了正在使用的页表、或者切换 satp 之后都要执行，
/// 否则 CPU 可能还在用旧的地址翻译结果。
pub inline fn sfenceVma() void {
    asm volatile ("sfence.vma zero, zero" ::: .{ .memory = true });
}

/// 作废 ASID 为 asid 的所有非全局 TLB 项，带 G 位的（内核映射）留着。rs2 必须是 x0 之外的寄存器：
/// 写成 x0 就是“所有地址空间、连全局项一起”，所以 asid 为 0 也要先放进一个寄存器（t0），不交给编译器挑
/// （常数 0 可能被分配成 zero 寄存器）。
pub inline fn sfenceVmaAsid(asid: u16) void {
    asm volatile ("sfence.vma zero, t0"
        :
        : [asid] "{t0}" (@as(usize, asid)),
        : .{ .memory = true });
}

/// 只作废虚拟地址 va 所在那一页的 TLB 项（所有地址空间的）。只改了一个页表项时用它，不用把整个 TLB 清空。
pub inline fn sfenceVmaPage(va: usize) void {
    asm volatile ("sfence.vma %[va], zero"
        :
        : [va] "r" (va),
        : .{ .memory = true });
}

comptime {
    // 位的位置照规范（The RISC-V Instruction Set Manual, Volume II，4.1 节）
    const std = @import("std");
    std.debug.assert(@bitOffsetOf(Sstatus, "sie") == 1 and @bitOffsetOf(Sstatus, "spie") == 5);
    std.debug.assert(@bitOffsetOf(Sstatus, "spp") == 8 and @bitOffsetOf(Sstatus, "fs") == 13);
    std.debug.assert(@bitOffsetOf(Interrupts, "ssi") == 1 and @bitOffsetOf(Interrupts, "sti") == 5 and @bitOffsetOf(Interrupts, "sei") == 9);
    std.debug.assert(@bitOffsetOf(Scause, "interrupt") == 63 and @bitOffsetOf(Satp, "mode") == 60);
}
