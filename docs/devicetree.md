# 设备树

涉及文件：`src/dtb.zig`（调用方：`src/main.zig`；结果交给 `src/page.zig`、`src/timer.zig`、`src/vm.zig`）

设备树（Devicetree）描述一台机器有哪些硬件：内存在哪、多大，CPU 的时钟频率，各个外设的地址和中断号。QEMU 生成设备树，OpenSBI 在里面补上自己的保留内存后，把它的物理地址放在 `a1` 里交给内核。内核用它代替写死的常量。

目前从设备树里取的是：

| 信息 | 来源 | 用在哪里 |
| --- | --- | --- |
| 物理内存的起点和大小 | `device_type = "memory"` 节点的 `reg` | 页分配器的范围、内核页表映射的范围 |
| `time` CSR 的频率 | `/cpus` 的 `timebase-frequency` | 计时（`time` 换算成毫秒）、时间片和 `sleep` 的到期时刻 |
| 不能分配的内存 | 设备树自身、内存保留块、`/reserved-memory` 的子节点 | 页分配器跳过这些页 |
| 有哪些 hart | `/cpus` 下 `device_type = "cpu"` 的节点的 `reg` | `kmain` 启动其他 hart（[boot.md](boot.md#启动其他-hart)） |

串口、PLIC 的地址和中断号仍然写死在 `uart.zig`、`plic.zig` 里（设备树里也有，见文末“扩展”）。

## 文件格式

扁平设备树（FDT，二进制文件叫 DTB）的格式见 Devicetree 规范第 5 章。**所有整数都是大端序**，RISC-V 是小端，所以每次读取都要转换（`std.mem.readInt(T, bytes, .big)`）。

### 文件头

文件开头 40 字节，10 个 32 位字段：

| 偏移 | 字段 | 含义 |
| --- | --- | --- |
| 0 | `magic` | 固定为 `0xd00dfeed` |
| 4 | `totalsize` | 整个文件的字节数 |
| 8 | `off_dt_struct` | 结构块的偏移 |
| 12 | `off_dt_strings` | 字符串块的偏移 |
| 16 | `off_mem_rsvmap` | 内存保留块的偏移 |
| 20 | `version` | 版本，目前是 17 |
| 24 | `last_comp_version` | 向下兼容的最低版本，目前是 16 |
| 28 | `boot_cpuid_phys` | 启动 CPU 的编号（没用到） |
| 32 | `size_dt_strings` | 字符串块的长度 |
| 36 | `size_dt_struct` | 结构块的长度 |

### 内存保留块

一串 `(address: u64, size: u64)`，以 `(0, 0)` 结尾，列出操作系统不能使用的内存。QEMU + OpenSBI 给的设备树里这一块是空的（OpenSBI 改用 `/reserved-memory` 节点）。

### 结构块

一串 4 字节对齐的 token，按深度优先顺序描述节点树：

| token | 值 | 后面跟着 |
| --- | --- | --- |
| `FDT_BEGIN_NODE` | 1 | 节点名，以 0 结尾，补齐到 4 字节；根节点的名字是空串 |
| `FDT_END_NODE` | 2 | 无 |
| `FDT_PROP` | 3 | `len: u32`、`nameoff: u32`，然后是 `len` 字节的值，补齐到 4 字节 |
| `FDT_NOP` | 4 | 无（被删除的内容留下的占位） |
| `FDT_END` | 9 | 无，结构块结束 |

属性名不直接存在结构块里，`nameoff` 是它在字符串块里的偏移，字符串以 0 结尾。

### reg 和 #address-cells / #size-cells

`reg` 属性是若干个 `(地址, 长度)`，每个数由若干个 32 位“单元”（cell）拼成。单元个数由**父节点**的 `#address-cells` 和 `#size-cells` 决定，规范规定的默认值是 2 和 1。QEMU `virt` 的根节点两者都是 2，所以 `/memory@80000000` 的 `reg = <0x00 0x80000000 0x00 0x8000000>` 读作地址 `0x8000_0000`、长度 `0x800_0000`（128 MiB）。

## QEMU 给的设备树长什么样

只看和内核有关的部分（`dtc` 反编译，节选）：

```dts
/ {
    #address-cells = <0x02>;
    #size-cells = <0x02>;

    memory@80000000 {
        device_type = "memory";
        reg = <0x00 0x80000000 0x00 0x8000000>;
    };

    cpus {
        #address-cells = <0x01>;
        #size-cells = <0x00>;
        timebase-frequency = <0x989680>;      // 10000000
        cpu@0 {
            device_type = "cpu";
            reg = <0x00>;                     // hart 编号
            status = "okay";
            interrupt-controller { ... };
            ...
        };
        cpu@1 { ... reg = <0x01>; ... };      // -smp 4 时到 cpu@3
        cpu-map { cluster0 { core0 { cpu = <0x07>; }; ... }; };   // 拓扑，没有 device_type
    };

    soc {
        plic@c000000 { reg = <0x00 0xc000000 0x00 0x600000>; ... };
        serial@10000000 { interrupts = <0x0a>; reg = <0x00 0x10000000 0x00 0x100>; ... };
    };
};
```

OpenSBI 在交给内核之前加了一个 `/reserved-memory` 节点，登记自己占用的内存（就是启动横幅里 OpenSBI 的代码和数据区域）：

```dts
reserved-memory {
    #address-cells = <0x02>;
    #size-cells = <0x02>;
    ranges;

    mmode_resv1@80000000 {
        reg = <0x00 0x80000000 0x00 0x40000>;
        no-map;
    };

    mmode_resv0@80040000 {
        reg = <0x00 0x80040000 0x00 0x20000>;
        no-map;
    };
};
```

内存保留块是空的。改过的设备树在 `0x87e0_0000`，`totalsize` 是 `0x1516`（5398 字节，占 2 页）。

查看 QEMU 生成的原始设备树（不含 OpenSBI 加的节点；`-smp` 决定 `/cpus` 下有几个 `cpu@N`）：

```sh
qemu-system-riscv64 -machine virt,dumpdtb=virt.dtb -smp 4 -m 128M -nographic -bios default
dtc -I dtb -O dts virt.dtb | less     # dtc 在 device-tree-compiler 包里
```

查看内核实际收到的设备树（含 OpenSBI 的改动），用 GDB 在 `kmain` 停下后把那段内存导出来（GDB 的用法见 [testing.md](testing.md#gdb)）：

```sh
qemu-system-riscv64 -machine virt -smp 4 -m 128M -nographic -bios default -kernel zig-out/bin/kernel -s -S &
gdb-multiarch -q -batch -ex 'set architecture riscv:rv64' -ex 'file zig-out/bin/kernel' \
  -ex 'target remote :1234' -ex 'break main.kmain' -ex 'continue' \
  -ex 'dump binary memory kernel.dtb 0x87e00000 0x87e01516' -ex 'kill'
dtc -I dtb -O dts kernel.dtb | less
```

导出范围是启动日志里 `device tree at` 给出的地址，加上文件头里的 `totalsize`（这台机器上是 `0x1516`；不知道时可以先用 GDB 的 `x/2wx 0x87e00000` 看前 8 字节。GDB 按小端显示，输出是 `0xedfe0dd0 0x16150000`，把字节倒过来就是魔数 `0xd00dfeed` 和 `totalsize = 0x00001516`）。

## 解析器

```zig
pub fn parse(addr: usize) Error!Info         // kmain 用：从地址读出 totalsize，把整个文件当成切片交给 parseBlob
pub fn parseBlob(blob: []const u8) Error!Info // 真正的解析，只看字节，单元测试直接喂数据进来
```

### 不信任输入

设备树是固件给的数据，原则上可能是坏的。解析器的做法是：

1. 只读文件头的前 8 字节（魔数和 `totalsize`），魔数不对立即返回 `BadMagic`。
2. 把 `[addr, addr + totalsize)` 当成一个切片 `blob` 交给 `parseBlob`，**之后的所有读取都通过带边界检查的函数**，越界就返回 `Truncated`：
   - `readBe(T, bytes, offset)`：读一个大端整数。
   - `readStr(bytes, offset)`：读以 0 结尾的字符串，找不到结尾的 0 也是 `Truncated`。
   - `readCells(bytes, offset, cells)`：按单元个数读一个数，只支持 1 或 2 个单元（32/64 位），否则返回 `UnsupportedCells`。
3. 结构块、字符串块各自先切成子切片（检查偏移和长度不超出文件），token 和属性只在各自的子切片里读。
4. `Region.end()` 用饱和加法（`base +| size`），设备树里写了离谱的数值也不会让内核在 Debug 模式下因为整数溢出而 panic。

`version < 16` 或 `last_comp_version > 17` 返回 `UnsupportedVersion`：这里用到的格式在版本 16 就确定了。

### 遍历

用一个栈 `stack: [16]Node` 记录从根节点到当前节点的路径：

```zig
const Node = struct {
    name: []const u8,
    address_cells: u32 = 2,   // 本节点的 #address-cells，给子节点的 reg 用
    size_cells: u32 = 1,      // 本节点的 #size-cells
    is_memory: bool = false,  // 本节点有 device_type = "memory"
    is_cpu: bool = false,     // 本节点有 device_type = "cpu"
    disabled: bool = false,   // 本节点有 status = "disabled"
    reg: ?[]const u8 = null,  // 本节点的 reg 原始字节
};
```

- `BEGIN_NODE`：压栈（超过 16 层返回 `TooDeep`）。
- `PROP`：`handleProp` 根据属性名处理：
  - `#address-cells` / `#size-cells`：记到当前节点上。
  - `device_type`：值等于 `"memory\0"` 时标记 `is_memory`，等于 `"cpu\0"` 时标记 `is_cpu`。
  - `status`：值等于 `"disabled\0"` 时标记 `disabled`。
  - `reg`：只记下原始字节，**不马上解析**。
  - `timebase-frequency`：当前节点是 `/cpus`、或者 `/cpus` 的直接子节点（规范允许写在各个 `cpu@N` 上）时采用，只取第一个。值可以是 4 字节或 8 字节。
- `END_NODE`：处理当前节点记下的 `reg`，然后出栈：
  - 节点是 memory 并且还没找到内存：解析 `reg` 的第一段作为内存范围。
  - 节点在第 3 层、父节点名为 `reserved-memory`：`reg` 里的每一段都加入保留区。
  - 节点在第 3 层、父节点名为 `cpus`、是 cpu 节点、没被禁用：`reg` 的第一个数是 hart 编号，加入 hart 列表（超过 32 个返回 `TooManyHarts`）。`cpu-map` 和 cpu 节点下面的 `interrupt-controller` 没有 `device_type = "cpu"`，不算。
  - 用的是**父节点**（栈里的上一层）的 `#address-cells` / `#size-cells`。
- `NOP`：跳过。`END`：结束。其他值返回 `BadToken`；`END_NODE` 多于 `BEGIN_NODE`、或者 `PROP` 出现在任何节点之外（第一个 `BEGIN_NODE` 之前）也是 `BadToken`。

`reg` 要等到 `END_NODE` 再解析，是因为同一个节点里 `device_type`、`status` 可能排在 `reg` 后面，看到 `reg` 的时候还不知道它是不是内存节点、cpu 节点。

### 结果

```zig
pub const Info = struct {
    memory: Region,
    timebase_hz: u64,
    reserved_buf: [16]Region,
    reserved_len: usize,
    harts_buf: [32]u32,
    harts_len: usize,
    pub fn reserved(info: *const Info) []const Region
    pub fn harts(info: *const Info) []const u32
};
```

保留区按这个顺序加入：设备树自身 `[addr, addr + totalsize)` → 内存保留块的条目 → `/reserved-memory` 的子节点。QEMU 下实测是 3 段：

```
0x87e00000..0x87e01516   设备树自身
0x80000000..0x80040000   /reserved-memory/mmode_resv1@80000000（OpenSBI 代码）
0x80040000..0x80060000   /reserved-memory/mmode_resv0@80040000（OpenSBI 数据）
```

### cpu 节点

hart 列表按节点在设备树里出现的顺序排列，QEMU `-smp 4` 时是 `0 1 2 3`，`-smp 1` 时只有 `0`。启动 hart 自己也在列表里，`startHarts` 会跳过它。列表为空（设备树里没有 cpu 节点）不算错误，那样就只用启动 hart 运行。

最后检查：没找到内存返回 `NoMemory`，没找到时钟频率返回 `NoTimebase`。

### 错误

| 错误 | 含义 |
| --- | --- |
| `BadMagic` | 文件头魔数不是 `0xd00dfeed`（地址不对，或者不是设备树） |
| `UnsupportedVersion` | 版本早于 16，或者要求兼容 17 以后的格式 |
| `Truncated` | 某次读取超出了文件、结构块或字符串块的范围 |
| `BadToken` | 不认识的 token，或者节点嵌套不匹配 |
| `TooDeep` | 节点嵌套超过 16 层 |
| `TooManyReserved` | 保留区超过 16 段 |
| `TooManyHarts` | cpu 节点超过 32 个 |
| `UnsupportedCells` | `#address-cells` / `#size-cells` 不是 1 或 2（解析 `reg` 时才检查） |
| `NoMemory` | 没有 memory 节点，或者它没有 `reg` |
| `NoTimebase` | 没有 `timebase-frequency` |

`kmain` 遇到任何错误都 panic：`cannot parse device tree at 0x...: <错误名>`。

### 限制

- 只用第一个 memory 节点的第一段内存。QEMU `virt` 只有一段；有多段内存（比如 NUMA 配置）时，其余的内存不会被使用。
- 保留区、嵌套深度（16）、hart 个数（32）都有固定上限，解析时不分配内存（这时页分配器还没初始化）。内核本身最多用 8 个 hart（`hart.max`），多出来的 hart 编号会被记下，但不启动。
- `/reserved-memory` 的子节点不管有没有 `no-map`、是不是 `reusable`，一律当成不可用。
- `Info` 里只有数值，不引用设备树的内容；解析完以后内核不再访问设备树。设备树所在的页仍然在保留区里、不会被分配出去，以后需要时还能再读。

## 扩展

- **从设备树取串口地址**：读 `/chosen` 的 `stdout-path`（QEMU 下是 `/soc/serial@10000000`），再找到那个节点的 `reg`。注意解析设备树发生在 `uart.init` 之后，要么把解析挪到最前面（出错时就没法打印了），要么先用写死的地址打印、解析后再切换。
- **从设备树取 PLIC 地址和串口中断号**：找 `compatible` 含 `riscv,plic0` 的节点的 `reg`，以及串口节点的 `interrupts`。
- 改动后记得同步修改 `vm.init` 里映射外设的代码（目前映射的是 `uart.base`、`plic.base` 这两个常量）。
