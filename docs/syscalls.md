# 系统调用

涉及文件：`src/abi.zig`（内核和用户程序共用）、`src/syscall.zig`（内核实现）、`user/sys.zig`（用户态封装）、`src/vm.zig` 的 `copyFromUser`、`copyToUser`、`pinSrc`/`pinSrcPrefix`/`pinDst`；文件相关的调用见 [files.md](files.md)

## 调用约定

和 Linux 在 RISC-V 上的约定一样：

| 寄存器 | 用途 |
| --- | --- |
| `a7` | 调用号（`abi.Syscall`） |
| `a0..a5` | 参数（哪个调用用几个、各是什么见 `abi.params`，目前最多用四个） |
| `a0`（返回） | 返回值 |
| 其他寄存器 | 内核原样恢复 |

用户程序执行 `ecall` → CPU 产生“来自 U 模式的 ecall”异常（`scause = 8`，委托给了 S 模式）→ `trapEntry` 通过 `sscratch` 换到进程内核栈、保存全部寄存器 → `handleTrap` 把 `sepc` 加 4（跳过 `ecall`，它没有压缩形式，固定 4 字节）→ `syscall.dispatch(frame)` 的返回值写进 `frame.regs[10]`（`a0`；`exec` 成功时不写）→ `trapExit` 恢复寄存器、`sret` 回到 `ecall` 的下一条指令。

**返回值按有符号数理解**：`>= 0` 表示成功；`-4095..-1` 表示失败，取反就是错误码（和 Linux 一样，错误码的编号也沿用 Linux）。

## abi.zig

```zig
pub const Syscall = enum(usize) {
    exit = 0, write = 1, getpid = 2, uptime = 3, yield = 4, sleep = 5,
    read = 6, fork = 7, exec = 8, wait = 9, kill = 10, getppid = 11,
    setfg = 12, procinfo = 13, meminfo = 14, shutdown = 16,   // 15 原来是 listprog，去掉了
    close = 17, dup = 18, pipe = 19, sbrk = 20,
    blockcount = 21, readblock = 22, writeblock = 23,
    open = 24, mkdir = 25, unlink = 26, chdir = 27, fstat = 28, readdir = 29,
    scrub = 30, rename = 31, lseek = 32, link = 33, mknod = 34,
    symlink = 35, readlink = 36, getcwd = 37, lstat = 38, kstat = 39,
    snapshot = 40, snaplist = 41, snapdel = 42,
    _,
};
pub const Major = enum(u16) { console = 1, null = 2, zero = 3, _ };   // 设备文件的设备号

pub const Errno = enum(usize) {
    perm = 1,     // EPERM：杀 init；给目录建硬链接（link）
    noent = 2,    // ENOENT：没有这个程序（exec），没有这个文件或目录
    srch = 3,     // ESRCH：没有这个进程（kill、setfg）
    nxio = 6,     // ENXIO：打开的设备文件的设备号内核不认识（open）
    mlink = 31,   // EMLINK：链接数到上限了（link）
    busy = 16,    // EBUSY：删一个有文件打开着的快照（snapdel）
    rofs = 30,    // EROFS：写保存的快照里的文件（open）
    io = 5,       // EIO：磁盘上的数据不对（校验和、结构）
    nodev = 19,   // ENODEV：没有磁盘，或者磁盘上没有文件系统
    exist = 17,   // EEXIST：已经有这个名字了（mkdir；open 带 O_CREATE 时不算错）
    notdir = 20,  // ENOTDIR：路径中间的一段不是目录；chdir、readdir 的不是目录
    isdir = 21,   // EISDIR：读写目录、写方式打开目录
    fbig = 27,    // EFBIG：文件太大
    nospc = 28,   // ENOSPC：磁盘满了
    nametoolong = 36, // ENAMETOOLONG：名字长于 255 字节，或者路径长于 256 字节
    notempty = 39,    // ENOTEMPTY：删除的目录不是空的
    toobig = 7,   // E2BIG：命令行参数太多或太长（exec）
    noexec = 8,   // ENOEXEC：程序不是合法的 ELF（exec）
    badf = 9,     // EBADF：fd 没有打开，或者方向不对（往读端写、从写端读）
    child = 10,   // ECHILD：没有可以等的子进程（wait）
    again = 11,   // EAGAIN：进程表满了（fork）
    nomem = 12,   // ENOMEM：物理内存不够（fork、exec、pipe），或者堆不能再长了（sbrk）
    fault = 14,   // EFAULT：指针指向的内存不属于用户空间、没有映射，或者要写的页不可写
    inval = 22,   // EINVAL：参数不对（wait 的 options，sbrk 缩到堆的起点下面，块号超出原始区域，open 的 flags，名字是 "."、".."，
                  //         rename 把目录挪进它自己下面，lseek 到负的位置、坏的 whence，readlink 的不是符号链接）
    nfile = 23,   // ENFILE：系统的文件表满了（pipe）
    mfile = 24,   // EMFILE：进程的 fd 表满了（dup、pipe）
    loop = 40,    // ELOOP：解析路径时跟着走的符号链接超过 10 个（多半是有环）
    range = 34,   // ERANGE：给的缓冲区放不下（getcwd）
    spipe = 29,   // ESPIPE：lseek 串口、管道
    pipe = 32,    // EPIPE：管道的读端都关了（write）
    nosys = 38,   // ENOSYS：没有这个系统调用
    _,
};

pub const max_procs = 64;                // xv6 的 NPROC 也是 64
pub const max_fds = 32;                  // 每个进程的 fd 表大小（xv6 的 NOFILE 是 16）
pub const stdin = 0, stdout = 1, stderr = 2;
pub const max_args = 32;                 // exec 最多传几个参数（xv6 的 MAXARG 也是 32）
pub const max_arg_bytes = 2048;          // 参数加起来最多多少字节
pub const block_size = 4096;             // 磁盘块的大小，正好一页
pub const max_path = 256;                // 路径最长多少字节
pub const max_name = 255;                // 名字（路径的一段）最长多少字节
pub const open_read = 0x000, open_write = 0x001, open_rdwr = 0x002;   // open 的 flags，数值照 xv6
pub const open_create = 0x200, open_trunc = 0x400;
pub const Arg = extern struct { ptr: usize, len: usize };   // 一个命令行参数（不以 0 结尾）
pub const wait_any: usize = 0 -% 1;   // wait 的 pid：任意一个子进程
pub const wait_nohang: usize = 1;     // wait 的 options：不阻塞
pub const killed_status: u32 = 0x100; // wait 拿到的“被杀”状态（正常退出是 0..255）

pub const ProcState = enum(u8) { unused, runnable, running, sleeping, zombie };
pub const ProcInfo = extern struct { pid: u64, ppid: u64, cpu_ms: u64, state: ProcState, name_len: u8, name: [16]u8 };
pub const MemInfo = extern struct { free_pages: u64, total_pages: u64, page_size: u64 };
pub const FileKind = enum(u8) { file = 1, dir = 2, console = 3, pipe = 4, device = 5, symlink = 6, _ };
pub const Stat = extern struct { ino: u64, size: u64, kind: FileKind, _pad: u8, major: u16, nlink: u32 };
pub const Dirent = extern struct { ino: u64, kind: FileKind, name_len: u8, _pad: [6]u8, name: [max_name]u8 };

pub fn fail(e: Errno) usize            // 把错误码编码成返回值：0 -% e
pub fn errnoOf(ret: usize) ?Errno      // 返回值在 [-4095, -1] 内时取出错误码
```

