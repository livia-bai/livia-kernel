# 同一个不变量的三种写法

内核里到处是“必须这样做，否则会出错”的规矩：拿锁要按顺序，拿着锁不能缺页，内核和用户程序对系统调用的参数要理解成一样的……写下这种规矩，有三种办法：

1. **注释约定**：写在注释或文档里，靠写代码、评审的人记住。违反了，多数时候照常运行，偶尔出错。
2. **运行时断言**：违反的那一刻 panic，说出是哪条规矩。只要那条路径跑到过一次就能发现，不用等它真的出错。
3. **类型约束**：错误的写法编译不过。不用跑，也不用跑到那条路径。

越往后越可靠，代价也越大：断言要在运行时付出一点检查，类型约束常常要把接口重新设计一遍，编译错误也更难读。下面五个例子都是这个仓库里真实发生过的改动：原来是第 1 种，改成了第 2 种或第 3 种。每个例子保留了改动前后的代码（摘录，省略了无关的部分），讲为什么停在那一级、没有再往前走。

| 规矩 | 原来 | 现在 | 违反了会怎样 |
| --- | --- | --- | --- |
| 拿着锁复制用户内存之前先把页准备好 | 注释约定 | 类型（`PinnedSrc`/`PinnedDst`） | 编译不过；绕过它直接调用 `copyFromUser` 会 panic |
| 嵌套加锁按固定的顺序 | 注释约定（一段话列了十几种锁） | 运行时断言（锁等级） | 拿锁的那一刻 panic，说出是哪两把锁 |
| 内核和用户程序对系统调用的参数个数、顺序、类型理解一致 | 注释约定（四处各写一遍） | 编译期核对（`abi.params`） | 编译不过 |
| 打开的文件只读写和它的种类相符的字段 | 注释约定（字段旁边写“kind 为 X 时”） | 类型（tagged union） | 编译不过，或者运行时 panic |
| 等待的一方和叫醒的一方用同一个“通道” | 注释约定（两边写同一个地址表达式） | 类型（每个条件一个 `WaitQueue` 字段）+ 断言（拿着锁） | 多半编译不过；没拿锁 panic |

## 拿着锁复制用户内存之前先把页准备好

