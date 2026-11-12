# 磁盘：virtio 块设备、睡眠锁、缓冲区缓存

涉及文件：`src/virtio_disk.zig`（驱动）、`src/sleeplock.zig`（睡眠锁）、`src/bio.zig`（缓冲区缓存）；调用方：`src/main.zig`（初始化）、`src/trap.zig`（中断）、文件系统（[fs.md](fs.md)）、`src/syscall.zig`（`blockcount`、`readblock`、`writeblock`）

内核有了一块磁盘：QEMU 给 `virt` 机器接一个 virtio 块设备，内核按 4 KiB 一块读写它，中间隔着一层缓冲区缓存。这三部分都照 xv6 的 `virtio_disk.c`、`sleeplock.c`、`bio.c` 写。磁盘的前一部分是文件系统（[fs.md](fs.md)），后一部分是“原始区域”，用户程序可以通过三个系统调用直接读写它的块。

```
系统调用 readblock / writeblock      文件系统（fs.zig → ctree.zig）
   （只能碰原始区域）                        │
        └──────────────┬───────────────────┘
bio.zig：缓冲区缓存（64 块，LRU，每块一把睡眠锁）
        │  Device.transfer(块号, 数据, 读/写)
virtio_disk.zig：组请求、交给设备、睡着等中断
        │  DMA、中断（PLIC 1 号源）
QEMU 的 virtio-blk 设备 → 磁盘镜像文件
```

## QEMU 的磁盘

```sh
-global virtio-mmio.force-legacy=false
-drive if=none,format=raw,id=disk,file=<镜像>[,snapshot=on]
-device virtio-blk-device,drive=disk,bus=virtio-mmio-bus.0
```

