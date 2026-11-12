# 用户程序

涉及文件：`user/start.zig`、`user/sys.zig`、`user/linker.ld`、`user/init.zig`、`user/sh.zig`、`user/hello.zig`、`user/fault.zig`、`user/spin.zig`、`user/ticker.zig`、`user/echo.zig`、`user/cat.zig`、`user/wc.zig`、`user/ls.zig`、`user/mkdir.zig`、`user/rm.zig`、`user/mv.zig`、`user/ln.zig`、`user/scrub.zig`、`user/kstat.zig`，写脚本用的 `user/test.zig`、`user/expr.zig`、`user/seq.zig`、`user/sleep.zig`、`user/head.zig`、`user/tail.zig`、`user/grep.zig`、`user/cp.zig`、`user/touch.zig`、`user/tee.zig`、`user/xargs.zig`

用户程序运行在 U 模式，只能访问自己地址空间里的页，要输出文字、读键盘、用管道、创建进程、退出都要通过系统调用（[syscalls.md](syscalls.md)）。它们在构建时编译成独立的 ELF，由 `mkfs` 装进磁盘镜像的 `/bin`；只有 `init` 嵌在内核里（[build.md](build.md#用户程序)、[process.md](process.md#程序从哪来)）。内核启动时只加载 `init`，其他程序都是由已有的进程 `fork` 再 `exec` 出来的（[process.md](process.md#创建进程)）：init 启动 shell（`sh`），shell 的 `run` 命令再启动别的程序。

## 目录结构

| 文件 | 角色 |
| --- | --- |
| `user/start.zig` | 每个程序的**根文件**，相当于 C 的 crt0：导出入口 `_start`，定义 panic 处理，调用程序的 `main` |
| `user/sys.zig` | `sys` 模块：系统调用封装和 `print`，程序用 `@import("sys")` 使用 |
| `user/linker.ld` | 所有程序共用的链接脚本 |
| `user/<名字>.zig` | 程序本身，作为 `program` 模块被 `start.zig` 导入，提供 `pub fn main() u8` |
| `src/abi.zig` | 系统调用号和错误码，内核和 `sys` 模块共用（构建时作为 `abi` 模块） |

## start.zig

```zig
const std = @import("std");
const sys = @import("sys");
const program = @import("program");

export fn _start(argc: usize, argv: [*]const sys.abi.Arg) callconv(.c) noreturn {
    sys.argv = argv[0..argc];
    sys.exit(program.main());
}

pub const panic = std.debug.FullPanic(panicImpl);

fn panicImpl(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    sys.print("panic: {s}\n", .{msg});
    sys.exit(255);
}
```

- **入口**：内核跳到 `_start` 时，`a0` = 参数个数，`a1` = `sp` = 栈顶的 `Arg` 数组的地址（16 字节对齐，参数的字节在它上面，[process.md](process.md#命令行参数)），其他寄存器全为 0。按 C 调用约定，`a0`、`a1` 正好是 `_start` 的前两个参数；`_start` 把它们变成切片存进 `sys.argv`，程序用 `sys.argv` 或 `sys.arg(i)` 读。参数在栈的最顶上，`_start` 的栈帧在它们下面，程序运行期间一直有效。`main` 的返回值就是退出码。没有环境变量。
- **打开的文件**：0、1、2 号 fd 是从父进程继承的（[files.md](files.md)），一般是串口；在 shell 的管道里运行时，0 或 1 是管道的一端。程序不用自己打开什么。
- **为什么 `_start` 在这里而不在 `sys.zig` 里**：Zig 按需分析代码，只有根文件里的 `export` 一定会被处理；写在 `sys.zig` 里的 `comptime { @export(...) }` 只有在 `sys.zig` 被引用到时才会执行。最初就是那么写的，结果 release 模式下 `_start` 没有导出，产出的 ELF 是空的（入口地址 0），运行时在地址 0 取指出错。
- **panic**：用户程序里的 `@panic`，以及 Debug/safe 模式下的安全检查失败（整数溢出、数组越界等），都会打印 `panic: <原因>` 并以退出码 255 结束。fast/small 模式没有安全检查，同样的代码不会 panic（比如整数溢出直接回绕）。没有栈回溯（没有调试信息和 unwind 表）。

## sys.zig

```zig
pub const abi = @import("abi");          // 系统调用号、参数表、错误码、ProcInfo 等，和内核共用
pub fn call(comptime n: abi.Syscall, args: anytype) usize   // 按 abi.params 放参数，做系统调用
pub fn check(ret: usize) Error!usize                         // 返回值是错误码的话换成错误
pub const Error = abi.Error || error{Unexpected};
pub fn raw(n: abi.Syscall, regs: [6]usize) usize             // 寄存器原样交给内核，测试用
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize
pub fn syscall4(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize) usize

pub var argv: []const abi.Arg            // 命令行参数，argv[i].slice() 是第 i 个
pub fn arg(i: usize) ?[]const u8         // 第 i 个参数，没有就是 null

pub const Fd = usize;                    // stdin = 0，stdout = 1，stderr = 2
pub fn exit(code: u8) noreturn
pub fn write(fd: Fd, bytes: []const u8) Error!usize
pub fn writeAll(fd: Fd, bytes: []const u8) Error!void
pub fn read(fd: Fd, buf: []u8) Error!usize   // 没有数据时阻塞；0 表示读到结尾
pub fn close(fd: Fd) Error!void
pub fn dup(fd: Fd) Error!Fd
pub fn pipe() Error![2]Fd            // { 读端, 写端 }
pub fn sbrk(increment: isize) Error!usize    // 返回原来的堆末尾
pub fn open(path: []const u8, flags: OpenFlags) Error!Fd   // OpenFlags{ read = true, write = false, create = false, truncate = false }
pub fn mkdir(path: []const u8) Error!void
pub fn unlink(path: []const u8) Error!void
pub fn chdir(path: []const u8) Error!void
pub fn fstat(fd: Fd) Error!abi.Stat
pub fn readdir(fd: Fd, ent: *abi.Dirent) Error!bool        // 列完了是 false
pub fn getpid() usize
pub fn getppid() usize
pub fn uptime() u64                      // 开机以来的毫秒数
pub fn yield() void                      // 让出 CPU
pub fn sleep(ms: u64) void               // 睡至少 ms 毫秒，精度 10 ms
pub fn fork() Error!usize            // 父进程得到子进程的 pid，子进程得到 0
pub fn exec(name: []const u8, args: []const []const u8) Error!noreturn
pub fn execRaw(name: []const u8, args: []const abi.Arg) Error!noreturn
pub fn wait(pid: ?usize, nohang: bool) Error!?WaitResult
pub fn kill(pid: usize) Error!void
pub fn setfg(pid: ?usize) Error!void
pub fn procinfo(buf: []abi.ProcInfo) usize
pub fn meminfo() abi.MemInfo
pub fn shutdown() noreturn
pub fn print(comptime fmt: []const u8, args: anytype) void              // 输出到 stdout
pub fn fprint(fd: Fd, comptime fmt: []const u8, args: anytype) void

pub const LineReader = struct {          // 带缓冲区地按行读一个 fd（head、tail、grep、xargs 用）
    pub fn init(fd: Fd, buf: []u8) LineReader
    pub fn next(r: *LineReader) Error!?[]const u8      // 下一行，不含 '\n'；读完了是 null
    pub fn nextRaw(r: *LineReader) Error!?[]const u8   // 带着 '\n'（有的话）
};
```

每个函数的语义和错误见 [syscalls.md](syscalls.md#用户态封装)。封装都很短，比如：

```zig
pub fn rename(old: []const u8, new: []const u8) Error!void {
    _ = try check(call(.rename, .{ old, new }));
}
```

`call` 按 `abi.params`（`.rename = .{ .bytes, .bytes }`）把两个切片各放成地址、长度两个寄存器，最后都交给 `raw`：

```zig
pub fn raw(n: abi.Syscall, regs: [6]usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (regs[0]),
          ...
          [arg5] "{a5}" (regs[5]),
        : .{ .memory = true });
}
```

- 调用号放 `a7`，参数放 `a0`..`a5`，返回值在 `a0`。内核会保存并恢复其他所有寄存器，所以不需要声明更多 clobber。memory clobber 是因为 `write` 要读用户内存、`read` 等要写用户内存，编译器必须在 `ecall` 之前把缓冲区真正写好，之后重新读。
- `call` 的参数个数、种类在编译期和 `abi.params` 对一遍，和内核的 `dispatch` 用的是同一张表（[syscalls.md](syscalls.md#分发)），所以封装和内核不会对参数有两种理解。
- `raw`、`syscall`、`syscall4` 是 `pub` 的：回归测试用它们传各种坏参数，直接看原始的返回值。
- 封装函数把内核返回的错误码换成 Zig 的错误（`check`：`abi.errnoOf` 取出错误码，`abi.errorOf` 按 `abi.zig` 的 `error_names` 换成错误，比如 `EFAULT` → `error.BadAddress`、`EBADF` → `error.BadFd`、`EPIPE` → `error.BrokenPipe`，不认识的错误码 → `error.Unexpected`）。所有封装的错误集都是 `sys.Error`。`write` 的返回值可能小于 `bytes.len`（遇到坏地址时只写出了前一部分）。
- `exit` 之后写的是 `unreachable`：内核保证 `exit` 不返回。
- `print` 和内核的 `uart.print` 一样接入 `std.Io.Writer`，输出到 1 号 fd（stdout），带一个 256 字节的缓冲区：格式化的各段先攒在缓冲区里，`print` 最后 `flush`，用**一次** `write` 系统调用写出去（超过 256 字节时，`drain` 先写出攒着的部分，再直接写剩下的，会多写几次）。`write` 在内核里关着中断整段输出，所以一次 `print` 的输出不会被别的进程的输出从中间打断。最初没有缓冲区，每一段都是一次 `write`（`print("pid {d}\n", .{pid})` 是三次），时钟中断可能落在两次 `write` 之间：后台进程刚启动时，它打印的一行插进了 shell 的 `[proc] pid 9 (spin) started in the background` 中间，fast 模式下的 QEMU 测试因此失败过。`drain` 里 `write` 失败（比如 stdout 是读端已经关了的管道）就返回 `error.WriteFailed`，`print` 吞掉错误、丢掉没写出去的部分。要知道写没写成功的程序（`echo`、`cat`）直接用 `writeAll`。
- `LineReader` 在调用方给的缓冲区里攒数据，找到 `\n` 就切出一行（返回的切片指向缓冲区，下一次调用就失效了），剩下的半行挪到开头再读。比缓冲区还长的行截成几段，每段当一行；最后一行没有 `\n` 也算一行。原样输出一行的程序用 `nextRaw`，带着换行一次 `write` 写出去：分两次写（内容、换行）的话，中间可能插进别的进程的输出（多核时管道里前面的程序结束，内核打印的 `[proc] ... exited` 那一行插在一行的中间，QEMU 测试在 4 核上碰到过）。
- `Writer` 包在 `FdWriter` 里，`FdWriter` 记着写到哪个 fd，`drain` 用 `@fieldParentPtr` 从 `Writer` 找回它。stdout 的 `FdWriter` 是全局变量，放在程序的 `.data` 段里（实测 Debug 版 `hello` 的 `.data` 是 56 字节：它占 40 字节，`sys.argv` 占 16 字节），缓冲区在 `.bss` 里（256 字节）。`fprint` 写别的 fd 时在栈上临时建一个。`fork` 出来的子进程有自己的一份；`print` 每次都清空缓冲区，所以 `fork` 时缓冲区总是空的。

## 链接脚本

`user/linker.ld`：从 `0x4000_0000`（`vm.user_base`）开始，用 `PHDRS` 声明 text（R+X）、rodata（R）、data（R+W，含 `.bss`）三个段，每个段从新的一页开始。内核的 ELF 加载器要求每个段页对齐、可读、在用户区内（[process.md](process.md#elf-加载器)）。详细的段布局见 [build.md](build.md#用户程序的链接脚本)。

## init 和 sh

这两个程序必须有（`build.zig` 的 `user_programs` 里排在最前面），整个系统靠它们运转，结构和 xv6 的 `user/init.c`、`user/sh.c` 一样。

**init**（`user/init.zig`）是内核启动时创建的第一个进程，pid 1（`proc.userinit`）：

```zig
pub fn main() u8 {
    while (true) {
        const sh = startShell();          // fork，子进程 exec("sh", &.{"sh"})
        while (true) {
            const child = (sys.wait(null, false) catch break) orelse continue;
            if (child.pid == sh) break;
        }
        sys.print("init: sh exited, restarting it\n", .{});
    }
}
```

- 启动 shell，然后一直 `wait` 任意一个子进程。父进程先结束的进程会被内核交给 init（[process.md](process.md#exit变成-zombie)），它们结束后变成 zombie，靠 init 的 `wait` 回收。
- 等到的是 shell 的话（shell 被 `kill` 了，或者执行了 `exit`），打印一行，再启动一个新的。
- init 不能结束：它一结束内核就 panic（`init exited`），`kill` 也不允许杀它。`fork` 失败时打印原因，睡一秒再试。

**sh**（`user/sh.zig`）是 shell，详见 [shell.md](shell.md)。它的父进程是 init，`run` 启动的程序都是它的子进程。

## 示例程序

### hello

```zig
pub fn main() u8 {
    sys.print("Hello from U-mode! I am pid {d}, the kernel has been up for {d} ms.\n", .{
        sys.getpid(), sys.uptime(),
    });
    const kernel_text: [*]const u8 = @ptrFromInt(0x8020_0000);
    if (sys.write(sys.stdout, kernel_text[0..16])) |_| {
        sys.print("the kernel leaked its own memory!\n", .{});
    } else |err| {
        sys.print("write() refused a kernel pointer: {s}\n", .{@errorName(err)});
    }
    return 0;
}
```

演示 `getpid`、`uptime`、`write`，并且故意把内核代码的地址交给 `write`：内核检查后发现这一页不属于用户空间，返回 `EFAULT`。

```
> run hello
Hello from U-mode! I am pid 3, the kernel has been up for 30 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 3 (hello) exited with code 0
```

### fault

```zig
pub fn main() u8 {
    const kernel_text: *const volatile u32 = @ptrFromInt(0x8020_0000);
    sys.print("reading kernel memory at 0x{x} from U-mode...\n", .{@intFromPtr(kernel_text)});
    const value = kernel_text.*;
    sys.print("read 0x{x}, memory protection is broken!\n", .{value});
    return 1;
}
```

在 U 模式直接读内核内存。内核页表项没有 U 位，读操作触发 `load_page_fault`，内核结束这个进程，shell 照常运行。`volatile` 保证这次读不会被优化掉。

```
> run fault
reading kernel memory at 0x80200000 from U-mode...
[proc] pid 6 (fault) killed: load_page_fault at 0x40011462, stval=0x80200000
```

（`at` 后面是出错指令的地址，随优化模式变化；`stval` 是被访问的地址。）

### spin

```zig
pub fn main() u8 {
    sys.print("pid {d} spinning in U-mode without making syscalls\n", .{sys.getpid()});
    while (true) {}
}
```

进入死循环，不再做任何系统调用。时钟中断每 10 ms 打断它一次，让它让出 CPU，别的进程和 shell 照样运行。证明用户程序没法霸占 CPU。前台运行时按 Ctrl-C 结束它；后台运行时用 `kill` 结束它，`ps` 能看到它的 `TICKS` 一直在涨。

```
> run spin
pid 4 spinning in U-mode without making syscalls
^C
[proc] pid 4 (spin) killed: interrupted by Ctrl-C
```

### ticker

```zig
pub fn main() u8 {
    const pid = sys.getpid();
    for (1..6) |i| {
        sys.sleep(1000);
        sys.print("[ticker pid {d}] tick {d} at {d} ms\n", .{ pid, i, sys.uptime() });
    }
    return 0;
}
```

每秒打印一行，共 5 行，然后退出。睡眠期间不被调度，`ps` 里是 `sleeping`、`TICKS` 几乎不涨。适合放到后台（`run ticker &`），和别的程序、shell 一起跑，看输出交错；多开几个，它们的输出间隔仍然是 1 秒：

```
> run ticker &
[proc] pid 4 (ticker) started in the background
> [ticker pid 4] tick 1 at 2330 ms
[ticker pid 4] tick 2 at 3330 ms
```

### echo、cat、wc

演示命令行参数和管道的三个小程序，和 Unix 的同名命令一样：

- `echo`（`user/echo.zig`）：把参数用空格连起来，加换行，写到 stdout。整行先拼在一个全局缓冲区里，一次 `write` 写出去（参数最多 2048 字节，放得下），理由和 `LineReader.nextRaw` 一样。写失败（读端关了）以 1 结束。
- `cat`（`user/cat.zig`）：`cat [文件...]` 把每个文件依次原样复制到 stdout；不给文件名时复制 stdin，读到结尾结束。打不开的文件打印 `cat: 名字: NotFound` 这样的一行，接着处理下一个，最后以 1 结束。直接从键盘读时输入不回显（串口不回显，回显是 shell 做的），按 Ctrl-D 结束。
- `wc`（`user/wc.zig`）：数 stdin 的行数、单词数、字节数，读到结尾后打印 `行 词 字节`。

```
> run echo hello world | wc
[proc] pid 60 (echo) exited with code 0
1 2 12
[proc] pid 61 (wc) exited with code 0
[proc] pid 59 (sh) exited with code 0
> run echo a b c | cat | cat | wc
[proc] pid 63 (echo) exited with code 0
[proc] pid 64 (cat) exited with code 0
[proc] pid 65 (cat) exited with code 0
1 3 6
[proc] pid 66 (wc) exited with code 0
[proc] pid 62 (sh) exited with code 0
```

（QEMU 测试跑到一半时的输出，所以 pid 比较大。）

最后一行 `(sh)` 是 shell 为管道 fork 出来的“组长”（[shell.md](shell.md#管道)）。

### ls、mkdir、rm、mv、ln

文件系统的几个小命令（[fs.md](fs.md)），出错时都打印 `程序名: 路径: 错误名`（比如 `rm: /d: NotEmpty`），接着处理下一个参数，最后以 1 结束：

- `ls`（`user/ls.zig`）：`ls [路径...]`，不给路径时是当前目录。目录的每一项一行：种类（`file`、`dir`、`dev`、`link`）、链接数、字节数（设备文件是设备号，符号链接是目标的长度）、名字，符号链接后面再加 ` -> 目标`（`readlink`）。给的是目录、或者指向目录的符号链接，列里面的东西（先 `open`，它跟着链接走）；别的（文件、设备、符号链接，包括悬空的）只列它自己。目录项里没有长度、链接数，每一项要再 `lstat` 一次（不跟着符号链接走、不用打开，所以内核不认识的设备也查得到）。顺序是名字的散列的顺序，不是字母顺序。
- `mkdir`（`user/mkdir.zig`）：`mkdir 目录...`，按顺序建，所以 `mkdir /a /a/b` 可以。
- `rm`（`user/rm.zig`）：`rm 路径...`，删文件、设备文件、符号链接或空目录（删掉一个名字；文件还有别的硬链接的话照常在；删符号链接不动它指向的东西）。
- `mv`（`user/mv.zig`）：`mv 旧 新` 改名（`rename` 系统调用，可以换目录；新名字已经有了就换掉它）；最后一个参数是已有的目录时，前面的都挪进去、名字不变（`mv a b /d` 是 `/d/a`、`/d/b`），和 Unix 的 `mv` 一样。给了两个以上的源、最后一个却不是目录，打印 `mv: DIR: not a directory`。出错打印 `mv: 旧 -> 新: 错误名`（比如把目录挪进自己下面：`mv: /m -> /m/sub: InvalidArgument`）。
- `ln`（`user/ln.zig`）：`ln 旧 新` 建硬链接（`link` 系统调用）；最后一个参数是已有的目录时，在里面建同名的链接。用法和出错的格式都和 `mv` 一样；目录不能链接（`ln: /bin -> /b2: PermissionDenied`）。`ln -s 目标 新` 建符号链接（`symlink` 系统调用，[fs.md](fs.md#符号链接)）：目标原样存下，可以还不存在，相对的目标从链接所在的目录算起（`ln -s sd/f /sl` 指向 `/sd/f`）。

```
> run ls /bin
...
file  1   144112 sh
...
file  1   107248 ls
...
> run ls /dev
dev   1        2 null
dev   1        3 zero
dev   1        1 console
> run ln /hello.txt /docs/hi.txt
> run ls /docs
file  1        7 count.txt
file  2       13 hi.txt
> ln -s /bin /b
> ls /
link  1        4 b -> /bin
...
> ls /b/ls
file  1   107248 /b/ls
```

（Debug 构建，`/bin` 只摘了两行，`[proc] ... exited` 的行略去了。）

### scrub

`scrub`（`user/scrub.zig`）调用 `scrub` 系统调用检查整个文件系统，打印统计；坏了打印 `scrub: the file system is damaged: IoError`，以 1 结束（[fs.md](fs.md#检查整个文件系统checkscrub)）：

```
> run scrub
scrub: ok: 35 files, 3 dirs, 3 devices, 0 symlinks, 987 data blocks verified
scrub: tree of 30 nodes, 1068 items, height 2; 6149 of 7168 blocks free, generation 1114
[proc] pid 494 (scrub) exited with code 0
```

### kstat

`kstat`（`user/kstat.zig`）调用 `kstat` 系统调用，打印内核的计数器和栈的高水位。计数器的名字就是 `abi.Counters` 的字段名，程序对字段做 `inline for` 逐个打印，内核加了计数器这里不用改。下面是跑完全部 QEMU 测试（safe、4 核）时的输出：

```
syscalls           43623
context_switches   20384
timer_interrupts   3769
ipis_sent          14028
wakeup_calls       166268
processes_woken    17583
lock_contended     46391
faults_zero        95662
faults_file        1694
faults_cow         3583
tlb_full_flushes   4
tlb_user_flushes   42188
bio_hits           123234
bio_misses         2724
disk_reads         2724
disk_writes        5930
disk_flushes       2080
fs_commits         1040
fs_aborts          0
fs_clean_aborts    57
stack_process      9632 of 24576 bytes
stack_boot         6192 of 32768 bytes
stack_trap         736 of 16384 bytes
```

几个数说明了之前改动的效果：`wakeAll` 调了 16.6 万次，一共只叫醒了 1.8 万个进程，绝大多数时候队列是空的，什么锁都不拿（[process.md](process.md#等待队列waitqueue)）。原来每次 `wakeup` 都要扫进程表、拿 64 把进程锁，换成等待队列之前的一次同样的运行里 `lock_contended` 是 9.1 万，之后是 4.6 万（各只量了一次）；57 次失败的文件系统操作什么都没改，作废时不用重走整棵树（[btree.md](btree.md#事务和提交)）；整个 TLB 只在每个 hart 启动时刷了一次，切换地址空间只作废用户映射，大约每次上下文切换 2 次（原来是每次 4 次全量刷新，[paging.md](paging.md#切换地址空间)）。每次跑的数都不太一样（几个 hart 谁先抢到进程是随机的）。计数器是每个 hart 一份、只有自己加的普通整数（`src/kstat.zig`），读的时候把所有 hart 的加起来。

### 写脚本用的程序

shell 没有 `if`、`while`、算术，也没有 `$(...)`（[shell.md](shell.md)），这些程序用退出码和管道补上，配合 `&&`、`||`、`;` 写脚本。和 Unix 的同名命令一样，只实现了常用的部分；出错信息写到 stderr（2 号 fd，平时也是串口），用法不对的退出码是 2。

| 程序 | 用法 | 说明 |
| --- | --- | --- |
| `test`（`user/test.zig`） | `test EXPR` | 检查条件，成立以 0 结束、不成立以 1、写错了以 2。文件：`-e`（存在）、`-f`（普通文件）、`-d`（目录）、`-L`（符号链接，不跟着走）、`-s`（存在且不空）；字符串：`-z`、`-n`、`S`（不空）、`=`、`!=`；整数（可以是负数）：`-eq -ne -lt -le -gt -ge`；`!`、`-a`（先算）、`-o`、括号 `(` `)`（shell 不把括号当运算符，直接写，前后要有空格）。没有参数时不成立；`test ! = !` 是比较字符串 `!`。没有 `[`（文件名不好起） |
| `expr` | `expr 1 + 2 '*' 3` | 64 位有符号整数运算，打印结果。优先级从低到高：`\|`、`&`、`= != < <= > >=`、`+ -`、`* / %`，括号。每个数、运算符是单独的参数；`*` 要写成 `'*'`（不然被当成文件名匹配），`<`、`>` 要加引号（不然是重定向）。结果不是 0 以 0 结束、是 0 以 1、出错（除以 0、溢出、不是数）以 2 |
| `seq` | `seq [FIRST [STEP]] LAST` | 一行一个数，`STEP` 可以是负数，不能是 0 |
| `sleep` | `sleep SECONDS` | 可以带小数（`sleep 0.25`），精确到毫秒，内核按 10 ms 一个 tick 睡（[syscalls.md](syscalls.md#调用列表)） |
| `head` | `head [-n N] [FILE...]` | 前 N 行（默认 10），带着换行原样输出（`LineReader.nextRaw`）。几个文件时每个前面打印 `==> 名字 <==` |
| `tail` | `tail [-n N] [FILE...]` | 后 N 行（默认 10）。要读到结尾才知道哪些是最后几行，所以整个输入读进堆里：每次 `sbrk` 1 MiB（只挪 `brk`，按需分配，读了多少才用多少内存），一次最多 `read` 64 KiB（`read` 先检查、分配好整个目标范围，[syscalls.md](syscalls.md#read)），读完再把堆缩回去 |
| `grep` | `grep [-vincq] PATTERN [FILE...]` | 打印匹配的行。模式照 xv6 的 `grep`（出自 Kernighan、Pike 的《程序设计实践》）：`^`、`$`、`.`、`c*`、`\c`（字符本身），没有 `[...]`、`+`、`?`。`-v` 反过来、`-i` 不分大小写、`-n` 加行号、`-c` 只打印行数、`-q` 不打印。几个文件时每行前面加 `文件名:`。有匹配以 0 结束、没有以 1、出错以 2。输出的一行（文件名、行号、内容、换行）拼好了一次写出去 |
| `cp` | `cp SRC DST`、`cp SRC... DIR` | 复制普通文件的内容；最后一个参数是目录时复制进去、名字不变。`DST` 已经有了就截断再写；和 `SRC` 是同一个文件（`cp a ./a`）的话截断之前就报 `are the same file`。正在运行的程序不能被覆盖（`TextBusy`，[process.md](process.md#按需分页)） |
| `touch` | `touch FILE...` | 没有就建一个空文件；文件系统没有时间戳，已经有的不动 |
| `tee` | `tee [-a] FILE...` | stdin 复制到 stdout，同时写进每个文件（`-a` 追加） |
| `xargs` | `xargs [-n N] [PROGRAM [ARGS...]]` | 把 stdin 里的词（按空格、制表符、换行分，不认引号）接在 `ARGS` 后面运行 `PROGRAM`（默认 `echo`），每次最多 N 个（默认放得下多少放多少：最多 32 个参数、2048 字节），一批运行完再运行下一批。都成功以 0 结束；有一次失败（或者被杀了）以 123；程序运行不起来以 127，不再运行后面的（和 GNU `xargs` 一样） |

```
> seq 3 | xargs -n 1 echo hi
hi 1
hi 2
hi 3
> test -d /bin -a ! -f /bin && echo dir
dir
> expr '(' 2 + 3 ')' '*' 4
20
> seq 12 | grep -n 1
1:1
10:10
11:11
12:12
> echo 'expr $1 % 2 > /dev/null && echo $1 odd || echo $1 even' > /odd.sh
> seq 3 | xargs -n 1 sh /odd.sh
1 odd
2 even
3 odd
```

（`[proc] ... exited` 的行略去了。）shell 没有循环，`seq ... | xargs -n 1 sh 脚本 ...` 就是一个循环：每个数运行一次脚本，数是 `$1`。QEMU 测试用例 `tools` 检查了上面这些程序的输出和退出码（[testing.md](testing.md#qemu-测试toolsqemu_testpy)）。

## 写一个新程序

1. 新建 `user/<名字>.zig`：

   ```zig
   const sys = @import("sys");

   pub fn main() u8 {
       sys.print("...\n", .{});
       return 0;
   }
   ```

   必须写 `@import("sys")`，不能写 `@import("sys.zig")`（同一个文件不能属于两个模块，见 [build.md](build.md#用户程序)）。
2. 在 `build.zig` 的 `user_programs` 数组里加一项 `.{ .name = "<名字>" }`。（回归测试程序放在 `user/tests/`，加到 `test_programs` 里，见 [testing.md](testing.md#加一个回归测试)。）
3. `zig build run`，在 shell 里 `run <名字> [参数...]`（加 ` &` 在后台运行，用 `|` 接成管道）。不带参数的 `run` 会列出所有程序。参数用 `sys.argv`、`sys.arg(i)` 读，`sys.arg(0)` 是程序名。

可以用的：`std.mem`、`std.fmt`、`std.math` 等纯计算的标准库；全局变量；最多 1 MiB 的栈（按需分配，用多少分配多少）。

不能用或要注意的：

- 堆要自己用 `sbrk` 要：`std.heap.page_allocator` 等依赖操作系统的分配器不可用，`sys.zig` 也还没有提供分配器。可以用 `sbrk` 要一块内存，再用 `std.heap.FixedBufferAllocator` 包起来；小的也可以直接用全局数组或者栈。`sbrk` 不分配页（用到才分配），所以要得多一点没关系；但真用上的时候没有内存了，进程会被结束。
- 全局数组也是按需分配的：程序文件里的页用到才读进来，`.bss` 用到才分配，所以几百 KiB 的全局数组只要没用满，不占那么多内存（[process.md](process.md#按需分页)）。
- 系统调用见 [syscalls.md](syscalls.md#调用列表)：可以读写 fd（串口、管道、文件）、用文件系统（`open`、`mkdir`、`readdir` 等）、`fork`/`exec`/`wait`、读命令行参数，没有线程。`exec` 运行文件系统里的程序：名字里没有 `/` 的在 `/bin` 里找。
- 不能用浮点指令：浮点运算由 compiler_rt 软件实现，慢而且让程序变大。浮点单元被内核关掉了（`sstatus.FS = Off`），手写的浮点指令会触发 `illegal_instruction` 被结束（回归测试 `t_fp`）。
- 栈最多 1 MiB，下面是永远没有页的保护页：栈溢出时触发 `store_page_fault`（`stval` 落在 `0x7feff000..0x7ff00000`），进程被结束。
- 不能执行特权指令、不能访问 S 模式的 CSR（比如 `csrr sstatus`），否则触发 `illegal_instruction` 被结束。例外是 `cycle`、`time`、`instret` 三个计数器：OpenSBI 启动时把 `scounteren` 设成了 7（内核进入时实测，内核没有改它），所以用户程序可以直接用 `rdtime` 等指令读，实测 `rdtime` 在 U 模式下正常返回。
- 代码段只读：往自己的代码里写会触发 `store_page_fault`。
- 程序的各段不能超出 `0x4000_0000..0x7feff000`，堆也只能长到 `0x7feff000` 为止（实际上先碰到的是 128 MiB 的物理内存：堆比整个物理内存还大时 `sbrk` 失败）。
- 读到 0 就是结尾，要结束循环：从管道读时写端都关了，从键盘读时按了 Ctrl-D。
