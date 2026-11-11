# 构建系统

涉及文件：`build.zig`、`linker.ld`、`user/linker.ld`

整个项目用 `zig build` 构建：一次构建会产出内核 ELF（`zig-out/bin/kernel`）、若干个用户程序 ELF，以及装着它们的磁盘镜像（`zig-out/disk.img`）。内核从磁盘上的文件系统加载用户程序，只有第一个程序 init 作为数据嵌进内核。

```sh
zig build                          # Debug 模式
zig build -Doptimize=small         # debug | safe | fast | small（0.17 起是小写）
zig build run                      # 编译并在 QEMU 中启动
zig build run -- -d int -D q.log   # -- 之后的参数原样传给 QEMU（这里是记录所有陷阱）
```

## 目标平台

```zig
const target = b.resolveTargetQuery(.{
    .cpu_arch = .riscv64,
    .os_tag = .freestanding,
    .abi = .none,
    .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
    .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }),
});
```

- `freestanding`：没有操作系统，标准库里依赖 OS 的部分（文件、线程、`std.debug` 的栈回溯输出等）都不可用；`std.fmt`、`std.mem`、`std.Io.Writer` 这类纯计算的部分可以用。
- CPU 是 `generic_rv64` 再加上 M（乘除）、A（原子指令）、C（压缩指令）、Zicsr（`csrr`/`csrw` 等 CSR 指令）、Zifencei（`fence.i`）。在 LLVM 里 Zicsr 和 Zifencei 要单独打开，否则内联汇编里的 `csrr` 会汇编失败。
- **刻意不开 F/D（浮点）**：编译器保证不生成浮点指令，所以陷阱处理不必保存 32 个浮点寄存器和 `fcsr`。用户程序用同一个目标，同样没有浮点；用户程序里写了浮点运算，编译器会用软件浮点（compiler_rt）实现。
- **浮点单元在启动时关掉**：只靠编译目标挡不住手写的浮点指令。QEMU 模拟的 CPU 其实有浮点单元，OpenSBI 交过来时它是开着的（`sstatus.FS` = 3，Dirty），所以 `kmain` 第一件事就是把 `FS` 清成 Off。之后内核和用户程序执行浮点指令都会触发非法指令异常（[boot.md](boot.md#kmain-的初始化顺序)）。
- 内核和用户程序共用这一个 `target`。

## 优化模式

`b.standardOptimizeOption(.{})` 提供 `-Doptimize=debug|safe|fast|small`，同时作用于内核和所有用户程序：

| 模式 | 安全检查（溢出、越界、`unreachable`、`.?` 等） | 典型体积 |
| --- | --- | --- |
| `debug`（默认） | 有，失败时进 panic 处理 | 内核 `.text` 约 304 KiB，ELF 文件约 2.4 MB（含调试信息） |
| `safe` | 有 | 介于两者之间 |
| `fast` | 没有，违反就是未定义行为 | 与 `small` 接近 |
| `small` | 没有 | 内核 `.text` 约 12.8 KiB，ELF 文件约 65 KB |

（体积是本文写作时实测，代码变化后会变；当前值用 `llvm-readelf -S zig-out/bin/kernel` 查看。）

优化模式之间的差别不只是速度和体积：编译器在 release 模式下会更激进地利用类型系统给出的承诺（比如 `noreturn`、没有 `volatile` 的内存访问可以合并或删除），所以内联汇编、MMIO、页表、进出 U 模式相关的改动要四种模式都测一遍（`python3 tools/qemu_test.py --all-modes`）。这个项目里有两个 bug 只在 release 模式下出现。

## 内核

```zig
const kernel = b.addExecutable(.{
    .name = "kernel",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medany,
    }),
});
kernel.setLinkerScript(b.path("linker.ld"));
b.installArtifact(kernel);
```

- **代码模型 `medany`**：RISC-V 的默认模型 `medlow` 用 `lui` + `addi` 生成绝对地址，`lui` 的结果要做符号扩展，所以只能寻址 `0..0x7fff_ffff` 和最高的 2 GiB。内核链接在 `0x8020_0000`，正好落在中间够不到的地方。`medany` 用 `auipc` 生成相对于当前 PC 的地址，只要目标离代码不超过 ±2 GiB 就行，和链接地址无关。
- **链接脚本** `linker.ld`：决定内核的内存布局，见 [boot.md](boot.md#链接脚本)。
- 产物安装到 `zig-out/bin/kernel`，QEMU 用 `-kernel` 直接加载这个 ELF（按程序头把各段放到对应的物理地址）。

## 用户程序

每个用户程序是一个独立的 `addExecutable`，模块关系如下：

```
根模块：user/start.zig（相当于 crt0：导出 _start、定义 panic）
├── import "sys"     → user/sys.zig（系统调用封装、print）
│                      └── import "abi" → src/abi.zig（系统调用号、错误码）
└── import "program" → <目录>/<名字>.zig（程序本身，提供 pub fn main() u8）
                       └── import "sys" → 同一个 sys 模块
```

程序列表是一个结构体数组，每一项可以指定目录和链接脚本（默认 `user/` 和 `user/linker.ld`）：

```zig
const UserProgram = struct {
    name: []const u8,
    dir: []const u8 = "user",
    linker_script: []const u8 = "user/linker.ld",
};
const user_programs = [_]UserProgram{
    .{ .name = "init" },  .{ .name = "sh" },    .{ .name = "hello" },
    .{ .name = "fault" }, .{ .name = "spin" },  .{ .name = "ticker" },
    .{ .name = "echo" },  .{ .name = "cat" },   .{ .name = "wc" },
    .{ .name = "ls" },    .{ .name = "mkdir" }, .{ .name = "rm" },
    .{ .name = "scrub" }, .{ .name = "mv" },    .{ .name = "ln" },
    .{ .name = "test" },  .{ .name = "expr" },  .{ .name = "seq" },
    .{ .name = "sleep" }, .{ .name = "head" },  .{ .name = "tail" },
    .{ .name = "grep" },  .{ .name = "cp" },    .{ .name = "touch" },
    .{ .name = "tee" },   .{ .name = "xargs" },
};
const test_programs = [_]UserProgram{
    .{ .name = "t_sys", .dir = "user/tests" },
    // ……
    .{ .name = "t_noperm", .dir = "user/tests", .linker_script = "user/tests/noperm.ld" },
};
const with_tests = b.option(bool, "test-programs", "Also embed the regression test programs in user/tests/") orelse false;
const all_programs = user_programs ++ test_programs;
const programs: []const UserProgram = if (with_tests) &all_programs else &user_programs;
```

`-Dtest-programs=true` 时，`user/tests/` 里的回归测试程序也编进内核，`tools/qemu_test.py` 会自动加上这个选项（[testing.md](testing.md#回归测试程序)）；平时不加，`/bin` 里没有测试程序。

对每个程序的构建代码：

```zig
const abi = b.createModule(.{ .root_source_file = b.path("src/abi.zig") });
const sys = b.createModule(.{
    .root_source_file = b.path("user/sys.zig"),
    .imports = &.{.{ .name = "abi", .module = abi }},
});
for (all_programs, 0..) |p, i| {
    const program = b.addExecutable(.{
        .name = p.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/start.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medany,
            .strip = true,
            .unwind_tables = .none,
            .imports = &.{
                .{ .name = "sys", .module = sys },
                .{ .name = "program", .module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("{s}/{s}.zig", .{ p.dir, p.name })),
                    .imports = &.{.{ .name = "sys", .module = sys }},
                }) },
            },
        }),
    });
    program.setLinkerScript(b.path(p.linker_script));
    program.link_gc_sections = true;
    unit_tests.root_module.addAnonymousImport(p.name, .{ .root_source_file = program.getEmittedBin() });
    if (i >= programs.len) continue; // 没被选中的测试程序只给单元测试用
    if (std.mem.eql(u8, p.name, "init")) kernel.root_module.addAnonymousImport(p.name, .{ .root_source_file = program.getEmittedBin() });
    program_bins.append(b.allocator, program.getEmittedBin()) catch @panic("OOM");   // 交给 mkfs，装进 /bin
    const install = b.addInstallArtifact(program, .{ .dest_dir = .{ .override = .{ .custom = "user" } } });
    b.getInstallStep().dependOn(&install.step);
}
```

要点：

- **根文件是 `user/start.zig`，不是程序本身。** `_start` 必须在根文件里导出：Zig 只分析被引用到的声明，写在被导入文件里的 `comptime { @export(...) }`，只有当这个文件被引用时才会执行。最初的写法把 `_start` 放在 `sys.zig` 里，Debug 模式下碰巧导出了，release 模式下则根本没有导出，链接器找不到入口、产出一个空文件。
- **`abi`、`sys` 模块只创建一次**，被所有用户程序共用。没有指定 `target`/`optimize` 的模块会继承导入它的父模块的设置。
- **一个文件在一次编译里只能属于一个模块。** 程序里必须写 `@import("sys")`（按模块名），不能写 `@import("sys.zig")`（按路径）：后者会让 `user/sys.zig` 同时属于 `sys` 和 `program` 两个模块，编译报错 `file exists in modules 'sys' and 'program'`。`src/abi.zig` 同时被内核（按路径导入）和用户程序（作为 `abi` 模块）使用没有问题，因为它们是不同的编译。
- **`.strip = true`**：去掉调试信息。内核加载用户程序时只看程序头，用不到符号和 DWARF。
- **`.unwind_tables = .none`**：不生成 `.eh_frame`。用户程序没有栈回溯，unwind 表只是占地方。
- **`link_gc_sections = true`**：Debug 模式默认不回收没被引用的段，会把整个 compiler_rt（`sin`、`log10` 等软件浮点函数）和 ubsan 运行时都链接进来。实测 Debug 版 `hello` 的可加载内容：默认 351 KB → 打开 GC 后 125 KB → 再去掉 unwind 表 91 KB。release 模式默认就会回收。
- **`program_bins`**：选中的每个程序的 ELF 交给 `mkfs`，装进磁盘镜像的 `/bin/<名字>`（[磁盘镜像](#磁盘镜像)），内核 `exec` 时从那里加载（[process.md](process.md#程序从哪来)）。
- **只有 init 用 `addAnonymousImport`**：把它的 ELF 作为一个名叫 `init` 的匿名模块交给内核，内核里 `@embedFile("init")` 拿到的就是这个 ELF 文件的全部字节（`*const [N:0]u8`）。第一个进程要在挂载文件系统之前加载，所以只能嵌着。构建系统据此知道内核依赖 init，init 改了会重新编译内核；别的程序改了只重新生成磁盘镜像。
- **`addInstallArtifact(..., .{ .dest_dir = .{ .override = .{ .custom = "user" } } })`**：另外把每个用户程序安装到 `zig-out/user/<名字>`，只是为了方便用 `llvm-readelf` 等工具查看，内核用的是磁盘镜像里的那份（同一个构建产物，字节完全相同）。

- **所有程序都交给单元测试**：单元测试用真正的用户程序 ELF 来测 ELF 加载器（见下面的“单元测试”）。构建系统只编译被用到的产物，所以 `zig build` 不会编译没选中的测试程序，`zig build test` 才会。

所以**新增用户程序只需要两步**：写 `user/<名字>.zig`，在 `user_programs` 数组里加一项 `.{ .name = "<名字>" }`，它就会出现在 `/bin` 里。

### 用户程序的链接脚本

`user/linker.ld` 用 `PHDRS` 显式声明三个可加载段，每个输出段从新的一页开始：

| 段 | 内容 | 权限（`FLAGS`） |
| --- | --- | --- |
| `text` | `.text*` | 5 = R + X |
| `rodata` | `.srodata*`、`.rodata*` | 4 = R |
| `data` | `.sdata*`、`.data*`、`.sbss*`、`.bss*`、`COMMON` | 6 = R + W |

起始地址 `0x4000_0000` 是用户地址空间的起点（`vm.user_base`）。页对齐是加载器的要求：它按页给每个段设置权限，段的起点必须在页边界上，否则一页可能同时属于两个段（见 [process.md](process.md#elf-加载器)）。入口地址由 ELF 头的 `e_entry` 给出（`ENTRY(_start)`），不要求 `_start` 排在最前面。

实测的段布局（Debug 版 `hello`，`llvm-readelf -l zig-out/user/hello`）：

```
LOAD 0x40000000 filesz 0x127dc R E    （代码，约 74 KiB）
LOAD 0x40013000 filesz 0x03e04 R      （只读数据）
LOAD 0x40017000 filesz 0x00020 memsz 0x00120 RW   （数据：sys.zig 里的 writer；.bss：print 的 256 字节缓冲区）
Entry point 0x400115dc
```

small 模式下同一个程序的代码段只有 0x3bc 字节，ELF 文件约 13 KB（大部分是页对齐留下的空隙）。

## 单元测试

```zig
const test_filter = b.option([]const u8, "test-filter", "Only run the unit tests whose names contain this text");
const unit_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }),
    .filters = if (test_filter) |f| &.{f} else &.{},
});
const test_step = b.step("test", "Run the unit tests on the host");
test_step.dependOn(&b.addRunArtifact(unit_tests).step);
```

- `-Dtest-filter=文字`：只编译、运行名字里含这段文字的测试（0.17 的测试程序运行时不接受过滤参数，过滤要在编译时给）。

- `zig build test` 编译 `src/tests.zig` 引用到的各个文件里的 `test` 块，然后运行。
- `.target = b.graph.host`：测试编译成**主机**的程序（比如 x86_64 Linux）直接运行，不是 RISC-V，所以只能测不碰硬件的代码（[testing.md](testing.md#单元测试zig-build-test)）。
- 和内核共用同一批源文件：Zig 只编译被用到的函数，测试用不到的 CSR 读写、裸函数里的 RISC-V 汇编不会被编译，所以不影响在主机上构建。

## 磁盘镜像

```zig
const mkfs = b.addExecutable(.{
    .name = "mkfs",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/mkfs.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    }),
});
const make_disk = b.addRunArtifact(mkfs);
const disk = make_disk.addOutputFileArg("disk.img");
make_disk.addArgs(&.{ b.fmt("{d}", .{disk_blocks}), b.fmt("{d}", .{fs_blocks}) });
for (program_bins.items) |bin| make_disk.addFileArg(bin);
b.getInstallStep().dependOn(&b.addInstallFile(disk, "disk.img").step);
```

- `mkfs`（`src/mkfs.zig`，[fs.md](fs.md#生成磁盘镜像mkfszig)）编译成**主机**的程序，构建时运行：`mkfs <输出> 8192 7168 <ELF>...`。32 MiB 的镜像，前 7168 块格式化成文件系统，选中的每个用户程序装成 `/bin/<名字>`，再建 `/dev/console`、`/dev/null`、`/dev/zero` 三个设备文件；后 1024 块是原始区域，填上固定图案（第 b 块的第 i 个字节是 `(b * 131 + i) % 251`），给回归测试 `t_disk` 检查读写（[disk.md](disk.md)）。结果装到 `zig-out/disk.img`。
- `addOutputFileArg`、`addFileArg` 让构建系统知道 Run 步骤的输入和输出：`mkfs` 或哪个 ELF 变了才重新生成，否则命中缓存。`InstallFile` 发现 `zig-out/disk.img` 的大小或修改时间和缓存里的不一样就重新拷一份，所以磁盘被改写过之后，下一次 `zig build` 会恢复原样。
- `-Dtest-programs=true` 时测试程序也装进 `/bin`，镜像和平时的不一样（空闲块少一些）。
- 两个数字是 `build.zig` 顶上的 `disk_blocks`、`fs_blocks`，`qemu_test.py` 从 `config.json` 读（见下面的[给测试脚本的配置](#给测试脚本的配置)）。原始区域的图案和块数还在几个地方各写了一遍：`src/mkfs.zig`（图案）、`user/tests/t_disk.zig`（原始区域的块数和图案）、`tools/qemu_test.py`（`disk_original`），改一处要一起改。

## 运行步骤

```zig
const qemu_machine = [_][]const u8{ "qemu-system-riscv64", "-machine", "virt", "-m", "128M", "-nographic", "-bios", "default" };
const run_smp = 4;
const qemu_disk_global = [_][]const u8{ "-global", "virtio-mmio.force-legacy=false" };
const qemu_drive = "if=none,format=raw,id=disk";
const qemu_disk_device = [_][]const u8{ "-device", "virtio-blk-device,drive=disk,bus=virtio-mmio-bus.0" };

const qemu = b.addSystemCommand(&qemu_machine);
qemu.addArgs(&.{ "-smp", b.fmt("{d}", .{run_smp}), "-kernel" });
qemu.addArtifactArg2(kernel, .{});
qemu.addArgs(&(qemu_disk_global ++ .{"-drive"}));
qemu.addPrefixedFileArg(qemu_drive ++ ",snapshot=on,file=", disk);
qemu.addArgs(&qemu_disk_device);
qemu.addPassthruArgs();
```

这些参数定义成 `build.zig` 顶上的常量，是为了和 `qemu_test.py` 共用（下一节）。

| 参数 | 含义 |
| --- | --- |
| `-machine virt` | QEMU 的通用 RISC-V 虚拟板，外设地址见 [architecture.md](architecture.md#物理内存布局) |
| `-smp 4` | 4 个 hart。内核从设备树里知道有几个、逐个启动（[boot.md](boot.md#启动其他-hart)），最多用 8 个。要换个数就在后面再给一个，后给的覆盖前面的：`zig build run -- -smp 1` |
| `-m 128M` | 内存大小。改了之后内核会从设备树里读到新的大小，不需要改代码 |
| `-nographic` | 不开窗口，串口接到当前终端；Ctrl-A 是 QEMU 的转义键，Ctrl-A X 退出 |
| `-bios default` | 使用 QEMU 自带的 OpenSBI（fw_dynamic），它以 S 模式跳到 `0x8020_0000` |
| `-kernel` + 内核路径 | `addArtifactArg2` 把内核 ELF 的路径接在后面，并让 run 依赖内核的构建 |
| `-global virtio-mmio.force-legacy=false` | virtio-mmio 设备用现代接口（version 2）。QEMU 默认是旧版，驱动不支持（[disk.md](disk.md#qemu-的磁盘)） |
| `-drive if=none,format=raw,id=disk,snapshot=on,file=…` | 磁盘镜像（缓存目录里生成的那份，`addPrefixedFileArg` 让 run 依赖它）。`snapshot=on`：写只进 QEMU 的临时覆盖层，退出就丢掉，镜像不变 |
| `-device virtio-blk-device,drive=disk,bus=virtio-mmio-bus.0` | 把它接成 virtio 块设备，放在第 0 个 virtio-mmio 槽位（`0x1000_1000`，PLIC 的 1 号中断） |

`addPassthruArgs()` 把 `zig build run -- ...` 里 `--` 之后的参数追加到 QEMU 命令行末尾（0.17 之前的写法是 `if (b.args) |args| run.addArgs(args)`，`b.args` 已经没有了）。

## 给测试脚本的配置

`tools/qemu_test.py` 要知道一些已经在 Zig 里定义了的东西：QEMU 的命令行、进程表多大（测“进程表满了”）、`exec` 最多几个参数、磁盘镜像的布局、用户地址空间和栈下面的保护页（测“被杀时的 `stval` 落在哪”）。原来它们在脚本里手抄一份，改一边忘了另一边，测试就在测一个过时的数。现在 `build.zig` 把它们放进一个结构体 `Config`（字段的默认值直接引用 `src/abi.zig` 的常量和 `build.zig` 自己的常量），用 `std.json.Stringify.valueAlloc` 写成 `zig-out/config.json`，测试脚本构建完读它（`load_config`）：

```zig
const abi_consts = @import("src/abi.zig");   // build.zig 可以直接导入仓库里的 Zig 文件
const Config = struct {
    max_procs: usize = abi_consts.max_procs,
    fs_blocks: usize = fs_blocks,
    user_stack_guard: [2]usize = .{ abi_consts.user_end - abi_consts.user_stack_max - 4096, abi_consts.user_end - abi_consts.user_stack_max },
    qemu: []const []const u8 = &qemu_machine,
    ...
};
```

用户地址空间的几个常量（`user_base`、`user_end`、`user_stack_max`）因此从 `vm.zig` 挪到了 `abi.zig`：它们本来就是内核和用户程序之间的约定（用户程序从 `user_base` 链接），`vm.zig` 引用它们。

## 产物和缓存

- 内核：`zig-out/bin/kernel`。
- 用户程序：`zig-out/user/<名字>`，例如 `llvm-readelf -l zig-out/user/hello`。和内核一样，是最近一次 `zig build` 用的那个优化模式的版本。
- 不要去 `.zig-cache/o/` 里找用户程序：那里同时留着各个优化模式、各个历史版本的产物（实测光 `hello` 就有十几个），按修改时间挑也不一定挑得对。
- `zig-out/` 和 `.zig-cache/` 都在 `.gitignore` 里。
