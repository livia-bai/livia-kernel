# Sv39 分页

涉及文件：`src/vm.zig`（以及 `linker.ld` 里的段边界符号；调用方：`src/main.zig`、`src/proc.zig`、`src/syscall.zig`）

## Sv39 基础

Sv39 是 RV64 上最常用的分页模式：虚拟地址有效位 39 位（512 GiB），物理地址最多 56 位。

### 地址拆分

```
 38        30 29        21 20        12 11            0
+------------+------------+------------+---------------+
|   VPN[2]   |   VPN[1]   |   VPN[0]   |   页内偏移     |
|   9 位     |   9 位     |   9 位     |   12 位        |
+------------+------------+------------+---------------+
```

第 39..63 位必须等于第 38 位（符号扩展），否则访问会触发缺页异常。这个内核只用低半部分（第 38 位为 0），所以虚拟地址都小于 `0x40_0000_0000`。

### 三级页表

每张页表 512 项、每项 8 字节，正好一页（4 KiB）。翻译过程：

1. 从 `satp` 里取根页表的物理页号，用 VPN[2] 索引得到一项。
2. 这一项无效（V = 0）→ 缺页异常。
3. R/W/X 中有一位为 1 → 这是**叶子**，翻译到此为止。
4. R/W/X 全为 0 → 这一项指向下一级页表，用 VPN[1]（再下一级用 VPN[0]）继续。第 0 级的项必须是叶子。

在不同级停下的叶子映射的大小不同：

| 叶子所在级 | 映射大小 | 对齐要求 |
| --- | --- | --- |
| 第 2 级（根） | 1 GiB | 虚拟地址和物理地址都 1 GiB 对齐 |
| 第 1 级 | 2 MiB | 都 2 MiB 对齐 |
| 第 0 级 | 4 KiB | 都 4 KiB 对齐 |

### 页表项

```
 63  54 53                        10 9  8 7 6 5 4 3 2 1 0
+------+----------------------------+----+-+-+-+-+-+-+-+-+
| 保留 |            PPN             |RSW |D|A|G|U|X|W|R|V|
+------+----------------------------+----+-+-+-+-+-+-+-+-+
```