- `virt` 机器有 8 个 virtio-mmio 槽位：`0x1000_1000` 起，每个 `0x1000`，第 i 个的中断是 PLIC 的 i + 1 号源（设备树里的 `virtio_mmio@10001000` 等节点，`interrupts = <1>`…`<8>`）。`bus=virtio-mmio-bus.0` 把磁盘接在第 0 个槽位，所以实际用的是 `0x1000_1000`、1 号中断。驱动不假定槽位，启动时逐个找。
- **`force-legacy=false`**：QEMU 默认给 virtio-mmio 设备旧版接口（version 1，要求整个队列在一块按页对齐的内存里，用 `QueuePFN` 指定），驱动只支持现代接口（version 2，三部分各自给地址）。没加这个参数时内核打印 `[warn] virtio disk uses the legacy interface; run QEMU with -global virtio-mmio.force-legacy=false`，当作没有磁盘。
- **磁盘镜像**由 `build.zig` 运行主机上的 `mkfs` 生成：32 MiB（8192 块）。前 7168 块是文件系统，用户程序装在 `/bin` 里；后 1024 块是原始区域，第 b 块（从原始区域的开头算）的第 i 个字节是 `(b * 131 + i) % 251`，回归测试照着它检查读到的内容（[testing.md](testing.md#回归测试程序)）。装到 `zig-out/disk.img`（[build.md](build.md#磁盘镜像)）。`zig build run` 用 `snapshot=on`：写只进 QEMU 的临时覆盖层，退出就丢，镜像不变；`qemu_test.py` 每次启动拷一份新的、不加 `snapshot`，退出之后读镜像文件检查写进去的内容（[build.md](build.md#磁盘镜像)）。
- 没有接磁盘时打印 `[warn] no virtio disk`，`blockcount` 返回 0，`readblock`、`writeblock` 和文件系统的系统调用返回 `-ENODEV`，别的照常。

启动日志（`zig build run` 的 Debug 构建；最后一行是第一个进程挂载文件系统时打印的，见 [fs.md](fs.md#接进内核fsyszig)）：

```
[ok] virtio disk: 8192 blocks of 4 KiB (32 MiB), irq 1, flush
[ok] interrupt sources enabled: timer at 100 Hz, keyboard via UART + PLIC, IPIs, disk
[ok] file system: 6840 of 7168 blocks free, generation 27
```

## virtio 块设备驱动（`virtio_disk.zig`）

virtio 是虚拟机里的“标准设备”：设备和驱动通过一组 MMIO 寄存器协商、配置，真正的请求放在内存里的**virtqueue**（三个数组）里，设备用 DMA 直接读写内存，做完了发中断。规范是 *Virtual I/O Device (VIRTIO) Version 1.2*：2.7 节（split virtqueue）、4.2 节（virtio-mmio）、5.2 节（块设备）。

### 寄存器

每个槽位 `0x1000` 字节，用到的（都是 32 位，`*volatile u32`）：

| 偏移 | 名字 | 用途 |
| --- | --- | --- |
| `0x000` | MagicValue | `0x74726976`（小端的 `"virt"`） |
| `0x004` | Version | 2 = 现代接口，1 = 旧版 |
| `0x008` | DeviceID | 2 = 块设备，0 = 这个槽位没接设备 |
| `0x010` / `0x014` | DeviceFeatures / DeviceFeaturesSel | 设备支持的特性，64 位分两组读，Sel 选第几组 |
| `0x020` / `0x024` | DriverFeatures / DriverFeaturesSel | 驱动接受的特性 |
| `0x030`、`0x034`、`0x038`、`0x044` | QueueSel、QueueNumMax、QueueNum、QueueReady | 选队列、队列最长多少、实际用多长、启用 |
| `0x050` | QueueNotify | 写队列号：告诉设备有新请求 |
| `0x060` / `0x064` | InterruptStatus / InterruptACK | 为什么发中断（第 0 位：有请求做完了）、确认 |
| `0x070` | Status | 初始化进行到哪一步 |
| `0x080..0x0a4` | QueueDesc/Driver/Device Low/High | 描述符表、avail 环、used 环的物理地址（各 64 位） |
| `0x0fc` | ConfigGeneration | 配置空间的版本号，读多个字的配置时用来检测有没有读到一半变了 |
| `0x100` | 块设备的配置空间 | 第一项 `capacity`：容量，512 字节的扇区数，64 位 |

### 初始化（`init`）

kmain 在开分页之后（要访问 MMIO）、`plic.init` 之前（PLIC 要知道中断号）调用。逐个槽位看 MagicValue 和 DeviceID，找到块设备后按规范 3.1.1 的顺序：

1. Status 写 0（复位），置上 ACKNOWLEDGE（看到设备了）、DRIVER（知道怎么驱动它）。
2. **协商特性**：第 1 组只要 `VIRTIO_F_VERSION_1`（第 32 位，在第 1 组的第 0 位，现代接口必须有）；第 0 组只要 `VIRTIO_BLK_F_FLUSH`（第 9 位），设备提供才要。别的一个都不要，所以没有 event idx、间接描述符、多队列、只读盘这些。设备不提供 VERSION_1 就 panic。然后置上 FEATURES_OK，再读回来确认设备接受了。QEMU 的 virtio-blk 提供 FLUSH，启动日志的那一行末尾是 `flush`；不提供的设备规范要求它写完就落盘（write-through），日志里是 `write-through`。
3. **队列 0**：QueueSel = 0，确认它还没在用（QueueReady 为 0）、QueueNumMax 至少 16，QueueNum = 16，三部分的物理地址写进去，QueueReady = 1。
4. 置上 DRIVER_OK，设备开始工作。
5. 读容量：`capacity` 是 64 位，分两次读，前后读两次 ConfigGeneration，不一样就重读。扇区数除以 8 就是块数。

### 队列

```zig
const num = 16;
const Queue = extern struct {
    desc: [num]Desc align(16),      // 描述符表：{ 物理地址, 长度, 标志, 下一个 }
    avail: Avail align(2),          // 驱动 → 设备：{ flags, idx, ring[num] }
    used: Used align(4),            // 设备 → 驱动：{ flags, idx, ring[num]{ id, len } }
    requests: [num]Request,         // 请求头，按请求链第一个描述符的下标
    status: [num]u8,                // 设备写回的状态字节，同上
};
var queue: Queue align(4096) = undefined;
```

- 现代接口的三部分只要求各自对齐（16、2、4），可以分开放；这里放在一个结构体里，一页对齐，好认。它在内核的 `.bss` 里，内核对物理内存是恒等映射，`@intFromPtr` 就是给设备的物理地址。
- **一个请求是三个描述符串成的链**（块设备的请求格式，规范 5.2.6）：请求头 `{ type: 读 0 / 写 1, reserved, sector }`（设备读）→ 数据（4096 字节；读请求时设备往里写，带 `WRITE` 标志）→ 状态字节（设备写，0 是成功）。块号乘 8 就是扇区号。
- **flush 请求**（类型 4，`VIRTIO_BLK_T_FLUSH`）没有数据，链上只有请求头和状态字节。它做完时，之前做完的写都已经落盘。
- `num = 16` 个描述符，一个请求用 3 个，最多同时 5 个请求在设备里。`free` 记哪些描述符空着，`allocDescs(3)` 一次拿三个（flush 只用两个，第二个跟着一起分配、一起放回，省得两种请求分开算）。

### 读写（`rw`、`flush`）

```zig
pub fn rw(block: u64, data: *[block_size]u8, write: bool) void
pub fn flush() void   // 协商到 FLUSH 才发请求，否则什么都不做
```

两个都交给 `submit(类型, 扇区号, 数据或 null)`：

1. 拿 `lock`。分配三个描述符，没有就 `free_waiters.wait(&lock)`，等有请求做完放回描述符。
2. 填请求头、状态字节（先写成 `0xff`）、三个描述符；`info[head].done = false`。
3. 把链的第一个描述符的下标放进 `avail.ring[avail.idx % num]`，**`fence`**，`avail.idx += 1`，**`fence`**，写 QueueNotify。设备看到新的 `idx` 时，前面写的描述符和 ring 必须已经可见；写 QueueNotify（MMIO）之前，`idx` 也必须已经可见。
4. `while (!info[head].done) info[head].waiters.wait(&lock)`：进程睡着等，CPU 给别的进程。
5. 醒来后看状态字节，不是 0 就 panic（QEMU 上只有内核给错了参数才会出现）；放回描述符，`free_waiters.wakeAll(&lock)`。

**写缓存**：写请求做完只说明设备收到了数据。设备（真实的磁盘，或者 QEMU 背后宿主机的页缓存）可能还把它放在缓存里，掉电会丢，几次写落盘的先后也不保证。写时复制的文件系统恰恰依赖顺序（新节点先落盘、超级块后落盘，[btree.md](btree.md#事务和提交)），所以提交时在超级块前后各 `flush` 一次。

队列结构通过 `*volatile Queue` 访问：设备在另一边改 `used`，编译器不能把读 `used.idx` 提到循环外面，也不能合并、省掉对描述符的写。

只能由进程调用（要睡下）。数据在设备读写期间不能被别人碰：调用方（`bio`）拿着这个块的睡眠锁。

### 中断（`onInterrupt`）

```zig
reg(.interrupt_ack).* = reg(.interrupt_status).* & 0x3;
while (used_idx != used.idx) {
    const id = used.ring[used_idx % num].id;   // 做完的请求链的第一个描述符
    info[id].done = true;
    info[id].waiters.wakeAll(&lock);
    used_idx +%= 1;
}
```

- `handleExternal` 从 PLIC claim 到磁盘的中断号时调用它（[trap.md](trap.md#分发)）。和串口一样，这个中断源发给所有 hart，谁先 claim 到谁处理（[devices.md](devices.md#plicpliczig)）。
- 先确认、再看 used 环：确认之后设备又做完的请求会再发一次中断，不会漏。一次中断可能对应好几个做完的请求（设备可能攒着一起报），所以循环处理到 `used.idx`。
- `used_idx`、`avail.idx` 都是 16 位、只增不减，`+%=` 回绕，对 `num` 取模就是下标（`num` 是 2 的幂，回绕时取模的结果是连续的）。
- `wakeup` 叫醒的进程可能在别的 hart 上运行，核间中断让空闲的 hart 马上来（[process.md](process.md#核间中断)）。

### 锁

`virtio_disk.lock`（自旋锁）保护队列、描述符的分配、`info`、`used_idx`。`rw` 拿着它睡下（`sleep` 放开它），中断处理程序拿着它叫醒进程，所以“检查 `done` → 睡下”和“设 `done` → 叫醒”不会交错，不会丢掉叫醒。加锁顺序：`virtio_disk.lock` → 进程锁。

## 睡眠锁（`sleeplock.zig`）

```zig
pub const Sleeplock = struct {
    name: []const u8,
    rank: Rank,                    // 等级：file_pos、fs_write、buf，检查加锁顺序
    lk: Spinlock,                  // 保护 locked、holder（等级 cond）
    locked: bool = false,
    holder: ?*proc.Process = null, // 拿着它的进程
    pub fn acquire(l: *Sleeplock) void
    pub fn release(l: *Sleeplock) void
    pub fn holding(l: *Sleeplock) bool
};
```

和 xv6 的一样：`acquire` 拿着 `lk` 检查 `locked`，被别人拿着就排进 `waiters` 睡下（`l.waiters.wait(&l.lk)`），`release` 清掉 `locked` 再 `l.waiters.wakeAll(&l.lk)`。和自旋锁的区别：

- **等锁时睡着**，不占 CPU 空转。拿着锁的进程可能正在等磁盘，拿着自旋锁等的话，别的 hart 上要同一把锁的进程都得陪着转。
- **拿着它可以睡觉**（等磁盘、等别的睡眠锁）。自旋锁不行：`sched` 只允许拿着自己的进程锁。反过来，拿睡眠锁之前不能拿着自旋锁（`acquire` 一开始就检查，原来要等到真的睡下、`sched` 发现时才 panic）。
- **有等级**（`Rank`）：`file_pos` → `fs_write` → `buf`，只能从低往高拿，`buf` 可以同时拿几把（[process.md](process.md#锁)）。
- **只有进程能拿**：要能睡下。调度器、`kmain`、中断处理程序都不能拿，所以磁盘也只能由进程读写（`kmain` 不读盘）。
- 记下的是拿着它的进程（`holder`，指针），不是 pid：读 pid 要拿进程锁。
- 自己再拿一次是死锁，直接 panic（`acquire: sleeplock buf is already held by this process`）；放开不是自己拿的锁也 panic。
- **回到 U 模式时不能拿着睡眠锁**：每个进程记着自己拿着每一级的几把（`Process.sleeplocks`，只有自己改，不用加锁），`handleTrap` 末尾和 `forkretC` 检查它们都是 0（`proc.assertNoLocksHeld`，和检查自旋锁放在一起）。

## 缓冲区缓存（`bio.zig`）

```zig
pub const nbuf = 64;
const nbucket = 13;
pub const Buf = struct {
    lock: Sleeplock,     // 保护 valid、data
    refcnt: u32,         // 桶的锁：几个人拿着或在等
    blockno: u64,        // 桶的锁：装的是哪一块，决定在哪个桶里（还没装过块的是 maxInt）
    stamp: u64,          // 桶的锁：最后一次变成没人用的时刻（LRU）
    valid: bool,         // data 是不是这一块在磁盘上的内容
    node: std.DoublyLinkedList.Node,   // 桶里的链表
    data: *align(4096) [block_size]u8,
};
pub const Device = struct { blocks: u64, transfer: *const fn (u64, *[block_size]u8, bool) void };

pub fn init(dev: ?Device) void
pub fn read(blockno: u64) Error!*Buf    // 拿着睡眠锁返回，内容是磁盘上的
pub fn get(blockno: u64) Error!*Buf     // 拿着睡眠锁返回，不读磁盘（要整块覆盖时用）
pub fn load(b: *Buf) bool               // 内容无效就从磁盘读进来，返回这次是不是真的读了盘
pub fn write(b: *Buf) void              // 写回磁盘，写完才返回
pub fn release(b: *Buf) void
pub fn blockCount() u64
```

作用有两个，和 xv6 的一样：

1. **缓存**：最近用过的块留在内存里，再读不用等磁盘。
2. **同一块在内存里只有一份，同时只有一个进程用**：`read`/`get` 返回时拿着这一块的睡眠锁，别的进程要同一块就睡着等。

**按块号散列的桶**（xv6 lock lab 的 bcache）：缓冲区按 `blockno % 13` 分进 13 个桶，每个桶一把自旋锁和一个链表。xv6 原来是一把锁管整个缓存，几个 hart 同时读不同的块（文件系统的读者在快照上并发读，[fs.md](fs.md#接进内核fsyszig)）也要抢这一把锁；分桶之后，块已经在缓存里时只拿它那一个桶的锁。桶的个数取质数，块号连续的块散到不同的桶里。

**LRU 用时间戳**：没有全局的 LRU 链表了（维护它又要一把全局的锁）。缓冲区变成没人用（`refcnt` 减到 0）时，从一个原子计数器 `clock` 取下一个值记进 `stamp`；换块时换掉所有没人用的缓冲区里 `stamp` 最小的。xv6 lock lab 用的是 `ticks`，同一个 tick 里放开的分不出先后；计数器每次加 1，先后是精确的（单元测试检查换掉的就是最久没用的那一块）。

### 找缓冲区（`get`）

1. 拿块号对应的桶的锁，在桶里找 `blockno` 相同的。找到了就 `refcnt += 1`，放开桶的锁，再拿缓冲区的睡眠锁：可能要睡着等别的进程用完。`refcnt` 在放开桶的锁之前加，所以别人没法在“找到了”和“拿到睡眠锁”之间把这个缓冲区换成别的块。
2. 没有就放开桶的锁，**换块**（`evict`），拿着 `evict_lock`：
   1. 再在桶里找一次：放开桶的锁到拿到 `evict_lock` 之间，别的进程可能刚把这一块换进来。换进来都要拿着 `evict_lock`，所以拿着它查一次就够了，之后没人能再换进同一块：**同一块在缓存里不会有两份**。
   2. 依次看每个桶（`takeOldest`），找 `refcnt == 0`、`stamp` 最小的缓冲区。一直拿着目前最好的候选所在的桶的锁，找到更好的才换成新的桶，这样候选的 `refcnt` 不会在找完之前被别人加上去。最后把它从原来的桶里摘下来，改成这一块（`valid = false`、`refcnt = 1`），挂进新的桶。摘下来到挂进去之间它不在任何桶里，别人找不到它。
   3. 都有人在用（64 个都有人拿着）就 `evict_waiters.wait(&evict_lock)`，等有人 `release`。xv6 在这里 panic。
3. 换来的缓冲区同样再拿睡眠锁。

**两把桶的锁同时拿只发生在换块的时候**，而换块拿着 `evict_lock`，一次只有一个进程在换，所以不会互相等。顺序是 `evict_lock` → 桶的锁；找已经缓存着的块只拿一把桶的锁，拿着它不再拿别的锁。

**等空闲缓冲区不会丢 wakeup**：换块的进程先把 `evicting` 加 1（拿着 `evict_lock`、找之前），找完才睡；`release` 拿着桶的锁把 `refcnt` 减到 0、放开之后看 `evicting`，不为 0 才拿 `evict_lock` 去 `wakeup`。如果 `release` 在换块的进程看那个桶之前减到 0，换块的进程会看到它；如果在之后，那时 `evicting` 早已加过（同一把桶的锁保证了先后），`release` 就会来拿 `evict_lock`，而换块的进程睡下之前一直拿着它，所以 `wakeup` 一定在它睡下之后。平时没人在换块，`release` 不碰 `evict_lock`。

**等下去不会死锁**：同时拿着好几个缓冲区的只有修改文件系统的一方（B 树的一条路径加上分裂出来的节点，再加一两个数据块，不到 20 个），而修改之间一个一个来（文件系统的写锁）；文件系统的读者、`readblock`、`writeblock` 一次只拿一个，拿着它的时候不去等别的缓冲区，用完就放开。所以修改的一方要等的缓冲区，迟早会被别人放开。

`read` = `get` + `load`：`valid` 为 false 时 `device.transfer(blockno, data, false)` 读进来。`load` 返回这次是不是真的读了盘，写时复制 B 树只在读盘时验节点的校验和（[btree.md](btree.md#节点格式btreezig)）；发现内容不对的调用方把 `valid` 设回 false，下次重新读盘。几个进程同时 `read` 同一块时，第一个拿到睡眠锁的去读盘，后面的醒来时看到 `valid` 已经是 true，不再读。

`get` 给要整块覆盖的调用方用：`writeblock` 系统调用整块写，不用先读旧的内容。覆盖完自己把 `valid` 设成 true 再 `write`。

### 写和放开

- `write` 要求拿着睡眠锁、`valid` 为 true，同步写回磁盘（write-through）：返回时数据已经交给设备了，但设备有写缓存的话还不一定落盘。
- `flush` 等之前 `write` 过的块都落盘（交给 `Device.flush`；为 null 的设备没有写缓存，什么都不做）。
- `invalidate` 逐个桶拿锁，把 `refcnt` 为 0 的缓冲区都标成 `valid = false`，之后再读它们都要重新读盘。给 `scrub` 用：校验和只在读盘时核对，要核对磁盘上的内容就不能用缓存里的（[fs.md](fs.md#检查整个文件系统checkscrub)）。写都是同步的，缓存里没有还没写下去的内容，作废不会丢东西；`valid` 本来由缓冲区的睡眠锁保护，`refcnt` 为 0 说明没人拿着、也没人在等这把睡眠锁，所以拿着桶的锁改它也安全。
- `release` 放开睡眠锁，拿桶的锁 `refcnt -= 1`；减到 0 就记下 `stamp`，有人在换块（`evicting` 不为 0）的话叫醒它。拿着睡眠锁时别人换不掉这个缓冲区，所以 `release` 用 `blockno` 算出来的桶就是它所在的桶。

### 磁盘是可以换的（`Device`）

`bio` 不直接调用 `virtio_disk`，而是通过 `init(dev)` 交进来的 `Device`（块数和一个读写函数）。内核里 `kmain` 交进去 virtio 磁盘：

```zig
bio.init(if (virtio_disk.blocks > 0) .{ .blocks = virtio_disk.blocks, .transfer = virtio_disk.rw } else null);
```

单元测试交进去一块内存，记着读写了几次，在主机上测缓存的行为（命中不读盘、换掉的是最久没用的、拿着的缓冲区不会被换掉、`write` 写回、超出范围、没有磁盘）。B 树、文件系统的单元测试和主机上的 `mkfs` 也这样在内存里跑。

### 锁

- 每个桶的锁（自旋锁）：桶里的链表，桶里每个缓冲区的 `refcnt`、`blockno`、`stamp`。
- `evict_lock`（自旋锁）：换块一个一个来；等空闲缓冲区时拿着它睡下。`evicting`、`clock` 是原子变量。
- 每个缓冲区的睡眠锁：`valid`、`data`。拿着它读写磁盘（睡着等）。
- 顺序：`evict_lock` → 桶的锁（同时拿两个桶的只有拿着 `evict_lock` 的）；先拿桶的锁找到缓冲区、加 `refcnt`，放开，再拿睡眠锁；读写磁盘时拿着睡眠锁去拿 `virtio_disk.lock`。

## 系统调用

| 号 | 调用 | 说明 |
| --- | --- | --- |
| 21 | `blockcount()` | 原始区域有多少块，没有磁盘时是 0 |
| 22 | `readblock(blockno, ptr)` | 原始区域的第 `blockno` 块读进用户内存 `ptr`（4096 字节）。先 `pinDst` 整个目标（检查可写，顺便复制好写时复制的页），再 `bio.read`，拿着缓冲区的睡眠锁 `copyOut` |
| 23 | `writeblock(blockno, ptr)` | 用户内存的 4096 字节写到原始区域的第 `blockno` 块，写完才返回。先 `pinSrc` 来源，再 `bio.get`（不读旧内容）、`copyIn`、`bio.write` |

都返回 0；块号超出原始区域是 `-EINVAL`，没有磁盘是 `-ENODEV`，指针不对是 `-EFAULT`（[syscalls.md](syscalls.md#调用列表)）。先检查指针再碰缓冲区：复制到一半失败的话，缓冲区里会留下半新半旧的内容（写），或者白读一次盘（读）。shell 的 `disk` 命令打印 `blockcount`。

**原始区域**：块号从文件系统之后算起（`fsys.raw_base`，就是超级块里记的文件系统块数），所以这三个调用碰不到文件系统用着的块，不会绕过事务把它写坏。磁盘上没有文件系统时整个磁盘都是原始区域。回归测试 `t_disk` 用它测驱动和缓冲区缓存。

## 限制和以后可以做的

- 只有一个队列、16 个描述符，最多同时 5 个请求在设备里；没有协商 event idx、间接描述符，每个请求都写一次 QueueNotify。
- 设备报错直接 panic，没有把错误交回调用方。
- 缓冲区缓存是 write-through：每次 `write` 都等磁盘写完。以后文件系统的事务可以把一批块攒着一起写。
- 换块要拿 `evict_lock`、扫所有桶，比找缓存着的块慢；缓存一直不命中时，换块的进程之间还是要排队。