**规矩**：用户页是按需分配的，第一次访问时可能要从程序文件读盘，读盘要睡着等。拿着锁的时候不能睡。所以写串口、管道、文件这些要拿着锁复制用户内存的系统调用，拿锁之前要先把范围里的页都准备好（[paging.md](paging.md#内核访问用户内存)）。

**原来**：两个准备函数，加一句注释，拿着锁的复制里写 `catch unreachable`：

```zig
/// 之后要拿着锁 copyFromUser / copyToUser 的系统调用先调用它（write 写管道、文件，readdir、wait）：
/// 拿着锁时只能分配清零的页，读不了盘（见 canSleep）。
pub fn prefault(s: *Space, va: usize, len: usize) void { ... }
pub fn checkUser(s: *Space, va: usize, len: usize, write: bool) error{BadAddress}!void { ... }

// file.zig，拿着串口的接收锁：
vm.copyToUser(space, ptr + done, buf[0..n]) catch unreachable; // 调用方检查过了
```

漏了 `prefault` 的系统调用平时都对：大多数时候那些页早就读进来了。只有那一页恰好还没读进来时，拿着锁的复制返回 `BadAddress`，用户看到一个莫名其妙的 `EFAULT`。测试很难撞到。`catch unreachable` 则把约定变成了隐含的前提：调用方真漏了，在 release 模式下是未定义行为。

**现在**：准备函数返回一个凭证，拿着锁的复制只有凭证上的方法：

```zig
pub const PinnedDst = struct {
    space: *Space,
    va: usize,
    len: usize,

    /// 把 src 复制到这段的 off 处。超出这段是内核的错。
    pub fn copyOut(p: PinnedDst, off: usize, src: []const u8) void { ... }
};

pub fn pinDst(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedDst

// 管道的读：拿不到 PinnedDst 就调用不了
pub fn read(p: *Pipe, dst: vm.PinnedDst) Error!usize
```

`pipe.read`、`file.read` 的参数类型就是 `PinnedDst`，没 pin 就没有东西可传。`copyOut` 不会失败，不用 `catch unreachable`。剩下的漏洞是有人绕过凭证，拿着锁直接调用 `copyFromUser`，这一条用断言补上：`copyFromUser` 这些函数一开始检查当前 hart 拿着几把锁，拿着就 panic：`copyFromUser while holding a lock (pin the range first)`。

**为什么能做到这一级**：凭证成立的前提是 pin 好之后，只有这个进程自己会改它的地址空间。这个内核没有线程、不换出页，前提成立，所以凭证只是一个“我检查过了”的证明，不用真的把页钉住。以后加了线程或者换页，`pin` 就要记引用、不许换出，类型不用变。

## 嵌套加锁按固定的顺序

**规矩**：两个 hart 用相反的顺序拿同两把锁，就可能互相等着，永远不放。

**原来**：`AGENTS.md` 里的一段话：

> 嵌套加锁按固定顺序：`wait_lock` → 进程锁 → 页分配器（每个 hart 一把）、`File.lock`、串口输出、`fsys.text_lock` 这些叶子锁；管道锁、串口输出锁、`uart.rx_lock` → 页分配器……；`bio.evict_lock` → `bio` 的桶的锁；`timer.lock`、管道锁、`uart.rx_lock`、`virtio_disk.lock`、`bio.evict_lock`、`Volume.snap_lock`、睡眠锁里的自旋锁 → 进程锁；睡眠锁之间 `File.pos_lock` → `fsys.write_lock` → 缓冲区的睡眠锁。新加的嵌套要先对照这个顺序。

违反了顺序的代码在绝大多数运行里不会死锁，要两个 hart 在几条指令的窗口里恰好交叉。真死锁了，看到的也只是机器卡住，不知道是哪两把锁。

**现在**：每把锁创建时给一个等级，`acquire` 检查这个 hart 已经拿着的锁的等级都更低：

```zig
pub const Rank = enum(u8) { wait, cond, bucket, proc, uart_out, leaf, ... };

var lock: Spinlock = .init("virtio disk", .cond);

pub fn acquire(l: *Spinlock) void {
    if (orderViolation(l)) |other| std.debug.panic("lock order: acquiring {s} ({s}) while holding {s} ({s})", .{
        l.name, @tagName(l.rank), other.name, @tagName(other.rank),
    });
    ...
}
```

一次正常的运行，只要那条嵌套的路径跑到过，就会 panic 并说出是哪两把锁，不用等两个 hart 真的交叉。`AGENTS.md` 那一段缩成了一句“按等级从低往高”。

**为什么停在断言、没有做成类型**：要让编译器检查顺序，类型里就得带着“现在拿着哪些锁”，每次拿锁、放锁都换一个类型。Zig 没有线性类型，做不到“放开之后这个值不能再用”；而且锁的交接（`sleep` 拿着进程锁切走、由调度器放开）也写不进这种类型。断言的代价是每次 `acquire` 扫一遍这个 hart 拿着的锁（实际最深五六把），可以接受。断言只能发现跑到过的路径，所以 QEMU 测试和随机空转（[testing.md](testing.md#qemu-测试toolsqemu_testpy)）还是要有。

## 系统调用的参数只写一次

**规矩**：系统调用 `open` 的第一个参数是路径（指针和长度两个寄存器），第二个是标志。内核的解码和用户态的封装必须理解成一样的。

**原来**：同一个签名写在四个地方：`abi.zig` 的编号和注释、`syscall.zig` 的分发、`user/sys.zig` 的封装、`docs/syscalls.md`。内核这边拿到的是六个 `usize`，每个处理函数自己解码：

```zig
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    return switch (number) {
        .write => write(args[0], args[1], args[2]),
        .exec => exec(args[0], args[1], args[2], args[3]),
        .open => open(args[0], args[1], args[2]),
        ...
    };
}
```

参数个数和顺序只在注释里，两边写反了编译器不会说。错误码要映射两次：内核里错误换成错误码，用户态再换回错误，`user/sys.zig` 里这样的分支有七十七条。

**现在**：参数只在 `abi.params` 里写一次，内核的 `dispatch` 由它生成，用户态的 `sys.call` 在编译期和它核对：

```zig
// abi.zig
pub const params = .{
    .write = .{ .fd, .bytes },
    .exec = .{ .bytes, .array },
    .wait = .{ .int, .ptr, .int },
    ...
};

// syscall.zig：处理函数拿到的已经是解码好的参数
pub fn write(f: *file.File, data: UserSlice) file.Error!usize
```

`dispatch` 用 `inline for` 遍历每个系统调用，按 `params` 从寄存器里解码（`.fd` 查 fd 表、给出 `*file.File`，`.bytes` 占两个寄存器），交给同名的处理函数。处理函数的参数个数和 `params` 对不上，编译错误会说 `syscall.handlers.open takes 3 parameters, abi.params says 2`。错误码也一样：每个错误码在 `abi.zig` 里有一个 Zig 名字，两个方向的转换都由这张表生成，内核里出现一个表里没有的错误，编译错误是 `no errno for error.X`（[syscalls.md](syscalls.md#新增一个系统调用)）。

**代价**：`dispatch` 展开成四十份解码代码，Debug 下进程内核栈最深多了约 2 KiB；编译错误要专门写，不然 `inline for` 展开之后的错误信息很难读。`docs/syscalls.md` 还是手写的。

## 打开的文件是一个 tagged union

**规矩**：串口、管道、文件、设备四种打开的文件，各自只有一部分字段有意义：只有管道有 `pipe`，只有文件有读写位置。

**原来**：一个 `kind` 加上所有种类的字段，字段旁边写着对哪种有效：

```zig
pub const File = struct {
    lock: Spinlock = .init("file", .leaf),
    ref: u32 = 0,
    kind: Kind = .none,
    readable: bool = false,
    writable: bool = false,
    pipe: *pipe.Pipe = undefined,
    /// kind 为 inode、device 时：文件系统里的 inode 号
    ino: u64 = 0,
    /// kind 为 device 时：哪个设备
    major: abi.Major = .console,
    off: u64 = 0,
    append: bool = false,
    ...

    /// 刚分配到的槽位：除了两把锁和 ref，字段都回到初始值
    fn reset(f: *File) void {
        f.kind = .none;
        f.readable = false;
        ...  // 新加字段要记得在这里加一行
    }
};
```

对串口文件读 `f.pipe`，编译器不拦，读到的是 `undefined`。`reset` 逐个字段手写，新加的字段漏了，上一个用这个槽位的文件的值就留了下来。

**现在**：

```zig
pub const File = struct {
    lock: Spinlock = .init("file", .leaf),
    ref: u32 = 0, // 0 = 空槽位
    open: Open = undefined,
    pos_lock: Sleeplock = .init("file pos", .file_pos),
};

pub const Open = struct {
    readable: bool,
    writable: bool,
    target: Target,
};

pub const Target = union(enum) {
    console,
    pipe: *pipe.Pipe,
    inode: Inode, // ino、读写位置 off、append
    device: struct { ino: u64, dev: Device },
};
```

要拿管道，只能 `switch (f.open.target)` 走到 `.pipe => |p|` 那一支；Safe 和 Debug 模式下直接读 `f.open.target.pipe` 而它不是管道，会 panic。加一种文件，没写 `else` 的 `switch` 都会被编译器指出来。分配槽位时一次赋值 `f.open = .{ ... }`，`reset` 删掉了，也就没有“忘了清哪个字段”这回事。

**为什么能做到这一级**：种类是固定的几种，而且每个字段只属于一种。代价几乎没有：`switch` 本来就要写。

## 等待和叫醒用同一个队列

**规矩**：等某件事的进程睡下，做了这件事的一方叫醒它。两边要说好“这件事”是什么，叫醒的一方要拿着保护条件的锁，不然会丢唤醒。

**原来**（照 xv6）：“这件事”是一个任意的地址，两边各写一遍：

```zig
pub fn sleep(chan: *const anyopaque, lock: *Spinlock) void
pub fn wakeup(chan: *const anyopaque) void

// pipe.zig
proc.sleep(&p.nread, &p.lock);   // 读的一方等数据
proc.wakeup(&p.nread);           // 写的一方写进了数据
```

谁在等什么，要靠搜同一个地址表达式来配对。把 `&p.nread` 写成 `&p.nwrite` 就是永远不醒，类型系统帮不上忙。`wakeup` 不检查调用方拿着锁：串口中断就是放开锁之后才 `wakeup` 的，它是对的，但读代码的人得自己想清楚为什么对。

**现在**：每个等待条件旁边放一个有名字的队列：

```zig
pub const Pipe = struct {
    lock: Spinlock = .init("pipe", .cond),
    nread: usize = 0,
    nwrite: usize = 0,
    readers: proc.WaitQueue = .{},
    writers: proc.WaitQueue = .{},
    ...
};

p.readers.wait(&p.lock);       // 读的一方等数据
p.readers.wakeAll(&p.lock);    // 写的一方写进了数据
```

配对的是一个字段，写错了多半编译不过（字段名不对），或者一眼就能看出来（`readers` 和 `writers` 写反了）。`wait` 和 `wakeAll` 都检查调用方拿着 `lock`，没拿就 panic：`WaitQueue.wakeAll: not holding uart rx`。串口中断也改成了拿着锁叫醒（[process.md](process.md#等待队列waitqueue)）。

**为什么还要断言**：类型只管住了“用哪个队列”，管不住“拿着哪把锁调用”：`WaitQueue` 不知道保护它的是哪把锁（把锁的指针存进队列，对管道这种放在一页里、对睡眠锁这种静态数组里的结构体都不方便）。所以锁作为参数传进去，在运行时检查。

## 还停在注释里的

有些规矩还只写在 `AGENTS.md` 和注释里，是下一步可以做的：

- **字段归哪把锁管**：进程的 `state`、`pid` 只能拿着进程锁读写，`parent` 只能拿着 `wait_lock`。可以把这些字段包进一个只能通过“持锁凭证”访问的结构体，像 `PinnedDst` 那样。
- **硬件约定**：`sscratch` 在三种情况下各存什么，`tp` 在内核里一定是 hart 编号。这类规矩没法交给类型，现在做到了运行时检查：启动时、每次进陷阱处理程序、调度器每一轮各核对一次（[trap.md](trap.md#sscratch-约定)）。
- **改程序文件之前先 `beginModify`**：现在靠每个改文件的地方记得调用（[fs.md](fs.md#删掉还有人用着的文件)），可以像 pin 那样做成凭证。

判断一条规矩该做到哪一级，可以问三个问题：违反了能不能马上看出来？检查的代价多大？能不能把规矩变成接口的形状，让错误的写法根本写不出来？
