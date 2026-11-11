# 文件：fd、串口、管道和文件系统里的文件

涉及文件：`src/file.zig`（文件表、串口和文件的读写）、`src/pipe.zig`（管道）、`src/syscall.zig` 的 `read`、`write`、`close`、`dup`、`pipe`、`open`、`src/proc.zig` 的 `Process.files`

照 xv6 的 `file.c`、`pipe.c`、`sysfile.c` 写。“文件”有四种：**串口**、**管道的一端**、**文件系统里的文件或目录**（`open` 打开，[fs.md](fs.md)）、**设备文件**（`open` 打开 `/dev/null` 这类文件，读写交给设备，[设备文件](#设备文件)）。用户程序用 fd（一个小整数）指代打开的文件，`read`/`write` 不关心 fd 背后是哪一种。

## 三层结构

```
进程 A 的 fd 表            文件表（全局，128 项）             底下的东西
files[0] ──┐
files[1] ──┼──────────→  File{ ref = 6, console }  ──→  串口（uart.zig）
files[2] ──┘         ┌→
files[3] ──────────┐ │
                   │ │   File{ ref = 1, pipe, 读端 } ──┐
进程 B 的 fd 表     │ │                                 ├→  Pipe（一页：缓冲区 + 状态）
files[0] ──────────┼─┘   File{ ref = 2, pipe, 写端 } ──┘
files[1] ──────────┴──────────↗
...
```

- **fd 表**（`Process.files: [abi.max_fds]?*File`，32 项）：每个进程一个，下标就是 fd。只有进程自己会改它，不用加锁。
- **文件表**（`file.table: [128]File`，xv6 的 `NFILE` 是 100）：全局，每个 `File` 带引用数 `ref`，`ref = 0` 表示空槽位。`fork` 复制 fd 表、`dup` 复制 fd，都只是让两个 fd 指向同一个 `File`（`ref` 加 1）。
- **底下的东西**：串口不需要状态；管道是一个 `Pipe`，读端和写端是两个不同的 `File`，指向同一个 `Pipe`。

为什么要中间这一层，而不是 fd 表直接指向管道：fd 表里的每一项要知道自己是读端还是写端；同一个“打开”被 `fork`、`dup` 共享时，要知道什么时候最后一个引用没了，才能真正关掉（管道的一端关了，另一端才会读到结尾或写失败）。文件系统里的文件还要记读写位置（`off`）：`fork`、`dup` 出来的 fd 共用一个位置（父进程写一段、子进程接着写一段，不会互相覆盖），各自 `open` 的各有各的，和 Unix 一样。

## 文件表

```zig
pub const File = struct {
    lock: Spinlock,              // 保护 ref
    ref: u32 = 0,
    kind: Kind = .none,          // .none（空槽位）、.console、.pipe、.inode、.device
    readable: bool = false,
    writable: bool = false,
    pipe: *pipe.Pipe = undefined,
    ino: u64 = 0,                // .inode、.device：文件系统里的 inode 号
    major: abi.Major = .console, // .device：哪个设备
    off: u64 = 0,                // .inode：下一次读写的位置（pos_lock 保护）
    append: bool = false,        // .inode：open_append，每次写之前先把 off 挪到文件末尾
    pos_lock: Sleeplock,         // 保护 off：读写文件、lseek、readdir 的整个过程拿着它
};

pub fn openConsole() error{TooManyFiles}!*File
pub fn openPipe() error{ TooManyFiles, OutOfMemory }![2]*File   // { 读端, 写端 }
pub fn openInode(ino: u64, readable: bool, writable: bool, append: bool) error{TooManyFiles}!*File
pub fn openDevice(ino: u64, major: abi.Major, readable: bool, writable: bool) error{ TooManyFiles, NoSuchDevice }!*File
pub fn dup(f: *File) *File
pub fn close(f: *File) void
pub fn read(f: *File, space: *vm.PageTable, ptr: usize, len: usize) Error!usize
pub fn write(f: *File, space: *vm.PageTable, ptr: usize, len: usize) Error!usize
pub fn seek(f: *File, offset: i64, whence: usize) Error!u64
```

- **没有整张表的锁，每个 `File` 有自己的锁**。`File.lock`（自旋锁）保护这个槽位的 `ref`：`alloc` 逐个槽位拿锁看 `ref` 是不是 0，是的话设成 1 再放开；`dup`、`close` 只拿这一个 `File` 的锁。几个 hart 同时打开、关闭不同的文件不用排队（xv6 是一把 `ftable.lock` 管整张表）。
- `File` 的其他字段（`kind`、`readable`、`ino` 等）在 `alloc` 拿到槽位之后、交给 fd 之前填好，之后就不变了，读写时不用拿锁。槽位清空、重新填写时**逐个字段赋值，不整个覆盖**（`reset`）：`f.* = .{...}` 会连两把锁一起覆盖掉，而别的 hart 可能正拿着这个槽位的 `lock` 在 `alloc` 里看它的 `ref`。
- **`off` 由 `File.pos_lock`（睡眠锁）保护**：读写文件、`lseek`、`readdir` 的整个过程拿着它。只有 `fork`、`dup` 共用同一个 `File` 的进程会争它（各自 `open` 的各有各的 `File`）；读写同一个文件、不同 `File` 的进程不会互相等。拿着它要读写磁盘，所以是睡眠锁；它在文件系统的锁之前拿（`pos_lock` → 文件系统的写锁 → 缓冲区，[fs.md](fs.md#接进内核fsyszig)）。
- **`close` 先放开 `File` 的锁，再去关管道**：管道有自己的锁，这样两把锁不会嵌套，就不用规定加锁顺序。最后一个引用关掉时，先把槽位清空（别的进程马上就能用），再关底下的东西。
- `openPipe` 先分配两个 `File`，再分配 `Pipe`；任何一步失败，`errdefer` 把已经分配的还回去。
- `read`/`write` 先检查方向（`readable`/`writable`，不对是 `NotReadable`/`NotWritable`，系统调用返回 `-EBADF`），再按 `kind` 分给串口、管道或文件系统。`Error` 包含文件系统的错误（`fs.Error`），系统调用按名字查表换成错误码（[syscalls.md](syscalls.md#分发)）。
- **文件的读写**（`inodeRead`、`inodeWrite`）：拿着 `pos_lock`；读在文件系统的快照上 `fs.read`（不挡着别人读写文件系统），写拿文件系统的写锁 `fs.run(Fs.write, ...)`（[fs.md](fs.md#接进内核fsyszig)），都从 `off` 开始，数据直接在缓冲区和用户内存之间复制；成功了 `off` 加上读写的字节数。一次 `write` 是一个事务：中途用户内存读不出来、磁盘满了，什么都不写、`off` 不动（串口、管道是写出多少算多少）。读到文件末尾返回 0。读写目录是 `IsDir`（列目录用 `readdir` 系统调用）。打开着的文件被别人删了，之后读写是 `NotFound`（[fs.md](fs.md#目录)）；被改名了照常（inode 号不变）。写的是正在运行的程序文件是 `TextBusy`（`beginModify`，[fs.md](fs.md#正在运行的程序文件)）。
- **追加**（`open_append`）：`inodeWrite` 在同一次文件系统的写锁里先 `stat` 出文件长度、从那里写，写完 `off` 挪到新的末尾；写失败 `off` 不动。查长度和写之间别人插不进来，所以几个进程各自 `open` 同一个文件追加，记录不会互相覆盖（不带 `open_append` 的话各自从 0 写起，会互相覆盖）。`t_fs` 用 4 个进程测过。
- **挪位置**（`seek`，`lseek` 系统调用）：拿着 `pos_lock`，在快照上 `stat`（`seek_end` 要文件长度、目录要另外处理），改 `off`（`dup`、`fork` 共用的 `File` 一起变）。`whence` 是 `seek_set`/`seek_cur`/`seek_end`（从 0、当前位置、文件长度算），`offset` 是有符号的；新位置是负的、超过 `maxInt(i64)`（返回值要能当成非负的有符号数，不会和错误码混淆）、`whence` 不对，都是 `InvalidArgument`（`-EINVAL`），位置不变。可以挪到文件末尾之后：读是 0 字节，写的话中间是洞（读出来是 0）。串口、管道没有位置，是 `NotSeekable`（`-ESPIPE`）。目录的 `off` 是 `readdir` 的 cookie，不是字节位置，只允许 `lseek(fd, 0, seek_set)`，从头再列一遍。

**谁打开、谁关掉**：

- init 启动时（`proc.userinit`）打开一次串口，作为 0、1、2 号 fd（同一个 `File`，`ref = 3`）。之后所有进程都是 `fork` 出来的，继承这三个 fd，所以串口的 `File` 只有一个，`ref` 随进程数变化。
- `pipe` 系统调用创建管道。
- `open` 系统调用打开文件系统里的文件、目录（`openInode`），关掉不用做什么：内容都已经在磁盘上了（每个 `write` 提交一次）。打开的是设备文件的话用 `openDevice`。
- 进程结束时（`proc.finish`）关掉 fd 表里所有的文件（[process.md](process.md#exit变成-zombie)）。`exec` 不碰 fd 表：shell 在子进程里先把标准输入输出换成管道，再 `exec`，新程序直接用 0、1 号 fd（[shell.md](shell.md#管道)）。

单元测试（`file.zig` 末尾）检查：`dup` 之后关一次，管道的写端还开着，再关一次才关上；表只剩一个空位时 `openPipe` 失败，不漏槽位也不漏页。

## 串口

```zig
fn consoleWrite(space: *vm.PageTable, ptr: usize, len: usize) Error!usize
fn consoleRead(space: *vm.PageTable, ptr: usize, len: usize) Error!usize
```

- **写**：先 `uart.lockOutput()` 拿上串口的输出锁，用户内存按块（128 字节、不跨页）复制到栈上、逐块输出，全部写完才放开锁，所以一次 `write` 的内容不会和别的 hart 的输出交错（[devices.md](devices.md#输出)）。部分写的语义见 [syscalls.md](syscalls.md#write)。
- **读**：拿着 `uart.rx_lock` 检查输入缓冲区（[devices.md](devices.md#输入环形缓冲区)），空着就 `proc.sleep(uart.rx_chan, &uart.rx_lock)`，串口中断叫醒它；被 kill 了就返回。有字符就有多少读多少（最多 `len`），每次最多 64 个放进栈上的缓冲区，再 `copyToUser`。调用方（`read` 系统调用）已经检查过目标范围可写，`copyToUser` 不会失败。
- **Ctrl-D（`0x04`）表示输入结束**，和 Unix 终端一样：读到它就停下。它前面有字符的话先返回这些字符，Ctrl-D 留在缓冲区里；下一次 `read` 读掉它、返回 0。所以单独按一次 Ctrl-D，`read` 返回 0。`cat`、`wc` 直接从键盘读时靠它结束；shell 读到 0 就忽略。
- 不回显、不做行编辑（shell 自己做），Ctrl-C 在串口中断里就被截下了（[process.md](process.md#ctrl-c)），读不到。

## 设备文件

`open` 在文件系统里找到的 inode 是设备文件（[fs.md](fs.md#硬链接和设备文件)）时，`File` 的种类是 `.device`，记着 inode 号和设备号 `major`，读写按设备号分给设备（xv6 的 `devsw` 表）：

| 设备号 | 设备 | 读 | 写 |
| --- | --- | --- | --- |
| 1 `console` | 串口 | 和 init 的 0 号 fd 一样（`consoleRead`） | 和 1 号 fd 一样（`consoleWrite`） |
| 2 `null` | 空设备 | 马上返回 0（结尾） | 全部收下，返回 `len`，不读用户内存（和 Linux 一样） |
| 3 `zero` | 零 | 读多少给多少个 0（一页一页 `copyToUser` 一个全 0 的常量页） | 同 `null` |

- 内核不认识的设备号，`openDevice` 返回 `NoSuchDevice`，`open` 系统调用返回 `-ENXIO`（Linux 打开没有驱动的设备文件也是这个）。所以 `File` 里的设备号一定认识，读写时不用再检查。
- 没有读写位置：`lseek` 是 `NotSeekable`（`-ESPIPE`），`readdir` 是 `-ENOTDIR`。不拿 `pos_lock`。
- `fstat` 照常在文件系统里查 inode：种类 `device`、设备号、链接数，长度 0。
- init 自己的 0、1、2 号 fd 还是种类 `.console`（`userinit` 时文件系统还没挂上，不能 `open("/dev/console")`），`fstat` 的种类是 `console`、inode 号 0；打开 `/dev/console` 得到的是 `.device`，读写的是同一个串口。

## 管道

```zig
pub const size = 2048;

pub const Pipe = struct {
    lock: Spinlock = .init("pipe"),
    nread: usize = 0,        // 读走的总字节数
    nwrite: usize = 0,       // 写进的总字节数
    read_open: bool = true,  // 读端还开着
    write_open: bool = true, // 写端还开着
    data: [size]u8 = undefined,
};

pub fn create() error{OutOfMemory}!*Pipe
pub fn close(p: *Pipe, writable: bool) void
pub fn write(p: *Pipe, space: *vm.PageTable, ptr: usize, len: usize) Error!usize
pub fn read(p: *Pipe, space: *vm.PageTable, ptr: usize, len: usize) Error!usize
```

- **一个管道占一页**（`page.alloc`），编译期断言 `@sizeOf(Pipe) <= 4096`。两端都关了才 `page.free`。
- **环形缓冲区**：`nread`、`nwrite` 只增不减，`nwrite - nread` 是缓冲区里的字节数，下标是它们对 `size` 取模。64 位的计数器不会回绕（每秒写 1 GB 也要几百年），所以不用像 xv6 那样担心回绕时取模出错。
- **所有字段由 `lock` 保护**，读写两端的进程拿着它等待：读写两端的进程可能在不同的 hart 上同时运行。回归测试 `t_smp` 让 6 个进程同时往一个管道里写，按字节数对账（[testing.md](testing.md#回归测试程序)）。

### 写

```zig
p.lock.acquire();
defer p.lock.release();
var done: usize = 0;
defer if (done > 0) proc.wakeup(&p.nread);
while (done < len) {
    if (!p.read_open) return if (done == 0) error.BrokenPipe else done;
    if (proc.isKilled()) return done;
    if (p.nwrite - p.nread == size) {        // 满了
        proc.wakeup(&p.nread);
        proc.sleep(&p.nwrite, &p.lock);
        continue;
    }
    // 复制一段：不超过空位、不越过缓冲区末尾、不跨用户页
    ...
}
```

- **写完全部字节才返回**（和 xv6 一样）：满了就叫醒读的进程，自己睡在 `&nwrite` 上，读的进程读走一些之后叫醒它。所以写 5000 字节进一个 2048 字节的管道，要来回几次（`t_pipe` 检查了读的一方至少读了 3 次）。
- **读端都关了**：一个字节都没写进去返回 `BrokenPipe`（`-EPIPE`），写进去一部分的返回这部分的字节数。睡在满的管道上时读端关了，`pipe.close` 叫醒它，它看到 `read_open = false` 就返回。没有 `SIGPIPE`：写的程序自己处理错误（`echo` 以 1 结束）。
- 坏地址的处理和串口一样：每段不跨页，前面的都写进去了，返回已经写进去的字节数；一个字节都没写进去才返回 `BadAddress`。
- 两个 `defer` 按相反的顺序执行：先叫醒读的进程，再放开锁。

### 读

```zig
p.lock.acquire();
defer p.lock.release();
while (p.nread == p.nwrite and p.write_open) {
    if (proc.isKilled()) return 0;
    proc.sleep(&p.nread, &p.lock);
}
// 有多少读多少，最多 len；读走了东西就叫醒写的进程
```

- **空着、写端还开着时等**；空着、写端都关了，返回 0（读到结尾）。缓冲区里还有数据时，就算写端已经关了，也先把数据读完。
- 有多少读多少，不等凑满 `len`。
- **复制成功了才算读走**：`copyToUser` 失败的那一段留在管道里（`read` 系统调用先检查过整个目标范围，正常情况下不会失败）。

### 关

```zig
pub fn close(p: *Pipe, writable: bool) void {
    p.lock.acquire();
    if (writable) { p.write_open = false; proc.wakeup(&p.nread); }
    else { p.read_open = false; proc.wakeup(&p.nwrite); }
    const unused = !p.read_open and !p.write_open;
    p.lock.release();
    if (unused) page.free(...);
}
```

关一端时叫醒等在另一端的进程：读的会读到结尾，写的会得到 `BrokenPipe`。释放在放开锁之后：这时两端都关了，没有人还能拿到这个管道。

单元测试（`pipe.zig` 末尾）只测不需要等待的路径（等待要切换进程，只能在 QEMU 里测）：写 1500、读 1000、再写 1500 越过缓冲区末尾，内容不错；要 3000 只给 2000；坏地址时数据不动；写端关了先读完剩下的再读到结尾；读端关了写返回 `BrokenPipe`；两端都关了页还回去。阻塞、叫醒、被 kill 的情况由回归测试 `t_pipe` 在 QEMU 里测（[testing.md](testing.md#回归测试程序)）。

## 限制和以后可以做的

- 没有 `pread`/`pwrite`：要在某个位置读写得先 `lseek`。
- 没有 `dup2`，重定向靠“`close` 再 `dup`，拿到编号最小的空闲 fd”。
- 没有非阻塞读写，没有 `poll`/`select`。
- 没有信号：写一个读端已经关了的管道只返回 `-EPIPE`，程序自己决定怎么办。
- 管道缓冲区固定 2048 字节，写满了就要等读的一方；`write` 写完全部字节才返回，一次大的写会被拆成很多次切换。
