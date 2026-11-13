# 文档目录

livia-kernel 的详细文档，按功能组织，讲这个用 Zig 写的 RISC-V 内核每一部分是怎么做的、为什么这样做。图用 Mermaid 写在 Markdown 里，GitHub 上直接显示成图。仓库根目录的 [README.md](../README.md) 只有简介和上手步骤。

## 精读路线

想通过读代码学设计、不打算读完全部文档的话，按这个顺序读下面这些，一共两千行左右，都是最能体现设计的部分：

1. [architecture.md](architecture.md)：先有全局的图景；再看 [design.md](design.md)，关键的设计决定和有意的简化都在那一页。
2. `src/hart.zig`、`src/spinlock.zig`：最小的并发基础，以及加锁顺序怎么交给等级检查（[process.md](process.md#锁)）。
3. `src/trap.zig`、`src/kstack.zig`、`src/canary.zig`：`sscratch` 的三种状态、陷阱栈、栈溢出时怎么失败（[trap.md](trap.md)）。`TrapFrame` 的保存和恢复汇编是用 `@offsetOf` 在编译期生成的。
4. `src/page.zig`、`src/ipi.zig`：短，每一处并发都有论证（[page-allocator.md](page-allocator.md)、[process.md](process.md#核间中断)）。
5. `src/proc.zig` 里的 `scheduler`、`sched`、`WaitQueue`、`fork`、`finish`、`wait`（[process.md](process.md)）。
6. `src/vm.zig` 的 `fault`、`breakCow`、`pinSrc`/`pinDst`（[paging.md](paging.md#按需分页)）。
7. [btree.md](btree.md)，再看 `src/ctree.zig` 的 `commit`、`abort` 和文件末尾的掉电、读写失败测试。
8. [invariants.md](invariants.md)：把上面读到的几条规矩放在一起看，它们是怎么从注释变成断言和类型的。

`src/fs.zig` 的目录和文件内容、`src/file.zig`、`src/syscall.zig` 的各个处理函数、shell 和用户程序可以跳过；`src/abi.zig` 的 `params` 和 `syscall.zig` 的 `dispatch` 值得看一眼，系统调用的签名是怎么在编译期核对的。

## 哪些模块可以当范本

按“当成写法的范本来读”合不合适分三类。这是维护者的判断，也是一份公开的欠账清单。

| 分类 | 文件 | 说明 |
| --- | --- | --- |
| 范本 | `trap.zig`、`kstack.zig`、`canary.zig`、`hart.zig` | 汇编由 comptime 生成，失败路径先设计好 |
| 范本 | `spinlock.zig`、`ipi.zig`、`page.zig` | 加锁顺序由等级检查；无锁的部分都有几行论证 |
| 范本 | `btree.zig`、`ctree.zig` | 写时复制、提交、快照读者，掉电和读写失败的穷举测试 |
| 范本 | `riscv.zig`、`abi.zig`、`syscall.zig` 的 `dispatch` | CSR 的位、系统调用的签名和错误码都只写一次，别的地方在编译期和它核对 |
| 够用 | `proc.zig` | 结构照 xv6；哪个字段归哪把锁管还只写在注释里，没有交给类型 |
| 范本 | `vm.zig` | 按需分页、写时复制、pin；用户地址空间是一张区域表（`Region`），段、堆、栈都只是其中一项 |
| 够用 | `timer.zig`、`file.zig`、`pipe.zig`、`sleeplock.zig`、`bio.zig`、`fsys.zig`、`loader.zig`、`dtb.zig`、`kstat.zig`、`main.zig`、`sbi.zig`、`plic.zig` | 清楚、有测试，没有特别值得学的写法 |
| 待重构 | `fs.zig` | 一千七百多行，路径解析、目录、文件内容、检查放在一起，可以按这几块拆开 |
| 待重构 | `uart.zig`、`virtio_disk.zig` | 外设地址按 QEMU `virt` 写死；串口输出拿着锁忙等发送寄存器 |

## 按功能

建议按这个顺序读：

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 总体结构：特权级、多核、物理内存布局、虚拟地址空间、模块关系、主要控制流、全局不变量 |
| [design.md](design.md) | 关键的设计决定（选了什么、放弃了什么、代价）和有意的简化（和主流内核的差别） |
| [invariants.md](invariants.md) | 同一个不变量的三种写法（注释约定、运行时断言、类型约束）：pin、锁等级、系统调用的签名、tagged union、等待队列，改动前后的代码对照 |
| [build.md](build.md) | 构建系统：目标平台、优化模式、用户程序的编译和嵌入、QEMU 运行步骤 |
| [boot.md](boot.md) | 启动流程：OpenSBI 交接、链接脚本、`_start`、每个 hart 的启动栈、`kmain` 的初始化顺序、启动其他 hart、交给调度器、panic 时让所有 hart 停下 |
| [riscv-sbi.md](riscv-sbi.md) | CSR 访问和 SBI 调用 |
| [trap.md](trap.md) | 陷阱处理：异常委托、`TrapFrame`、`sscratch` 和 `tp` 约定、陷阱栈、入口/出口汇编、分发、内核栈溢出 |
| [devices.md](devices.md) | 串口（含输入缓冲区和 Ctrl-C）、PLIC、定时器 |
| [devicetree.md](devicetree.md) | 设备树：格式、解析器、QEMU 给的内容、错误和限制 |
| [page-allocator.md](page-allocator.md) | 物理页分配器、每一页的引用数 |
| [paging.md](paging.md) | Sv39 分页：页表格式、建立映射、内核页表（内核栈的保护页）、用户地址空间、按需分页、`fork` 的写时复制 |
| [user-programs.md](user-programs.md) | 用户程序：运行时（`start.zig`、`sys.zig`）、示例程序、写脚本用的程序（`test`、`expr`、`xargs`……）、怎么写新程序 |
| [process.md](process.md) | 进程：进程表、ELF 加载器、按需分页、`userinit`/`fork`/`exec`、命令行参数、`sbrk`、xv6 式调度（每个 hart 的 `scheduler`、`sched`、等待队列 `WaitQueue`）、核间中断、切换上下文、`exit`/`wait`/`kill`、Ctrl-C、锁和加锁顺序 |
| [disk.md](disk.md) | 磁盘：virtio 块设备驱动、睡眠锁、缓冲区缓存、读写块的系统调用 |
| [btree.md](btree.md) | 写时复制 B 树（文件系统的基础，类似 btrfs）：节点格式、写时复制、事务和提交、空闲空间、保存的快照、掉电测试 |
| [fs.md](fs.md) | 文件系统：inode、目录、文件内容（内联、数据块、洞、校验和），每个操作一个事务，接进内核（挂载、锁、系统调用、当前目录），`mkfs`，掉电测试 |
| [files.md](files.md) | 文件：fd 表、文件表、串口、管道和文件系统里的文件的读写 |
| [syscalls.md](syscalls.md) | 系统调用：调用约定、调用列表、访问用户内存、怎么加新调用 |
| [shell.md](shell.md) | shell（用户程序）：输入处理、前台和后台进程、命令 |
| [testing.md](testing.md) | 测试与调试：单元测试、QEMU 测试（`tools/qemu_test.py`）、回归测试程序、QEMU 日志、GDB、症状速查 |
| [zig-0.17.md](zig-0.17.md) | Zig 0.17 和旧版本的差别，以及这个项目里踩过的坑 |

## 按源码文件

| 文件 | 主要文档 | 也涉及 |
| --- | --- | --- |
| `build.zig` | [build.md](build.md) | [user-programs.md](user-programs.md) |
| `linker.ld` | [boot.md](boot.md#链接脚本) | [paging.md](paging.md#内核页表) |
| `src/main.zig` | [boot.md](boot.md) | [process.md](process.md#调度器) |
| `src/hart.zig` | [boot.md](boot.md#panic) | [trap.md](trap.md#tp-约定)、[process.md](process.md#锁) |
| `src/riscv.zig` | [riscv-sbi.md](riscv-sbi.md) | |
| `src/sbi.zig` | [riscv-sbi.md](riscv-sbi.md#sbi-调用sbizig) | [devices.md](devices.md#定时器timerzig) |
| `src/trap.zig` | [trap.md](trap.md) | [process.md](process.md)、[syscalls.md](syscalls.md) |
| `src/uart.zig` | [devices.md](devices.md#串口uartzig) | [files.md](files.md#串口) |
| `src/plic.zig` | [devices.md](devices.md#plicpliczig) | |
| `src/timer.zig` | [devices.md](devices.md#定时器timerzig) | |
| `src/virtio_disk.zig` | [disk.md](disk.md#virtio-块设备驱动virtio_diskzig) | [devices.md](devices.md#中断路径汇总) |
| `src/sleeplock.zig` | [disk.md](disk.md#睡眠锁sleeplockzig) | [process.md](process.md#锁) |
| `src/bio.zig` | [disk.md](disk.md#缓冲区缓存biozig) | [syscalls.md](syscalls.md#调用列表) |
| `src/btree.zig` | [btree.md](btree.md#节点格式btreezig) | |
| `src/ctree.zig` | [btree.md](btree.md) | [disk.md](disk.md#缓冲区缓存biozig) |
| `src/fs.zig` | [fs.md](fs.md) | [btree.md](btree.md) |
| `src/fsys.zig` | [fs.md](fs.md#接进内核fsyszig) | [fs.md](fs.md#删掉还有人用着的文件)、[files.md](files.md)、[disk.md](disk.md#系统调用) |
| `src/mkfs.zig` | [fs.md](fs.md#生成磁盘镜像mkfszig) | [build.md](build.md#磁盘镜像) |
| `src/ipi.zig` | [process.md](process.md#核间中断) | [riscv-sbi.md](riscv-sbi.md#用到的扩展)、[trap.md](trap.md#分发) |
| `src/dtb.zig` | [devicetree.md](devicetree.md) | |
| `src/page.zig` | [page-allocator.md](page-allocator.md) | |
| `src/vm.zig` | [paging.md](paging.md) | [syscalls.md](syscalls.md#访问用户内存)、[process.md](process.md#按需分页) |
| `src/proc.zig` | [process.md](process.md) | |
| `src/loader.zig` | [process.md](process.md#elf-加载器) | [paging.md](paging.md#按需分页) |
| `src/pagecache.zig` | [paging.md](paging.md#程序页缓存) | [fs.md](fs.md#删掉还有人用着的文件) |
| `src/kstat.zig` | [syscalls.md](syscalls.md#调用列表) | [user-programs.md](user-programs.md#kstat) |
| `src/canary.zig` | [process.md](process.md#进程表) | [boot.md](boot.md#每个-hart-的启动栈) |
| `src/kstack.zig` | [process.md](process.md#进程表) | [trap.md](trap.md#内核栈溢出)、[paging.md](paging.md#内核页表)、[boot.md](boot.md#每个-hart-的启动栈) |
| `src/spinlock.zig` | [process.md](process.md#锁) | [boot.md](boot.md#panic) |
| `src/file.zig` | [files.md](files.md) | [syscalls.md](syscalls.md#closeduppipe) |
| `src/pipe.zig` | [files.md](files.md#管道) | |
| `src/syscall.zig` | [syscalls.md](syscalls.md) | [process.md](process.md) |
| `src/abi.zig` | [syscalls.md](syscalls.md#abizig) | [build.md](build.md#用户程序) |
| `user/start.zig` | [user-programs.md](user-programs.md#startzig) | |
| `user/sys.zig` | [user-programs.md](user-programs.md#syszig) | [syscalls.md](syscalls.md#用户态封装) |
| `user/linker.ld` | [build.md](build.md#用户程序的链接脚本) | [process.md](process.md#elf-加载器) |
| `user/init.zig` | [user-programs.md](user-programs.md#init-和-sh) | [process.md](process.md#结束进程) |
| `user/sh.zig` | [shell.md](shell.md) | [user-programs.md](user-programs.md#init-和-sh) |
| `user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig` | [user-programs.md](user-programs.md#示例程序) | |
| `user/echo.zig`、`user/cat.zig`、`user/wc.zig` | [user-programs.md](user-programs.md#echocatwc) | [shell.md](shell.md#管道) |
| `user/ls.zig`、`user/mkdir.zig`、`user/rm.zig`、`user/mv.zig`、`user/ln.zig` | [user-programs.md](user-programs.md#lsmkdirrmmvln) | [fs.md](fs.md) |
| `user/kstat.zig` | [user-programs.md](user-programs.md#kstat) | [syscalls.md](syscalls.md#调用列表) |
| `user/snap.zig` | [user-programs.md](user-programs.md#snap) | [fs.md](fs.md#保存的快照) |
| `user/scrub.zig` | [user-programs.md](user-programs.md#scrub) | [fs.md](fs.md#检查整个文件系统checkscrub) |
| `user/test.zig`、`user/expr.zig`、`user/seq.zig`、`user/sleep.zig`、`user/head.zig`、`user/tail.zig`、`user/grep.zig`、`user/cp.zig`、`user/touch.zig`、`user/tee.zig`、`user/xargs.zig` | [user-programs.md](user-programs.md#写脚本用的程序) | [shell.md](shell.md) |
| `user/tests/*.zig`、`user/tests/noperm.ld` | [testing.md](testing.md#回归测试程序) | [build.md](build.md#用户程序) |
| `src/tests.zig` | [testing.md](testing.md#单元测试zig-build-test) | [build.md](build.md#单元测试) |
| `tools/qemu_test.py` | [testing.md](testing.md#qemu-测试toolsqemu_testpy) | |

## 修改记录

[changes.md](changes.md)：每次改动新增了什么功能、修了什么 bug。
