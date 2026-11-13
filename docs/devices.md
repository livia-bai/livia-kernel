# 设备：串口、PLIC、定时器

涉及文件：`src/uart.zig`、`src/plic.zig`、`src/timer.zig`（串口作为文件的读写在 `src/file.zig`，[files.md](files.md#串口)）

这三个模块的地址、中断号都按 QEMU `virt` 写死（时钟频率除外，它来自设备树）。分页打开后，串口和 PLIC 的寄存器区域在内核页表里按恒等映射为 RW（[paging.md](paging.md#内核页表)），所以开分页前后访问方式不变。

## 串口（`uart.zig`）

QEMU `virt` 上的 NS16550A 兼容串口，基地址 `0x1000_0000`，寄存器区 `0x100` 字节（分页时映射一整页）。它同时充当“屏幕”和“键盘”：输出用轮询，输入用中断。

### 寄存器

每个寄存器 1 字节，偏移相对基地址：

| 偏移 | 名字 | 用法 |
| --- | --- | --- |
| 0 | RBR（读）/ THR（写） | 读：取出收到的一个字节；写：发送一个字节 |
| 1 | IER | 中断使能，bit 0 = 收到数据时产生中断 |
| 2 | FCR（写） | FIFO 控制 |
| 3 | LCR | 线路控制：数据位、校验、停止位 |
| 5 | LSR | 线路状态：bit 0 = 有数据可读，bit 5 = 发送保持寄存器空 |

寄存器指针都是 `*volatile u8`：每次读写都必须真的发生，而且不能合并、不能重排。比如轮询 LSR 的循环，如果不是 `volatile`，优化模式下编译器可以只读一次。

### 初始化

```zig
reg(.ier).* = 0x00; // 配置期间先关掉串口中断
reg(.lcr).* = 0x03; // 8 位数据、无校验、1 位停止位
reg(.fcr).* = 0x07; // 启用并清空收发 FIFO
reg(.ier).* = 0x01; // 收到数据时产生中断
```

QEMU 的模拟串口不在乎波特率，所以没有设置分频（DLAB）。IER 打开接收中断后，串口在收到字符时拉高中断线，但 CPU 要等 PLIC 和 `sie.SEIE` 都配好、`sstatus.SIE` 打开之后才会真的收到。

### 输出

```zig
fn putRaw(c: u8) void {
    while (reg(.lsr).* & lsr_thr_empty == 0) {}
    reg(.rbr_thr).* = c;
}
fn putc(c: u8) void { hart.checkPanic(); if (c == '\n') putRaw('\r'); putRaw(c); }

var tx_lock: Spinlock = .init("uart tx", .uart_out);
pub const Output = struct {        // 拿着 tx_lock 的一段输出
    locked: bool,                  // panic 的 hart 不拿锁
    pub fn write(o: Output, bytes: []const u8) void
    pub fn unlock(o: Output) void
};
pub fn lockOutput() Output
pub fn write(bytes: []const u8) void                          // lockOutput + write + unlock
pub fn print(comptime fmt: []const u8, args: anytype) void    // 同上，中间是格式化输出
```

- 轮询 LSR 的“发送保持寄存器空”位，空了才写下一个字节。
- `\n` 前补一个 `\r`：终端需要回车才会回到行首。
- 每个字符之前看一眼是不是有别的 hart 在 panic，是的话停下（[boot.md](boot.md#panic)）。
- `print` 通过 `std.Io.Writer` 使用标准库的格式化（`{d}`、`{x}`、`{s}` 等）。Writer 的 `buffer` 为空，所以每次写入都直接调用 `drain`：

  ```zig
  fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize
  ```

  `data` 是若干段字节，最后一段要重复输出 `splat` 次（格式化填充对齐时会用到），返回实际写出的字节数。这里全部写完，返回总长度。
- `print` 吞掉格式化错误（串口写不会失败）。

**输出锁 `tx_lock`**：几个 hart 会同时输出（一个进程退出时内核打印 `[proc] ... exited`，另一个 hart 上的 shell 正好在打印提示符），不加锁的话字符会交错在一起。所以每次 `write`、`print` 整段拿着 `tx_lock`：

- **`print` 要在外面拿锁，不能只在 `drain` 里拿**：格式化一行时 `drain` 会被调用好几次（每段字面量、每个参数各一次），只在 `drain` 里拿锁的话，别的 hart 的输出会插进一行的中间。`print` 先 `lockOutput()`，再 `writer.print`，`drain` 里直接写（它构造一个 `locked = false` 的 `Output`，只用来调用 `write`）。
- **用户程序的 `write` 系统调用也整段拿锁**：`file.consoleWrite` 在开头 `lockOutput()`，把用户内存分块复制出来、逐块输出，最后才 `unlock()`（[files.md](files.md#串口)）。用户程序的 `print` 先攒进缓冲区，再一次 `write` 写出（[user-programs.md](user-programs.md#syszig)），所以一行不会被别的进程的输出插进来。两个进程的多次 `write` 之间仍然可能交错。
- 拿着输出锁时不能再调用 `print`、`write`（同一个 hart 重复拿锁会 panic）。`tx_lock` 是“叶子”锁，拿着别的锁的时候可以打印，拿着 `tx_lock` 时不再拿别的锁（[process.md](process.md#锁)）。
- **panic 时不拿锁**：`lockOutput` 发现当前 hart 正在 panic，就返回一个 `locked = false` 的 `Output`，直接输出。锁可能就在 panic 的 hart 自己手里，也可能在别的 hart 手里，而那个 hart 一输出下一个字符就会停下、永远不放锁。
- 时钟和串口的中断处理程序本身不打印（只有“意外的外部中断”、Ctrl-C 的 `^C` 和 panic 会打印）。

### 输入：环形缓冲区

```zig
var rx_buf: [256]u8 = undefined;
var rx_head: u8 = 0;  // 中断处理程序写入的位置
var rx_tail: u8 = 0;  // read 系统调用读出的位置
pub var rx_lock: Spinlock = .init("uart rx", .cond);   // 保护上面三个

pub var rx_waiters: proc.WaitQueue = .{};  // rx_lock。等输入的进程排在这里

pub fn hasInput() bool   // 调用方要拿着 rx_lock，下同
pub fn peek() ?u8        // 看一眼下一个字符，不取出来
pub fn read() ?u8        // 取出一个字符
```

- 索引是 `u8`，`+%` 回绕正好对应 256 字节的缓冲区，不需要取模。
- `head == tail` 表示空；`head + 1 == tail` 表示满（留一个空位区分空和满，实际容量 255）。满了之后新来的字符被丢弃。
- **单生产者单消费者**：只有中断处理程序（`onInterrupt`）改 `head`，只有 `read` 系统调用（`file.consoleRead` 里的 `uart.hasInput`、`peek`、`read`）改 `tail`。两边都拿着 `rx_lock`（`hasInput` 等断言了这一点）：串口中断在一个 hart 上处理的同时，另一个 hart 上的进程可能正在 `read`。中断处理程序也拿这把锁不会死锁：拿着它的代码都关着中断，同一个 hart 上不会被串口中断打断。
- 缓冲区为空时 `read` 系统调用拿着 `rx_lock` 调用 `rx_waiters.wait(&rx_lock)`；`trap.handleExternal` 在 `onInterrupt` 之后拿上 `rx_lock`、`rx_waiters.wakeAll(&rx_lock)` 叫醒它（[files.md](files.md#串口)）。驱动只放着这个队列，不叫醒、不睡。

```zig
pub fn onInterrupt() bool {
    rx_lock.acquire();
    defer rx_lock.release();
    var ctrl_c_pressed = false;
    while (getc()) |c| {
        if (c == ctrl_c) { ctrl_c_pressed = true; continue; }
        if (rx_head +% 1 == rx_tail) continue;   // 满了，丢弃
        rx_buf[rx_head] = c;
        rx_head +%= 1;
    }
    return ctrl_c_pressed;
}
```

一次中断里把硬件 FIFO 里所有字符都读走（循环直到 LSR 说没有数据）。只读一个也能工作：串口的接收中断是电平信号，FIFO 里还有数据时，`complete` 之后 PLIC 会再次投递。但那样每个字符都要完整走一遍陷阱。实测（临时改成每次只读一个字符，一次性发出 30 个字符）：字符一个不丢，外部中断 30 次；现在的循环读法同样的输入只有 2 次。

### Ctrl-C

Ctrl-C（ASCII `0x03`）不进缓冲区，`onInterrupt` 返回这一次有没有收到过它。

- `trap.handleExternal` 拿到 `true` 就交给 `proc.interruptForeground()`，由它杀掉前台进程和它的子孙（[process.md](process.md#ctrl-c)）。用户程序就算在 U 模式死循环、从不做系统调用，串口中断也照样会打断它，这次中断返回之前它就结束了。
- 没有前台进程时按的 Ctrl-C 也在这里被处理掉、什么都不做，所以不会留到下一个程序一启动就把它杀掉。Ctrl-C 不进缓冲区，`read` 读不到它。
- Ctrl-D（`0x04`）照常进缓冲区，由 `read` 当作“输入结束”处理（[files.md](files.md#串口)）。
- 管道测试里用 `printf '\003'` 发送 Ctrl-C。QEMU `-nographic` 会把 Ctrl-C 原样交给客户机串口，不会结束 QEMU 自己（结束 QEMU 是 Ctrl-A X）。

## PLIC（`plic.zig`）

PLIC（Platform-Level Interrupt Controller）把外设的中断线汇总起来，按优先级送给各个 hart 的各个特权级。QEMU `virt` 上它的基地址是 `0x0c00_0000`，寄存器区域 6 MiB（`mmio_size = 0x60_0000`，设备树里 plic 节点的 `reg`），分页时整块映射。串口是 10 号中断源（`uart0_irq = 10`，设备树里串口节点的 `interrupts = <0x0a>`）。

### 上下文

PLIC 把“某个 hart 的某个特权级”叫一个上下文（context）。QEMU `virt` 上每个 hart 有两个：`2 * hart` 是 M 模式，`2 * hart + 1` 是 S 模式。内核用 S 模式上下文，hart 0 是上下文 1，hart 2 是上下文 5。`context()` 按当前 hart 的编号（`hart.id()`）现算，所以 `claim`、`complete` 操作的总是当前 hart 自己的上下文。

### 寄存器

| 地址 | 寄存器 | 用法 |
| --- | --- | --- |
| `base + 4 * irq` | 中断源 `irq` 的优先级 | 0 表示永不触发，所以至少设成 1 |
| `base + 0x2000 + 0x80 * ctx` | 上下文 `ctx` 的使能位图（第一个字对应中断源 0..31） | 第 `irq` 位置 1 |
| `base + 0x20_0000 + 0x1000 * ctx` | 上下文 `ctx` 的优先级阈值 | 只有优先级 > 阈值的中断才会送达；设 0 接收所有 |
| `base + 0x20_0004 + 0x1000 * ctx` | 上下文 `ctx` 的 claim/complete | 读 = 领取（claim），写 = 完成（complete） |

都是 32 位寄存器，用 `*volatile u32` 访问。

### 初始化

```zig
pub fn init(disk_irq: u32) void {  // 启动 hart 调用一次；disk_irq 是磁盘的中断源，没有磁盘时是 0
    for ([_]u32{ uart0_irq, disk_irq }) |irq| {
        if (irq == 0) continue;
        priority(irq).* = 1;
        enabled |= @as(u32, 1) << @intCast(irq);
    }
}

pub fn initHart() void {           // 每个 hart 调用一次
    enable().* = enabled;
    threshold().* = 0;
    riscv.set(.sie, riscv.sie_seie);
}
```

中断源的优先级是全局的，设一次；使能位图、阈值是每个上下文的，`sie` 是每个 hart 的，每个 hart 自己设。最后一步打开 `sie.SEIE`：S 模式外部中断使能。之后只要 PLIC 有中断送给这个上下文，这个 hart 的 `sip.SEIP` 就会置位。

**串口、磁盘中断发给每个 hart**（和 xv6 的 `plicinithart` 一样）：每个上下文都使能了串口的 10 号源和磁盘的中断源（[disk.md](disk.md#qemu-的磁盘)，QEMU 上是 1 号），PLIC 把它同时送给所有 hart，谁先 `claim` 到谁处理，别的 hart 再 `claim` 时拿到 0，什么也不做。只发给一个 hart 也行，但那个 hart 正在 U 模式里跑一个死循环的进程的话，也照样会被打断，没有什么好处；发给所有 hart，空闲的 hart（在 `wfi`）能最快处理。

### claim / complete

外部中断处理（`trap.handleExternal`）：

1. `plic.claim()` 读当前 hart 的上下文的 claim 寄存器，得到当前优先级最高的待处理中断号；PLIC 同时把它标记为“处理中”。读到 0 表示没有（被别的 hart 抢先领取了），直接返回。
2. 按中断号分发：10 号交给 `uart.onInterrupt()`；其他号打印一条 `[trap] unexpected external interrupt N`。
3. `plic.complete(irq)` 把中断号写回同一个寄存器，告诉 PLIC 处理完了。在此之前 PLIC 不会再投递同一个中断源。

## 定时器（`timer.zig`）

```zig
pub const slice_ms = 10;                          // 时间片的长度
var timebase_hz: u64 = undefined;                 // time CSR 每秒增加多少，来自设备树
var boot_time: u64 = undefined;                   // 打开时钟时的 time，uptime 从这里算
var slice_end: [hart.max]?u64 = @splat(null);     // 每个 hart 正在运行的进程的这一片在哪结束
pub var lock: Spinlock = .init("timer", .cond);   // 保护 sleepers
var sleepers: ?*Sleeper = null;                   // sleep 里的进程，按到期时刻排好
var earliest: std.atomic.Value(u64);              // 最早的 sleeper 的到期时刻，没有是 maxInt
```

没有固定频率的 tick（tickless）。原来照 xv6，每个 hart 每 10 ms 一次时钟中断，启动 hart 给全局的 `ticks` 加 1，`sleep` 的进程每个 tick 都被叫醒、自己数时间到了没有；空闲的 hart 也每秒被打断 100 次。现在时钟中断只在有事要做的时候来：

- **计时**：`time` CSR 以 timebase 频率递增，QEMU `virt` 上是 10 MHz，所有 hart 读到的是同一个时钟（频率来自设备树 `/cpus` 的 `timebase-frequency`，[devicetree.md](devicetree.md)）。`uptimeMs()` 直接用 `time` 减去 `boot_time` 换算成毫秒，不数中断，不用锁，也就没有“中断处理晚了、计时慢下来”的问题。
- **时间片**：调度器切到一个进程之前调用 `startSlice()`，记下 `slice_end = 现在 + 10 ms`。时钟中断来了、而且已经过了这个时刻，`onInterrupt()` 返回 true，陷阱处理程序让 U 模式的进程让出 CPU（[trap.md](trap.md#分发)）。进程切回调度器之后 `endSlice()` 清掉。用完了的这一片在 `onInterrupt` 里也马上清掉：不然重新预约的时刻已经过去，进程让出之后调度器一开中断就又来一次中断，处理完又预约这个过去的时刻，调度器就卡在开中断的那一条指令上（开发时真的这样卡住过）。
- **sleep**：`sleepUntil(deadline)` 在调用者的内核栈上放一个 `Sleeper`（到期时刻、链表指针、一个只有它自己的 `WaitQueue`），按到期时刻插进 `sleepers`，排在自己的队列里睡下。到期时 `onInterrupt()` 拿着 `lock` 从头摘下所有到期的，叫醒它们。被 `kill` 叫醒的自己从 `sleepers` 里摘掉。精度不再是 10 ms，而是从到期到中断被处理的那段延迟。
- **预约**：`arm()` 通过 `sbi.setTimer` 预约这个 hart 的下一次时钟中断：在运行进程的话是 `slice_end` 和 `earliest` 中早的那个；空闲的话只看 `earliest`；都没有就预约 `maxInt`，也就是不要时钟中断（`setTimer` 同时清掉已经挂起的时钟中断）。调度器每一轮都重新预约：切到进程之前（`startSlice`），`wfi` 之前（`stopSlice`）；时钟中断处理完也重新预约。
- **为什么不会漏掉一个 sleeper**：`arm` 不拿锁读 `earliest`，可能读到旧的值。但新的 sleeper 是它所在的 hart 排进去的，这个 hart 接着就切回调度器、重新预约，读到的一定是自己写的新值，所以至少它的定时器盖住了新的最早时刻。到期时处理它的 hart 叫醒它之后重新预约，带上下一个最早的。几个 hart 可能都预约了同一个时刻，先拿到 `lock` 的叫醒，别的发现没有到期的、各自重新预约。
- **空闲的 hart 靠核间中断叫醒**：空闲的 hart 没有 sleeper 时不预约时钟中断，`wfi` 一直睡到别的中断。原来别的 hart 叫醒进程时漏发核间中断，空闲的 hart 最多 10 ms 后也会被时钟中断叫醒；现在不会了，所以“让进程变成 runnable 只经过 `makeRunnable`（它发核间中断）”更是不能破坏（[process.md](process.md#核间中断)）。
- **初始化**：`init(hz)` 由启动 hart 调用一次，记下频率和 `boot_time`；`initHart()` 每个 hart 调用一次，打开自己的 `sie.STIE`，先不预约。
- **实测**：4 个 hart、shell 空闲 5 秒，`kstat` 的 `timer_interrupts` 从 2004 次（每个 hart 100 Hz）变成 4 次。`t_sleep` 的 `sleep(200)` 前后都量到约 200 ms。

时钟中断在 U 模式下同样会发生（`sret` 进入 U 模式时 `SPIE = 1`），这是内核能从死循环的用户程序手里拿回 CPU 的原因。

## 中断路径汇总

| 中断 | `scause` | 来源 | 处理 |
| --- | --- | --- | --- |
| S 模式时钟中断 | 中断 5 | OpenSBI 按 `setTimer` 的预约触发，每个 hart 各自的 | `timer.onInterrupt()` |
| S 模式外部中断 | 中断 9 | PLIC：串口（10 号源）、virtio 磁盘（1 号源），送给所有 hart | `plic.claim()` → `uart.onInterrupt()` 或 `virtio_disk.onInterrupt()`（[disk.md](disk.md#中断oninterrupt)）→ `plic.complete()` |
| S 模式软件中断 | 中断 1 | 核间中断（IPI）：别的 hart 通过 SBI 发来，叫醒空闲的 hart、打断运行着被杀进程的 hart | `ipi.onInterrupt()`：清掉 `sip.SSIP`（[process.md](process.md#核间中断)） |

这三类都在 `mideleg` 里委托给了 S 模式（OpenSBI 设置的 `MIDELEG = 0x1666`）。陷阱分发的细节见 [trap.md](trap.md)。
