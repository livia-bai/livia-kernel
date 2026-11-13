# 进程：创建、调度和结束

涉及文件：`src/proc.zig`、`src/loader.zig`（ELF 加载器、命令行参数）（以及 `src/trap.zig` 的 `trapExit`、`src/vm.zig` 的用户地址空间函数、`src/spinlock.zig`、`src/hart.zig`、`src/ipi.zig`；调用方：`src/main.zig`、`src/trap.zig`、`src/syscall.zig`、`src/file.zig`、`src/pipe.zig`、`src/timer.zig`）

进程表里最多同时有 64 个进程，在所有 hart 上按时间片轮转（round-robin）抢占式调度。进程的创建、调度、结束和加锁都照搬 [xv6](https://github.com/mit-pdos/xv6-riscv)（`kernel/proc.c`）的结构：

- **第一个进程 init 由内核创建**（`userinit`），pid 1。之后的进程都是 `fork` 出来的：init 用 `fork` + `exec` 启动 shell，shell 再用同样的办法运行程序（[user-programs.md](user-programs.md#init-和-sh)）。
- **每个 hart 有自己的调度器 `proc.scheduler()`，只管调度**。每个 hart 初始化完之后调用它，它在这个 hart 的启动栈上永远循环：依次扫描（所有 hart 共用的）进程表，遇到 `runnable` 的进程就切过去，等它切回来再接着往下扫。进程不绑定 hart，这次在哪个 hart 上让出 CPU，下次可能在另一个 hart 上接着运行。
- **进程自己让出 CPU**：先拿上自己的锁、改自己的状态，再调用 `sched()` 切回调度器。时间片用完（`yield`）、等某件事（`sleep`）、结束（`exit`）都是这样。进程之间从不直接切换。
- **每个进程有一把锁**，保护它的状态等字段；**`wait_lock`** 保护父子关系。调度器拿着进程锁切到进程，进程拿着它切回来，所以一个进程同一时刻只会在一个 hart 上运行（[锁](#锁)）。
- **等待用等待队列 `WaitQueue`**：每个等待条件旁边放一个队列，`q.wait(lock)` 排进去睡下，`q.wakeAll(lock)` 叫醒排着的进程；`lock` 是保护等待条件（也保护这个队列）的锁。
- **每个进程有自己的 fd 表**，指向全局文件表里的串口或管道（[files.md](files.md)）。`fork` 复制，`exec` 保留，结束时全部关掉。
- **结束的进程变成 zombie，由父进程 `wait` 回收**。父进程先结束的，子进程交给 init。
- **`kill` 只做标记**，被杀的进程回到 U 模式之前自己结束。

## 程序从哪来

```zig
const init_image = @embedFile("init");   // 内核里只嵌着 init

const Source = union(enum) {
    bytes: []const u8,                                   // 嵌在内核里的（init、单元测试）
    file: struct { fs: *fs.Fs, ino: u64, size: u64 },    // 文件系统里的一个文件（exec）
    fn size(src: Source) u64
    fn read(src: Source, off: u64, dst: []u8) LoadError!void   // 读不全是 BadElf
};
```

- **init 嵌在内核里**：构建系统只把 init 的 ELF 作为匿名模块交给内核（[build.md](build.md#用户程序)），`@embedFile("init")` 拿到它的字节，放在内核的 `.rodata` 里。第一个进程要在挂载文件系统之前加载：挂载要读盘，读盘要睡着等，只有进程能做（[fs.md](fs.md#接进内核fsyszig)）。xv6 也是这样，只是它嵌的是一小段汇编（`initcode`），由它去 `exec("/init")`。
- **别的程序都在文件系统的 `/bin` 里**：构建时 `mkfs` 把它们装进去（init 也在，可以 `run init`），`exec` 从那里加载。程序是普通的文件，可以复制、删除，也可以运行别的路径上的文件（`run /h`）。
- 加载器（[ELF 加载器](#elf-加载器)）只通过 `Source` 读 ELF 的文件头和程序头，不关心它在哪：嵌着的直接复制，文件系统里的用 `fs.read` 读。段的内容不在 `exec` 时读：程序运行起来、访问到哪一页，才从同一个来源（`vm.Backing`：嵌着的字节，或者程序文件的 inode）读进那一页（[按需分页](#按需分页)）。

## 进程表

```zig
pub const max_procs = abi.max_procs;   // 64（xv6 的 NPROC），shell 也要知道，所以放在 abi.zig
pub const State = abi.ProcState;       // procinfo 原样交给用户程序

pub const ProcState = enum(u8) { unused, runnable, running, sleeping, zombie };   // abi.zig

pub const Process = struct {
    lock: Spinlock = .init("proc", .proc),    // 保护下面标着 lock 的字段，见“锁”
    state: State = .unused,            // lock
    hart: usize = 0,                   // lock。running 时在哪个 hart 上运行（kill 发核间中断用）
    pid: usize = 0,                    // lock
    name: Name = .{},                  // lock。程序名（最多 16 字节，存在这里），exec 时换掉；fork 出来的子进程沿用父进程的
    space: vm.Space = undefined,       // 地址空间：根页表、各个段、堆（按需分页要用，见 paging.md）
    parent: ?*Process = null,          // wait_lock。父进程；init 没有
    context: Context = undefined,      // 不在运行时保存的内核上下文
    wait_next: ?*Process = null,       // 排在某个 WaitQueue 里时的下一个进程
    queued: bool = false,              // 在不在某个 WaitQueue 里。这两个由那个队列的锁保护
    child_exit: WaitQueue = .{},       // wait_lock。在 wait 里等子进程结束时排在这里
    killed: ?[]const u8 = null,        // lock。被 kill 了的话是原因
    xstatus: u32 = 0,                  // lock。zombie 的结束状态，父进程 wait 时取走
    ticks: u64 = 0,                    // lock。在 U 模式运行期间来过的时钟中断数
    files: [abi.max_fds]?*file.File = @splat(null),  // 打开的文件，下标就是 fd
    sleeplocks: sleeplock.Held = .{},  // 拿着每一级的睡眠锁各几把，回到 U 模式时必须都是 0
    cwd: u64 = fs.root_ino,            // 当前目录的 inode 号（chdir），fork 继承，exec 不变
};

pub var table: [max_procs]Process = @splat(.{});
var wait_lock: Spinlock = .init("wait", .wait);           // 保护所有进程的 parent
var next_pid: std.atomic.Value(usize) = .init(1);  // 每次创建进程加 1（fetchAdd），从不复用
var init_proc: ?*Process = null;                   // 孤儿交给它；userinit 设置后不再改
var foreground: std.atomic.Value(usize) = .init(0);  // 前台进程的 pid（setfg），按 Ctrl-C 时杀掉它

// 槽位 i 的进程用 kstack.process[i] 作内核栈（src/kstack.zig）

const Cpu = struct {                   // 每个 hart 一份（xv6 的 struct cpu）
    proc: ?*Process = null,            // 正在这个 hart 上运行的进程；在调度器里时为 null
    context: Context = undefined,      // 调度器切到进程时保存的上下文
};
var cpus: [hart.max]Cpu = @splat(.{});  // 按 hart 编号下标
pub fn current() ?*Process              // cpus[hart.id()].proc
```

状态名和 xv6 一样。xv6 还有一个 `USED`，表示“槽位已占、还在初始化”：它的 `allocproc` 拿到槽位后会先放开进程锁再填其他字段。这里 `fork`、`userinit` 拿着新进程的锁一口气填完所有字段才放开（见[fork](#fork)），别的 hart 看到的要么是 `unused`，要么已经是完整的 `runnable`，用不着这个状态。状态的变化：

| 从 | 到 | 什么时候 | 谁做的 |
| --- | --- | --- | --- |
| `unused` | `runnable` | 启动时创建 init；`fork` 系统调用。拿着新进程的锁填好所有字段 | `userinit`、`fork` |
| `runnable` | `running` | 调度器扫到它 | `scheduler` |
| `running` | `runnable` | 时钟中断打断了 U 模式（时间片用完），或者 `yield` 系统调用 | `yield` |
| `running` | `sleeping` | 等某件事：`sleep` 系统调用等时钟，`read` 等键盘或管道里的数据，`write` 等管道腾出空间，`wait` 等子进程结束 | `sleep` |
| `sleeping` | `runnable` | 等的事发生了（时钟中断、串口中断、管道被读写或关掉、子进程结束），或者被 kill | `wakeup`、`kill` |
| `running` | `zombie` | `exit` 系统调用，或者 U 模式下出了异常，或者发现自己被 kill 了 | `exit`、`killCurrent`（经 `finish`） |
| `zombie` | `unused` | 父进程 `wait` 到它 | `wait` → `reap` |

所有的状态变化都拿着这个进程的锁。

- **每个进程一块 24 KiB 的内核栈**（`kstack.process`，`src/kstack.zig`），静态分配在 `.bss` 里（64 块，每块下面还有一页保护页，共 1.75 MiB）。不从页分配器要：它一次只给一页，给不出连续的几页。原来是 16 KiB，高水位量出 Debug 模式下只剩 2.4 KiB（见下面），调成了 24 KiB。用得最深的是文件系统的系统调用（B 树的操作，[fs.md](fs.md#接进内核fsyszig)）。
- **栈用到过多深是内核自己量的**（高水位）：启动时 `kstack.paintAll` 把所有的栈都写上金丝雀的图案（每块栈最底下的金丝雀也就写好了），栈从没用到过的地方一直是图案；`shutdown` 时 `kstack.deepest` 从每块栈的底部往上找第一个被改过的字，取每种栈的最大值，打印一行 `[stack] deepest use: process P of 24576, boot B of 32768, trap T of 16384 bytes`。`allocSlot` 复用槽位时只重写最底下的金丝雀，所以量到的是整个运行期间的最深值。`qemu_test.py` 在每次关机后检查每种栈都还留着至少 2048 字节（`STACK_MARGIN`）没用到过。
- 实测（跑完全部 QEMU 测试，单核 / 4 核）：

  | 模式 | 进程内核栈 | 启动栈 | 陷阱栈 |
  | --- | --- | --- | --- |
  | debug | 16048 / 16192 | 18784 | 3248 |
  | safe | 9632 / 9632 | 6192 | 712 |
  | fast | 9592 / 9592 | 4920 | 744 |
  | small | 8584 / 8584 | 5560 | 832 |

  （内核保留了帧指针、系统调用改成生成的 `dispatch` 之后量的。保留帧指针让每种栈深了几百字节；生成的 `dispatch` 让 Debug 模式下的进程内核栈从 14224 字节深到 16192 字节，release 模式下几乎不变，见 [syscalls.md](syscalls.md#分发)。）进程内核栈是 16 KiB 时，Debug 模式下只剩 2.4 KiB 左右（那时最深 13912 字节），所以调成了 24 KiB。以前用临时代码量过一次（Debug 11624 字节），那是加按需分页、保护页之前，当时推测之后不会变深，内核自己量出来多了 2 KiB 多（没有逐个调用量过是哪一条路径变深的）。启动栈的数字是上限：启动 hart 自己的启动栈只从 `kmain` 开头的 `sp` 往下留出 1 KiB 之后才写图案（再往上正在用），这一段都算作用到过。
- **栈下面的保护页**：每块内核栈下面一页不映射（`vm.init` 建内核页表时跳过它，[paging.md](paging.md#内核页表)）。进程 i 的内核栈往下溢出时，碰到的是保护页，马上缺页，而不是写进进程 i-1 内核栈的最顶上（它的 `TrapFrame`，那个进程回到 U 模式时寄存器就乱了，很难查）。缺页时 `sp` 已经在保护页里了，所以 S 模式的陷阱都在每个 hart 的陷阱栈上处理（[trap.md](trap.md#sscratch-约定)），`handleTrap` 看出 `stval` 落在谁的保护页里，panic：`kernel stack overflow: pid N (name) hit its guard page at 0x...`。临时让 `yield` 系统调用在内核里无限递归实测过，`t_sleep` 一调用 `yield` 就是这一行。
- **栈底的金丝雀**（`src/canary.zig`）：保护页只能发现越过栈底的访问。一个很大、只写了一部分的栈帧可能整个跨过 4 KiB 的保护页，写进下面那块栈；用到了离栈底很近的地方也值得知道。所以每块内核栈最底下的 256 字节还写着固定的图案（`allocSlot` 拿到空槽位时写，这时这块栈没人用），切回调度器（`sched`）、回到 U 模式之前（`handleTrap` 末尾、`forkretC`）由 `proc.checkStack` 检查，图案被改了就 panic：`kernel stack overflow: pid N (name)`。这是尽力而为的检查：一个很大、只写了一部分的栈帧可能整个跨过 256 字节而不碰它。临时在 `getpid` 里放一个 15.5 KiB 的数组实测过（那时还没有保护页），shell 一调用 `getpid` 就 panic。启动栈也有保护页和金丝雀（[boot.md](boot.md#每个-hart-的启动栈)）。
- init 和 shell 一直占着两个槽位，所以同时最多运行 14 个别的程序。
- `current()` 返回当前 hart 上正在运行的进程：`cpus[hart.id()].proc`，只在 `scheduler` 切到进程前设置、切回来后清回 `null`。系统调用和陷阱处理程序用 `current().?` 取当前进程，Debug/safe 模式下没有进程时会 panic。它不用加锁：只有这个 hart 自己读写自己那一项，而且内核关着中断运行，读到之后到开中断之前，这个 hart 不会换进程（xv6 的 `myproc` 为此要 `push_off`）。
- 哪些字段由谁保护见[锁](#锁)。`space`、`context`、`files`、`cwd` 不用加锁：只有进程自己会读写它们（`close`/`dup`/`pipe`/`sbrk` 系统调用、缺页、`fork` 时复制给子进程、结束时关掉文件），没有线程，别的进程碰不到；父进程回收 zombie 时它已经不会再运行了。

## 用户地址空间

所有用户映射都在根页表第 1 项覆盖的 `vm.user_base..vm.user_end`（`0x4000_0000..0x8000_0000`）里，原因见 [paging.md](paging.md#用户地址空间)。

| 用户地址 | 内容 | 权限 |
| --- | --- | --- |
| `0x4000_0000` 起 | ELF 的各个 PT_LOAD 段（代码 / 只读数据 / 数据和 `.bss`） | 按程序头：`R-X` / `R--` / `RW-`，都带 U |
| 紧接着最后一个段之后的页边界（`heap_start`）到 `brk` | 堆，`sbrk` 调整（[sbrk](#sbrk堆)），一开始是空的 | `RW-`，带 U |
| …… | 没有页 | |
| `0x7fef_f000..0x7ff0_0000`（`vm.heap_limit..vm.stack_limit`） | 保护页，永远没有页 | 栈溢出时触发缺页异常（结束进程），而不是悄悄写进堆里；堆也不能长进来 |
| `0x7ff0_0000..0x8000_0000`（`vm.stack_limit..vm.stack_top`） | 用户栈，最多 1 MiB（`vm.stack_max`）。最顶上是 `exec` 传进来的命令行参数（[命令行参数](#命令行参数)） | `RW-`，带 U |

这张表是“可以有页的地方”（`vm.Space` 记着它），不是页表里已经有的：页表里只有访问过的页（[按需分页](#按需分页)）。刚 `exec` 完的程序只有栈最顶上那一页（放命令行参数），运行到哪儿、用到哪儿再分配；栈用多深就分配多少页，最多 1 MiB。

## ELF 加载器

加载器在 `src/loader.zig`：它只依赖 `vm.Space` 和读文件的那一点（`Source`），不碰进程表，所以能完整地在主机上测。原来它和命令行参数的压栈（`pushArgs`）都在 `proc.zig` 里，`proc.zig` 现在只管进程的生命周期，`exec`、`userinit` 调用 `loader.loadImage`。

```zig
pub fn load(space: *vm.Space, src: Source) LoadError!usize      // 记下各个段，设好堆的起点，返回入口地址
fn loadSegment(space: *vm.Space, src: Source, phdr: elf.Elf64.Phdr) LoadError!void
pub const LoadError = error{ BadElf, OutOfMemory, IoError };
```

ELF 来自文件系统，任何人都能往里写一个文件再去运行它，所以加载器按“输入可能是坏的”来写，每个字段都检查，坏的 ELF 只会得到 `BadElf`，不会让内核读写到不该碰的地方（读文件本身出错是 `IoError`）。头部结构用 `std.elf.Elf64.Ehdr` / `Elf64.Phdr`（0.17 里字段是带类型的枚举和 packed struct，旧的 `Elf64_Ehdr` 已弃用）：文件头和每个程序头各读一次到栈上（64、56 字节），用 `std.mem.bytesToValue` 从字节复制出来。

**ELF 头的检查**（任何一条不满足都是 `BadElf`）：

| 检查 | 原因 |
| --- | --- |
| 长度至少是一个 ELF 头（`Source.read` 读不全就是 `BadElf`） | 防止越界读 |
| 魔数 `\x7fELF`、64 位、小端 | 必须是 RV64 的 ELF |
| `e_type == EXEC` | 只支持静态链接的可执行文件，不处理重定位 |
| `e_machine == RISCV` | |
| `e_phentsize == sizeof(Elf64_Phdr)` | 程序头大小对得上才能按数组读 |
| 每个程序头的 `[e_phoff + i * 56, +56)` 在文件内（加法检查溢出） | 防止越界读 |

只处理 `PT_LOAD` 且 `p_memsz > 0` 的程序头，其他类型跳过。现在的用户 ELF 有 3 个 `PT_LOAD` 和 1 个链接器自动加的 `PT_RISCV_ATTRIBUTES`（`llvm-readelf -l` 显示为 `ATTRIBUTES`）。

**每个段的检查**（`loadSegment`）：

| 检查 | 原因 |
| --- | --- |
| `p_vaddr` 按页对齐 | 每一页只属于一个段，才能按段设置权限（`user/linker.ld` 保证这一点） |
| `p_vaddr >= user_base`，`p_vaddr + p_memsz` 不溢出且 `<= 栈底 - 4096` | 整段在用户区内，并且在保护页之下，不会和栈重叠 |
| `p_filesz <= p_memsz` | 文件里的内容不能比内存里的段还长 |
| `[p_offset, p_offset + p_filesz)` 在文件内 | 防止越界读 |
| 段必须可读（`p_flags.R`） | R/W/X 全为 0 的页表项会被 CPU 当成指向下一级页表的指针；W 无 R 是保留组合。见下面的说明 |
| 和已经记下的段重叠（按页算）、段超过 `vm.max_segments`（8）个 → `BadElf` | `vm.Space.addSegment` 返回 `Overlap`、`TooMany` 时转换过来 |

检查通过的段只是**记下来**（`vm.Space.addSegment`：`[p_vaddr, alignForward(p_vaddr + p_memsz))`、权限、`p_offset`、`p_filesz`），不分配页、不读内容。程序访问到段里的某一页时缺页，`vm.fault` 才分配一页清零的物理内存，把文件里对应的部分（`[p_offset + 页在段里的偏移, ...)`，最多 `p_filesz` 为止）读进去，`p_filesz` 之后的部分（`.bss`）保持清零，再按段的权限映射上（[按需分页](#按需分页)）。所以上面的检查必须在 `exec` 时做完：之后缺页时读的范围都是这里检查过的。

最后检查**入口地址落在一个可执行的段里**，不然是 `BadElf`：以前加载器把每一页都映射好，入口不对的程序运行起来第一条指令就缺页；现在在 `exec` 时就拒绝它。

**为什么一定要拒绝不可读的段**：如果一个段的 R/W/X 全为 0，`map` 写出的页表项只有 V = 1，硬件会把它当成“指向下一级页表”的项，而它指向的是一页用户数据。只要用户程序（或者构造 ELF 的人）往那一页里写入精心构造的页表项，就能把任意物理内存映射进自己的地址空间。这个漏洞是写完加载器后复查代码时发现的，现在加载器拒绝这样的段，`vm.map` 也断言了叶子权限合法。回归测试 `t_noperm`（[testing.md](testing.md#回归测试程序)）一直在检查这一点：故意去掉这条检查时，Debug 模式下 `vm.map` 的断言让内核 panic，small 模式下断言被编译掉，那一页真的被当成了页表。

栈也不在这里分配（[命令行参数](#命令行参数)写参数时分配最顶上那一页）。

堆的起点（`space.heap_start`，`brk` 一开始也是它）是**所有段的末尾按页向上取整后的最大值**。段的最后一页整页属于段（权限是那个段的，比如只读），堆从下一页开始，堆里的页都是 `RW-`，不会和段的权限混在一起。

单元测试（`src/loader.zig` 末尾）加载真正的 `hello`：加载完只多用了根页表这一页；再把每个段的每一页都读一遍（按需分配），读到的第一个字节和 ELF 文件里 `p_offset` 处的一样；栈的两端读得到，保护页、空的堆读不到；释放后不漏页。

## 按需分页

`exec` 只记下“哪些地址可以有页、页从哪来”（`vm.Space`），页表里一开始几乎是空的。用户程序访问一页还没有的地址时缺页（读是 `load_page_fault`，写是 `store_page_fault`，取指令是 `instruction_page_fault`），陷阱处理程序调用 `vm.fault`：地址在某个段、堆或者栈里，并且这次访问是那个区域允许的，就分配一页（段的页从程序文件读内容），映射上，回到那条指令重新执行；不然（没有这个区域、保护页、写代码段、执行数据）照常结束进程。写时复制也在这里处理（[paging.md](paging.md#按需分页)）。

- **页从哪读**（`vm.Backing`）：init 是嵌在内核里的字节（`.bytes`），别的程序是程序文件的 inode（`.file`）。缺页时 `fsys.readText` 拿一个新的快照、按 inode 读那一页、马上放开快照。读盘要睡着等磁盘中断，陷阱处理程序这时什么锁都没拿，可以睡。
- **程序文件运行期间不能变**：不然一个进程前后读到的页来自两个版本的文件（比如代码段的前一半是旧的、后一半是新的）。所以 `exec` 先占住它（`fsys.holdText`），之后有人要改它的内容（`write`、截断）、删掉它的最后一个名字（`unlink`、`rename` 换掉它）都是 `TextBusy`（`-ETXTBSY`，和 Linux 一样）；它正在被改时也不能开始运行（`exec` 返回 `-ETXTBSY`）。改名、加硬链接、删掉别的名字不动内容，照常可以。`fork` 出来的子进程多占一份（`fsys.dupText`），进程结束时（`finish`）就放开，不等父进程回收；`exec` 换掉地址空间时放开旧的。见 [fs.md](fs.md#正在运行的程序文件)。
- **内存不够**：缺页时分配不到页，进程被结束：`[proc] pid N (name) killed: out of memory (demand paging) at ...`（写时复制没内存复制是 `out of memory (copy-on-write)`），读不出程序文件是 `cannot read the program file (demand paging)`。`sbrk` 不预先分配，所以“堆长成功了、用的时候没内存”是可能的（和 Linux 的 overcommit 一样）。
- 回归测试 `t_demand`（[testing.md](testing.md#回归测试程序)）：程序里 256 KiB 的只读数组，读其中 16 页正好多用 16 页；数据页的内容来自文件、可写、`fork` 之后各改各的；内核替它读写还没读进来的页；512 KiB 的栈；运行中的程序文件不能写、截断、删除、被 `rename` 换掉，能改名、删另一个硬链接，结束之后又都可以。

## 创建进程

```zig
pub const SpawnError = error{ TooManyProcesses, OutOfMemory, BadElf, TooManyFiles };
pub fn userinit() SpawnError!void                          // kmain 调用，创建 init

pub const ForkError = error{ TooManyProcesses, OutOfMemory };
pub fn fork() ForkError!usize                              // fork 系统调用，返回子进程的 pid

pub const ExecError = error{ NoSuchProgram, OutOfMemory, BadElf, IoError, NoDevice, NotDir, NameTooLong, SymlinkLoop, TextBusy };
pub fn exec(path: []const u8, args: []const []const u8) ExecError!void   // exec 系统调用
```

三个函数都要准备一个“下次被调度时从哪里开始”的状态。用户进程第一次被调度时的路径都一样：

```
scheduler → switchContext ─ret→ forkret → forkretC（放开进程锁、checkKilled）→ trapExit ─sret→ U 模式
```

- **初始的内核上下文**（`firstContext`）：`ra` = `forkret`，`sp` = 这个槽位的 `TrapFrame` 的地址，`s0..s11` = 0。`switchContext` 恢复它之后 `ret` 就跳进 `forkret`。
- **`TrapFrame` 总在内核栈的最顶端**（`frameOf(p)`）：必须放在栈顶下方正好 `@sizeOf(TrapFrame)` 处，`trapExit` 回到 U 模式时会把“TrapFrame 地址 + 288”当作内核栈顶写进 `sscratch`（[trap.md](trap.md#trapexit)）；之后从 U 模式陷入时，`trapEntry` 也正好把 `TrapFrame` 压在这里。
- **`forkret`**（名字来自 xv6）是一个裸函数：

  ```zig
  fn forkret() callconv(.naked) noreturn {
      asm volatile (
          \\call %[forkretC]
          \\tail %[trapExit]
          ...
      );
  }

  fn forkretC() callconv(.c) void {
      const p = current().?;
      p.lock.release();
      if (p == init_proc) fsys.init();   // 第一个进程：挂载文件系统
      checkKilled();
      assertNoLocksHeld();   // 没拿着自旋锁，也没拿着睡眠锁
  }
  ```

  `forkretC` 先放开进程锁：调度器是拿着它切过来的，平时由 `sched` 的调用方在切回来之后放开，新进程没有这个调用方，就在这里放（xv6 的 `forkret` 第一句也是 `release(&myproc()->lock)`）。再调用 `checkKilled`（还没运行就被 kill 了的话，在这里结束，见[结束进程](#结束进程)），然后跳进 `trapExit`。第一个进程（init）在这里挂载文件系统（`fsys.init`，[fs.md](fs.md#接进内核fsyszig)）：挂载要读盘、睡着等磁盘中断，`kmain` 不是进程，做不了（xv6 的 `forkret` 里调用 `fsinit` 也是这个原因）；之后的进程都是 init 的子孙，在它之后运行，用的时候已经挂好了。`sp` 一直指向 `TrapFrame`（`forkretC` 是普通函数，只用 `sp` 以下的栈），于是 `trapExit` 按它恢复寄存器、`sret` 进入 U 模式。

### userinit

和 xv6 的 `userinit` 一样，只在启动时调用一次（这时别的 hart 已经在各自的调度器里空转了）：新建地址空间（`vm.createUserSpace()`，复制内核的根页表），页从嵌在内核里的 `init` 程序读（`backing = .bytes`，[程序从哪来](#程序从哪来)），`loadImage` 记下它的段（`Source.bytes`）、把命令行参数 `"init"` 放到栈顶（[命令行参数](#命令行参数)）；**打开串口作为 0、1、2 号 fd**（一个 `File`，引用数 3，[files.md](files.md)），之后所有进程都从 init `fork` 继承它们；拿着空槽位的锁（`allocSlot`），用 `startFrame(frame, image)` 构造从入口开始运行的 `TrapFrame`，填好字段，状态设为 `runnable`，pid 是 1，记进 `init_proc`，最后才放开锁。`init_proc` 在放开锁之前设置：别的 hart 要先拿到这把锁才能运行 init，那时一定看得到它。没有 `init` 程序是构建配置错了，直接 `@panic`；其他错误 `kmain` 会 panic。

`startFrame` 构造的 `TrapFrame`：`sepc` = 入口地址，`sp`（`regs[2]`）和 `a1`（`regs[11]`）= 栈上 `Arg` 数组的地址，`a0`（`regs[10]`）= `argc`，其他寄存器为 0，`sstatus` 是当前的 `sstatus` 改三个字段（`spp = .user`、`sie = false`、`spie = true`）：

- `SPP = 0` 让 `sret` 回到 U 模式；`SPIE = 1` 让 U 模式下中断是开着的（时钟和键盘照常工作，抢占和 Ctrl-C 都靠它）。
- **`SIE` 必须清掉**：`trapExit` 第一步就把 `frame.sstatus` 写回 `sstatus`，`SIE = 1` 的话恢复寄存器的途中就可能被中断打断，而那时 `sscratch` 已经指向进程的内核栈，栈和寄存器都是一半新一半旧的状态。内核代码都是关着中断运行的，读到的 `SIE` 本来就是 0，但不依赖这一点（更早的版本里 shell 在内核里开着中断调用过这里，踩过这个坑）。
- 其他位保持内核当前的值，其中 `SUM = 0`、`FS = Off`（`kmain` 启动时清的，见 [riscv-sbi.md](riscv-sbi.md#位定义)），所以 U 模式同样不能用浮点。

### fork

```zig
pub fn fork() ForkError!usize {
    const parent = current().?;
    var space = try vm.cloneUserSpace(&parent.space);
    errdefer vm.destroyUserSpace(&space);
    wait_lock.acquire();
    defer wait_lock.release();
    const child = try allocSlot();          // 拿着它的锁返回
    defer child.lock.release();
    const frame = frameOf(child);
    frame.* = frameOf(parent).*;
    frame.regs[10] = 0;
    var files: [abi.max_fds]?*file.File = undefined;
    for (&files, parent.files) |*c, f| c.* = if (f) |x| file.dup(x) else null;
    const pid = next_pid.fetchAdd(1, .monotonic);
    fill(child, .{ .state = .runnable, .pid = pid, .name = parent.name, .space = space,
                   .parent = parent, .context = firstContext(child), .files = files, .cwd = parent.cwd });
    return pid;
}
```

- **先复制地址空间，再拿锁**：复制要分配页表，这时什么锁都不拿。然后拿着 `wait_lock`（要写子进程的 `parent`）和子进程的锁（`allocSlot` 拿着锁返回）一次填好所有字段，最后才放开。所以子进程在别的 hart 看来，要么还是 `unused`，要么已经是完整的 `runnable`，别的 hart 的调度器不会运行一个半填好的进程。进程表满了的话 `errdefer` 释放刚复制的地址空间（在放开 `wait_lock` 之后：`defer` 和 `errdefer` 按相反的顺序执行）。
- **`fill(p, new)` 换掉除了锁以外的所有字段**：直接 `child.* = .{...}` 会连锁一起覆盖成“没人拿着”，而这时锁在自己手里，别的 hart 可能正在等它。`fill` 在编译期遍历 `Process` 的字段名（`std.meta.fieldNames`），跳过 `lock`，以后加字段也不会漏。回收时用 `fill(c, .{})` 清空。
- **地址空间写时复制**（`vm.cloneUserSpace`，[paging.md](paging.md#复制用户地址空间)）：子进程只新分配页表，用户页和父进程共用（引用数加 1）；可写的页两边都改成只读、标上 `cow`，谁先写哪一页，谁在写缺页里复制一份（`vm.breakCow`，[paging.md](paging.md#写时复制)），所以之后仍然各改各的。shell 运行程序是 `fork` 之后马上 `exec`，子进程的旧地址空间一页都不用复制。
- **`TrapFrame` 原样复制**，只把 `a0` 改成 0。`fork` 是在系统调用里调用的，这时 `handleTrap` 已经把父进程 `TrapFrame` 的 `sepc` 加过 4 了，所以子进程第一次被调度时，经 `forkret` → `trapExit` 回到 U 模式，正好从 `ecall` 的下一条指令继续，看到 `fork` 返回了 0。父进程照常从系统调用返回，`a0` 是子进程的 pid。
- **打开的文件和父进程共用**：fd 表逐项复制，每个 `File` 的引用数加 1（`file.dup`），所以父子进程的 fd 指向同一个串口、同一个管道的同一端。shell 运行管道就靠这个（[shell.md](shell.md#管道)）。`dup` 只加引用数，不会失败。
- 段、堆（`space` 里的 `heap_start`、`brk`）、程序文件也照抄（程序文件多占一份，`fsys.dupText`），已经有的页随地址空间一起共用（写时复制）；父进程还没访问过的页，子进程访问时自己按需分配，从同一个程序文件读（[paging.md](paging.md#复制用户地址空间)）。
- 进程表满了是 `TooManyProcesses`，`fork` 系统调用返回 `-EAGAIN`；内存不够（页表都分配不出来）是 `OutOfMemory`（`-ENOMEM`），`cloneUserSpace` 自己释放已经建好的部分。
- pid 用原子变量 `next_pid.fetchAdd` 分配：几个 hart 同时 `fork` 也不会拿到同一个 pid。

### exec

```zig
pub fn exec(path: []const u8, args: []const []const u8) ExecError!void {
    const p = current().?;
    const ino = blk: {                                   // 在一个快照上找到程序文件
        var r = fsys.reader() catch return error.NoDevice;
        defer r.end();
        break :blk try findProgram(&r.fs, p.cwd, path);
    };
    fsys.holdText(ino) catch return error.TextBusy;      // 占住它：运行期间不能改、不能删
    var space = vm.createUserSpace() catch |err| { fsys.releaseText(ino); return err; };
    space.backing = .{ .file = ino };                    // 占用交给地址空间，destroyUserSpace 时放开
    errdefer vm.destroyUserSpace(&space);
    const image = blk: {                                 // 占住之后再拿一个快照，读文件头、记下段
        var r = fsys.reader() catch return error.NoDevice;
        defer r.end();
        const st = r.fs.stat(ino) catch ...;             // 中间被删掉了是 NoSuchProgram
        break :blk try loadImage(&space, .{ .file = .{ .fs = &r.fs, .ino = ino, .size = st.size } }, args);
    };
    var old = p.space;
    p.space = space;
    vm.activate(space.root);
    vm.destroyUserSpace(&old);                           // 也放开旧的程序文件
    p.lock.acquire();
    p.name = .init(std.fs.path.basenamePosix(path));     // procinfo 在别的 hart 上读它
    p.lock.release();
    startFrame(frameOf(p), image);
}
```

- **找程序**（`findProgram`）：`path` 里没有 `/` 的在 `/bin` 里找（`run hello` 就是 `/bin/hello`，相当于 `PATH` 只有 `/bin`），有的按路径找，相对路径从当前目录开始，跟着符号链接走（进程名是路径的最后一段，也就是链接的名字）。找不到是 `NoSuchProgram`（`ENOENT`），是目录是 `BadElf`（`ENOEXEC`），路径中间不是目录是 `NotDir`，符号链接有环是 `SymlinkLoop`（`ELOOP`），`/bin/` 加上名字超过 256 字节是 `NameTooLong`，没挂上文件系统是 `NoDevice`。
- **先占住、再读**：`exec` 只读文件头和程序头，段的内容要等程序运行起来、缺页时才读，那时用的是新的快照（`fsys.readText`），所以必须保证这段时间里文件不变：先 `holdText` 占住（[fs.md](fs.md#正在运行的程序文件)），再拿一个**新的**快照读文件头。找程序时的那个快照是占住之前拿的，可能已经旧了：别人可能刚好在两者之间改完了这个文件。占住之后，修改它的一方都会得到 `TextBusy`；占住之前就开始了的修改，要么还没做完（`holdText` 看到有人正在改它，`exec` 返回 `TextBusy`），要么已经提交了，新快照里看得到。所以新快照里的文件头和之后每次缺页读到的内容是同一个版本。两次之间文件被删掉了是 `NoSuchProgram`。快照都不挡着别人读写文件系统（几个 hart 同时 `exec` 各读各的）。
- 先把新程序加载进**新的**地址空间（记下段、写好参数），全部成功之后才换掉旧的。失败时旧的地址空间和 `TrapFrame` 都没动，系统调用返回错误，原来的程序接着运行（xv6 也是这样）。
- `args` 已经在**内核内存**里了：参数在旧的地址空间里，换掉之前 `exec` 系统调用就把它们复制到了内核栈上（[syscalls.md](syscalls.md#exec)）。
- **释放旧的页表之前必须先切走**：这时 `satp` 还指着旧的根页表。`destroyUserSpace` 同时放开旧的程序文件（`vm.releaseBacking`）。
- 改写 `TrapFrame`：从新程序的入口开始，`a1`、`sp` 指向参数，其他寄存器为 0。系统调用返回值会写进 `a0`，所以 `exec` 系统调用成功时返回 `argc`，新程序看到 `a0 = argc`，和 init 第一次运行时一样。
- pid、父进程、`ticks`、`killed`、**打开的文件**、当前目录都不变；名字换成程序文件的名字（路径的最后一段，`Name` 存在进程里，最多 16 字节，`run /h` 之后叫 `h`）；堆重新从新程序的段之后开始（空的）。

### 命令行参数

```zig
fn pushArgs(space: *vm.Space, args: []const []const u8) error{OutOfMemory}!usize   // 返回栈上 Arg 数组的地址

pub const Arg = extern struct { ptr: usize, len: usize };            // abi.zig
pub const max_args = 32;
pub const max_arg_bytes = 2048;
```

`exec` 把参数复制到新地址空间的栈顶，布局是：

```
0x8000_0000（stack_top）
参数的字节        依次往下放：第 0 个在最上面。不以 0 结尾（长度在 Arg 里）
（向下对齐到 16）
Arg 数组          argc 个 { ptr, len }，ptr 是上面那些字节的用户地址   ← sp、a1
```

- 新程序的 `sp` 就从 `Arg` 数组的地址开始，往下才是真正的栈。`Arg` 数组的地址按 16 字节对齐（RISC-V 调用约定要求 `sp` 16 字节对齐）。
- 和 C 不一样，参数不以 0 结尾、`argv` 数组后面也没有 `NULL`：Zig 用切片，长度和指针一起传，`user/start.zig` 直接把它变成 `[]const abi.Arg`（[user-programs.md](user-programs.md#startzig)）。
- 最多 32 个参数、加起来最多 2048 字节，所以整块不到 2.6 KiB（2048 + 32 × 16 字节的 `Arg`，再加对齐），栈最顶上那一页一定放得下。栈是按需分配的，`copyToUser` 写参数时才分配这一页，没有内存时 `exec` 返回 `OutOfMemory`（`-ENOMEM`），这是这里唯一可能的失败。上限由 `exec` 系统调用检查，超出返回 `-E2BIG`。
- 用 `loadImage(&hello, &.{ "hello", "", "world!" })` 的单元测试检查了布局：16 字节对齐，每个 `Arg` 指向栈上正确的字节，没有参数时 `sp` 就是栈顶。

### sbrk：堆

```zig
pub fn sbrk(increment: isize) SbrkError!usize   // 返回原来的 brk
pub const SbrkError = error{ OutOfMemory, InvalidArgument };
```

照 xv6 的 `growproc`：堆是 `[heap_start, brk)`（都在 `p.space` 里），`brk` 按字节记，页按页分配。和 xv6 的 lazy allocation 实验一样，**按需分配**：

- **变大**：只挪 `brk`，一页都不分配。新跨进来的页第一次被访问时缺页，`vm.fault` 才分配一页清零的 `RW-` 页（[按需分页](#按需分页)）。所以 `sbrk(4 MiB)` 之后只碰两页，只多用两页和装它们的页表。
- **变小**：`vm.shrinkUser` 把整个落在新 `brk` 之后、已经分配了的页释放掉（没访问过的本来就没有），空出来的第 0 级页表也释放（[paging.md](paging.md#堆的增长和缩小)），然后 `vm.flushUserTlb`：这些页可能还在 TLB 里，不刷的话进程还能访问已经还给页分配器的页。
- **边界**：不能小于 `heap_start`（`InvalidArgument`，`-EINVAL`），不能长进栈下面的保护页（`vm.heap_limit`，超出是 `OutOfMemory`）。堆一共比整个物理内存（`page.total_pages`）还大时也是 `OutOfMemory`：肯定用不上，和 Linux 默认的 overcommit 检查一个意思。别的时候不看还有多少空闲的页，比空闲内存大的堆也能长成功，真的都用上时，访问它的进程因为没内存被结束（内核替它写的时候返回 `-EFAULT`）。`increment` 是有符号的，加减都检查溢出。
- 回归测试 `t_sbrk` 检查了：新内存清零、按页分配（`brk` 所在页的页尾能写，下一页缺页）、缩小后被释放的页缺页、`fork` 复制堆、各种越界、超过物理内存时失败；按需分配：`sbrk(4 MiB)` 不用页，碰两页用 2～5 页（加页表），缩回去全部还回来；比空闲内存大的堆，子进程一页页写满时被结束（`qemu_test.py` 检查 `out of memory (demand paging)` 那一行），内核替进程写（读 `/dev/zero`）写到没内存时返回 `-EFAULT`。

## 调度

```zig
pub fn scheduler() noreturn            // 每个 hart 初始化完之后调用，不返回
fn sched() void                        // 当前进程切回调度器
pub fn yield() void                    // yield 系统调用
pub fn yieldTimeslice() void           // 时钟中断打断了 U 模式
pub fn WaitQueue.wait(q: *WaitQueue, lock: *Spinlock) void
pub fn WaitQueue.wakeAll(q: *WaitQueue, lock: *Spinlock) void
```

### 调度器

```zig
pub fn scheduler() noreturn {
    const c = &cpus[hart.id()];
    while (true) {
        riscv.enableInterrupts();
        riscv.disableInterrupts();
        hart.checkPanic();
        ipi.setIdle(true);
        var found = false;
        for (&table) |*p| {
            p.lock.acquire();
            defer p.lock.release();
            if (p.state != .runnable) continue;
            ipi.setIdle(false);
            p.state = .running;
            p.hart = hart.id();
            c.proc = p;
            vm.activate(p.space);
            switchContext(&c.context, &p.context);
            vm.activate(vm.kernel_root);
            c.proc = null;
            found = true;
        }
        if (!found) riscv.wfi();
    }
}
```

和 xv6 的 `scheduler()` 一句一句对得上。每个 hart 跑一份，各自用自己的启动栈和 `cpus[hart.id()]`，扫的是同一张进程表：

1. **开一下中断再关上**。进程和调度器都是关着中断运行的，中断只在这里（以及 U 模式）才会被处理。挂起的中断（时钟、键盘、核间中断）在这一刻进来，中断处理程序可能 `wakeup` 某个进程。然后看一眼是不是有别的 hart 在 panic（[boot.md](boot.md#panic)），有的话停下。
2. **登记成空闲，扫一遍进程表**，每个槽位先拿它的锁再看状态。`runnable` 的进程：清掉空闲登记，状态设为 `running`，记下 `p.hart`，`c.proc` 指向它，切到它的地址空间，`switchContext(&c.context, &p.context)` 切过去。进程要么第一次运行（`forkret`），要么从它上次调用 `sched()` 的地方继续。
3. 进程调用 `sched()` 之后，执行回到这里，这时**又拿着这个进程的锁**（进程是拿着它切回来的）：切回内核页表，`c.proc = null`，放开锁，接着扫下一个槽位。
4. **一整圈都没有可运行的进程就 `wfi`**，等下一个中断。

**为什么拿着进程锁切换**：从“检查到 `runnable`、改成 `running`”到“`switchContext` 真正换到它的栈上”之间，别的 hart 的调度器不能插进来也去运行它；反过来，进程“改掉自己的状态、切回调度器”这一步也要在别的 hart 看来是一下子完成的，否则另一个 hart 看到它是 `runnable`，就会在它还在原来的栈上运行时恢复它的 `context`，两个 hart 用同一块内核栈。所以锁在两次切换之间交接：调度器拿着锁切到进程，进程那边（`sched` 的调用方，或者新进程的 `forkretC`）放开；进程要让出 CPU 时先拿上锁再改状态、调用 `sched`，调度器那边放开。xv6 的注释管这叫“锁由一个线程拿、另一个线程放”。

**先切回内核页表再放开锁**：这个进程可能已经结束了。父进程（可能在另一个 hart 上）要拿到它的锁才能看到它是 `zombie`、回收它、释放它的页表（[wait](#wait回收子进程)），所以放开锁的时候，这个 hart 必须已经不用它的页表了。同样，`finish` 拿着锁切走，也保证了父进程回收它（重用这个槽位的内核栈）时，它已经不在这块栈上了。

**轮转**：每扫一圈，每个 `runnable` 的进程运行一次，所以就绪的进程轮流运行，不需要记“上次运行的是谁”。几个 hart 同时扫的时候，谁先拿到锁谁运行，另一个 hart 再看到时它已经是 `running` 了，跳过。

**先关中断再扫描、再 `wfi`，顺序不能改**，原因是一个经典的竞争：如果开着中断扫描，可能出现“扫描时没有可运行的进程 → 正要执行 `wfi` 时键盘中断来了，叫醒了 shell → `wfi` 睡下去”，shell 要等到下一个中断（最长 10 ms 后的时钟中断）才能运行。关着中断扫描就没有这个问题：中断只是挂起（`sip` 里的位置 1）而不会被处理；`wfi` 只看 `sie` 和 `sip`、不看 `sstatus.SIE`，有挂起的中断就立即返回；下一轮开头开中断，挂起的中断马上被处理。xv6 的注释里讲的也是这件事。

**别的 hart 叫醒的进程**：hart A 上的 `wakeup` 把一个进程改成 `runnable` 时，正在 `wfi` 的 hart B 本来不会知道，要等它自己的下一个时钟中断（最多 10 ms，xv6 就是这样）。现在 hart A 给一个登记为空闲的 hart 发核间中断，它马上来运行这个进程，见下一节。

### 核间中断

```zig
// ipi.zig
var idle: std.atomic.Value(usize)        // 第 i 位：hart i 在调度器里扫描或者正要 wfi，没在运行进程
pub fn initHart() void                   // sie.SSIE = 1，每个 hart 一次
pub fn setIdle(on: bool) void            // 调度器：扫描之前置位，挑中进程时清掉
pub fn wakeIdle(n: usize) void           // 叫醒最多 n 个别的空闲 hart
pub fn send(id: usize) void              // 给 hart id 发一个核间中断
pub fn onInterrupt() void                // 收到时清掉 sip.SSIP
```

核间中断（IPI）就是一个 hart 打断另一个 hart。S 模式自己发不了（要写只有 M 模式能访问的 CLINT），请 OpenSBI 代发（`sbi.sendIpi`，[riscv-sbi.md](riscv-sbi.md#用到的扩展)）；目标 hart 的 `sip.SSIP` 被置 1，收到 S 模式软件中断。中断不带任何信息，只是让目标 hart 进一次陷阱处理程序，`ipi.onInterrupt` 清掉 `SSIP`（不清的话一开中断又会进来），别的什么都不做。用在两件事上：

**叫醒空闲的 hart**（`wakeIdle`）。让别的进程变成 `runnable` 都经过 `makeRunnable(p)`（拿着 `p.lock`，断言 `p` 不在运行）：它改状态、`wakeIdle(1)` 叫一个空闲的 hart。`wakeup` 叫醒几个进程就叫了几次，`kill` 叫醒睡着的进程、`fork` 建好子进程、`userinit` 建好 init 时各一次。原来这是一条约定（“改成 `runnable` 的地方要调用 `wakeIdle`”），每个地方自己写；收进一个函数之后，新加的路径不会漏。被叫的 hart 如果在 `wfi`，立刻醒来；如果还在扫描，中断挂在 `sip` 里，接下来的 `wfi` 立刻返回。下一轮开头开中断时处理掉它，接着扫描，看到新的 `runnable` 进程。

- **扫描之前登记，不是扫完才登记**：hart B 扫到槽位 k（不是 `runnable`）之后、`wfi` 之前，hart A 把槽位 k 改成 `runnable`。如果 B 扫完才登记，A 可能在那之前读 `idle`、看不到 B，B 就白睡一觉。B 在扫描之前登记，而 A 是拿着槽位 k 的锁改状态、放开锁之后才读 `idle`：要么 B 拿到这把锁时已经看到 `runnable`，要么 A 拿到锁在 B 放开之后，那么 B 的登记（在 B 放开锁之前）一定对 A 可见，A 会发核间中断过来。和调度器“关着中断扫描再 `wfi`”防的是同一种竞争，只是跨 hart。
- **认领**：`wakeIdle` 用 `cmpxchg` 把一个空闲 hart 的位清掉，成功了才给它发。两个 hart 同时叫醒进程时不会都去叫同一个空闲的 hart，另一个会去叫下一个。被叫的 hart 下一轮开头重新登记。
- **不叫自己**：调用方所在的 hart 反正会再扫一遍（它在调度器里，或者当前进程迟早让出 CPU）。
- 挑中进程时清掉登记，所以正在运行进程的 hart 不会被白白打断。被认领、但没等到中断就自己扫到了进程的 hart，会在进入 U 模式之后收到这个中断，什么也不做就回去了。

**催正在运行被杀进程的 hart**（`markKilled` → `send(p.hart)`）。`kill`、Ctrl-C 杀的进程正在另一个 hart 上运行（`state == running`，`p.hart` 不是自己）时，给那个 hart 发核间中断：

- 它在 U 模式里的话，马上陷入内核，`handleTrap` 末尾的 `checkKilled` 结束它，不用等那个 hart 的下一个时钟中断。
- 它在内核里（系统调用中，中断关着）的话，中断挂着；它本来就会在回到 U 模式之前检查 `killed`，回到 U 模式时这个中断进来一次，什么也不做。
- `p.hart` 和 `state` 都在 `p.lock` 下读写，`markKilled` 拿着这把锁，所以读到的是一致的：要么它真在那个 hart 上运行，要么它刚好在切走（调度器要拿到这把锁才能换下一个进程），那样下一个进程会收到一个什么也不做的中断。

`send` 可以拿着锁调用（`wakeup`、`markKilled` 都拿着锁），它只是一次 SBI 调用。单元测试在主机上运行，`send` 什么也不做。

实测（回归测试 `t_ipi`，用 U 模式的 `rdtime` 计时，15 次的中位数，safe 模式）：

| | 没有核间中断 | 有核间中断 |
| --- | --- | --- |
| 杀掉另一个 hart 上在 U 模式里死循环的进程，从 `kill` 到 `wait` 返回 | 2 核 7.2～8.1 ms，4 核 4.0～4.4 ms | 2～8 核 0.27～0.46 ms |
| 父进程写管道之后自己接着忙，睡在 `read` 里的子进程多久之后醒来运行 | 2 核 1.1～7.6 ms，4 核 3.6～3.8 ms | 2～8 核 0.18～0.23 ms |
| 单核（只有一个 hart，没有核间中断可发） | kill 约 0.2 ms，wakeup 7.3～8.1 ms | 一样 |

单核时第二项要等父进程的时间片用完，和有没有核间中断无关。

### sched、yield

```zig
fn sched() void {
    const p = current().?;
    if (!p.lock.holding()) @panic("sched: not holding the process lock");
    if (spinlock.heldCount() != 1) std.debug.panic("sched: {d} spinlocks held", .{spinlock.heldCount()});
    std.debug.assert(p.state != .running);
    std.debug.assert(!riscv.interruptsEnabled());
    switchContext(&p.context, &cpus[hart.id()].context);
}

pub fn yield() void {
    const p = current().?;
    p.lock.acquire();
    p.state = .runnable;
    sched();
    p.lock.release();
}
```

`sched` 是进程切回调度器的唯一入口，切换前检查四件事（和 xv6 一样）：拿着自己的进程锁，而且只拿着这一把（拿着别的锁切走的话，下一个要这把锁的会永远自旋下去），状态已经改掉了（不再是 `running`，否则调度器会以为它还在跑），中断是关着的。等调度器下次挑中这个进程时（可能在另一个 hart 上），`switchContext` 才返回，执行从 `sched` 之后继续，这时又拿着进程锁，由调用方放开。

注意 `sched` 每次现查 `cpus[hart.id()]`，不能在函数开头取一次存着：切回来的时候可能已经在另一个 hart 上了。

`yield` 由 `yield` 系统调用调用；时钟中断打断 U 模式时（时间片用完，[trap.md](trap.md#分发)）陷阱处理程序调用 `yieldTimeslice`，它多做一件事：拿着锁给 `ticks` 加 1。只有时钟中断让出 CPU，串口中断不让（和 xv6 一样）：串口中断只是叫醒在 `read` 里等输入的进程（通常是 shell），它最多等当前进程用完这个时间片（10 ms）；多核时 `wakeup` 给一个空闲的 hart 发核间中断，它马上来运行 shell。

**时间片**：每个 hart 的时钟中断是每 10 ms 一次（[devices.md](devices.md#定时器timerzig)），不是按进程计时的，所以一个进程刚被调度就碰上时钟中断时，它的时间片会不足 10 ms。`ticks` 只在时钟中断打断这个进程时加 1，是它用掉的 CPU 时间的近似值（单位 10 ms），`ps` 显示它。两个死循环的进程一起跑时，`ticks` 的增速几乎相同；多核时它们在不同的 hart 上同时跑，各自每秒接近 100。

### 等待队列（WaitQueue）

```zig
pub const WaitQueue = struct {
    first: ?*Process = null, // 排着的进程，用 Process.wait_next 串起来；由保护等待条件的锁保护

    pub fn wait(q: *WaitQueue, lock: *Spinlock) void {
        const p = current().?;
        p.wait_next = q.first; // 拿着 lock 排进队列
        q.first = p;
        p.queued = true;
        p.lock.acquire();
        lock.release();
        p.state = .sleeping;
        sched();
        p.lock.release();
        lock.acquire();
        if (p.queued) q.remove(p); // 被 kill 叫醒的还排着，自己摘掉
    }

    pub fn wakeAll(q: *WaitQueue, lock: *Spinlock) void {
        while (q.first) |p| {
            q.first = p.wait_next; // 摘下来
            p.wait_next = null;
            p.queued = false;
            p.lock.acquire();
            defer p.lock.release();
            if (p.state == .sleeping) makeRunnable(p);
        }
    }
};
```

（省略了检查和计数。）每个等待条件旁边放一个队列，和条件由同一把锁保护：

| 谁在等 | 等什么 | 队列 | 锁 | 谁叫醒 |
| --- | --- | --- | --- | --- |
| `sleep` 系统调用 | 时钟走够 | `timer.waiters` | `timer.lock` | 启动 hart 的每个时钟中断（`timer.onInterrupt`） |
| `read` 系统调用（串口） | 键盘输入 | `uart.rx_waiters` | `uart.rx_lock` | 串口中断（`trap.handleExternal`） |
| `read` 系统调用（管道） | 管道里有数据，或者写端都关了 | `Pipe.readers` | `Pipe.lock` | 往管道里写了东西（`pipe.write`），写端关了（`pipe.close`） |
| `write` 系统调用（管道） | 管道腾出空间，或者读端都关了 | `Pipe.writers` | `Pipe.lock` | 从管道里读走了东西（`pipe.read`），读端关了（`pipe.close`） |
| `wait` 系统调用 | 子进程结束 | 自己的 `child_exit` | `wait_lock` | 子进程结束时（`finish` 叫醒父进程）；孤儿交给 init 时（`reparent` 叫醒 init） |
| 拿睡眠锁 | 锁被放开 | `Sleeplock.waiters` | `Sleeplock.lk` | `Sleeplock.release` |
| 读写磁盘 | 请求做完；有空闲的描述符 | `info[head].waiters`；`free_waiters` | `virtio_disk.lock` | 磁盘中断（`virtio_disk.onInterrupt`）；做完的请求放回描述符 |
| 换缓冲区 | 有缓冲区没人用了 | `bio.evict_waiters` | `bio.evict_lock` | `bio.release` |
| 修改的一方等 `limbo` | 旧树的读者读完 | `Volume.readers_done` | `Volume.snap_lock` | 最后一个旧树的读者 `endRead` |

规矩是**醒来之后自己检查条件，不满足就再等**：`while (!条件) q.wait(lock);`。醒来不代表条件满足：时钟的队列每个 tick 都叫醒所有在等的进程，各自数够了没有；两个进程同时 `read`，一个字符只能给其中一个；被 `kill` 也会醒。`wakeAll` 只改状态、不切换，所以中断处理程序里也能调用。

**`lock` 是保护等待条件的锁**，照 xv6 的 `sleep(chan, lk)`：调用方拿着它检查条件、拿着它调用 `wait`；醒来后重新拿上再返回，所以调用方的循环里一直拿着锁。改条件的一方（往管道里写、串口中断往缓冲区里放字符、时钟中断加 `ticks`）也要先拿这把锁，**拿着它调用 `wakeAll`**：队列本身也归这把锁管。`wait` 和 `wakeAll` 都检查调用方拿着 `lock`，没拿就 panic。例子是管道的读：

```zig
p.lock.acquire();
defer p.lock.release();
while (p.nread == p.nwrite and p.write_open) {
    if (proc.isKilled()) return 0;
    p.readers.wait(&p.lock);
}
```

**为什么不会丢唤醒**（lost wakeup：叫醒发生在睡下之前，等的人永远睡下去）：`wait` 拿着 `lock` 排进队列，先拿上自己的进程锁，再放开 `lock`，然后才改状态、切走；调度器切回来之后才放开进程锁。改条件的一方要先拿 `lock` 才能改、才能 `wakeAll`，于是它看到的要么是还没检查条件之前（那调用方会看到新的条件，不睡），要么是已经排进队列之后；它要拿进程锁才能改状态，等拿上时这个进程已经完全睡下、切走了（`sleeping`，叫醒它）。进程锁还保证了另一件事：`wakeAll` 不会在这个进程还没切走时就把它改成 `runnable`，让另一个 hart 的调度器在它还在原来的栈上运行时恢复它。

**被 `kill` 叫醒的进程还排在队列里**：`kill` 只拿进程锁，直接把 `sleeping` 改成 `runnable`（`markKilled`），不知道它排在哪个队列里，也没拿那个队列的锁。所以 `wait` 醒来、重新拿上 `lock` 之后看 `queued`：还是 `true` 就自己从队列里摘掉（单链表，要从头找，但只有被 kill 时才走这一步）。在它拿上 `lock` 之前，`wakeAll` 可能已经把它摘下来了，那时它已经不是 `sleeping`，`wakeAll` 只摘不改状态。`wait_next`、`queued` 都由队列的锁保护，所以两边不会同时改。一个进程同一时刻最多排在一个队列里：它在从 `wait` 返回之前一定已经出队了。

**为什么从“通道”换成队列**：原来照 xv6 写的是 `sleep(chan, lock)` / `wakeup(chan)`，`chan` 是任意一个地址（`&p.nread`、`&timer.ticks`、`&info[head]`……），内核不读它指向的内容，只用来配对。这有两个问题。一是谁在等什么要靠搜同一个地址表达式来配对，把 `&p.nread` 写成 `&p.nwrite` 就是永远不醒，类型系统帮不上忙；现在队列是结构体里有名字的字段，写错了多半编译不过，或者一眼就能看出来。二是 `wakeup` 要扫整张进程表、拿 64 次进程锁，而它调得很频繁（每次放开睡眠锁、每次管道读写、每个磁盘中断、每个时钟 tick），绝大多数时候没人在等：B 树查找每经过一层节点放一次缓冲区的睡眠锁。中间有一版按通道地址散列成 32 个原子计数器，没人在等时直接返回；现在 `wakeAll` 看到队列是空的就直接返回，有人在等时也只拿排着的进程的锁。代价是每个进程多两个字段，每个等待条件多一个指针。

**当前进程不会排在队列里**：它在运行。所以 `wakeAll` 不用像 xv6 的 `wakeup` 那样跳过 `myproc()`（调用方可能拿着自己的锁，再拿就是重复加锁），只断言一下。

`lock` 不能为空。单核时内核全程关中断，不传锁也不会丢唤醒；多核时另一个 hart 上的写者随时可能插进来，等待的条件必须有锁保护。

`sleep` 系统调用（`syscall.zig`）就是 xv6 的 `sys_sleep`：

```zig
const n = (ms *| timer.tick_hz +| 999) / 1000;
timer.lock.acquire();
defer timer.lock.release();
const start = timer.ticks;
while (timer.ticks - start < n and !proc.isKilled()) timer.waiters.wait(&timer.lock);
```

要睡的 tick 数 `⌈ms × 100 / 1000⌉`，乘法和加法都是饱和运算，`ms` 再大也不会溢出（最多睡到永远，只能被 `kill`）。`ticks` 由 `timer.lock` 保护（xv6 的 `tickslock`），只有启动 hart 的时钟中断给它加 1，加完在锁里 `waiters.wakeAll(&lock)`（[devices.md](devices.md#定时器timerzig)）。用户程序看到的 `uptime()` 也是按 tick 算的，所以醒来后 `uptime()` 至少增加了 `ms`；按真实时间算，可能比 `ms` 少不到一个 tick（睡下去时当前 tick 已经过了一部分）。`ms = 0` 时不睡，直接返回。被 kill 了就提前返回，回到陷阱处理程序后结束。

## 切换上下文

### 保存的上下文

```zig
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,   // s0..s11
};
```

按 RISC-V 的 C 调用约定，函数调用前后需要保持不变的只有 `sp` 和 `s0..s11`（被调用者保存），再加上返回地址 `ra`。其他寄存器（`t0..t6`、`a0..a7`）调用方本来就不指望它们保持原值。所以“暂停”一段内核代码只需要保存这 14 个寄存器，就像协程切换一样。保存/恢复它们的指令由 `contextAsm(op, base)` 在编译期生成，并在编译期断言寄存器个数和 `Context` 的大小一致。

### switchContext

```zig
fn switchContext(from: *Context, to: *const Context) void {
    asm volatile (
        \\mv a0, %[from]
        \\mv a1, %[to]
        \\call %[switchNaked]
        :
        : [from] "r" (from),
          [to] "r" (to),
          [switchNaked] "X" (&switchNaked),
        : .{ .ra = true, .t0 = true, ..., .t6 = true, .a0 = true, ..., .a7 = true, .memory = true });
}

fn switchNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a0") ++   // 把 ra、sp、s0..s11 存进 from
        contextAsm("ld", "a1") ++             // 从 to 恢复 ra、sp、s0..s11
        "ret\n");                             // 跳到恢复出来的 ra
}
```

- `call` 把返回地址（`call` 的下一条指令）放进 `ra`，`switchNaked` 把它存进 `from`；恢复 `to` 之后 `ret` 跳到的是**另一次** `switchContext` 调用里 `call` 的下一条指令，`sp` 也换成了那边的栈。对那边来说，它的 `switchContext` 刚刚返回。
- 新进程的 `context` 是 `firstContext` 构造的：`ra` = `forkret`，`sp` = 它的 `TrapFrame`，所以 `ret` 跳进 `forkret`，最后 `sret` 进入 U 模式。
- 只用在两处：调度器切到进程（`scheduler`），进程切回调度器（`sched`）。进程之间从不直接切换，总是经过调度器。
- 真正的切换在裸函数 `switchNaked` 里（它要直接改 `sp`，不能有序言和尾声）。Zig 不允许直接调用裸函数，所以在一段内联汇编里 `call` 它。
- 对编译器来说，这段内联汇编就是“会破坏 `ra`、`t0..t6`、`a0..a7` 和内存的一段代码”，正好对应一次 C 函数调用的效果；编译器不会对裸函数本身做任何假设。`from` 和 `to` 用 `"r"` 约束传进任意寄存器，再在汇编里 `mv` 到 `a0`、`a1`，而不是直接用 `"{a0}"`、`"{a1}"` 约束：`a0`、`a1` 已经声明为被破坏，被破坏的寄存器不应该同时用作输入（GCC 的内联汇编规则明确禁止），这样写就不依赖编译器怎么处理这种重叠。被声明为被破坏的寄存器也不会被分配给 `"r"` 输入，所以两条 `mv` 不会互相覆盖。
- `switchNaked` 声明成 `noreturn`：它用 `ret` 跳走，不会走到函数体结尾。这没关系，因为它只从内联汇编里调用，编译器看不到这个调用。**曾经踩过的坑**：单进程版本最初把裸函数 `@ptrCast` 成 C 调用约定的函数指针来调用，而裸函数被声明成了 `noreturn`。release 模式下编译器据此认为调用之后的代码永远不会执行，把切回内核页表、释放内存这些代码都删掉了，进程一退出内核就崩溃。现在的写法不依赖裸函数的签名。
- 切换全程关着中断、拿着这个进程的锁：调度器关着中断扫描进程表，进程这边是在陷阱处理程序里（[调度器](#调度器)讲了为什么要拿着锁）。
- `Context` 里没有 `tp`：`tp` 存的是 hart 编号（[trap.md](trap.md#tp-约定)），属于 hart 而不属于进程。进程在 hart A 上切走、在 hart B 上被恢复时，`tp` 保持 B 的值，正好是对的。

### 栈的变化

```
hart 0 的启动栈（调度器在用）      进程 A 的内核栈（24 KiB）          进程 B 的内核栈
┌─────────────────────┐          ┌─────────────────────┐ ← 栈顶     ┌─────────────────────┐
│ kmain → scheduler → │          │ TrapFrame（288 字节）│            │ 初始 TrapFrame       │ ← B.context.sp
│ switchContext       │ ←        ├─────────────────────┤            └─────────────────────┘
│                     │ cpus[0]  │ handleTrap →        │              （还没运行过，
└─────────────────────┘ .context │ yieldTimeslice →    │                ra = forkret）
                          .sp    │ sched →             │
                                 │ switchContext       │ ← A.context.sp
                                 └─────────────────────┘
```

- 调度器切到进程时，它的调用链（`kmain → scheduler → switchContext`，别的 hart 是 `kmainSecondary → scheduler → switchContext`）留在这个 hart 的启动栈上，`cpus[hart].context.sp` 记住它的位置。`kmain` 永远不会返回，启动栈从此归这个 hart 的调度器用（[boot.md](boot.md#每个-hart-的启动栈)）。
- 上图里 A 停在 hart 0 的调度器切过来的位置，但它的 `context` 不记得是哪个 hart：下次可能是 hart 2 的调度器 `switchContext(&cpus[2].context, &A.context)` 把它恢复出来，`sched` 返回后它就在 hart 2 上接着运行，切回去时也是切回 hart 2 的调度器。
- 每次从 U 模式陷入，`trapEntry` 都从 `sscratch`（这个进程的内核栈顶）开始压 `TrapFrame`。陷阱处理程序让出 CPU 时，它的调用链就停在这个进程的内核栈上，等下次轮到它再继续。同一时刻每块进程内核栈上最多只有一层陷阱。
- 进程结束时它的内核栈上的内容直接丢弃，下一个用这个槽位的进程从头再用。`fork` 出来的子进程的内核栈上只有复制来的 `TrapFrame`，没有父进程的调用链：它从 `forkret` 开始，不经过 `handleTrap` 的后半段。
## 结束进程

```zig
pub fn exit(code: u8) noreturn                                          // exit 系统调用
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn // U 模式下的异常
pub fn checkKilled() void                                               // 回到 U 模式之前
fn finish(p: *Process, status: u32) noreturn

pub fn wait(pid: usize, nohang: bool, status_ptr: usize) WaitError!?usize  // wait 系统调用
pub const WaitError = error{ NoChildren, BadAddress };
fn reap(c: *Process) void

pub fn kill(pid: usize, reason: []const u8) KillError!void              // kill 系统调用
pub const KillError = error{ NoSuchProcess, PermissionDenied };
pub fn interruptForeground() void                                       // Ctrl-C
```

### exit：变成 zombie

`exit`、`killCurrent` 打印一行信息，然后调用 `finish(p, status)`（xv6 的 `exit` 的后半部分）：

```zig
fn finish(p: *Process, status: u32) noreturn {
    const init = init_proc.?;
    if (p == init) std.debug.panic("init exited (status {d})", .{status});
    for (&p.files) |*f| {
        if (f.*) |x| file.close(x);
        f.* = null;
    }
    vm.releaseBacking(&p.space);   // 不会再缺页了：放开程序文件
    wait_lock.acquire();
    reparent(p, init);
    p.parent.?.child_exit.wakeAll(&wait_lock);
    p.lock.acquire();
    p.xstatus = status;
    p.state = .zombie;
    wait_lock.release();
    sched();
    unreachable;
}
```

1. **init 不能结束**：所有孤儿都靠它回收，它没了内核就 panic（xv6 也是 `panic("init exiting")`）。正常情况下 init 从不退出，`kill` 也不允许杀它。
2. **关掉所有打开的文件**。必须在这里关，不能等父进程回收：管道的写端关了，读的进程才会读到结尾。要是等到 `wait` 回收时才关，读的进程能不能结束就取决于父进程先回收谁：`run echo hi | wc` 的组长要是先 `wait` wc，echo 的写端就一直开着，wc 永远读不到结尾，两边一起卡住。`reap` 断言 zombie 的 fd 表是空的。
3. **放开程序文件**（`vm.releaseBacking`，[按需分页](#按需分页)）：之后不会再回到 U 模式、不会再缺页，用不着它了。不等父进程回收：父进程可能很久以后才 `wait`（比如后台进程），这段时间里程序文件应该已经能改、能删了。
4. 拿上 `wait_lock`（下面要读写 `parent`）。**`reparent`：子进程交给 init**。被交过去的子进程可能已经是 zombie 了，所以顺便叫醒 init，让它的 `wait` 重新看一遍。
5. 叫醒父进程（它可能在 `wait` 里睡着）。先叫醒、后改状态也不会漏：父进程要拿到 `wait_lock` 才能检查子进程，而 `wait_lock` 要等这个进程变成 `zombie` 之后才放开。
6. 拿上自己的锁，记下结束状态（`exit(code)` 是退出码 0..255，被杀的是 `abi.killed_status` 即 `0x100`，两者不会混淆），状态改成 `zombie`，放开 `wait_lock`，拿着自己的锁切回调度器，再也不回来。顺序和 xv6 的 `exit` 一样。

**不在这里释放内存**：进程这时还在用自己的内核栈和地址空间（`satp` 指着它的页表）。地址空间由父进程在 `wait` 里回收，那时运行的是父进程，用的是父进程的页表。父进程可能在另一个 hart 上，正好在这个进程切走的同时去回收它：它要拿到这个进程的锁才能看到 `zombie`，而锁要等调度器换回内核页表之后才放开（[调度器](#调度器)），所以回收时这个进程的页表和内核栈已经没人在用了。zombie 只占一个槽位和它的用户内存，直到被回收。

### wait：回收子进程

```zig
pub fn wait(pid: usize, nohang: bool, status_ptr: usize) WaitError!?usize {
    const p = current().?;
    wait_lock.acquire();
    defer wait_lock.release();
    while (true) {
        if (try findZombieChild(p, pid)) |c| {      // 拿着 c 的锁返回
            defer c.lock.release();
            if (status_ptr != 0) {
                vm.copyToUser(p.space, status_ptr, std.mem.asBytes(&c.xstatus)) catch return error.BadAddress;
            }
            const child_pid = c.pid;
            reap(c);
            return child_pid;
        }
        if (nohang or isKilled()) return null;
        p.child_exit.wait(&wait_lock);
    }
}
```

- **整个过程拿着 `wait_lock`**：`parent` 字段只在拿着它时改（`fork`、`reparent`、`reap`），所以扫描期间父子关系不会变。
- `findZombieChild` 扫一遍进程表，看 `parent == p` 的进程（`pid` 不是 `abi.wait_any` 时只看这一个 pid），每个都拿它的锁看状态：有 zombie 就**拿着它的锁**返回；有符合条件的子进程但都没结束返回 `null`；一个都没有是 `NoChildren`（`-ECHILD`）。它只看进程表，单元测试直接测它。
- 都没结束就**排在自己的 `child_exit` 里睡下**（`p.child_exit.wait(&wait_lock)`），子进程的 `finish` 用 `p.parent.?.child_exit.wakeAll(&wait_lock)` 叫醒它。醒来再扫一遍。`nohang` 时不睡，返回 `null`（系统调用返回 0）；被 kill 了也不睡，回到陷阱处理程序后结束。
- 找到 zombie 后，先把 `xstatus` 写进用户给的地址（`status_ptr` 为 0 时不写；写不进去就返回 `BadAddress`，系统调用返回 `-EFAULT`，**不回收**，子进程还在，可以再 `wait`），然后 `reap`：释放地址空间，`fill(c, .{})` 把槽位清回 `unused`（锁留着）。xv6 也是先 `copyout` 再 `freeproc`，也是拿着 `wait_lock` 和子进程的锁做这些。`copyToUser` 只查页表、复制，不会等待，拿着锁调用没问题。

### kill：只做标记

**杀别的进程**（`kill`），照 xv6 的做法：**只记下原因（`killed`），在睡的改成 `runnable`，不当场结束它**。被杀的进程可能停在内核栈上的任何地方（`sleep` 里、`yield` 里），只有它自己知道怎么安全地收尾，所以让它自己来：

- 陷阱处理程序回到 U 模式之前调用 `checkKilled()`（[trap.md](trap.md#分发)），新进程第一次进入 U 模式之前 `forkretC` 也调用它。拿着进程锁读出 `killed`，不为空就 `killCurrent("{s}", .{reason})`。所以**被杀的进程不会再执行一条用户指令**。
- 睡着的进程被改成 `runnable`，醒来后在 `sleep`、`read`、`write`（管道）、`wait` 的循环里看到 `killed`（`proc.isKilled()`，也拿进程锁读），提前返回，接着在 `checkKilled` 里结束。
- 正在 U 模式运行的进程：中断（或者另一个 hart 上的 `kill` 系统调用）只给它做标记。单核时串口中断打断的就是它，这次中断返回之前 `checkKilled` 就结束它；多核时它可能正在另一个 hart 上运行，`markKilled` 给那个 hart 发核间中断，它马上进入内核，回到 U 模式之前结束（[核间中断](#核间中断)）。xv6 不发，要等那个 hart 的下一个时钟中断。
- `kill` 先找到这个 pid 的进程并拿着它的锁（`lockPid`：逐个槽位拿锁比较 pid），再标记。只改标志和状态，所以中断处理程序里也能调用。同一个进程被杀两次，保留第一次的原因。zombie 也能“杀”，什么都不变。
- 杀 init 是 `PermissionDenied`（`-EPERM`），没有这个进程是 `NoSuchProcess`（`-ESRCH`）。

输出：

```
[proc] pid 3 (hello) exited with code 0
[proc] pid 6 (fault) killed: load_page_fault at 0x40011462, stval=0x80200000
[proc] pid 7 (spin) killed: interrupted by Ctrl-C
[proc] pid 8 (spin) killed: kill()
```

| 原因 | 谁调用 | 输出 | `wait` 拿到的状态 |
| --- | --- | --- | --- |
| `exit(code)` 系统调用，或 `main` 返回 | `syscall.dispatch` → `proc.exit` | `exited with code N` | `N` |
| 用户程序 panic（Debug/safe 模式下的安全检查失败等） | `user/start.zig` 打印 `panic: ...` 后调用 `exit(255)` | `exited with code 255` | 255 |
| U 模式下的任何异常（缺页、非法指令、`ebreak` 等） | `trap.handleTrap` → `proc.killCurrent` | `killed: <异常名> at <sepc>, stval=<stval>` | `0x100` |
| 前台进程运行期间按了 Ctrl-C | 串口中断 → `proc.interruptForeground` → `proc.kill`，之后 `checkKilled` | `^C`，然后 `killed: interrupted by Ctrl-C` | `0x100` |
| `kill` 系统调用（shell 的 `kill PID`） | `syscall` → `proc.kill`，之后 `checkKilled` | `killed: kill()` | `0x100` |

## Ctrl-C

Ctrl-C 结束的是**前台进程和它的所有子孙**：shell 用 `fork` 启动前台程序后，调用 `setfg(pid)` 告诉内核，等它结束后再 `setfg(0)`（[shell.md](shell.md#前台和后台)）。运行管道时，前台进程是管道的“组长”，各个程序都是它的子进程（[shell.md](shell.md#管道)）。内核只记一个 pid（`proc.foreground`，原子变量：`setfg` 在一个 hart 上写，串口中断可能在另一个 hart 上读），后台进程不受影响。

1. 串口中断处理程序看到 `0x03`，不放进输入缓冲区，`uart.onInterrupt()` 返回 `true`（[devices.md](devices.md#ctrl-c)）。
2. 同一个中断里，`trap.handleExternal` 接着调用 `proc.interruptForeground()`：拿上 `wait_lock`，前台进程存在、没结束、不是 init 的话，打印 `^C`，然后扫一遍进程表，对前台进程和它的子孙（顺着 `parent` 往上找得到前台进程的）都拿锁做 `kill` 的标记（原因是 `interrupted by Ctrl-C`）；否则什么也不做，所以在 shell 里随手按的 Ctrl-C 不会留到下一个程序。整个扫描拿着 `wait_lock`，父子关系不会变、前台进程也不会被回收；`kill` 只做标记，标记的时候谁都还没结束、没有被交给 init，父子关系是完整的，一遍就能找全。这和 xv6 的 `consoleintr` 在中断里直接处理控制字符是一个思路。
3. 被杀的进程在这个 hart 的 U 模式运行的话，这次中断返回之前 `checkKilled` 就结束它；在别的 hart 的 U 模式运行的话，`markKilled` 发过去的核间中断让那个 hart 马上进内核结束它；在 `sleep`、`read`、`write`、`wait` 里睡着的话，它被叫醒后结束；`runnable` 的话，下次被调度时结束。用户程序就算死循环、从不做系统调用，也不会再回到 U 模式。
4. 前台进程结束时叫醒在 `wait` 里等它的 shell。

## 限制和以后可以做的

- 内核代码不可抢占：进程在内核里关着中断运行，直到自己调用 `sched`。xv6 在内核里也开着中断，内核代码被时钟中断打断时也会 `yield`。这里内核里没有长时间的计算，不需要。
- 进程之间没有优先级，也不考虑在哪个 hart 上运行过（没有亲和性）。
- 进程表固定 64 项，内核栈和启动栈是静态的、大小固定，所以按实测用量留了余量；溢出时撞到下面的保护页，内核 panic（[进程表](#进程表)），不能像用户栈那样长。
- `fork` 写时复制，但页表还是整个复制的；内存用完时，按需分配新页、写共用的页都只能结束进程（没有换页、没有 OOM killer 挑别的进程）。
- 按需分页每缺一页读一次盘（经过缓冲区缓存），没有预读，也没有页缓存：同一个程序的几个进程（不是 `fork` 出来的）各读各的，代码页不共用；页一旦读进来就不会被换出去。
- 正在运行的程序文件不能删（`TextBusy`），Linux 允许删（inode 留到最后一个用它的进程结束）；这里的文件系统没有“没名字但还打开着”的 inode。
- `exec` 没有 `PATH`、没有 `#!` 脚本，也不检查执行权限（文件系统没有权限位）：`/bin` 之外的程序要写路径，任何文件都可以拿去试着运行，不是 ELF 的得到 `ENOEXEC`。
- 只有一个前台进程，没有进程组和信号：Ctrl-C 杀前台进程和它的子孙；前台进程的子孙被交给 init 之后（父进程先结束了）就不算了。
- 只有 `sbrk`，没有 `mmap`；用户栈最多 1 MiB，按需分配，不能再长（Linux 默认 8 MiB）。

## 锁

几个 hart 同时访问的数据都由自旋锁（`src/spinlock.zig`，照 xv6 的 `spinlock.c`）保护：

| 锁 | 保护什么 | 在哪 |
| --- | --- | --- |
| `Process.lock`（每个进程一把） | 这个进程的 `state`、`hart`、`pid`、`name`、`killed`、`xstatus`、`ticks`；调度器拿着它切到进程，进程拿着它切回调度器 | 本文 |
| `proc.wait_lock` | 所有进程的 `parent`；`wait` 拿着它睡在自己身上 | 本文 |
| `timer.lock` | `timer.ticks`；`sleep` 系统调用拿着它睡在 `&ticks` 上 | [devices.md](devices.md#定时器timerzig) |
| `page.Pool.lock`（每个 hart 一把） | 这个 hart 的空闲页链表和页数；每一页的引用数是原子变量，不用锁 | [page-allocator.md](page-allocator.md#并发) |
| `File.lock`（每个打开的文件一把） | 这个 `File` 的引用数（文件表没有整张表的锁） | [files.md](files.md#文件表) |
| `Pipe.lock` | 一个管道的缓冲区和两端的状态；读写的进程拿着它睡在管道上 | [files.md](files.md#管道) |
| `uart.rx_lock` | 串口的输入缓冲区；`read` 拿着它排在 `uart.rx_waiters` 里睡下，串口中断也要拿它（拿着它叫醒） | [devices.md](devices.md#输入环形缓冲区) |
| `virtio_disk.lock` | 磁盘的请求队列；发出请求的进程拿着它睡着等，磁盘中断拿着它叫醒 | [disk.md](disk.md#锁) |
| `bio` 的桶的锁（13 把） | 桶里的缓冲区链表，和这些缓冲区的 `refcnt`、`blockno`、`stamp` | [disk.md](disk.md#锁-1) |
| `bio.evict_lock` | 换块一个一个来；等空闲缓冲区时拿着它睡下 | [disk.md](disk.md#找缓冲区get) |
| `Volume.snap_lock` | 文件系统已提交的根、读者计数；修改的一方等旧树的读者时拿着它睡下 | [btree.md](btree.md#快照读者) |
| `Sleeplock.lk` | 一把睡眠锁的 `locked`、`holder`；等锁的进程拿着它睡下 | [disk.md](disk.md#睡眠锁sleeplockzig) |
| `uart.tx_lock` | 串口输出：一次 `print`、一次 `write` 系统调用整段输出，不和别的 hart 的输出交错 | [devices.md](devices.md#串口uartzig) |
| `fsys.text_lock` | 正在运行的程序文件的表（`texts`）和正在被改的 inode（`modifying`） | [fs.md](fs.md#正在运行的程序文件) |

不用锁的：`proc.next_pid`、`proc.foreground`、每一页的引用数（`page.refs`）、缓冲区缓存的 `clock`、`evicting` 是原子变量；`init_proc` 只在启动时写一次；`cpus[i]`、`spinlock` 的 `held[i]`、`timer.deadline[i]` 只有 hart i 自己读写；进程的 `space`、`context`、`files`、`cwd` 只有进程自己读写（见[进程表](#进程表)）；内核页表启动后不再改。

**锁尽量细**：进程、管道、打开的文件、页分配器（每个 hart 一把）、缓冲区缓存（按块号分桶）各有各的锁，文件系统的读者不拿锁（快照）。几个 hart 做互不相干的事（各自分配页、读各自的文件、读同一个文件的不同块）时不抢同一把锁。剩下几把全局的锁是有原因的：

- `wait_lock`：照 xv6。父子关系跨进程（`finish` 要把子进程交给 init、叫醒父进程），用每个进程的锁就得同时拿父子两把，顺序不好定，还会丢 `wakeup`；它只在 `fork`、`exit`、`wait` 时拿一下。
- `timer.lock`：保护一个计数器 `ticks`，`sleep` 系统调用拿着它睡在 `&ticks` 上。
- `virtio_disk.lock`、`uart.tx_lock`、`uart.rx_lock`：设备只有一个（一个请求队列、一个串口），本来就要一个一个来。
- `fsys.write_lock`：写时复制的 B 树同一时刻只能有一个事务（[fs.md](fs.md#接进内核fsyszig)）。读不拿它。
- `bio.evict_lock`：只在换块时拿；缓存命中时不碰它。

规矩（`spinlock.zig` 的开头也写了）：

- **拿着锁时中断必须关着**，`acquire` 检查这一点。不然中断处理程序在同一个 hart 上去拿同一把锁（比如串口中断拿 `rx_lock`），就会永远自旋。内核本来就全程关着中断，所以 `acquire` 只检查、不负责关中断（xv6 用 `push_off`/`pop_off` 计数）。
- **切换进程时只能拿着这个进程自己的锁**（`sched` 检查 `heldCount() == 1` 且拿着的就是它），**回到 U 模式时什么锁都不能拿着**（`handleTrap` 末尾和 `forkretC` 检查 `heldCount() == 0`）。要拿着锁等待的，用等待队列（`WaitQueue.wait(lock)`）。
- **加锁顺序由等级检查**：每把锁创建时给一个等级（`spinlock.Rank`），只能从低往高拿：拿一把锁时，这个 hart 已经拿着的锁的等级都必须更低，否则 `acquire` 直接 panic，说出是哪两把锁（`lock order: acquiring proc (proc) while holding wait (leaf)`，这是把 `wait_lock` 故意标成 `leaf` 实测的）。等级从低到高：

  | 等级 | 锁 | 为什么在这一级 |
  | --- | --- | --- |
  | `wait` | `proc.wait_lock` | `fork`、`finish`、`wait`、`interruptForeground`、`info` 拿着它看、改各个进程（拿进程锁），`finish` 还拿着它叫醒父进程 |
  | `cond` | `timer.lock`、`Pipe.lock`、`uart.rx_lock`、`virtio_disk.lock`、`bio.evict_lock`、`Volume.snap_lock`、`Sleeplock.lk` | 保护等待条件的锁：`sleep` 拿着它去拿进程锁，改条件的一方拿着它调用 `wakeup`、`isKilled`（拿进程锁）。它们之间不嵌套 |
  | `bucket` | `bio` 的桶的锁 | `evict_lock`（`cond`）之后拿；`takeOldest` 同时拿两个桶，所以这一级允许同时拿几把：只有拿着 `evict_lock` 的才这样做，不会互相等 |
  | `proc` | `Process.lock` | 一次只拿一个进程的锁（`sleep` 里交接时拿着自己的进程锁和条件的锁，两者不同级） |
  | `uart_out` | `uart.tx_lock` | 拿着进程锁、条件的锁时都可能打印，所以比它们高；打印时不再拿别的锁 |
  | `leaf` | `page.Pool.lock`、`File.lock`、`fsys.text_lock` | 拿着它们不再拿别的锁。`fork` 拿着 `wait_lock` 和子进程的锁调用 `file.dup`，`reap` 拿着锁释放页 |

  只有 `bucket` 一级允许同时拿几把；别的同一级的锁不嵌套：`file.close` 先放开 `File.lock` 再去关管道，页分配器从别的 hart 拿页（`steal`）时先放开别人的链表的锁再拿自己的，`file.alloc` 一个槽位一个槽位地拿锁。拿着锁复制用户内存的地方都先 pin 好（[paging.md](paging.md#内核访问用户内存)），拿着锁时不会再缺页、分配页。

  每个 hart 记着自己拿着哪些锁（`held[hart.id()]`，按拿的顺序，最多 16 把），`acquire` 拿它和要拿的锁比等级，`release` 把锁从里面去掉（放的顺序不一定和拿的相反：`sleep` 先拿进程锁、再放条件的锁）。原来顺序只写在文档里，违反了的代码大多数时候不会死锁，要两个 hart 恰好交叉才会；现在一次正常的运行就能发现。整个 QEMU 测试跑下来没有违反的地方。

  另外有**睡眠锁**（[disk.md](disk.md#睡眠锁sleeplockzig)：打开的文件的 `File.pos_lock`、文件系统的写锁 `fsys.write_lock`、缓冲区缓存的每一块）：拿着它可以睡觉，所以拿它之前不能拿着任何自旋锁（`Sleeplock.acquire` 一开始就检查）；拿着它可以再去拿自旋锁（读写磁盘时拿 `virtio_disk.lock`）。回到 U 模式时也不能拿着睡眠锁（`proc.assertNoLocksHeld`）。睡眠锁也有等级（`sleeplock.Rank`）：`file_pos`（`File.pos_lock`）→ `fs_write`（`fsys.write_lock`）→ `buf`（缓冲区），每个进程记着自己拿着每一级的几把（`Process.sleeplocks`），拿的时候一样检查。`buf` 一级允许同时拿几把：同时拿着好几个缓冲区的只有修改文件系统的一方（一次一个，`write_lock`）；文件系统的读者、`readblock`、`writeblock` 一次只拿一个，拿着的时候不等别的缓冲区，所以不会互相等（[disk.md](disk.md#找缓冲区get)）。

  文件系统的读者拿着的**快照**不是锁，但修改的一方可能睡着等旧树的读者读完（[btree.md](btree.md#快照读者)），所以它也算在顺序里：`File.pos_lock` → 快照，拿着快照时不去等 `pos_lock`、`write_lock`。这一条没有检查。
- 同一个 hart 重复拿同一把锁直接 panic（`holding()` 比较锁里记的 hart 编号和 `hart.id()`）。
- 等锁时每转一圈看一眼是不是有别的 hart 在 panic（`hart.checkPanic`）：锁可能在已经停下的 hart 手里，永远等不到。

进程锁在调度器和进程之间交接（调度器拿、进程放，或者反过来），但交接的两边总在同一个 hart 上：调度器切到的进程就在这个 hart 上接着运行，进程切回的也是这个 hart 的调度器。所以每个 hart 记着的“拿着哪些锁”都对得上。

**页表和 TLB**：每个进程同一时刻只在一个 hart 上运行（没有线程），用户页表只在这个 hart 的 TLB 里。进程换到另一个 hart 时，调度器 `vm.activate` 会作废这个 hart 的 TLB 里的用户映射；离开时调度器切回内核页表也作废一次（内核映射带 G 位，留着，[paging.md](paging.md#切换地址空间)）。`sbrk` 缩小、`exec` 换地址空间时只刷当前 hart 的 TLB 就够了，不用跨 hart 刷（TLB shootdown）。内核页表启动后不再改，所有 hart 共用。

**随机空转（`-Dlock-jitter`）**：测试时可以让 `acquire` 之前、`release` 之后随机空转一会儿，拉大竞争窗口（`spinlock.jitterSpin`，用法和效果见 [testing.md](testing.md#qemu-测试toolsqemu_testpy)）。默认关着，是编译期常量，关着时不生成代码。根文件 `main.zig` 的 `lock_jitter` 来自构建选项；单元测试、`mkfs` 的根文件没有它，`spinlock.zig` 用 `@hasDecl(@import("root"), "lock_jitter")` 判断。
