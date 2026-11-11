# CSR 和 SBI 调用

涉及文件：`src/riscv.zig`、`src/sbi.zig`

## CSR 访问（`riscv.zig`）

控制和状态寄存器（CSR）只能用专门的指令访问，地址在指令里编码，所以必须在编译期确定。内核里所有 CSR 操作都通过 `riscv.zig`，不在别处手写 `csrr`/`csrw`（陷阱入口出口等必须用汇编写的地方除外）。

### 用到的 CSR

`Csr` 枚举的名字就是汇编里的寄存器名，`@tagName(csr)` 直接拼进指令：

| CSR | 用途 | 用在哪里 |
| --- | --- | --- |
| `sstatus` | S 模式状态：全局中断使能 SIE、陷入前的特权级 SPP、陷入前的 SIE（SPIE）等 | 开关中断；陷阱时保存/恢复；构造进入 U 模式的状态 |
| `sie` | 各类 S 模式中断的使能位 | PLIC、定时器、核间中断初始化时打开 SEIE、STIE、SSIE；panic 停机时清零 |
| `sip` | 各类中断的挂起位 | 收到核间中断后清掉 SSIP（`ipi.onInterrupt`）；也是 `wfi` 的唤醒条件 |
| `stvec` | 陷阱入口地址 + 模式 | `trap.init` |
| `sscratch` | 给陷阱处理程序用的暂存寄存器 | 进出 U 模式时存内核栈顶，见 [trap.md](trap.md#sscratch-约定) |
| `sepc` | 陷阱发生时的 PC | 陷阱入口保存、出口恢复；跳过 `ebreak`/`ecall` |
| `scause` | 陷阱原因：最高位区分中断/异常，低位是编号 | `handleTrap` 分发 |
| `stval` | 和陷阱相关的值：出错的地址，或非法指令的编码 | 打印异常信息 |
| `satp` | 分页模式 + 根页表的物理页号 | `vm.activate` |
| `time` | 只读计数器，按 timebase 频率递增 | 定时器预约下一次中断 |

新用到的 CSR 要加进这个枚举。

### 位定义

有位定义的 CSR 读写的是 `packed struct(u64)`，字段名就是规范里的位名，和页表项 `vm.Pte` 一样：

```zig
pub const Sstatus = packed struct(u64) {
    _0: u1 = 0,
    sie: bool = false,             // S 模式全局中断使能
    _2: u3 = 0,
    spie: bool = false,            // 陷入前的 SIE，sret 时恢复到 SIE
    _6: u2 = 0,
    spp: Privilege = .user,        // 陷入前的特权级；sret 回到这个特权级
    _9: u4 = 0,
    fs: u2 = 0,                    // 浮点单元状态：0 = Off
    _15: u49 = 0,
};
pub const Interrupts = packed struct(u64) { ... ssi: bool, ... sti: bool, ... sei: bool, ... };  // sie 和 sip
pub const Scause = packed struct(u64) { code: u63, interrupt: bool };
pub const Satp = packed struct(u64) { ppn: u44, asid: u16 = 0, mode: enum(u4) { bare = 0, sv39 = 8, _ } };
```

`read(.scause)` 的返回类型由 CSR 决定（`Type(csr)`：`.sstatus` 是 `Sstatus`，`.sie`、`.sip` 是 `Interrupts`，没有位定义的 `stval`、`time` 这些是 `usize`），所以 `handleTrap` 写 `scause.interrupt`、`frame.sstatus.spp == .user`，不再手工移位、对掩码。`set`、`clear` 的参数也是同一个类型：`set(.sie, .{ .sti = true })`。原来是一组 `usize` 常量（`sstatus_sie = 1 << 1`、`sie_ssie = 1 << 1`……），两个寄存器的第 1 位意思不一样，掩码却可以随手用错地方，编译器不拦。没用到的位也有名字（`_9` 这样），读出来、改几个字段、写回去时原样保留；`riscv.zig` 末尾用 `@bitOffsetOf` 对照规范检查了每个字段的位置。

汇编里要用的立即数从同一个定义算出来：`trapEntry` 的 `andi t1, t1, %[spp]` 传的是 `comptime riscv.bits(riscv.Sstatus{ .spp = .supervisor })`（`bits` 把结构体换成整数），不另外写一个 `1 << 8`。

陷阱发生时硬件自动做的事：`SPIE ← SIE`、`SIE ← 0`、`SPP ← 陷入前的特权级`。`sret` 反过来：`SIE ← SPIE`、`SPIE ← 1`、特权级 ← `SPP`、`SPP ← 0`，然后跳到 `sepc`。内核正是利用这一点进入 U 模式：把 `SPP` 设成 0、`SPIE` 设成 1，`sret` 之后就在 U 模式运行并且开着中断（见 [process.md](process.md#userinit)）。

`sstatus` 里还有几个这个内核刻意保持为 0 的位：`SUM`（为 1 时 S 模式可以访问 U 页，见 [syscalls.md](syscalls.md#访问用户内存)）、`MXR`、`FS`（浮点单元状态）。`SUM` 和 `MXR` 进入内核时就是 0，内核从不设置它们。`FS` 不一样：OpenSBI 交过来时是 3（Dirty，浮点单元开着），实测入口处 `sstatus = 0x8000000200006000`。所以 `kmain` 一开始用 `clear(.sstatus, .{ .fs = 3 })` 把它清成 0（Off），之后是 `0x200000000`，S 模式和 U 模式的浮点指令都是非法指令。CSR 是每个 hart 自己的，其他 hart 在 `kmainSecondary` 开头也各清一次（[boot.md](boot.md#启动其他-hart)）。最高位 SD 是只读的汇总位，`FS` 为 Dirty 时它是 1。

### 函数

```zig
pub inline fn read(comptime csr: Csr) Type(csr)              // csrr
pub inline fn write(comptime csr: Csr, value: Type(csr)) void   // csrw
pub inline fn set(comptime csr: Csr, mask: Type(csr)) void      // csrs：mask 中为 1 的位置 1
pub inline fn clear(comptime csr: Csr, mask: Type(csr)) void    // csrc：mask 中为 1 的位清 0
pub inline fn enableInterrupts() void            // set(.sstatus, .{ .sie = true })
pub inline fn disableInterrupts() void           // clear(.sstatus, .{ .sie = true })
pub inline fn interruptsEnabled() bool           // read(.sstatus).sie
pub inline fn wfi() void
pub inline fn sfenceVma() void                   // sfence.vma zero, zero
```

- 全部是 `inline` 加 `comptime` CSR 参数：每次调用都直接展开成一条指令。
- 所有内联汇编都是 `asm volatile`，写操作都带 `.{ .memory = true }` clobber。`volatile` 防止编译器把“结果没被使用”的汇编删掉或合并；memory clobber 防止编译器把内存访问挪到 CSR 操作的另一边。例如关中断之后读环形缓冲区，读操作不能被提前到关中断之前。
- `read` 没有 memory clobber，但有 `volatile`，不会被删除或合并（`time` 每次读的值都不一样）。
- `wfi`：让 CPU 休眠直到有**使能的**中断挂起（看 `sie & sip`，不看 `sstatus.SIE`）。规范允许它随时返回，所以总是放在循环里使用。
- `sfenceVma`：不带参数的 `sfence.vma` 作废所有地址空间的所有 TLB 项。改了当前正在用的页表、或者写了 `satp` 之后都要执行（见 [paging.md](paging.md#切换地址空间)）。

## SBI 调用（`sbi.zig`）

SBI（Supervisor Binary Interface）是 S 模式软件请求 M 模式固件服务的接口，相当于“内核的系统调用”。调用约定：

| 寄存器 | 含义 |
| --- | --- |
| `a7` | 扩展号 EID |
| `a6` | 功能号 FID |
| `a0..a5` | 参数 |
| 返回 `a0` | 错误码（0 = 成功，负数为错误） |
| 返回 `a1` | 返回值 |

```zig
fn call(ext: Extension, fid: usize, arg0: usize, arg1: usize, arg2: usize) Ret {
    var err: isize = undefined;
    var value: usize = undefined;
    asm volatile ("ecall"
        : [err] "={a0}" (err),
          [value] "={a1}" (value),
        : [eid] "{a7}" (@backingInt(ext)),
          [fid] "{a6}" (fid),
          [arg0] "{a0}" (arg0),
          [arg1] "{a1}" (arg1),
          [arg2] "{a2}" (arg2),
        : .{ .memory = true });
    return .{ .err = err, .value = value };
}
```

从 S 模式执行 `ecall` 产生的是“来自 S 模式的 ecall”（异常 9），这个异常没有委托给 S 模式，所以直接进入 M 模式由 OpenSBI 处理，不会经过内核的陷阱处理程序。用户程序的 `ecall`（异常 8）则委托给了 S 模式，进的是内核（见 [syscalls.md](syscalls.md)）。两者用的是同一条指令，靠当前特权级区分。

### 用到的扩展

| 扩展 | EID | 函数 | FID | 用途 |
| --- | --- | --- | --- | --- |
| Base | `0x10` | `get_spec_version` | 0 | `specVersion()`：返回值的 bit 24..30 是主版本号，低 24 位是次版本号 |
| Base | `0x10` | `get_impl_id` | 1 | `implName()`：0 BBL、1 OpenSBI、2 Xvisor、3 KVM、4 RustSBI、5 Diosix |
| TIME | `0x54494D45`（"TIME"） | `set_timer` | 0 | `setTimer(deadline)`：`time` 达到 `deadline` 时产生 S 模式时钟中断，同时清除当前挂起的时钟中断 |
| SRST | `0x53525354`（"SRST"） | `system_reset` | 0 | `shutdown()`：参数 type 0 = 关机，reason 0 = 无原因 |
| HSM | `0x48534D`（"HSM"） | `hart_start` | 0 | `hartStart(hartid, start, arg)`：让停着的 hart 在 S 模式从物理地址 `start` 开始执行，`a0` = 它的编号，`a1` = `arg`，`satp` = 0、`sstatus.SIE` = 0。返回错误码 |
| IPI | `0x735049`（"sPI"） | `send_ipi` | 0 | `sendIpi(hart_mask, hart_mask_base)`：给 `hart_mask` 里的 hart（第 i 位是 `hart_mask_base + i` 号）发核间中断，它们的 `sip.SSIP` 被置 1。返回错误码 |

- `setTimer` 是唯一能清除 S 模式时钟中断挂起位的办法（`sip.STIP` 对 S 模式只读），所以时钟中断处理程序每次都要调用它预约下一次，否则中断会一直挂着、处理程序返回后马上又进来。
- `shutdown` 成功时不返回，QEMU 退出且退出码为 0。如果固件不支持 SRST 扩展调用会返回，这时只能在 `wfi` 循环里停机。不管在哪个 hart 上调用，整台机器都关掉。
- `hartStart` 只是请固件让那个 hart 开始运行，返回时它不一定已经执行到 `start` 了，所以 `kmain` 还要等它报到（[boot.md](boot.md#启动其他-hart)）。实测（QEMU 8.2 的 OpenSBI，4 个 hart）：启动不存在的 hart 5 返回 -3（`SBI_ERR_INVALID_PARAM`），再启动一次已经在运行的 hart 1 返回 -6（`SBI_ERR_ALREADY_AVAILABLE`）。
- S 模式自己发不了核间中断（要写只有 M 模式能访问的 CLINT），所以请 OpenSBI 代发：它在 M 模式写目标 hart 的 CLINT，目标 hart 进 M 模式之后再把它的 `sip.SSIP` 置 1，于是目标 hart 收到 S 模式软件中断（[process.md](process.md#核间中断)）。`ipi.send` 每次只发给一个 hart（`sendIpi(1, id)`）。
- QEMU 的 CPU 支持 Sstc 扩展（横幅里的 `Boot HART ISA Extensions: time,sstc`），S 模式本可以直接写 `stimecmp` 设置定时器，这个内核为了简单和可移植仍然走 SBI。