`Syscall` 和 `Errno` 都是非穷尽的（`_`），所以用户程序传来任意数字都能安全地转换成 `Syscall`（`@fromBackingInt`），不认识的落到 `_` 分支。

`ProcInfo`、`MemInfo`、`Arg`、`Stat`、`Dirent` 是 `extern struct`，内核把它们的字节原样复制进用户内存，两边的布局由 C ABI 保证一致。`ProcState` 同时是内核进程表的状态类型（`proc.State = abi.ProcState`），不用转换。

这个文件被**两次编译**使用：内核里按路径 `@import("abi.zig")`，用户程序里作为构建系统创建的 `abi` 模块（[build.md](build.md#用户程序)），用户程序通过 `sys.abi` 访问它。改它就同时改了两边的约定。

## 调用列表

| 号 | 调用 | 参数 | 返回 | 说明 |
| --- | --- | --- | --- | --- |
| 0 | `exit` | `a0` = 退出码 | 不返回 | 只取低 8 位（`@truncate` 成 `u8`）。打印 `[proc] pid N (NAME) exited with code C`，变成 zombie 等父进程回收（[process.md](process.md#结束进程)） |
| 1 | `write` | `a0` = fd，`a1` = 用户缓冲区地址，`a2` = 长度 | 写出的字节数；`-EBADF`、`-EFAULT`、`-EPIPE`；文件：`-ENOSPC`、`-EFBIG`、`-EIO`、`-ETXTBSY`（文件是正在运行的程序） | 写进串口、管道或文件，详见下文 |
| 2 | `getpid` | 无 | 进程号 | 每创建一个进程加 1，不复用。init 是 1，shell 是 2 |
| 3 | `uptime` | 无 | 开机以来的毫秒数 | `timer.uptimeMs()`：直接读 `time` CSR 换算 |
| 4 | `yield` | 无 | 0 | 让出 CPU：回到调度器，别的 runnable 进程先运行，轮到它时返回。没有别的 runnable 进程时很快就会返回 |
| 5 | `sleep` | `a0` = 毫秒数 | 0 | 睡至少 `a0` 毫秒（按到期时刻排进 `timer.sleepers`，到期的时钟中断叫醒），期间不被调度、不占 CPU。`0` 立刻返回 |
| 6 | `read` | `a0` = fd，`a1` = 缓冲区地址，`a2` = 长度 | 读到的字节数，0 表示读到结尾；`-EBADF`、`-EFAULT`；文件：`-EISDIR`、`-EIO`、`-ENOENT` | 从串口、管道或文件读，详见下文 |
| 7 | `fork` | 无 | 父进程得到子进程的 pid，子进程得到 0；或 `-EAGAIN`、`-ENOMEM` | 复制当前进程（[process.md](process.md#fork)） |
| 8 | `exec` | `a0` = 路径地址，`a1` = 路径长度，`a2` = `Arg` 数组的地址，`a3` = 参数个数 | 成功时不返回（新程序的 `a0` = 参数个数）；`-ENOENT`、`-ENOEXEC`、`-ENOMEM`、`-EFAULT`、`-E2BIG`、`-ENAMETOOLONG`、`-ENOTDIR`、`-ELOOP`、`-EIO`、`-ENODEV`、`-ETXTBSY`（程序文件正在被改） | 换成文件系统里的程序运行（名字里没有 `/` 时在 `/bin` 里找，跟着符号链接走），打开的文件不变，详见下文 |
| 9 | `wait` | `a0` = pid（`wait_any` 表示任意一个），`a1` = 状态的地址（0 表示不要），`a2` = options | 回收的子进程的 pid；`nohang` 时没有已结束的子进程返回 0；`-ECHILD`、`-EFAULT`、`-EINVAL` | 详见下文 |
| 10 | `kill` | `a0` = pid | 0；`-ESRCH`、`-EPERM`（init） | 只做标记，目标进程回到 U 模式之前结束（[process.md](process.md#kill只做标记)） |
| 11 | `getppid` | 无 | 父进程的 pid；init 是 0 | |
| 12 | `setfg` | `a0` = pid，0 表示没有 | 0；`-ESRCH` | 设置前台进程：按 Ctrl-C 时内核杀掉它（[process.md](process.md#ctrl-c)） |
| 13 | `procinfo` | `a0` = `ProcInfo` 数组的地址，`a1` = 数组长度 n | 进程总数（可能大于 n）；`-EFAULT` | 按槽位顺序写最多 n 个进程的信息。n = 0 时只返回总数。名字超过 16 字节时截断。每个槽位单独拿锁读一次（`proc.info`），不是同一瞬间的快照：别的 hart 上的进程可能正在 `fork`、结束 |
| 14 | `meminfo` | `a0` = `MemInfo` 的地址 | 0；`-EFAULT` | 空闲页数、总页数、页大小 |
| 15 | （去掉了） | | `-ENOSYS` | 原来是 `listprog`（列出嵌在内核里的程序）。程序搬进 `/bin` 之后用 `readdir` 列目录 |
| 16 | `shutdown` | 无 | 不返回 | 通过 SBI 关机 |
| 17 | `close` | `a0` = fd | 0；`-EBADF` | 关掉 fd。是这个文件的最后一个引用的话，真正关掉它（[files.md](files.md)） |
| 18 | `dup` | `a0` = fd | 新的 fd；`-EBADF`、`-EMFILE` | 编号最小的空闲 fd 指向同一个文件 |
| 19 | `pipe` | `a0` = 两个 `u32` 的地址 | 0；`-EFAULT`、`-EMFILE`、`-ENFILE`、`-ENOMEM` | 创建管道，读端、写端的 fd 写进 `a0` 指向的地方（[files.md](files.md#管道)） |
| 20 | `sbrk` | `a0` = 增量（有符号） | 原来的堆末尾；`-ENOMEM`、`-EINVAL` | 堆变大或变小（[process.md](process.md#sbrk堆)）。`sbrk(0)` 只查询。变大时不分配页，用到时才分配（按需分页），所以比空闲内存大也能成功；堆比整个物理内存还大时才是 `-ENOMEM` |
| 21 | `blockcount` | 无 | 磁盘的原始区域（文件系统之后的块）有多少块，没有磁盘时是 0 | 每块 `abi.block_size` = 4096 字节（[disk.md](disk.md#系统调用)） |
| 22 | `readblock` | `a0` = 块号，`a1` = 缓冲区地址 | 0；`-EINVAL`（块号超出原始区域）、`-ENODEV`、`-EFAULT`、`-EIO`（设备报错） | 经过缓冲区缓存读原始区域的一块，4096 字节写进缓冲区 |
| 23 | `writeblock` | `a0` = 块号，`a1` = 缓冲区地址 | 0；`-EINVAL`、`-ENODEV`、`-EFAULT`、`-EIO` | 缓冲区的 4096 字节写到原始区域的这一块，写完才返回 |
| 24 | `open` | `a0` = 路径地址，`a1` = 路径长度，`a2` = flags | 新的 fd；`-ENOENT`、`-ENOTDIR`、`-EISDIR`、`-EEXIST`、`-ENAMETOOLONG`、`-EINVAL`、`-ELOOP`、`-ENOSPC`、`-EIO`、`-ENODEV`、`-EFAULT`、`-ENFILE`、`-EMFILE`、`-ENXIO`（不认识的设备）、`-ETXTBSY`（截断正在运行的程序文件）、`-EROFS`（写方式打开快照里的文件） | 打开文件、目录或设备文件（[fs.md](fs.md#接进内核fsyszig)，设备见 [files.md](files.md#设备文件)）。flags：`open_read`/`open_write`/`open_rdwr` 加上 `open_create`（没有就建一个空文件）、`open_trunc`（可写时截成 0 字节）、`open_append`（0x800，每次写都写在末尾）；别的位、读写方式是 3 都是 `-EINVAL`。目录只能只读地打开。相对路径从当前目录开始。跟着符号链接走；带 `open_create` 时最后一段是悬空的符号链接的话，建的是它指向的文件 |
| 25 | `mkdir` | `a0` = 路径地址，`a1` = 路径长度 | 0；`-EEXIST`、`-ENOENT`、`-ENOTDIR`、`-EINVAL`、`-ENAMETOOLONG`、`-ENOSPC` 等 | 建一个空目录 |
| 26 | `unlink` | 同上 | 0；`-ENOENT`、`-ENOTEMPTY`、`-EINVAL` 等。删掉还有人用着（打开着、正在运行）的文件的最后一个名字只删名字，最后一个使用者放开时才删内容（[fs.md](fs.md#删掉还有人用着的文件)） | 删掉一个名字（文件、设备文件或空目录）。是最后一个名字、又没人用着的话文件也删掉 |
| 27 | `chdir` | 同上 | 0；`-ENOENT`、`-ENOTDIR` 等 | 换当前目录（`Process.cwd`，`fork` 继承） |
| 28 | `fstat` | `a0` = fd，`a1` = `Stat` 的地址 | 0；`-EBADF`、`-EFAULT`、`-ENOENT` | inode 号、长度、种类、设备号、链接数。串口、管道的 inode 号、长度、链接数是 0 |
| 29 | `readdir` | `a0` = fd，`a1` = `Dirent` 的地址 | 1；列完了是 0；`-EBADF`、`-ENOTDIR`、`-EFAULT` | 目录的下一项（不含 `.`、`..`），按名字的散列排序。读写位置就是 `fs.readdir` 的 cookie，结果写进用户内存成功了才往后挪 |
| 30 | `scrub` | `a0` = `ScrubInfo` 的地址 | 0；`-EIO`（文件系统坏了）、`-ENODEV`、`-EFAULT` | 检查整个文件系统：作废缓冲区缓存，B 树、每个数据块的校验和、条目之间的关系都核对一遍，只读不改（[fs.md](fs.md#检查整个文件系统checkscrub)）。统计（文件数、目录数、设备文件数、符号链接数、数据块数、B 树的节点数、条目数、层数、空闲块数、总块数、事务号）写进 `a0` 指向的地方；`ScrubInfo.orphans` 是孤儿（名字都删掉了、还有人用着的 inode）的个数 |
| 31 | `rename` | `a0`、`a1` = 旧路径的地址、长度，`a2`、`a3` = 新路径的地址、长度 | 0；`-ENOENT`、`-ENOTDIR`、`-EISDIR`、`-ENOTEMPTY`、`-EINVAL`、`-ENAMETOOLONG`、`-ENOSPC`、`-EIO`、`-ENODEV`、`-EFAULT` | 改名，可以换目录，一个事务做完（[fs.md](fs.md#改名rename)）。新名字已经有了的话换掉它：文件换掉文件，目录换掉空目录（不空是 `-ENOTEMPTY`）；目录换文件是 `-ENOTDIR`，文件换目录是 `-EISDIR`；目录挪进它自己下面是 `-EINVAL`。打开着的 fd、当前目录照常能用 |
| 32 | `lseek` | `a0` = fd，`a1` = 偏移（有符号），`a2` = whence（`seek_set`、`seek_cur`、`seek_end`） | 新的位置；`-EBADF`、`-ESPIPE`（串口、管道、设备）、`-EINVAL`（负的位置、坏的 whence、目录挪到 0 以外）、`-ENOENT` | 挪文件的读写位置（[files.md](files.md#文件表)），可以挪到末尾之后。`lseek(fd, 0, seek_cur)` 查当前位置；目录只能 `lseek(fd, 0, seek_set)` 从头再列 |
| 33 | `link` | `a0`、`a1` = 旧路径的地址、长度，`a2`、`a3` = 新路径的地址、长度 | 0；`-ENOENT`、`-EEXIST`、`-EPERM`（目录）、`-ENOTDIR`、`-EINVAL`、`-ENAMETOOLONG`、`-EMLINK`、`-ENOSPC`、`-EIO`、`-ENODEV`、`-EFAULT` | 硬链接：给文件（或设备文件）再起一个名字，两个名字是同一个文件，一个事务做完（[fs.md](fs.md#硬链接和设备文件)） |
| 34 | `mknod` | `a0` = 路径地址，`a1` = 路径长度，`a2` = 设备号 | 0；`-EINVAL`（设备号是 0 或者超过 `u16`、名字是 `.`、`..`）、`-EEXIST`、`-ENOENT`、`-ENOTDIR`、`-ENAMETOOLONG`、`-ENOSPC`、`-EIO`、`-ENODEV`、`-EFAULT` | 建一个设备文件。不认识的设备号也能建，打开时才是 `-ENXIO` |
| 35 | `symlink` | `a0`、`a1` = 目标的地址、长度，`a2`、`a3` = 新路径的地址、长度 | 0；`-ENOENT`（目标是空的、新路径的目录没有）、`-ENAMETOOLONG`（目标长于 256 字节）、`-EEXIST`、`-ENOTDIR`、`-EINVAL`、`-ELOOP`、`-ENOSPC`、`-EIO`、`-ENODEV`、`-EFAULT` | 建符号链接，内容就是目标这个字符串，不检查它在不在（[fs.md](fs.md#符号链接)） |
| 36 | `readlink` | `a0`、`a1` = 路径的地址、长度，`a2`、`a3` = 缓冲区的地址、长度 | 写了几个字节；`-EINVAL`（不是符号链接）、`-ENOENT`、`-ENOTDIR`、`-ELOOP`、`-EIO`、`-ENODEV`、`-EFAULT` | 符号链接的目标写进缓冲区，不以 0 结尾，放不下就截断（和 Linux 一样）。最后一段不跟着走 |
| 37 | `getcwd` | `a0` = 缓冲区地址，`a1` = 缓冲区长度 | 路径的长度；`-ERANGE`（放不下）、`-ENOENT`（当前目录被删掉了）、`-EIO`、`-ENODEV`、`-EFAULT` | 当前目录的绝对路径，不以 0 结尾。是真实的位置：经过符号链接 `chdir` 进来的，得到的是目标目录的路径（[fs.md](fs.md#当前目录的路径getcwd)） |
| 38 | `lstat` | `a0`、`a1` = 路径的地址、长度，`a2` = `Stat` 的地址 | 0；`-ENOENT`、`-ENOTDIR`、`-ELOOP`、`-ENAMETOOLONG`、`-EIO`、`-ENODEV`、`-EFAULT` | 路径自己的 `Stat`，最后一段是符号链接时不跟着走（种类 `symlink`，长度是目标的长度）。不用打开文件，所以内核不认识的设备文件也查得到 |
| 39 | `kstat` | `a0` = `KStat` 的地址 | 0；`-EFAULT` | 内核的计数器（`abi.Counters`：系统调用、上下文切换、`wakeup`、缺页、TLB 刷新、缓冲区缓存、磁盘请求、文件系统的提交和作废……，开机以来所有 hart 加起来）和各种内核栈用到过的最深处（[process.md](process.md#进程表)）。用户程序 `kstat` 把它们打印出来 |
| 40 | `snapshot` | 无 | 快照的编号（事务号）；`-ENOSPC`（已经有 4 个）、`-EIO`、`-ENODEV` | 把文件系统最后一次提交的样子存成一个快照，之后在 `/.snap/编号/` 下只读地看得到（[fs.md](fs.md#保存的快照)） |
| 41 | `snaplist` | `a0`、`a1` = `u64` 数组的地址、元素个数 | 一共有几个快照；`-EFAULT`、`-ENODEV` | 快照的编号写进数组（最多 `a1` 个） |
| 42 | `snapdel` | `a0` = 编号 | 0；`-ENOENT`、`-EBUSY`（有文件打开着它）、`-EIO`、`-ENODEV` | 删掉一个快照，它独占的块空出来 |
| 其他 | | | `-ENOSYS` | |

### 分发

系统调用的签名只写一次，在 `abi.zig` 的 `params` 里：每个调用一串 `abi.Param`，说 `a0..a5` 里依次是什么。

```zig
pub const Param = enum { int, fd, bytes, array, ptr };   // bytes、array 占两个寄存器（地址、长度）
pub const params = .{
    .write = .{ .fd, .bytes },
    .exec = .{ .bytes, .array },
    .wait = .{ .int, .ptr, .int },
    ...
};
```

内核这边，每个调用是 `syscall.handlers` 里同名的一个函数，参数已经解码好了：

```zig
const handlers = struct {
    pub fn write(f: *file.File, data: UserSlice) file.Error!usize { ... }
    pub fn close(fd: OpenFd) void { ... }
    pub fn rename(old_arg: UserSlice, new_arg: UserSlice) !void { ... }
    pub fn exec(path_arg: UserSlice, argv_arg: UserSlice) !Replaced { ... }
    ...
};

pub fn dispatch(frame: *TrapFrame) ?usize {
    const number = frame.regs[17]; // a7
    const regs = frame.regs[10..16]; // a0..a5
    inline for (comptime std.meta.fieldNames(abi.Syscall)) |name| {
        if (number == @backingInt(@field(abi.Syscall, name))) return call(name, regs);
    }
    return abi.fail(.nosys);
}
```

`dispatch` 对 `abi.Syscall` 的每个名字展开一份 `call(name, regs)`。`call` 在编译期拿 `abi.params` 和处理函数的参数类型对一遍：个数不一样编译不过（`syscall.handlers.kill takes 2 parameters, abi.params says 1`），种类对不上也编译不过（`a parameter of type syscall.UserSlice cannot take abi.Param.ptr`）；`handlers` 里缺了哪个调用也编译不过。对得上就按参数的类型解码：

| `abi.Param` | 处理函数的参数类型 | 解码 |
| --- | --- | --- |
| `int` | 整数类型 | 有符号的按补码（`sbrk` 的增量、`lseek` 的偏移）；窄的无符号整数（`mknod` 的设备号 `u16`）放不下是 `-EINVAL` |
| `fd` | `*file.File`，或者 `OpenFd`（还要 fd 本身的，`close`） | 查当前进程的 fd 表，`fd >= max_fds` 或者没打开是 `-EBADF` |
| `bytes`、`array` | `UserSlice{ ptr, len }` | 两个寄存器原样放进去；内核不能直接解引用，要经过 `vm.copyFromUser`、pin 这些 |
| `ptr` | `usize` | 用户内存的地址，原样 |

处理函数的返回值也由 `call` 换成 `a0`：错误联合里的错误换成错误码（`errno`，见下面），`void` 是 0，`bool` 是 0 或 1，整数原样，`noreturn` 的（`exit`、`shutdown`）不返回；`Replaced` 是 `exec` 专用的，表示 `TrapFrame` 已经换成新程序的了（`a0 = argc` 由 `proc.exec` 设好），`dispatch` 返回 `null`，`handleTrap` 不写 `a0`。原来 `exec` 成功时返回 `argc`，靠 `handleTrap` 把返回值写进 `a0`“恰好”设对新程序的 `argc`，要一段注释才看得懂。

所以处理函数里没有 `catch |err| return abi.fail(...)`（原来重复了几十次），出错直接 `try`；fd 不对、坏的设备号这些也不用每个函数自己查。用户程序的 `sys.call` 按同一张 `abi.params` 放参数（[用户态封装](#用户态封装)），两边的参数个数、顺序都由它决定。

代价是 `dispatch` 展开成 40 份解码代码。Debug 模式下进程内核栈的最深处从约 14 KiB 变成了约 16 KiB（`kstack.deepest` 量的，[process.md](process.md#进程表)），release 模式下几乎不变；内核栈是 24 KiB，余量还够。编译错误也比手写的 `switch` 难读一些，所以上面那几条错误信息是专门写的。

**错误码**：每个错误码在 Zig 里有一个名字，写在 `abi.zig` 的 `error_names` 里（`.noent = error.NotFound`、`.fault = error.BadAddress`……），内核和用户程序共用。编译期检查它正好列出了每一个错误码、名字不重复，所以两个方向都是一一对应的：`abi.errorOf(errno)` 换成错误，`abi.errnoFor(err)` 换回错误码，单元测试把每个错误码换过去再换回来。

内核这边，`syscall.errno(err)` 对错误集做 `inline else`，在编译期逐个看名字：和 `abi.Error` 里的同名（`NotFound`、`BadAddress`、`TextBusy`……）就直接用那个错误码；内核里别的名字（`Corrupt`、`InvalidName`、`IsDirLink`……）在 `syscall.aliases` 里说明换成哪个。两边都没有的错误直接编译失败（`no errno for error.X: add it to syscall.aliases`）。所以新加一个错误不会悄悄变成 `-EIO`（这个内核里 `EIO` 的意思是“磁盘上的数据不对”），原来的 `fsys.errno(anyerror)` 有一个 `else => .io` 兜底，就会这样。内核的错误尽量直接用 `abi.Error` 里的名字，`aliases` 里剩下的十来个是文件系统、`exec` 内部更具体的说法。

会等待的调用（`yield`、`sleep`、`read`、管道的 `write`、`wait`）在里面切回调度器，等这个进程再被调度时才返回，然后 `handleTrap` 照常把返回值写进 `a0`、检查 `killed`、回到 U 模式。`sleep` 和 xv6 的 `sys_sleep` 一样，拿着 `timer.lock` 在循环里 `timer.waiters.wait(&timer.lock)`，每个 tick 醒来一次，数够了 tick（或者被 kill 了）才返回（[process.md](process.md#等待队列waitqueue)）。

## write

```zig
pub fn write(f: *file.File, data: UserSlice) file.Error!usize {
    return file.write(f, vm.pinSrcPrefix(space(), data.ptr, data.len), data.len);
}
```

`vm.pinSrcPrefix` 先把来源开头能读的那一段 pin 好：**来自程序文件、还没读进来**的页（比如字符串常量所在的只读数据页）在这里读进来。下面串口、管道、文件都是拿着锁复制用户内存的，那时读不了盘，只能用 pin 好的范围（[访问用户内存](#访问用户内存)）。

参数类型 `*file.File` 由 `dispatch` 解码：查当前进程的 fd 表，`fd >= max_fds` 或者那一项是空的，返回 `-EBADF`。不可写的文件（管道的读端）也是 `-EBADF`。真正的写由 `file.write` 按文件的种类分给串口、管道或文件系统（[files.md](files.md)）。串口和管道遵守同一个约定：

- 用户内存先**复制**到内核（串口：栈上 128 字节的缓冲区；管道：直接复制进管道的缓冲区），再输出。内核从不直接解引用用户给的指针。
- 每一块都不跨页（块大小取缓冲区大小、剩余长度、到页尾的距离三者的最小值）。所以一块复制失败，就说明这一页整个不能读，而之前的块都已经完整写出了。这保证了返回值的含义是精确的：
  - 一个字节都没写出就遇到坏地址 → 返回 `-14`（EFAULT）。
  - 写出了一部分之后遇到坏地址 → 返回已经写出的字节数（小于 `len`），和 POSIX 的部分写语义一致。
  - `len = 0` → 返回 0，不检查指针（但要先是一个打开的、可写的 fd）。
- `ptr + done` 不会溢出：`done > 0` 说明 `[ptr, ptr + done)` 已经全部通过了检查，都在用户区内。
- 最初的实现不按页分块，一个 128 字节的块可能跨过有效页和无效页的边界，导致“前 4 个字节有效，后面无效”的写入整体失败、返回 EFAULT，而不是写出 4 个字节。测试时发现并修正了。
- 写管道时管道满了会等，读端都关了返回 `-EPIPE`（已经写进去一部分的话返回写进去的字节数）。

写文件不一样：**一次 `write` 是一个事务**（[fs.md](fs.md#事务每个操作提交一次)），要么全写进去、返回 `len`，要么什么都没写、返回错误码（用户内存中途读不出来是 `-EFAULT`，磁盘满了是 `-ENOSPC`）。

## read

```zig
pub fn read(f: *file.File, buf: UserSlice) !usize {
    if (buf.len == 0) return 0;
    return file.read(f, try vm.pinDst(space(), buf.ptr, file.readLimit(f, buf.len)));
}
```

- **先 pin 整个目标范围（检查可写），再读**（`vm.pinDst`）：从串口的缓冲区取出来的字符放不回去，要是取出来才发现用户给的地址写不进去，这些字符就丢了。所以坏地址立刻返回 `-EFAULT`，不阻塞、不消耗输入。pin 的同时把范围里还没分配的页都分配好（按需分页）、写时复制的页复制好，所以之后拿着锁用 `PinnedDst.copyOut` 写进去一定成功。
- **pin 之前先截短 `len`**（`file.readLimit`）：串口一次最多给出接收缓冲区里的 255 个字符，管道一次最多给出缓冲区里的 2048 字节，`/dev/null` 什么都没有。程序给一个 1 MiB 的缓冲区读管道，只 pin、分配开头的一页，不会为没用到的部分提前分配 256 页。文件（和 `/dev/zero`）一次可能读满 `len`，不截短，整个缓冲区都要先分配（`tail` 因此一次最多读 64 KiB，[user-programs.md](user-programs.md#写脚本用的程序)）。
- `len = 0` 直接返回 0，不检查指针、不阻塞。
- 没有数据时阻塞，至少读到一个字节才返回；有多少就读多少（最多 `len`），不等凑满。**返回 0 表示读到了结尾**：管道的写端都关了，或者在串口上按了 Ctrl-D。
- 串口：**不回显、不做行编辑**，原样返回收到的字节（回车是 `\r`），shell 自己回显；Ctrl-C 不会被读到。管道：写进去什么读出来什么。文件：从读写位置开始读，不阻塞，到末尾返回 0。细节见 [files.md](files.md)。
- 被 kill 了就提前返回（返回值是 0，没人看），回到陷阱处理程序后结束。
- 好几个进程同时 `read` 同一个文件时，都被叫醒，先运行的那个拿走数据，其他的发现又空了，接着睡。

## exec

```zig
pub fn exec(path_arg: UserSlice, argv_arg: UserSlice) !Replaced
```

1. 路径复制进内核（和 `open` 一样最长 256 字节，长了是 `-ENAMETOOLONG`）。
2. `argc > max_args` 返回 `-E2BIG`。从 `argv_ptr` 复制 `argc` 个 `Arg`（每个 16 字节，`{ ptr, len }`），再把每个参数的字节依次复制进栈上 2048 字节（`max_arg_bytes`）的缓冲区，总长超过 `max_arg_bytes` 返回 `-E2BIG`。任何一个指针坏了都是 `-EFAULT`。长度为 0 的参数不检查 `ptr`。
3. 交给 `proc.exec(path, args)`：参数这时已经在内核里了，`exec` 换掉旧的地址空间之后照样能用。它在文件系统里找程序（没有 `/` 的名字在 `/bin` 里找）、在一个快照上加载（[process.md](process.md#exec)）。
4. 成功时返回 `.replaced`：`TrapFrame` 已经换成新程序的，`a0` = `argc`、`a1` 和 `sp`（栈上 `Arg` 数组的地址）都由 `proc.startFrame` 设好了，`dispatch` 看到 `Replaced` 就不再写 `a0`（[process.md](process.md#命令行参数)）。

所有检查都在换掉地址空间之前做完，所以失败时原来的程序照常运行，看到的是错误码。回归测试 `t_args check` 测了参数太多、太长、坏指针、正好用满上限、没有参数这几种情况；`t_fork` 测了找不到的名字和路径、空名字、太长的路径、坏 ELF、目录、路径中间是文件。

## close、dup、pipe

```zig
pub fn close(fd: OpenFd) void       // 清掉 fd 表的这一项，file.close 减引用数
pub fn dup(f: *file.File) !usize    // file.dup 加引用数，放进编号最小的空闲 fd
pub fn pipe(fds_ptr: usize) !void
```

- `dup` 返回**编号最小**的空闲 fd，这是 shell 重定向标准输入输出的基础：`close(1); dup(p[1])` 之后，1 号 fd 就是管道的写端（xv6 的写法，所以不需要 `dup2`）。fd 表满了返回 `-EMFILE`，引用数加上去的又减回来。
- `pipe` 先用 `pinDst` 确认能写两个 `u32`，再创建管道、把两端装进 fd 表，最后写回 fd。顺序是为了失败时好撤销：任何一步失败（文件表满了、内存不够、fd 表放不下两个），已经做了的都撤销掉，不留下半个管道。
- fd 表、文件表、管道的结构见 [files.md](files.md)。

## wait

```zig
pub fn wait(pid: usize, status_ptr: usize, options: usize) !usize {
    if (options & ~abi.wait_nohang != 0) return error.InvalidArgument;
    const status = if (status_ptr == 0) null else try vm.pinDst(space(), status_ptr, @sizeOf(u32));
    return try proc.wait(pid, options & abi.wait_nohang != 0, status) orelse 0;
}
```

- 怎么找、怎么等子进程、怎么写状态和回收见 [process.md](process.md#wait回收子进程)：这些都要拿着 `wait_lock` 和子进程的锁做，所以整个放在 `proc.wait` 里，系统调用这一层只转换错误码。
- 结束状态是一个 `u32`：正常退出时是退出码（0..255），被杀（异常、`kill`、Ctrl-C）时是 `abi.killed_status`（`0x100`）。
- **状态地址写不进去时不等、不回收**，返回 `-EFAULT`：状态是拿着锁写的，所以在等子进程之前就先 `pinDst` 这 4 个字节，pin 不了直接返回，子进程照样留着，可以换个地址再 `wait`（[访问用户内存](#访问用户内存)）。
- 不认识的 options 位返回 `-EINVAL`。

## 访问用户内存

```zig
pub fn copyFromUser(s: *Space, dst: []u8, src: usize) error{BadAddress}!void
pub fn copyToUser(s: *Space, dst: usize, src: []const u8) error{BadAddress}!void
pub fn pinSrc(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedSrc   // 拿锁之前准备好，见下面
pub fn pinSrcPrefix(s: *Space, va: usize, len: usize) PinnedSrc
pub fn pinDst(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedDst
```

系统调用拿到的指针完全由用户程序控制，可能是：没有映射的地址、内核的地址（比如 `hello` 故意传的 `0x8020_0000`）、跨越地址空间末尾的范围、或者让 `src + len` 溢出的长度。`copyFromUser` 对每一页：

1. `src + done` 用 `std.math.add` 计算，溢出就是 `BadAddress`。
2. `translateUser`：地址必须在 `[user_base, user_end)` 里；用**软件**走一遍进程的页表，叶子必须有效、带 U 位、可读。翻译不了的话，和用户程序自己访问一样按缺页处理（`vm.fault`：还没分配的页按需分配，[paging.md](paging.md#按需分页)），再翻译一次。还不行就是 `BadAddress`。
3. 用翻译得到的物理地址，通过内核的恒等映射读出这一页里需要的部分。

为什么不直接让内核去读用户地址（打开 `sstatus.SUM`，让 S 模式可以访问 U 页）：

- 那样用户传进来一个**内核地址**，内核会照读不误（内核页在 S 模式下本来就可读），用户程序就能借 `write` 把内核内存打印出来。软件查页表时要求 U 位，内核地址自然被拒绝。
- 用户地址没有映射时，内核会在 S 模式下触发缺页。按需分页之后这是正常情况（页还没分配），内核就得在 S 模式的缺页里分辨“是替用户程序访问的”还是“内核自己的 bug”，还要在任意的锁下处理它。软件查页表时缺页就在 `copyFromUser` 这些函数里处理，什么时候能读盘（见下面）由调用的地方决定。

所以 `sstatus.SUM` 始终为 0，这也意味着内核里任何地方不小心解引用了用户指针都会立刻缺页 panic，而不是悄悄成功。

**往用户内存写**用 `copyToUser`，检查和 `copyFromUser` 一样，`translateUser` 再多要求叶子**可写**：

- 不能借系统调用改写内核内存（内核页没有 U 位）；
- 也不能改写自己的只读页：硬件不会替内核检查这一点（内核的映射可写，S 模式写的是物理地址的恒等映射），不检查的话，用户程序可以让 `read` 把输入写进自己的代码段。
- **写时复制的页**（`fork` 之后和别的进程共用、还没写过的页）W 也是 0，但它本来是可写的：`copyToUser` 先 `vm.breakCow` 给这个进程复制一份，再往复制出来的页里写。不这样做的话，`wait` 写回的结束状态、`read` 读到的字符会直接写进共用的物理页，同时改掉另一个进程的内存。复制时内存不够就是 `BadAddress`（`-EFAULT`），和 Linux 一样（[paging.md](paging.md#写时复制)）。

**拿着锁时不能缺页**：按需分页的页可能要从程序文件读、睡着等，拿着自旋锁不能睡，拿着睡眠锁（可能是缓冲区的锁）也不行。所以 `copyFromUser`、`copyToUser` 一开始就检查没有拿着锁，拿着的话直接 panic（`copyFromUser while holding a lock (pin the range first)`）。只拿着文件系统快照的（`readlink`、`getcwd`、`lstat`、`fstat`）可以直接调用：快照不是锁，再拿一个快照不用等谁。

要拿着锁读写用户内存的系统调用分两步：**拿锁之前 pin**，把范围里的每一页都准备好（还没分配的分配好、程序文件的页读进来、要写的话写时复制的页复制好），得到一个 `vm.PinnedSrc`（要读的）或 `vm.PinnedDst`（要写的）；**拿着锁时**用它的 `copyIn` / `copyOut` 复制。它们只走页表、不缺页、不会失败，返回 `void`，所以调用的地方不用 `catch unreachable`。`Pinned*` 只能由 pin 函数造出来，拿着锁的复制又只能通过它们，“先准备再拿锁”就从一条要人记住的约定变成了类型：

| 系统调用 | 拿着什么锁复制 | pin 什么 |
| --- | --- | --- |
| `write` | 串口的输出锁、管道锁、文件系统的写锁和缓冲区的锁 | `pinSrcPrefix`：开头能读的那一段。串口、管道写出这一段、返回写了多少（部分写）；文件的一次写是一个事务，不全就是 `-EFAULT` |
| `read` | 串口的输入锁、管道锁、读写位置的锁 | `pinDst` 整个范围（先按 `readLimit` 截短）：取出来的字符放不回去，写不进去的话要在取之前知道 |
| `readdir` | 读写位置的锁 | `pinDst` 一个 `Dirent` |
| `wait` | `wait_lock` 和子进程的锁 | `pinDst` 一个 `u32`；写不进去在等之前就是 `-EFAULT`，子进程还在 |
| `readblock`、`writeblock` | 缓冲区的睡眠锁 | 整块 |
| `scrub`、`pipe` | 文件系统的写锁；不拿锁，但 fd 装进 fd 表之后再失败要一个个撤销 | 整个结果 |

`PinnedSrc` 还实现了 `fs.write` 要的 `in.get`，`PinnedDst` 实现了 `fs.read` 要的 `out.put`，文件系统直接从 pin 好的用户内存读写，不用再包一层。

这样做成立的前提是：pin 好之后，只有这个进程自己会改它的地址空间（没有线程、不换出页），而它正在这个系统调用里。以后加了线程或者换页，pin 就要真的把页钉住。原来这里是一条约定：拿锁之前 `vm.prefault`（或者 `checkUser`），拿着锁的复制碰到程序文件的页时返回 `-EFAULT`；漏了 `prefault` 的系统调用平时都对，只有那一页恰好还没读进来时才出错。

`copyToUser` 逐页写，中途遇到坏页时前面的页已经写进去了。需要“要么全写、要么不写”的调用方先 pin（`pipe` 就是这样）。pin 逐页查页表，`len = 0` 时不检查，`va + len` 溢出算作溢出之后的地址都不行。这几个函数在 `vm.zig` 里有单元测试（跨页、只读页、没有映射、溢出、按需分配、只要开头能读的一段）。

## 用户态封装

`user/sys.zig` 为每个调用提供一个函数。它们都用 `call(.名字, .{ 参数... })` 做系统调用：`call` 按 `abi.params` 把元组里的参数放进 `a0..a5`（切片放地址和长度，指针放地址，枚举放它的整数），参数的个数、种类在编译期对一遍（`sys.call(.write): 3 arguments, abi.params says 2`、`[]const u8 is not an integer`），所以封装和内核不会对参数的顺序有两种理解。`raw`（和 `syscall`、`syscall4` 两个简写）把寄存器原样交给内核，回归测试用它传坏参数。

返回值是错误码的话换成错误（`check`：`abi.errorOf`）。所有函数的错误集都是同一个 `sys.Error`，就是 `abi.Error` 加上 `Unexpected`（不认识的错误码，比这个程序新的内核才会给），所以原来每个封装里把错误码一个个换成错误的 `switch`（七十多个分支）都没有了。一个错误码只有一个名字：`exec` 找不到程序和 `open` 找不到文件都是 `NotFound`，`readblock` 的块号超出范围是 `InvalidArgument`（[user-programs.md](user-programs.md#syszig)）：

```zig
pub const abi = @import("abi");
pub fn call(comptime n: abi.Syscall, args: anytype) usize        // 按 abi.params 放参数
pub fn check(ret: usize) Error!usize                            // 错误码换成错误
pub fn raw(n: abi.Syscall, regs: [6]usize) usize                // 原始调用，测试用
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize
pub fn syscall4(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize) usize
pub var argv: []const abi.Arg                                   // 命令行参数，start.zig 设好
pub fn arg(i: usize) ?[]const u8                                // 第 i 个参数

pub fn exit(code: u8) noreturn
pub fn write(fd: Fd, bytes: []const u8) Error!usize
pub fn writeAll(fd: Fd, bytes: []const u8) Error!void
pub fn getpid() usize
pub fn getppid() usize
pub fn uptime() u64
pub fn yield() void
pub fn sleep(ms: u64) void
pub fn read(fd: Fd, buf: []u8) Error!usize
pub fn open(path: []const u8, flags: OpenFlags) Error!Fd   // OpenFlags{ read = true, write, create, truncate, append }
pub fn mkdir(path: []const u8) Error!void
pub fn unlink(path: []const u8) Error!void
pub fn chdir(path: []const u8) Error!void
pub fn fstat(fd: Fd) Error!abi.Stat
pub fn readdir(fd: Fd, ent: *abi.Dirent) Error!bool        // 列完了是 false
pub fn scrub() Error!abi.ScrubInfo                         // 坏了是 IoError
pub fn rename(old: []const u8, new: []const u8) Error!void
pub fn link(old: []const u8, new: []const u8) Error!void    // 目录是 PermissionDenied
pub fn mknod(path: []const u8, major: abi.Major) Error!void
pub fn symlink(target: []const u8, path: []const u8) Error!void
pub fn readlink(path: []const u8, buf: []u8) Error![]const u8   // 不是符号链接是 InvalidArgument
pub fn getcwd(buf: []u8) Error![]const u8                   // 放不下是 BufferTooSmall
pub fn lstat(path: []const u8) Error!abi.Stat               // 不跟着最后一段的符号链接走
pub fn lseek(fd: Fd, offset: i64, whence: Whence) Error!u64 // Whence = enum { set, cur, end }；串口、管道是 NotSeekable
pub fn close(fd: Fd) Error!void
pub fn dup(fd: Fd) Error!Fd
pub fn pipe() Error![2]Fd   // { 读端, 写端 }
pub fn sbrk(increment: isize) Error!usize
pub const block_size = abi.block_size;
pub fn blockCount() u64
pub fn readBlock(n: u64, buf: *[block_size]u8) Error!void
pub fn writeBlock(n: u64, buf: *const [block_size]u8) Error!void
pub fn fork() Error!usize
pub fn exec(name: []const u8, args: []const []const u8) Error!noreturn
pub fn execRaw(name: []const u8, args: []const abi.Arg) Error!noreturn
pub fn wait(pid: ?usize, nohang: bool) Error!?WaitResult   // WaitResult{ pid, status }
pub fn kill(pid: usize) Error!void
pub fn setfg(pid: ?usize) Error!void
pub fn procinfo(buf: []abi.ProcInfo) usize
pub fn meminfo() abi.MemInfo
pub fn shutdown() noreturn
pub fn print(comptime fmt: []const u8, args: anytype) void   // 格式化输出到 stdout
pub fn fprint(fd: Fd, comptime fmt: []const u8, args: anytype) void
```

- `exec` 的返回类型是 `Error!noreturn`：成功时不返回，所以只可能拿到错误。它把 `[]const []const u8` 转成栈上的 `Arg` 数组再交给内核，超过 `max_args` 个直接返回 `ArgsTooLong`；参数总长由内核检查。
- `Fd` 就是 `usize`，`sys.stdin`、`sys.stdout`、`sys.stderr` 是 0、1、2。
- `wait` 的 `pid` 为 `null` 时等任意一个子进程；`nohang` 时没有已结束的子进程返回 `null`。状态写进 `wait` 自己栈上的变量，再放进 `WaitResult`。

## 执行环境

- 系统调用在陷阱处理程序里执行，**全程关着中断**，所以每个调用都要短。一个很长的 `write` 会在输出期间挡住时钟中断，但不会丢失中断：挂起的中断在 `sret` 回到 U 模式后立刻被处理（这时进程马上让出 CPU），计时也不会少，`timer` 按预约时刻补上错过的 tick（[devices.md](devices.md#定时器timerzig)）。
- 会等待的调用（`yield`、`sleep`、`read`、管道的 `write`、`wait`）不在里面开中断等待，而是切回调度器，由调度器开着中断去处理别的事。
- `exec` 一次加载整个程序（分配页、从文件系统读内容），`fork` 一次复制整个地址空间，`sbrk` 一次映射所有新的页，期间都关着中断。现在的程序都只有几十 KiB，没有问题；`sbrk` 一次要上百 MiB 时会关着中断清零这么多页，`t_sbrk` 里长到超过物理内存（约 125 MiB）再失败、回滚，QEMU 里测试照常通过。
- 运行在当前进程自己的内核栈上（24 KiB），系统调用里不要放大的局部数组，也不要按值复制大的结构体（[fs.md](fs.md#接进内核fsyszig)：8 KiB 的位图按值传过一次，把栈撑爆了）。局部数组最大的是 `exec` 复制参数和路径用的约 1.8 KiB（参数 1024 字节、`Arg` 数组和切片各 256 字节、路径 256 字节）；栈用得最深的是文件系统的调用（实测 Debug 模式约 16 KiB，[process.md](process.md#进程表)）。
- 文件系统的调用读写磁盘，要等磁盘时和 `read` 一样切回调度器。读的调用在快照上读、不拿锁，改的调用拿着睡眠锁 `fsys.write_lock`（[fs.md](fs.md#接进内核fsyszig)）。
- `exit`、`shutdown` 和成功的 `exec` 不返回；其他调用返回后，用户程序从 `ecall` 的下一条指令继续执行，除 `a0` 以外的寄存器都不变。

## 新增一个系统调用

1. `src/abi.zig`：在 `Syscall` 里加一个编号，在 `params` 里写它的参数（需要新错误码就在 `Errno` 里加，沿用 Linux 的编号，再在 `error_names` 里给它起名字）。漏了 `params` 编译不过。
2. `src/syscall.zig`：在 `handlers` 里加一个同名的 `pub fn`，参数类型按上面的表（`*file.File`、`UserSlice`、整数……），返回什么都行（`!usize`、`!void`……），出错直接 `try`。漏了、参数对不上编译不过。内核里新的错误名要么和 `abi.Error` 里的同名，要么加进 `aliases`，否则编译不过。
3. 涉及用户指针的，一律通过 `vm.copyFromUser` / `vm.copyToUser` 访问，不要打开 `SUM`。要拿着锁读写用户内存、或者会消耗内核状态（比如取走输入）的，先 pin（[访问用户内存](#访问用户内存)）。
4. 要阻塞等待的（比如等键盘输入），照 `sleep` 的办法：在等待条件旁边放一个 `proc.WaitQueue`，拿着保护条件的锁 `while (!条件 and !proc.isKilled()) q.wait(&lock);`，在条件可能变化的地方（中断处理程序、别的进程）拿着同一把锁改条件、`q.wakeAll(&lock)`（[process.md](process.md#等待队列waitqueue)）。读串口用的是 `uart.rx_waiters` 和 `uart.rx_lock`，管道用的是 `Pipe.readers`/`writers` 和管道的锁，`wait` 用的是进程自己的 `child_exit` 和 `proc.wait_lock`，`sleep` 用的是 `timer.waiters` 和 `timer.lock`。`lock` 不能为空。不要在系统调用里开中断 `wfi`（[trap.md](trap.md#中断开关不变量)）。
5. `user/sys.zig`：加一个封装函数，用 `call(.名字, .{ 参数... })` 和 `check`。参数个数、种类不对编译不过。
6. 更新本文的调用列表，在 [changes.md](changes.md) 里加一行。
