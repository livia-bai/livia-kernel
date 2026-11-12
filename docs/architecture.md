# 总体结构

这一篇从整体上介绍内核：谁运行在哪个特权级、物理内存和虚拟地址怎么分布、各模块之间的关系，以及几条主要的控制流。各部分的细节见对应的文档（[目录](README.md)）。

## 特权级

RISC-V 有三个特权级，这个项目三个都用到了：

| 特权级 | 运行的代码 | 负责的事 |
| --- | --- | --- |
| M（Machine，最高） | OpenSBI 固件（QEMU 自带，`-bios default`） | 上电初始化，把中断和部分异常委托给 S 模式，替 S 模式做它无权做的事：设置定时器、关机（通过 SBI 调用，见 [riscv-sbi.md](riscv-sbi.md)） |
| S（Supervisor） | 本内核（`src/`） | 陷阱处理、设备驱动、页表、加载和运行用户程序、系统调用 |
| U（User，最低） | 用户程序（`user/`） | 只能访问自己地址空间里带 U 位的页，要做任何别的事都得通过 `ecall` 请内核代办 |

内核从头到尾只在 S 模式运行，没有切到 M 模式的路径；需要 M 模式权限的操作都通过 `ecall` 交给 OpenSBI。

## 多核

QEMU 默认给 4 个 hart（`-smp 4`，最多用 8 个）。所有 hart 运行同一份内核、共用内核页表和所有数据结构，地位是对称的（SMP），只在启动时有区别：OpenSBI 只把一个 hart（启动 hart）交给内核，它做完全局的初始化后用 SBI 调用逐个启动其他 hart（[boot.md](boot.md#启动其他-hart)）。之后每个 hart 都在跑自己的调度器，从同一张进程表里挑进程运行；每个 hart 有自己的启动栈、定时器、PLIC 上下文和 `cpus[i]`（当前进程、调度器的上下文），内核用 `tp` 存当前 hart 的编号（[trap.md](trap.md#tp-约定)）。共享数据都由自旋锁保护，加锁照搬 xv6（[process.md](process.md#锁)）。

## 物理内存布局

QEMU `virt` 机器、`-m 128M` 时，和这个内核有关的物理地址如下（完整的设备列表可以用 `-machine virt,dumpdtb=virt.dtb` 导出设备树查看，见 [devicetree.md](devicetree.md)）：

| 物理地址 | 内容 | 内核怎么用 |
| --- | --- | --- |
| `0x0000_0000` 附近 | 没有设备 | 不映射，空指针解引用会触发缺页异常 |
| `0x0010_0000` | `sifive,test` 设备 | OpenSBI 用它关机/重启，内核不直接碰 |
| `0x0200_0000` | CLINT（核间中断、`mtime`） | 只有 M 模式能访问，内核不碰 |
| `0x0c00_0000..0x0c60_0000` | PLIC，6 MiB | 映射为 RW，见 [devices.md](devices.md) |
| `0x1000_0000..0x1000_0100` | NS16550A 串口 | 映射一页 RW |
| `0x1000_1000..0x1000_9000` | 8 个 virtio-mmio 槽位，每个 `0x1000` | 映射为 RW；磁盘（virtio 块设备）在其中一个，启动时逐个找（[disk.md](disk.md)） |
| `0x8000_0000..0x8006_0000` | OpenSBI 自己的代码和数据 | 被 PMP 保护，S 模式无权访问；设备树里登记为保留内存 |
| `0x8020_0000` 起 | 内核镜像：`.text`、`.rodata`、`.data`、`.bss`（含每个 hart 32 KiB 的启动栈和 16 KiB 的陷阱栈、每个进程 24 KiB 的内核栈，每块栈下面一页保护页） | 按段设置权限，保护页不映射，见 [paging.md](paging.md) |
| `__kernel_end..0x8800_0000` | 其余内存 | 交给页分配器（[page-allocator.md](page-allocator.md)）：页表、用户程序的页都从这里来 |
| `0x87e0_0000` 起约 5.3 KiB | OpenSBI 传给内核的设备树 | 页分配器跳过这些页，不会分配出去 |

内存的起点和大小、设备树的位置都是运行时从设备树里读出来的，上表是 QEMU 默认配置下的实测值。串口、PLIC、virtio-mmio 的地址目前写死在代码里。

## 虚拟地址空间

内核开启 Sv39 分页后，有两种地址空间：

```
内核地址空间（vm.kernel_root）            用户进程的地址空间（每个进程一个）
                                          
0x0c00_0000  PLIC        RW- (G)          0x0c00_0000  PLIC        RW- (G)  ┐
0x1000_0000  串口        RW- (G)          0x1000_0000  串口        RW- (G)  │ 和内核共用
                                          0x4000_0000  程序各段、堆 U + R/W/X│ ← 根页表第 1 项，
                                          0x7fef_f000  保护页（没有页）    │   每个进程独有，
                                          0x7ff0_0000  用户栈 ≤1M  U + RW-  │   按需分页
0x8020_0000  内核镜像    R-X/R--/RW- (G)  0x8020_0000  内核镜像    同左     │ 和内核共用
内核之后     其余内存    RW- (G)          内核之后     其余内存    同左     ┘
```

- 内核的映射都是恒等映射（虚拟地址 = 物理地址），都不带 U 位、都带 G（全局）位。
- 内核栈下面的保护页（80 页）在恒等映射里留成空洞，内核栈溢出时缺页、panic（[trap.md](trap.md#内核栈溢出)）。
- 用户空间里的页都是**按需分配**的：`exec` 只记下各个段在程序文件里的位置，`sbrk` 只挪堆的末尾，访问到哪一页才分配哪一页，段里的页那时才从程序文件读进来（[process.md](process.md#按需分页)）。
- 用户空间固定是 Sv39 根页表第 1 项覆盖的 `0x4000_0000..0x8000_0000`（1 GiB）。内核的映射都不在这一项里，所以新建进程地址空间时只复制一份内核根页表，下面的页表全部共用。陷入内核时不用切换页表：内核代码在用户地址空间里照样能执行，U 模式只是访问不到它们。

为什么选根页表第 1 项、为什么用户映射不能用大页等细节见 [paging.md](paging.md) 和 [process.md](process.md)。

## 模块和依赖

```
main.zig ─┬─ uart.zig ──────────── 串口输出（加锁）、键盘输入缓冲、Ctrl-C
          ├─ sbi.zig ───────────── ecall 到 OpenSBI（定时器、关机、启动其他 hart）
          ├─ trap.zig ─┬─ timer.zig、plic.zig、uart.zig（中断）
          │            ├─ syscall.zig ─── abi.zig（调用号、abi.params：每个调用的参数，生成 dispatch）、vm.zig、proc.zig、
          │            │                   file.zig、page.zig、timer.zig、uart.zig、sbi.zig、bio.zig（原始区域）、
          │            │                   fsys.zig（文件系统的调用）、kstat.zig（计数器）
          │            ├─ virtio_disk.zig（磁盘中断）
          │            └─ proc.zig（让出 CPU、wakeup、杀进程）
          ├─ virtio_disk.zig ───── virtio 块设备驱动（proc.zig 的 sleep/wakeup 等磁盘）
          ├─ bio.zig ───────────── 缓冲区缓存（每块一把睡眠锁 sleeplock.zig），读写交给 virtio_disk.zig
          ├─ dtb.zig ───────────── 设备树
          ├─ page.zig ──────────── 物理页
          ├─ vm.zig ────────────── 页表（用 page.zig 分配页表）
          ├─ plic.zig、timer.zig
          └─ proc.zig ──────────── userinit、scheduler（每个 hart 最后都调用它，永不返回）
                                   vm.zig、trap.zig（进入 U 模式）、file.zig（fd 表）、abi.zig、嵌入的 init、fsys.zig（exec 从 /bin 找程序）、
                                   loader.zig（ELF 加载器、命令行参数，只依赖 vm.zig）

file.zig ─┬─ uart.zig（串口作为文件）
          ├─ pipe.zig ─── page.zig（每个管道一页）、vm.zig（复制用户内存）、proc.zig（sleep/wakeup）
          └─ fsys.zig ─── 挂载（proc.zig 的 forkretC 调用）、一把睡眠锁、错误码
                └─ fs.zig ─── inode、目录、文件内容
                      └─ ctree.zig ─── 写时复制 B 树、事务 ─── btree.zig（节点格式）、bio.zig

src/mkfs.zig（主机上的程序）─── fs.zig、ctree.zig、bio.zig：构建时生成磁盘镜像

user/start.zig ─┬─ user/sys.zig ─── src/abi.zig（与内核共用的系统调用约定）
                └─ user/<程序>.zig ─── user/sys.zig      （init.zig、sh.zig 也是这样的程序）
```

`riscv.zig`（CSR 读写）、`hart.zig`（当前 hart 的编号、panic 时让所有 hart 停下）、`spinlock.zig`（自旋锁，带等级）、`kstat.zig`（每个 hart 的计数器）和 `kstack.zig`（内核栈、保护页、高水位、panic 时的调用栈）几乎被所有内核模块用到，图里省略了。



## 主要控制流

**启动**（[boot.md](boot.md)）：OpenSBI → `_start`（清 `.bss`、`tp` = hart 编号、设栈）→ `kmain`：关浮点单元 → 串口 → 陷阱向量 → 设备树 → 页分配器 → 内核页表、开分页 → PLIC 和定时器 → 逐个启动其他 hart（它们从 `secondaryEntry` → `kmainSecondary` 做自己那份初始化，进入自己的调度器）→ 创建 init（`proc.userinit`，打开串口作为 0、1、2 号 fd）→ `proc.scheduler()`，不再返回（全局中断开关由调度器打开）。init 被某个 hart 调度后 `fork` + `exec` 出 shell。

**调度器**（[process.md](process.md#调度)，结构照搬 xv6）：每个 hart 一个，在这个 hart 的启动栈上永远循环：开一下中断（处理挂起的中断）再关上 → 依次扫描进程表，每个槽位拿着进程锁看状态，`runnable` 的进程：切到它的地址空间，`switchContext` 换到它的内核栈，等它调用 `sched()` 切回来 → 一个都没有就 `wfi`。别的 hart 把进程改成 `runnable`、或者杀了在这个 hart 上运行的进程时，发核间中断叫醒或打断它（`ipi.zig`），不用等 10 ms 一次的时钟中断。新进程从 `forkret` → `trapExit` 进入 U 模式，老进程从上次 `sched()` 的地方继续（可能在另一个 hart 上）。

**进程让出 CPU**：时钟中断打断 U 模式（时间片用完）→ `proc.yieldTimeslice`，`yield` 系统调用 → `proc.yield`；要等某件事（`sleep` 系统调用等时钟，`read` 等键盘输入或管道里的数据，`write` 等管道腾出空间，`wait` 等子进程结束）→ 排进条件旁边的等待队列（`q.wait(lock)`，`proc.WaitQueue`），等中断处理程序或别的进程 `q.wakeAll(lock)`。两者都经 `proc.sched` 切回调度器。

**shell**（[shell.md](shell.md)）：普通的用户程序：`read` 一个字节、自己回显 → 回车时执行命令；`run` 用 `fork` + `exec` 启动程序（带命令行参数），前台程序用 `setfg` 登记、`wait` 等它结束；`run a | b` 用 `pipe` + `dup` 把 a 的标准输出接到 b 的标准输入。

**文件**（[files.md](files.md)）：`read`/`write`/`close`/`dup` 的 fd 是当前进程 fd 表的下标，指向全局文件表里的 `File`（串口或管道的一端，带引用计数）；`fork` 复制 fd 表，进程结束时全部关掉。

**中断**（[trap.md](trap.md)、[devices.md](devices.md)）：硬件跳到 `trap.trapEntry` → 压 `TrapFrame`（来自 U 模式时换回内核的 `tp`）→ `handleTrap` 按 `scause` 分发：时钟中断预约这个 hart 的下一次（启动 hart 上还让 `ticks` 加 1、叫醒等时钟的进程），打断的是 U 模式就让出 CPU；外部中断向 PLIC 领取中断号，串口中断把字符搬进环形缓冲区、处理 Ctrl-C、叫醒在 `read` 里等的进程 → 回到 U 模式之前检查 `killed` → `trapExit` 恢复寄存器、`sret`。

**创建进程**（[process.md](process.md#创建进程)）：`fork` 系统调用 → `proc.fork`：写时复制地址空间（只建页表，用户页和父进程共用，谁先写谁在写缺页里复制一份）、复制 `TrapFrame`（子进程的 `a0` 改成 0）→ 拿着 `wait_lock` 和新槽位的锁一次填好，状态 `runnable`，父进程是调用者。`exec` 系统调用 → 把命令行参数复制进内核 → `proc.exec`：占住程序文件（运行期间不能改、不能删）、新建地址空间、读 ELF 的程序头记下各个段、参数放到栈顶（分配栈最顶上那一页）→ 换掉旧的地址空间 → `TrapFrame` 改成从新程序的入口开始（`a0` = argc，`a1` = argv）。

**缺页**（[process.md](process.md#按需分页)）：用户程序访问还没有的页 → `handleTrap` → `vm.fault`：在段、堆、栈里的话分配一页（段的页从程序文件读，睡着等磁盘）、映射上，回去重新执行那条指令；写时复制的页复制一份；别的地址结束进程。

**系统调用**（[syscalls.md](syscalls.md)）：用户程序 `ecall` → `trapEntry` 通过 `sscratch` 换到内核栈 → `handleTrap` → `syscall.dispatch` → 返回值写进 `TrapFrame` 的 `a0` → `trapExit` 回到 U 模式。

**进程结束**（[process.md](process.md#结束进程)）：`exit` 系统调用或 U 模式下的任何其他异常 → `proc.exit` / `proc.killCurrent` 打印原因 → 关掉所有打开的文件，子进程交给 init，状态改成 `zombie`，叫醒父进程，切回调度器 → 父进程的 `wait` 找到它，取走结束状态，释放它的全部内存。`kill` 系统调用和 Ctrl-C（前台进程和它的子孙）调用 `proc.kill`，只做标记，进程回到 U 模式之前自己结束。

## 全局不变量

改代码时要守住的几条约定，详细原因见各篇文档：

- `sscratch`：在 U 模式运行时存着当前进程的内核栈顶；在内核里是这个 hart 的陷阱栈顶（S 模式的陷阱都在陷阱栈上处理）；正在处理 S 模式的陷阱时为 0（[trap.md](trap.md#sscratch-约定)）。
- 内核代码全程关着中断（`sstatus.SIE = 0`）：初始化、陷阱处理、系统调用、调度器扫描进程表。中断只会打断 U 模式，或者调度器每一轮开头开中断的那一下，不会嵌套（[trap.md](trap.md)）。
- 拿自旋锁时中断关着；切换进程（`sched`）时只拿着这个进程自己的锁，回到 U 模式时不拿着任何锁；要拿着锁等待的用 `proc.WaitQueue`；同时拿几把锁时按固定的顺序（[process.md](process.md#锁)）。
- 进程切换只在关中断、拿着这个进程的锁时发生，并且总是经过调度器：`scheduler` ↔ 进程，进程只通过 `proc.sched` 切回，进程之间不直接切换（[process.md](process.md#切换上下文)）。一个进程同一时刻只在一个 hart 上运行。
- 内核里 `tp` 是当前 hart 的编号；用户程序的 `tp` 在进出 U 模式时换掉（[trap.md](trap.md#tp-约定)）。
- 被 kill 的进程不会再回到 U 模式：陷阱返回前、新进程第一次进入 U 模式前都检查 `killed`（[process.md](process.md#结束进程)）。
- init（pid 1）一直存在：结束的进程由父进程回收，父进程先结束的交给 init 回收。init 结束内核就 panic。
- 用户程序只能用根页表第 1 项；内核的映射不能放进 `0x4000_0000..0x8000_0000`（[paging.md](paging.md)）。
- 内核从不直接解引用用户给的指针，`sstatus.SUM` 始终为 0，访问用户内存一律走 `vm.copyFromUser`（[syscalls.md](syscalls.md)）。拿着锁复制用户内存的系统调用先 pin（`vm.pinSrc`、`pinDst`），拿着锁时只用 pin 好的 `PinnedSrc`/`PinnedDst` 复制：拿着锁时不能缺页（[paging.md](paging.md#内核访问用户内存)）。
- 正在运行的程序文件不能改、不能删（`ETXTBSY`）：按需分页一直要从它读页（[fs.md](fs.md#正在运行的程序文件)）。
- `TrapFrame` 的布局和 `trapEntry`/`trapExit` 的汇编绑在一起；`proc.Context` 和 `proc.contextAsm` 绑在一起。
- 内核和用户程序都不用浮点（目标是 rv64imac），陷阱处理不保存浮点寄存器；`sstatus.FS` 在启动时清成 Off，手写的浮点指令也会触发非法指令异常（[build.md](build.md)）。