| 位 | 含义 |
| --- | --- |
| V | 有效 |
| R / W / X | 可读 / 可写 / 可执行；全 0 表示指向下一级页表。W = 1 且 R = 0 是保留组合，不能用 |
| U | U 模式可以访问。S 模式默认**不能**访问 U 页（除非 `sstatus.SUM = 1`），也永远不能执行 U 页里的代码 |
| G | 全局映射：在所有地址空间里都存在，切换地址空间时不需要作废 TLB 里的这一项 |
| A / D | 访问过 / 写过。规范允许硬件在它们为 0 时直接产生缺页异常，而不是自动置位 |
| RSW | 留给软件用。这里用第 8 位标记写时复制的页（`cow`，见[写时复制](#写时复制)），第 9 位没用 |
| PPN | 物理页号 = 物理地址 >> 12，44 位 |

## 数据类型

```zig
pub const Pte = packed struct(u64) {
    v: bool = false, r: bool = false, w: bool = false, x: bool = false,
    u: bool = false, g: bool = false, a: bool = false, d: bool = false,
    cow: bool = false, rsw: u1 = 0,   // RSW 的两位：第 8 位标记写时复制的页
    ppn: u44 = 0,
    reserved: u10 = 0,
};
pub const PageTable = [512]Pte;
pub const Perm = struct { r: bool = false, w: bool = false, x: bool = false, u: bool = false };
pub const MapError = error{ OutOfMemory, AlreadyMapped };
```

`packed struct(u64)` 的字段从最低位开始排，和硬件格式一一对应，编译器保证总共正好 64 位。

**A 和 D 总是直接置 1。** 这个内核不靠它们统计页面访问情况，预先置位可以避免“硬件不自动置位、要靠缺页异常让软件来置位”这种实现带来的额外缺页。

## 建立映射

```zig
pub fn map(root: *PageTable, va: usize, pa: usize, size: usize, perm: Perm) MapError!void
```

把虚拟地址 `[va, va+size)` 映射到物理地址 `[pa, pa+size)`。

**前提**（用 `std.debug.assert` 检查，Debug/safe 模式下违反会 panic）：

- `va`、`pa`、`size` 都按 4 KiB 对齐。
- 叶子权限合法：`r` 或 `x` 至少有一个，有 `w` 就必须有 `r`。R/W/X 全为 0 的“叶子”会被 CPU 当成指向下一级页表的指针，后果很严重（见 [process.md](process.md#elf-加载器) 里“为什么一定要拒绝不可读的段”）。
- 用户映射（`perm.u`）必须完全落在 `[user_base, user_end)` 里；内核映射不能和这个范围有任何重叠（原因见下文“用户地址空间”）。

**算法**：从 `offset = 0` 开始，每一步选一个尽量大的页：

```zig
const level: u2 = for ([_]u2{ 2, 1 }) |l| {
    const s = levelSize(l);
    if ((va + offset) % s == 0 and (pa + offset) % s == 0 and size - offset >= s) break l;
} else 0;
```

也就是：当前的虚拟地址和物理地址都按 1 GiB 对齐、剩余长度也够 1 GiB，就用 1 GiB 的页；否则试 2 MiB；都不行就用 4 KiB。然后用 `walk` 找到那一级的页表项，已经有效就返回 `AlreadyMapped`，否则写入叶子：`v = 1`、权限来自 `perm`、`g = !perm.u`、`a = d = 1`、`ppn = (pa + offset) >> 12`。

```zig
fn walk(root: *PageTable, va: usize, level: u2) MapError!*Pte
```

从根页表往下走到第 `level` 级，途中遇到无效的项就用 `page.alloc()` 分配一张清零的新页表、填一个指向它的非叶子项（只有 V = 1）。途中遇到叶子说明这段地址已经被一个大页覆盖，返回 `AlreadyMapped`。

`map` 失败时已经建好的那部分映射和页表不会回滚。内核页表失败了直接 panic；用户地址空间失败了，整个地址空间会被 `destroyUserSpace` 一起释放，所以都没有问题。

## 内核页表

```zig
pub fn init(memory: dtb.Region, guards: []const usize) MapError!void
fn mapExcept(root: *PageTable, start: usize, end: usize, holes: []const usize, perm: Perm) MapError!void
```

`kmain` 在页分配器初始化之后调用它，`guards` 是内核栈下面的保护页（`kstack.guardPages()`，按地址排好序，[process.md](process.md#进程表)）。所有内核映射都是**恒等映射**（虚拟地址 = 物理地址），不带 U 位，带 G 位：

| 范围 | 来自 | 权限 | Debug 模式实测 | 页大小 |
| --- | --- | --- | --- | --- |
| `[__text_start, __rodata_start)` | 代码 | R-X | `0x80200000..0x8027d000` | 4 KiB |
| `[__rodata_start, __data_start)` | 只读数据（含 `.eh_frame`、嵌入的 init 的 ELF） | R-- | `0x8027d000..0x802bf000` | 4 KiB |
| `[__data_start, __kernel_end)` 去掉 80 个保护页 | `.data`、`.bss`、每个 hart 的启动栈和陷阱栈、进程内核栈 | RW- | `0x802bf000..0x804d0000` | 4 KiB |
| `[__kernel_end, 内存末尾)` | 页分配器管理的内存、设备树 | RW- | `0x804d0000..0x88000000` | 到 `0x80600000` 为止用 4 KiB，之后 61 个 2 MiB |
| 串口 | `uart.base`、`uart.mmio_size` 向上取整到页 | RW- | `0x10000000..0x10001000` | 4 KiB |
| PLIC | `plic.base`、`plic.mmio_size` | RW- | `0x0c000000..0x0c600000` | 3 个 2 MiB |
| virtio-mmio | `virtio_disk.mmio_base`、`virtio_disk.mmio_size`（8 个槽位） | RW- | `0x10001000..0x10009000` | 4 KiB |

整张内核页表一共 6 页（Debug 模式；内核镜像小一些的模式下，`__kernel_end` 没过 `0x8040_0000` 的话少一张第 0 级页表）：

```
根页表
├─ [0] → 第 1 级页表 A
│        ├─ [0x60..0x62]  PLIC 的 3 个 2 MiB 叶子
│        └─ [0x80] → 第 0 级页表（串口 1 项、virtio-mmio 8 项）
└─ [2] → 第 1 级页表 B
         ├─ [1] → 第 0 级页表（0x8020_0000..0x8040_0000：内核镜像按段的 4 KiB 叶子，保护页的项是空的）
         ├─ [2] → 第 0 级页表（0x8040_0000..0x8060_0000：内核镜像的剩下部分 + 之后的空闲内存）
         └─ [3..63]  0x8060_0000..0x8800_0000 的 61 个 2 MiB 叶子
```

临时在 `vm.init` 前后打印空闲页数实测过：少了 6 页，就是这 6 页。

**保护页**：`[__data_start, __kernel_end)` 用 `mapExcept` 映射，跳过 `guards` 里的页：洞之间的每一段照常调用 `map`（能用大页就用大页）。保护页本身是 `.bss` 里的物理内存，只是没有映射，内核不再访问它们（`_start` 清零 `.bss` 时还没开分页，清的是物理地址）。内核栈往下溢出碰到它就缺页（[trap.md](trap.md#内核栈溢出)）。80 页 = 8 个 hart 的启动栈 + 8 个 hart 的陷阱栈 + 64 块进程内核栈，各一页。以前这里没有洞，整段可以用一张第 0 级页表、少量的叶子映射；挖洞之后第 0 级页表多了一张（因为内核镜像变大了，过了 `0x8040_0000`），叶子还是 4 KiB 的，数量不变。

几点说明：

- **为什么是恒等映射**：写 `satp` 的那一刻 CPU 就开始翻译地址，正在执行的代码地址必须在新页表里映射到同一个物理地址，否则下一条指令就会取错。恒等映射一次性解决这个问题，也让页分配器给出的物理地址可以继续直接当指针用（分配页表、往用户页里复制数据都靠这一点）。
- **按段设权限**带来的保护：往代码或只读数据里写会触发写缺页（`store_page_fault`），跳到数据或空闲内存里执行会触发取指缺页。这要求各段按页对齐，见 [boot.md](boot.md#链接脚本)。开发时用一段临时代码验证过：往 `kmain` 所在的代码页写一个字，得到 `store_page_fault`。
- **不映射的地方**：内核之前的 `0x8000_0000..0x8020_0000`（其中 `0x8000_0000..0x8006_0000` 是 OpenSBI，PMP 本来就不让 S 模式访问；后面是空着的，内核用不到）；地址 0 附近（空指针解引用变成 `load_page_fault`）；设备树里的其他外设（RTC、PCIe 等，内核不用）。
- 开始映射前检查内核镜像是否完全在设备树报告的内存范围里，不在就 panic（`kernel image is outside of RAM`）。
- 单元测试 `mapExcept 跳过保护页，两边照常映射` 检查了洞里的页没有映射、别的页都恒等映射。启动时 `kmain` 还做一次自检（`trap.probeGuard`）：把 `sp` 挪到启动栈的保护页上沿再往栈上写，必须缺页、并且在陷阱栈上处理完回来（[boot.md](boot.md#kmain-的初始化顺序)）。
- **所有 hart 共用这一份内核页表**：启动 hart 在 `vm.init` 里建好、打开分页，其他 hart 启动时调用 `vm.initHart()`，只做 `activate(kernel_root)`（[boot.md](boot.md#启动其他-hart)）。内核页表启动后不再改，所以不用担心别的 hart 的 TLB 里留着旧的内核映射。

## 切换地址空间

```zig
pub fn activate(root: *PageTable) void {
    riscv.write(.satp, .{ .mode = .sv39, .ppn = @intCast(@intFromPtr(root) >> 12) });
    flushUserTlb(); // sfence.vma zero, t0（t0 = 0）：作废 ASID 0 的非全局项
}
```

- `satp` = MODE（最高 4 位，8 = Sv39）| ASID（第 44..59 位，这里一直是 0）| 根页表的物理页号。
- 规范规定写 `satp` 本身不保证之前对页表的修改已经生效，也不会作废 TLB。所以写完之后执行一次 `sfence.vma`：它作废旧地址空间留在 TLB 里的翻译，同时保证之前对页表的写入（可能是这个进程上次在别的 hart 上运行时写的）对之后的页表遍历可见。写 `satp` 之前不用再执行一次：从写 `satp` 到 `sfence.vma` 之间只有几条指令，用到的只有内核映射，而内核映射在每个地址空间里都一样。
- **只作废用户映射**：没有使用 ASID，所有地址空间都是 ASID 0。`sfence.vma` 的 rs2 是 x0 时作废所有地址空间的所有项，连带 G 位的全局项一起；rs2 是别的寄存器时只作废那个 ASID 的**非全局**项。内核映射都带 G 位（`map` 给不带 U 位的映射置上 G），在每个根页表里都一样，所以切换时可以留着；用户映射不带 G 位，都会被作废。ASID 0 也要放进一个寄存器：`riscv.sfenceVmaAsid` 固定用 `t0`，不让编译器挑（常数 0 可能被分配成 `zero` 寄存器，意思就变了）。这要求内核映射一定带 G 位、用户映射一定不带，`map` 里的 `.g = !perm.u` 保证了这一点。
- 启动时（`vm.init`、`vm.initHart` 调用的 `enable`）作废整个 TLB，前后各一次：OpenSBI 留下的翻译一项都不能信。
- 原来每次切换前后各作废一次整个 TLB，调度器切到进程、切回内核页表一来一回 4 次。跑完全部 QEMU 测试（safe、4 核）时，`kstat` 的 `tlb_full_flushes` 从约 7.7 万次变成 4 次（每个 hart 启动时一次），换成了约 4.3 万次只作废用户映射的 `tlb_user_flushes`，大约每次上下文切换 2 次。QEMU 每次写 `satp` 都会清空它自己模拟的整个 TLB，所以在 QEMU 上测不出快了多少（推测）；在真实硬件上，内核映射不再每次都要重新遍历页表。
- **为什么不用 ASID**：用了 ASID，切换时就不用作废用户映射。但一个进程会在几个 hart 之间换来换去，它在 hart 1 上改了自己的页表、只刷了 hart 1 的 TLB，hart 0 的 TLB 里还留着它的 ASID 的旧翻译，回到 hart 0 时就会用错。要像 Linux 那样每个 hart 记着每个 ASID 是哪一代的、用完一轮全部作废，代码多不少，而在 QEMU 上又看不到收益，所以没有做。
- `satp` 和 TLB 都是每个 hart 自己的，`activate` 和 `sfence.vma` 只影响当前 hart。
- `vm.init` 最后调用 `activate(kernel_root)` 打开分页；`proc.scheduler` 每次切到用户进程前切到它的地址空间，进程让出 CPU 后切回 `kernel_root`（父进程可能在别的 hart 上回收它的页表，之前这个 hart 必须先切走，见 [process.md](process.md#调度器)）；`proc.exec` 换地址空间时先切到新的，再释放旧的。一个用户地址空间同一时刻只在一个 hart 上使用，所以改用户页表（`sbrk` 缩小、`fork` 把父进程的页改成写时复制、`breakCow`、按需分页映射上新的页）后只刷当前 hart 的 TLB 就够了（[process.md](process.md#锁)）。写时复制让几个地址空间共用同一个物理页，但页表项是各自的：一个进程复制走自己那一份，只改它自己的页表项，别的进程的 TLB 里留着的还是它们自己的、仍然正确的翻译。

## 用户地址空间

```zig
pub const user_base: usize = 0x4000_0000;
pub const user_end: usize = 0x8000_0000;
```

用户程序只能使用根页表的**第 1 项**覆盖的这 1 GiB。内核的映射都不在这一项里：外设在第 0 项（`0x0..0x4000_0000`），内存从第 2 项开始（`0x8000_0000..`）。这样：

- 新建地址空间只需要复制内核的根页表（512 项，一页）。复制出来的第 0、2 项指向内核的第 1 级页表，**下面的页表全部共用**，不用复制；第 1 项在内核页表里是空的，留给这个进程自己填。
- 进程的映射全部在第 1 项下面，释放时只需要遍历这一项，不会碰到共用的内核页表。
- 陷入内核时不需要切换页表：内核的代码、数据、栈在进程的地址空间里照样映射着，只是没有 U 位，U 模式访问不到。

这就是 `map` 断言“内核映射不能进入用户区”的原因：如果内核往第 1 项里加了映射，它就会出现在之后复制出来的每个进程的根页表里，而且会被进程的映射覆盖或者在释放时被当成进程的页释放掉。

QEMU `virt` 上 `0x4000_0000..0x8000_0000` 其实是 PCIe 的 32 位 MMIO 窗口（设备树 `pci@30000000` 的 `ranges`），但内核不用 PCIe，从不映射它，所以没有冲突。

### 地址空间：Space

```zig
pub const Space = struct {
    root: *PageTable,
    regions: [2 + max_segments]Region,             // 区域表：[0] 栈，[1] 堆，[2..] 程序的段（最多 8 个）
    nregions: usize,
    backing: Backing = .none,                      // 段的内容从哪读
    brk: usize = 0,                                // 堆的末尾（字节）；堆那一项的 end 是它向上对齐到页
    pub fn addSegment(s: *Space, r: Region) error{ Overlap, TooMany }!void
    pub fn setHeap(s: *Space, start: usize) void   // 加载完程序：堆从这里开始，空的
    pub fn setBrk(s: *Space, brk: usize) void      // sbrk
};
pub const Region = struct {
    start: usize, end: usize, perm: Perm,
    source: union(enum) { zero, file: struct { off: u64, size: u64 } },
};
pub const Backing = union(enum) { none, bytes: []const u8, file: u64 };

pub const stack_max = 1 << 20;                     // 用户栈最多 1 MiB
pub const stack_top = user_end;                    // 0x8000_0000
pub const stack_limit = stack_top - stack_max;     // 0x7ff0_0000：栈最低能长到这里
pub const heap_limit = stack_limit - page.size;    // 0x7fef_f000：堆最多长到这里，中间一页是保护页
```

一个进程的用户地址空间（`Process.space`）：根页表，加上按需分页要知道的“哪些地址可以有页、页从哪来”：一张区域表。页表里只有已经访问过的页；用户区里别的地址在区域表里查（`Space.regionOf`）：

| 区域 | 权限 | 一页的内容 |
| --- | --- | --- |
| `regions[0]`：栈 `[stack_limit, stack_top)` | `RW-` | 全是 0（`.zero`） |
| `regions[1]`：堆 `[堆的起点, alignForward(brk))` | `RW-` | 全是 0（`.zero`） |
| `regions[2..]`：程序的每个段 `[start, end)` | 段的权限（ELF 的 `p_flags`） | `.file`：开头最多 4096 字节来自 `backing` 的 `off + 页在段里的偏移`，到 `size` 为止；其余是 0（`.bss`） |

都不在的地址（包括 `[heap_limit, stack_limit)` 这一页保护页、堆末尾之后）不该有页。栈和一个空的堆在 `createUserSpace` 时就放进表里；段由 ELF 加载器加（`addSegment`：按页对齐、不和任何区域重叠、最多 8 个，[process.md](process.md#elf-加载器)），加完之后 `setHeap` 把堆的起点放在所有段之后；`sbrk` 只改堆那一项的末尾（`setBrk`）。原来 `regionOf` 先查段的数组、再特判堆和栈，加一种映射（匿名映射、文件映射）就要改它、`fork` 和 `sbrk`；现在是往表里加一项，`regionOf` 和 `fork`（照抄整张表）都不用动。`backing` 是 `.bytes`（嵌在内核里的 init，单元测试）或者 `.file`（程序文件的 inode，`exec`）。

```zig
pub fn createUserSpace() error{OutOfMemory}!Space
pub fn destroyUserSpace(s: *Space) void
pub fn releaseBacking(s: *Space) void
pub fn allocUserPage(root: *PageTable, va: usize, perm: Perm) MapError!*align(page.size) page.Page
```

- `createUserSpace`：分配一页作为根页表，内容复制 `kernel_root.*`（用 `@memcpy`：`root.* = kernel_root.*` 在 Debug 模式下会先在栈上复制一份 4 KiB），段、堆都是空的。
- `destroyUserSpace`：释放用户区（根页表第 1 项）下面的所有东西：`freeTree` 递归地释放每个有效的叶子指向的物理页、每一张中间级页表，最后释放根页表本身；再 `releaseBacking`。叶子指向的页可能还被别的进程共用（写时复制），`page.free` 只是放掉一个引用，最后一个用它的进程释放时它才回到空闲链表（[page-allocator.md](page-allocator.md#引用数)）。**调用前必须已经切换到别的地址空间**，否则正在使用的页表会被释放。`freeTree` 把叶子都当作 4 KiB 的页释放，这依赖于“用户映射只用 4 KiB 的页”。
- `releaseBacking`：`backing` 是程序文件的话放开对它的占用（`fsys.release(ino, .text)`；名字已经删掉了的话这时删掉它，[fs.md](fs.md#删掉还有人用着的文件)），改成 `.none`。进程结束时（`proc.finish`）就调用：之后不会再缺页了，不用等父进程回收地址空间。
- `allocUserPage`：分配一页清零的物理内存，以 `perm` + U 位映射到用户地址 `va`。现在只有单元测试用它直接摆好页；内核自己的用户页都是按需分配的（`fault`）。用户映射**只用 4 KiB 的页**，每一页单独分配，所以物理上不连续也没关系。

## 按需分页

```zig
pub const Access = enum { read, write, exec };
pub const FaultError = error{ BadAddress, OutOfMemory, CowOutOfMemory, IoError };
pub fn fault(s: *Space, va: usize, access: Access) FaultError!void
```

用户地址 `va` 那一页还没有、或者不允许这样访问时调用。返回之后重新执行那次访问就能成功；返回错误的话，那次访问本来就不该成功，或者没法让它成功：

1. `va` 不在用户区：`BadAddress`。
2. **已经有这一页**（`leafOf`）：
   - 页表项的权限够了：什么都不做，直接返回（TLB 里留着旧的无效项时可能这样）。
   - 要写、是写时复制的页：`breakCow`（[写时复制](#写时复制)），没内存复制是 `CowOutOfMemory`。
   - 别的（写只读的页、执行不可执行的页）：`BadAddress`。
3. **没有这一页**：`regionOf` 找它在哪个区域，不在任何区域里、或者区域的权限不允许这次访问（写代码段、执行数据段、执行堆和栈）是 `BadAddress`，什么都不分配。
4. `page.alloc()` 一页清零的页（没有是 `OutOfMemory`），把文件里的那部分读进来（`Backing.read`：`.bytes` 直接复制，`.file` 是 `fsys.readText`，读不出来是 `IoError`），按区域的权限加 U 位映射上（要新的页表、没有内存时把这一页还回去，`OutOfMemory`），最后刷新这一页的 TLB。读盘要睡着等，所以调用的时候不能拿着锁（见下面）。读盘时进程睡着，但只有它自己会改自己的地址空间，醒来时这一页还是没有，`map` 不会 `AlreadyMapped`。

**谁调用它**：

- **用户程序访问**：陷阱处理程序收到 U 模式的 `load_page_fault`、`store_page_fault`、`instruction_page_fault` 时调用（这时什么锁都没拿），失败时结束进程，原因按错误不同（[trap.md](trap.md#分发)）。
- **内核替用户程序访问**：`copyFromUser`、`copyToUser`、`pinSrc`/`pinDst` 翻译不了一页时调用（[内核访问用户内存](#内核访问用户内存)）。

**为什么这样记区域**：和 xv6 的 lazy allocation 实验一样，只是多了从文件读的段。Linux 用 VMA（`vm_area_struct`）记同样的东西，每个区域有自己的缺页处理；这里只有三种区域，用一个固定大小的结构体就够了，`fork` 时整个复制（`cloneUserSpace`）。

单元测试（`vm.zig` 末尾，用一段 6000 字节的“程序镜像”和两个段）检查了：一开始只有根页表；读代码段的第 2 页只分配这一页和它的页表，文件之外的部分是 0；数据段开头来自镜像、后面是 0、可写，`.bss` 的页整页是 0；写代码段、执行数据段返回 `BadAddress` 并且不分配；同一页缺两次只分配一次；堆的 `brk` 所在页整页能用、下一页不行；栈的两端能用、保护页不行；段不能重叠、最多 8 个；`backing` 是文件、读不出来（单元测试里没挂文件系统）时返回 `IoError`、分配的页还回去，清零的页照常分配；释放后不漏页。

### 内核访问用户内存

```zig
fn translateUser(root: *PageTable, va: usize, write: bool) ?usize
fn userPage(s: *Space, va: usize, write: bool) ?usize
pub fn copyFromUser(s: *Space, dst: []u8, src: usize) error{BadAddress}!void
pub fn copyToUser(s: *Space, dst: usize, src: []const u8) error{BadAddress}!void
pub fn pinSrc(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedSrc
pub fn pinSrcPrefix(s: *Space, va: usize, len: usize) PinnedSrc
pub fn pinDst(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedDst
```

`translateUser` 用软件走一遍页表，把用户虚拟地址翻译成物理地址；要求地址在用户区里，叶子有效、带 U 位、可读（`write` 为 true 时还要可写），否则返回 null。`userPage` 翻译不了时先按缺页处理（`fault`：按需分配、写时复制的页复制一份）再翻译一次，处理不了就是 null。`copyFromUser` / `copyToUser` 在此基础上逐页翻译、逐页复制，是系统调用读写用户内存的途径之一；它们可能缺页、读盘，所以不能拿着锁调用（一开始就检查）。

**拿着锁访问用户内存要先 pin**：内核有不少地方是拿着锁复制用户内存的：写管道拿着管道的锁、写串口拿着输出锁（自旋锁），写文件拿着文件系统的写锁（睡眠锁，而且 `fs.write` 从用户内存取数据时还拿着缓冲区的睡眠锁），`readdir` 拿着读写位置的锁，`wait` 拿着进程的锁写结束状态。这时不能缺页：段里来自程序文件的页要读盘、睡着等，拿着自旋锁不能睡；拿着缓冲区的睡眠锁再去拿别的缓冲区，可能和别的进程互相等。所以这些地方在拿锁之前 pin（`pinSrc`、`pinSrcPrefix`、`pinDst`）：逐页 `userPage`，把页都准备好（写的话写时复制的页也复制好），得到一个 `PinnedSrc` / `PinnedDst`；拿着锁时用它的 `copyIn` / `copyOut`，只调用 `translateUser`，不缺页、不分配，返回 `void`。哪个系统调用 pin 什么见 [syscalls.md](syscalls.md#访问用户内存)。

所以拿着锁时内核不会再为用户内存分配页（以前拿着管道锁、串口的锁复制时碰到清零的页会就地分配，加锁顺序里因此有“`Pipe.lock` → 页分配器”这样的边），`vm.fault` 也不再需要“现在能不能睡”的参数（原来的 `may_sleep` 和 `WouldSleep`）。

单元测试检查了 `copyFromUser` 只读得到 U 模式可读的用户页（不可读的、没映射也不在区域里的、内核的、地址溢出的都是 `BadAddress`），`copyToUser` 只写得进可写的页，pin 检查整个范围（`pinSrcPrefix` 只要开头能读的一段），pin 好之后 `copyIn` / `copyOut` 跨页读写。`t_demand` 在 QEMU 里检查了 `write` 管道、串口、文件的来源是没读进来的只读数据，`read`、`fstat`、`readdir`、`wait` 写进没读进来的数据页，都成功（[testing.md](testing.md#回归测试程序)）。

### 堆的增长和缩小

```zig
pub fn shrinkUser(root: *PageTable, old_end: usize, new_end: usize) void
fn leafOf(root: *PageTable, va: usize) ?*Pte
```

堆按需分配：`sbrk` 变大时只挪 `brk`，新的页第一次被访问时 `fault` 才分配（[process.md](process.md#sbrk堆)）；变小时用 `shrinkUser` 释放。`old_end`、`new_end` 按字节算，页按页：一段内存 `[起点, end)` 占的页是到 `alignForward(end, 4096)` 为止。

- `shrinkUser`：把 `[alignForward(new_end), alignForward(old_end))` 里已经分配了的页找到页表项（`leafOf`，只查不分配；没访问过的页本来就没有，跳过）、还给页分配器、清掉页表项。然后检查这段范围涉及的每个 2 MiB 区域，**第 0 级页表整张都空了就也释放**，清掉指向它的第 1 级页表项。不这样做的话，堆长到 100 多 MiB 再缩回来，每 2 MiB 留下一张空页表（以前一次分配好整个堆时，`t_sbrk` 里实测留下了 62 页）。第 1 级页表整个用户区只有一张，留着：它多半还有栈的映射，空了也只是一页，地址空间释放时一起释放。
- 改的是正在用的页表，调用方（`proc.sbrk`）要 `sfence.vma`。
- 缩小时释放的页可能和子进程共用（`fork` 之后还没写过的堆页），`page.free` 只放掉自己的引用。

单元测试检查：`brk` 挪到 4 MiB 之后只碰三页，只分配这三页和它们的第 0 级页表；缩回去时碰过的页和空出来的页表都释放，没碰过的跳过；再长回来，重新分配的页是清零的；内存不够时缺页失败、一页都不留（页分配到了、页表分配不到时，这一页也还回去）。

### 复制用户地址空间

```zig
pub fn cloneUserSpace(src: *Space) error{OutOfMemory}!Space
fn cloneTree(dst: *PageTable, pte: *Pte, level: u2, va: usize) error{OutOfMemory}!void
```

`fork` 用它给子进程一份地址空间（[process.md](process.md#fork)），**写时复制**（copy-on-write）：页表照 `src` 的结构建一份，用户页一页都不复制。

1. `createUserSpace()` 新建一个根页表（内核部分照常共用）。
2. 遍历 `src` 根页表的用户区（第 1 项），`cloneTree` 递归地往下走：遇到无效项跳过；遇到中间级页表就继续往下，同时算出这一项覆盖的虚拟地址；遇到叶子，先 `walk(dst, va, 0)` 在 `dst` 里建好到第 0 级的页表（缺的现场分配），再：
   - 叶子可写的话，在 `src` 里清掉 W、置上 `cow`；
   - `page.share` 给这个物理页加一个引用；
   - 把（改过的）叶子原样抄进 `dst`：同一个物理页、同样的权限。
3. 中途内存不够时，`errdefer destroyUserSpace(dst)` 把 `dst` 整个释放掉（已经抄过去的叶子各放掉一个引用，正好抵消 `share`）。
4. 段、堆、`backing` 照抄；`backing` 是程序文件的话多占一份（`fsys.dup`）。
5. 最后刷新当前 hart 的 TLB（成功、失败都刷）：`src` 是正在用的地址空间，它的可写页刚变成只读。

`src` 里还没有的页（按需分页，还没访问过），`dst` 里也没有：以后谁访问谁自己分配，段里的页从同一个程序文件读，所以内容和 `src` 的一样（文件在这期间不会变，[fs.md](fs.md#删掉还有人用着的文件)）。

之后父子进程读到的都是同一批物理页。谁先写一个 `cow` 页，谁就触发写缺页（W 是 0），由 `breakCow` 给它复制一份；本来就只读的页（代码、只读数据）不标 `cow`，一直共用，写它照常是用户程序的错。

- 要新分配的只有子进程的页表：一个用户程序通常是根页表 + 第 1 级一张 + 第 0 级两张（段和堆一张、栈一张）= 4 页。`t_cow` 实测：带着 64 页堆的进程 `fork` 之后，子进程刚开始运行时整个系统只多用了 6 页（4 张页表，加上父子两边已经写过的栈页）；改成写时复制之前是 78 页。
- `fork` 之后马上 `exec`（shell 运行程序就是这样）的话，子进程的旧地址空间里一页都没复制过，`exec` 换掉它时只是放掉引用。
- 先建好 `dst` 的页表、再改 `src`：`walk` 失败时这个叶子还没动过。`walk` 返回 `AlreadyMapped` 不可能发生（`dst` 是新的，按 `src` 的结构一页一页地映射），写成 `unreachable`。
- 失败时 `src` 里已经改成 `cow` 的页不改回去：以后写的时候 `breakCow` 发现只剩自己在用，直接改回可写，不用复制，也不用内存。
- 断言叶子都在第 0 级：用户映射只用 4 KiB 的页，所以不会遇到大页。

### 写时复制

```zig
pub const CowError = error{ NotCow, OutOfMemory };
pub fn breakCow(root: *PageTable, va: usize) CowError!void
```

让地址空间 `root` 能写用户地址 `va` 所在的 `cow` 页：

1. `leafOf` 找到第 0 级的叶子（只查不分配）。不在用户区、没有映射、不是 `cow`（本来就只读，或者已经可写）都返回 `NotCow`，什么都不改。
2. `page.isExclusive(旧页)`：还有别的地址空间在用，就分配一页、整页复制、把叶子指向新页，再 `page.free(旧页)` 放掉自己的引用；只剩自己在用（别人已经复制走了，或者已经结束了），就不用复制。
3. 清掉 `cow`、置上 W，用 `sfence.vma va, zero` 只作废这一页的 TLB 项（`riscv.sfenceVmaPage`）。

谁调用它：

- `fault` 发现要写的是已经有的 `cow` 页时调用它：用户程序写 `cow` 页触发 `store_page_fault`，成功就回到原来那条写指令重新执行，内存不够时结束这个进程（`out of memory (copy-on-write)`，[trap.md](trap.md#分发)）；内核往用户内存里写（`copyToUser`、`pinDst`）也经过 `fault`，内存不够时返回 `BadAddress`，系统调用返回 `-EFAULT`（Linux 的 `copy_to_user` 在这种情况下也是返回 `-EFAULT`）。

几点说明：

- **“只剩自己在用”看到了就不会再变**：只有映射着这一页的进程自己 `fork` 才会给它加引用，而这个进程正在这里处理缺页。所以“看到引用数是 1 → 直接改回可写”不需要一直拿着页分配器的锁。
- **两个进程同时在不同的 hart 上复制同一页**：两边都看到引用数是 2，各自分配、复制，然后各放掉一个引用，旧页减到 0 被释放。每一边都是先复制、再放掉引用，所以复制的时候旧页一定还在；放掉之后谁也不再映射它。结果正确，只是多复制了一次。
- 用户栈和全局变量在 `fork` 之后也是共用的：父子进程从系统调用一返回就会写栈，各自复制一两页。
- `vm.zig` 只有这里、`fault`、`cloneUserSpace`（`flushTlb`）和 `activate`、`enable`、`flushUserTlb` 执行 `sfence.vma`，`flushTlb`、`flushUserTlb` 在单元测试里（主机上）什么都不做；其他函数都不执行特权指令。

单元测试（`vm.zig` 末尾）检查：`fork` 只分配了 4 张页表；两边的可写页都变成 `cow`，代码页不是；子进程先写时复制一份，父进程的不变；父进程再写时这一页只剩它在用，不复制、还是原来那一页；代码页、没映射的页、已经复制过的页 `breakCow` 返回 `NotCow`；`pinDst` 把 `cow` 页复制好；三方共用之后依次释放不漏页；`cloneUserSpace` 内存不够时不漏页；没有内存复制时 `breakCow` 返回 `OutOfMemory`、`fault` 返回 `CowOutOfMemory`、`copyToUser`/`pinDst` 返回 `BadAddress`，两边的页表项都不变；`fork` 之后两边都没访问过的页各自按需分配，内容都来自程序镜像。

## 调试技巧

- 想确认映射，可以在 GDB 里用 `monitor info mem`（QEMU 监视器命令，打印当前 `satp` 下的所有映射，相邻且权限相同的会合并成一行）。开分页之后在 `plic.init` 处停下，Debug 模式下的实际输出：

  ```
  vaddr            paddr            size             attr
  ---------------- ---------------- ---------------- -------
  000000000c000000 000000000c000000 0000000000600000 rw--gad     PLIC
  0000000010000000 0000000010000000 0000000000001000 rw--gad     串口
  0000000080200000 0000000080200000 000000000004c000 r-x-gad     .text
  000000008024c000 000000008024c000 0000000000063000 r---gad     .rodata
  00000000802af000 00000000802af000 0000000000151000 rw--gad     .data 到 0x8040_0000（4 KiB 页）
  0000000080400000 0000000080400000 0000000007c00000 rw--gad     其余内存（2 MiB 页）
  ```

  `attr` 依次是 r、w、x、u、g、a、d；内核映射都没有 `u`，都有 `g`。在用户程序运行时停下（比如断在 `syscall.dispatch`），还能看到 `0x4000_0000` 起带 `u` 的用户映射。GDB 的用法见 [testing.md](testing.md#gdb)。
- 想看缺页发生在哪：内核态的缺页会 panic 并打印 `sepc`（出错指令）和 `stval`（出错地址）；QEMU 的 `-d int` 会记录每一次陷阱（[testing.md](testing.md#qemu-的陷阱日志)）。
- 改了内核映射以后，四种优化模式都要跑（`qemu_test.py --all-modes`）：映射错一页往往只在某些模式下才会被访问到（各模式下内核镜像的大小、段边界都不一样）。
