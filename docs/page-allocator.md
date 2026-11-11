# 物理页分配器

涉及文件：`src/page.zig`（调用方：`src/main.zig`、`src/vm.zig`、`src/syscall.zig`、`src/pipe.zig`）

把内核镜像之后的空闲内存切成 4 KiB 的页，一页一页地分配和释放。页表、用户程序的代码/数据/栈都从这里来。每一页有一个引用数，`fork` 之后父子进程共用的页（写时复制）放掉最后一个引用才真正释放。每个 hart 有自己的空闲链表和锁，几个 hart 同时分配、释放不用排队（[并发](#并发)）。

## 接口

```zig
pub const size = 4096;
pub const Page = [size]u8;

pub var total_pages: usize;   // init 时放进空闲链表的页数
pub fn freePages() usize      // 当前空闲的页数（各个 hart 的链表加起来）

pub fn init(start: usize, end: usize, reserved: []const dtb.Region) void
pub fn alloc() error{OutOfMemory}!*align(size) Page   // 返回清零的一页，引用数为 1
pub fn allocUninit() error{OutOfMemory}!*align(size) Page   // 不清零，只给马上整页覆盖的调用方
pub fn free(page: *align(size) Page) void              // 放掉一个引用，减到 0 才回到空闲链表
pub fn share(page: *align(size) Page) void             // 加一个引用（fork 时父子共用）
pub fn isExclusive(page: *align(size) Page) bool       // 引用数是不是 1（写时复制时用）
```

接口直接用指针：内核对所有物理内存做了恒等映射（[paging.md](paging.md#内核页表)），物理地址就是能直接解引用的虚拟地址，开分页前后都一样。返回类型 `*align(4096) [4096]u8` 把“按页对齐”写进了类型，`@ptrCast` 成 `*PageTable` 时不需要再做对齐检查。

## 数据结构：侵入式空闲链表

```zig
const Pool = struct {
    lock: Spinlock = .init("page", .leaf),
    list: std.SinglyLinkedList = .{},
    count: usize = 0,
};
var pools: [hart.max]Pool = @splat(.{});   // 每个 hart 一个，见“并发”
```

0.17 的 `std.SinglyLinkedList` 是侵入式的：链表只管 `Node { next: ?*Node }`，节点放在哪由使用者决定。这里每个空闲页的**开头 8 字节**就是它的 `Node`，指向下一个空闲页。所以：

- 空闲链表不占额外内存（引用数另外占几页，见下一节）。
- 分配：`popFirst()` 取表头，O(1)。
- 释放：`prepend()` 插回表头，O(1)。
- 空闲页的内容除了开头 8 字节都是无意义的；`alloc` 返回前整页清零，所以拿到的页里不会残留上一个使用者的数据（包括链表指针）。这对页表尤其重要：新页表必须全是无效项。对用户程序来说，这也保证了它读不到之前别的进程留下的内容。

## 引用数

```zig
var refs: []u8 = &.{};   // 按 (地址 - range.base) / 4096 下标，空闲页是 0
```

写时复制的 `fork`（[paging.md](paging.md#复制用户地址空间)）让几个地址空间映射同一个物理页，这一页什么时候能释放，要看还有几个地址空间在用它：

- `alloc` 把引用数设成 1；`vm.cloneUserSpace` 每让子进程多映射一页就 `share` 一次（加 1）。
- `free` 减 1，减到 0 才放回（当前 hart 的）空闲链表。所以调用方不用管这一页是不是还被别人用着：进程结束（`destroyUserSpace`）、堆缩小（`shrinkUser`）、写时复制换上新页（`breakCow`）都是照常 `free`。页表、管道的页从来不共用，引用数一直是 1，`free` 和原来一样直接释放。
- `isExclusive` 判断引用数是不是 1：写时复制的页只剩自己在用时不用复制（[paging.md](paging.md#写时复制)）。
- **能发现重复释放了**：`free` 一个引用数已经是 0 的页直接 panic（`page.free: 0x.. is already free`）。`share` 一个空闲页也 panic。
- 一页最多被进程表里的 64 个进程共用（zombie 被回收之前也还占着它的页），`u8` 足够；`share` 溢出说明引用数记错了，panic。
- **引用数用原子操作改，不拿锁**（`@atomicRmw`、`@atomicLoad`）：`free` 原子地减 1，减之前是 1 的那一个调用方负责把页放回链表；`share` 原子地加 1，调用方自己拿着一个引用，所以不会和“减到 0”同时发生；`alloc` 拿到的页刚从空闲链表上摘下来，只有自己知道，直接写 1。rv64 的原子指令只有 32、64 位的，`u8` 的原子操作由编译器展开成对齐的字上的 LR/SC 循环。

数组放在管理范围**最开头的几页**里：`init` 先按整个范围的页数算出数组要几个字节（每页一个字节），向上取整到页，这几页不放进空闲链表、清零，管理范围从它们之后开始。128 MiB 内存约 31800 页，数组占 8 页（32 KiB）。这几页和保留区重叠的话直接 panic（实际上它们紧跟在内核镜像后面，设备树在内存的最末尾，不会重叠）。

## 初始化

```zig
page.init(vm.kernelEnd(), info.memory.end(), info.reserved());
```

1. 范围 = `[alignForward(start, 4096), alignBackward(end, 4096))`，也就是从 `__kernel_end` 到内存末尾，去掉开头放引用数数组的几页（见上一节）。内核之前的 `0x8000_0000..0x8020_0000` 是 OpenSBI 和空隙，不归分配器管。
2. 所有页都放进**启动 hart 的链表**（这时只有它在运行），别的 hart 第一次分配时再来拿（[并发](#并发)）。**从高地址往低地址**遍历每一页，跳过和任一保留区重叠的页（`isReserved`：`addr + 4096 > r.base and addr < r.end()`，只要有一个字节重叠就跳过），其余的插到表头。因为是倒着插的，最后表头是最低地址的页：先分配出去的是低地址，调试时地址更好认（新建的页表、用户页都在 `0x802c_xxxx` 附近）。
3. `total_pages` = 放进去的页数。

保留区来自设备树（[devicetree.md](devicetree.md#结果)）：设备树自身、内存保留块、`/reserved-memory`。OpenSBI 的两段在内核之前，本来就不在范围里；真正起作用的是设备树自身那 2 页。

实测（Debug 模式，128 MiB，不带测试程序的 `zig build`）：

```
[0x80359000, 0x88000000)       = 31911 页   ← 0x80359000 是 __kernel_end（llvm-readelf -s）
减去引用数数组的 8 页          = 31903 页
减去设备树占的 2 页            = 31901 页   ← 启动日志 [ok] page allocator: 31901 free pages
```

之后建内核页表、创建 init 和 shell 还会用掉一些页，进 shell 后 `mem` 显示的空闲页数更少。

不同优化模式下内核镜像大小不同，`__kernel_end` 不同，页数也会不同。

初始化的开销是“页数 × 保留区数”次比较，32K 页 × 3 段在 QEMU 上可以忽略。初始化时要往每个空闲页写一个指针，这发生在开分页之前，用的是物理地址。

## 分配和释放

```zig
pub fn alloc() error{OutOfMemory}!*align(size) Page {
    const page = try allocUninit();
    @memset(page, 0);
    return page;
}

pub fn allocUninit() error{OutOfMemory}!*align(size) Page {
    const pool = &pools[hart.id()];
    pool.lock.acquire();
    var node = pool.list.popFirst();
    if (node != null) pool.count -= 1;
    pool.lock.release();
    if (node == null) node = steal(pool);           // 自己的空了，去别的 hart 那里拿一批
    const page: *align(size) Page = @ptrCast(@alignCast(node orelse return error.OutOfMemory));
    @atomicStore(u8, refOf("page.alloc", page), 1, .release);
    return page;
}

pub fn free(page: *align(size) Page) void {
    const old = @atomicRmw(u8, refOf("page.free", page), .Sub, 1, .acq_rel);
    if (old == 0) std.debug.panic("page.free: 0x{x} is already free", .{@intFromPtr(page)});
    if (old > 1) return;                            // 还有别人在用
    const pool = &pools[hart.id()];
    pool.lock.acquire();
    defer pool.lock.release();
    pool.list.prepend(@ptrCast(page));
    pool.count += 1;
}
```

- `refOf` 检查地址是否在分配器管理的范围内，不在就 panic（`page.free: 0x.. was not handed out by the page allocator`）。这能抓住“把一个不是页分配器给的指针拿来释放”这类错误；它在开发 U 模式时确实抓到过一次（进程退出后内核状态被破坏，拿着垃圾值去释放）。
- 重复释放靠引用数发现（见[引用数](#引用数)）。
- 释放时不清零（分配时清）。
- `allocUninit` 不清零，只给马上用 `@memcpy` 整页覆盖它的两个地方：写时复制（`vm.breakCow`）和复制内核根页表（`vm.createUserSpace`）。清零白做一遍，而且是整整 4 KiB 的写。别的地方一律用 `alloc`：新页表必须全是无效项，给用户程序的页不能留着别人的数据。

## 谁在用

| 调用方 | 用途 | 何时释放 |
| --- | --- | --- |
| `vm.init` | 内核根页表、中间级页表（Debug 模式下共 6 页） | 从不 |
| `vm.walk` | 建映射时缺的中间级页表 | 用户区的页表在 `vm.destroyUserSpace` 时释放 |
| `vm.createUserSpace` | 进程的根页表 | `vm.destroyUserSpace` |
| `vm.fault`（按需分页） | 用户程序的代码、数据、`.bss`、堆、栈的页，第一次被访问时（用户程序自己访问缺页，或者内核 `copyFromUser` 这些替它访问时） | `vm.destroyUserSpace`（`exec` 换掉旧的地址空间时；父进程 `wait` 回收子进程时）；堆缩小时 `vm.shrinkUser`。和别的进程共用的页只是放掉一个引用 |
| `vm.cloneUserSpace`（`fork`） | 子进程的页表；用户页不分配，`share` 父进程的 | 同上 |
| `vm.breakCow` | 写时复制：给写共用页的进程复制一页，放掉它对旧页的引用 | 同上 |
| `pipe.create` | 每个管道一页（缓冲区 2048 字节和状态） | 两端都关了（`pipe.close`） |
| `meminfo` 系统调用（shell 的 `mem` 命令） | 只读 `freePages()`、`total_pages` | — |

一个用户程序运行时用多少页：根页表 1 + 第 1 级页表 1 + 第 0 级页表 2（各段所在的 `0x4000_0000..0x4020_0000` 一张，栈所在的 `0x7fe0_0000..0x8000_0000` 一张）+ 各段占的页 + 栈 4 页。以 Debug 版 `hello` 为例：代码 19 页 + 只读数据 4 页 + 数据 1 页，合计 4 + 24 + 4 = 32 页。用 GDB 在进程第一次进入 U 模式前停下读当时的 `page.free_pages`（那时还是一个变量），实测正好从 32052 降到 32020（单进程版本时测的，当时停在 `proc.switchToUser`；之后内核的 `.bss` 变大了，空闲页的绝对数会不同，差值不变）。

`fork` 出来的子进程一开始只多用 4 张页表，用户页都和父进程共用，之后谁写哪一页谁才多用一页。

程序结束、被父进程回收后这些页全部还回来，`mem` 前后的数字应该一致（zombie 还没被回收时，它的页还占着）；测试时就用这一点检查有没有漏页（[testing.md](testing.md)）。

## 并发

照 xv6 lock lab 的 kalloc：**每个 hart 一条空闲链表，各有一把自旋锁**（`Pool`）。分配、释放只拿当前 hart 自己那条的锁，几个 hart 同时分配、释放（`fork`、`exec`、写时复制的缺页）不用排队，锁的那一行缓存也不在 hart 之间来回跑。只有一把全局锁时，所有 hart 的每一次分配、释放都要抢它。

- **自己那条空了才去拿别人的**（`steal`）：依次看别的 hart 的链表，拿着它的锁一次摘下最多 32 页（`steal_batch`），放开；再拿自己的锁，留一页返回、其余的放进自己的链表。一页一页地拿的话，接下来每次分配都要去拿别人的锁。所有链表都空了才是 `OutOfMemory`。
- **一次只拿一把链表的锁**：`steal` 先放开别人的，再拿自己的，两个 hart 同时互相 `steal` 也不会死锁。
- **用 `hart.id()` 选链表是安全的**：内核代码关着中断运行、不会被抢占，`alloc`/`free` 从头到尾都在同一个 hart 上；即使不是，用错了链表也只是放进了别人的链表，链表本身有锁保护。
- 启动时所有页都在启动 hart 的链表里，别的 hart 第一次分配时各自拿走一批；之后哪个 hart 释放的页就进哪个 hart 的链表。
- **`freePages()`** 逐个拿锁把各个链表的 `count` 加起来。别的 hart 正在分配、释放时，加出来的是某一瞬间前后的值，只用来显示（`meminfo`）和测试时比较前后有没有漏页（那时别的进程都停着）。
- 引用数不归任何一把锁管，用原子操作（见[引用数](#引用数)）。

这些锁都是“叶子”锁，拿着进程锁、`wait_lock` 时也可以分配、释放页（`fork`、`reap`）。`alloc` 只在锁里摘下一页，清零放在锁外面（这一页已经是自己的了），持锁的时间很短。

拿锁时中断必须关着（`Spinlock.acquire` 检查）。现在分配器只在启动阶段、系统调用和用户程序的写缺页（写时复制）里调用（`kmain`、`fork`、`exec`、`wait`、`sbrk`、`pipe`、`breakCow`），从不在中断处理程序里调用，内核代码又都关着中断运行，所以满足。`kmain` 在创建 init 时就会分配页，这也是 `kmain` 不再打开 `sstatus.SIE` 的原因之一（[boot.md](boot.md#kmain-的初始化顺序)）。

单元测试在主机上只有一个“hart”（`hart.id()` 总是 0），`steal` 由单元测试直接把页挪到别的链表上来测。

## 限制和以后可以做的

- 只能一页一页地分配，没有连续多页的分配（需要的话可以改成伙伴系统或位图）。
- 只管理设备树里第一段内存。
- 没有统计谁占用了哪些页；排查泄漏只能看 `freePages()` 的前后差。
- 一个 hart 释放了很多页之后，别的 hart 要靠 `steal` 一批一批地拿过去，不会主动平衡。
