# Zig 0.17 笔记

这个项目必须用 Zig **0.17.0**。0.17 的 API 和旧版本差别很大，网上的教程、旧代码、甚至模型的训练数据里的写法很多已经不能用了。拿不准时直接查标准库源码，路径是 `zig env` 输出里的 `std_dir`（不要用 `$(dirname $(which zig))/lib/std`：`zig` 是符号链接时会指错地方）。

下面分两部分：和旧版本不同的地方（写这个项目时对照 0.17.0 的语言参考和 0.16/0.17 的 release notes 整理），以及在这个项目里实际踩过的坑。

## 和旧版本不同的地方

### 语言和标准库

- `std.builtin` 改名为 `std.lang`（旧名称已弃用）。注意构建系统自己的 API 里还能看到 `std.builtin.CodeModel` 之类的类型名，那是标准库内部的写法，不影响我们用 `.medany` 这样的字面量。
- `@intFromEnum` / `@enumFromInt` 已弃用，改用 `@backingInt` / `@fromBackingInt`（`uart.zig`、`sbi.zig`、`trap.zig`、`syscall.zig`、`abi.zig` 里有用到）。
- 内联汇编的 clobber 写成结构体：`.{ .memory = true }`、`.{ .ra = true, .t0 = true, ... }`。各架构可用的字段定义在 `std/lang/assembly.zig` 的 `Clobbers` 里，RISC-V 既有 `x1..x31` 也有 ABI 名 `ra`、`t0`、`a0` 等。
- 自定义 panic：在根文件写 `pub const panic = std.debug.FullPanic(fn)`。必须是 `pub`，因为 0.17 起 `@hasDecl` 只认公开声明，不写 `pub` 会悄悄用回默认的 panic。0.17.0 里 `std.debug.simple_panic` 有已知回归（#36986），编译不过，不要用。freestanding 下默认的 panic 是直接 `@trap()`。
- `std.Io.Writer` 是新的输出接口：自己提供一个 `drain(w, data, splat)` 函数，就能用 `print` 做格式化输出（`uart.zig`、`user/sys.zig`）。`data` 是若干段字节，最后一段要重复 `splat` 次。
- `std.SinglyLinkedList` 是**侵入式**的、不带类型参数：链表只认 `Node { next: ?*Node }`，节点嵌在哪里由使用者决定（`page.zig` 直接把节点放在空闲页的开头）。
- `std.mem.indexOfScalar` 改名为 `std.mem.findScalar`（旧名是弃用的别名）；新增 `std.mem.cutScalar(T, s, c)`，返回分隔符前后两段（`user/sh.zig` 用它拆命令名和参数）。
- `std.elf` 推荐用 `std.elf.Elf64.Ehdr` / `Elf64.Phdr`：字段名没有 `e_` / `p_` 前缀，类型是枚举（`type: ET`、`machine: EM`）和 packed struct（`flags: PF`，有 `.R`、`.W`、`.X` 字段）。旧的 `Elf64_Ehdr` 等已弃用。
- `@typeInfo` 的结果换了形状：结构体是 `@typeInfo(T).@"struct".field_names`、`.field_types`、`.field_attrs` 几个并列的数组（不再是 `.fields` 里一个个带 `name`、`type` 的结构体），枚举是 `.field_names`、`.field_values`，错误集是 `@typeInfo(E).error_set.error_names`（`?[]const [:0]const u8`，`anyerror` 是 null）。只要名字的话用 `std.meta.fieldNames(T)` 最简单（`kstat.zig`、`abi.zig`、`user/kstat.zig`）。
- `std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 })` 把一个值写成 JSON（`build.zig` 生成 `config.json`）。
- 0.17.0 有一个 x86 软浮点下 compiler-rt 编译失败的回归（#37006），只影响 x86 目标，这里的 RISC-V 目标不受影响。

### 构建系统

- 优化模式改成小写：`-Doptimize=debug|safe|fast|small`（以前是 `Debug/ReleaseSafe/ReleaseFast/ReleaseSmall`）。
- `addArtifactArg` → `addArtifactArg2(artifact, .{})`。
- 透传命令行参数：`if (b.args) |args| run.addArgs(args)` → `run.addPassthruArgs()`，`b.args` 已经没有了。
- 嵌入另一个构建产物：`module.addAnonymousImport("名字", .{ .root_source_file = exe.getEmittedBin() })`，代码里 `@embedFile("名字")`。
- 传编译期常量：`const o = b.addOptions(); o.addOption([]const []const u8, "名字", &list); module.addOptions("build_options", o);`，代码里 `@import("build_options")`。支持字符串切片的切片。
- `Module.CreateOptions` 里有 `.strip`、`.unwind_tables`（`.none`/`.sync`/`.async`）、`.code_model` 等；`Compile` 上有 `link_gc_sections`。没有指定 `target`/`optimize` 的模块会继承导入它的父模块的设置。

## 在这个项目里踩过的坑

### 裸函数不能直接调用，签名也不能写错

```
error: unable to call function with calling convention 'naked'
```

裸函数（`callconv(.naked)`）没有序言和尾声，Zig 不允许从 Zig 代码直接调用。可行的办法：

- **在内联汇编里 `call` 它**，并把调用者保存的寄存器（`ra`、`t0..t6`、`a0..a7`）和 memory 声明为 clobber（`proc.switchContext` 的做法）。编译器只把它当作一段汇编，不对裸函数做任何假设。
- 或者 `@ptrCast` 成 `callconv(.c)` 的函数指针来调用。这也能编译、能工作，但**签名必须如实**：一个调用之后还会回来的裸函数如果声明成了 `noreturn`，编译器就会认为调用之后的代码永远不会执行，release 模式下把它们全部删掉。这个项目就因此出过一次只在 release 模式下出现的崩溃。

### `comptime @export` 和按需分析

Zig 只分析被引用到的声明。根文件里的 `export fn` 一定会被处理，但写在被导入文件里的 `comptime { @export(&f, .{ .name = "_start" }); }`，只有当那个文件里的声明被引用到时才会执行。用户程序最初把 `_start` 放在 `sys.zig` 里：Debug 模式下入口碰巧导出了（推测是 Debug 模式会提前分析根文件里引用了 `sys.panic` 的 `panic` 声明，没有深究）；safe/fast/small 模式下入口没有导出，链接器把所有代码都当作没用的回收掉，产出一个空的 ELF。现在 `_start` 放在用户程序的根文件 `user/start.zig` 里。

### 链接器的警告不会让 `zig build` 失败

上一条的情况下，构建输出里会有：

```
+- compile exe hello small riscv64-freestanding-none failure
error: warning(link): unexpected LLD stderr:
       ld.lld: warning: cannot find entry symbol _start; not setting start address
```

看起来是错误，但实测 `zig build` 的退出码是 0，依赖它的内核也照样生成。所以检查构建结果时要看输出（正常构建没有任何输出），不能只看退出码。

### 一个文件只能属于一个模块

```
error: file exists in modules 'sys' and 'program'
```

在同一次编译里，一个文件只能属于一个模块。用户程序如果按路径 `@import("sys.zig")`，`user/sys.zig` 就同时成了 `program` 模块的一部分和 `sys` 模块的根，报这个错。要按模块名 `@import("sys")`。不同的编译之间没有这个限制：`src/abi.zig` 在内核里按路径导入，在用户程序里是 `abi` 模块的根，没有问题。

### `std.fmt.comptimePrint` 不允许多余的参数

```
error: unused argument in '...'
```

用 `comptimePrint` 生成汇编代码时，参数结构体里有格式串没用到的字段就会报错（比如 `trapEntry`、`trapExit` 想共用一个偏移量结构体，而其中一个字段只有 `trapExit` 用）。解决办法：把多段汇编模板先用 `++` 拼起来再统一 `comptimePrint`；只有一边用到的常量改用内联汇编的操作数传入，比如立即数用 `"i"` 约束：`andi t0, t0, %[spp]` + `[spp] "i" (riscv.sstatus_spp)`。

### 内联汇编里取变量的地址不能用 `"X"` 约束

```
error: ld.lld: undefined symbol: a0
```

`tail %[kmain]` + `[kmain] "X" (&kmain)` 能用：函数的地址是个符号，编译器把符号名原样代进汇编。但对一个**变量**（`var boot_stacks: [8][32768]u8`）这样写，`la sp, %[stacks]` + `[stacks] "X" (&boot_stacks)`，编译器先生成一段把地址算进寄存器的代码（这里挑了 `a0`），再把寄存器名代进去，汇编就成了 `la sp, a0`，`a0` 被当成一个叫 `a0` 的符号，链接时找不到。在裸函数里这更要命：`a0` 里本来放着要保留的参数（hart 编号），已经被覆盖了。办法是把变量 `export` 出来，汇编里直接写它的名字（`main.zig` 的 `boot_stacks`）。

### 指针转换

- `@ptrCast` 不能提高对齐要求：`*[512]Pte`（8 字节对齐）转成 `*align(4096) [4096]u8` 会报 `@ptrCast increases pointer alignment`，要写成 `@ptrCast(@alignCast(p))`，`@alignCast` 在 Debug/safe 模式下会检查实际地址。
- 普通指针不能为 0：`@ptrFromInt(0)` 转成普通指针，编译期已知时直接报错，运行时在安全模式下会 panic。确实要指向地址 0 时用 `*allowzero T`（以前内核 shell 的 `crash` 命令就是这样读地址 0 的）。
- 从字节数组里读结构体（ELF 头）用 `std.mem.bytesToValue(T, bytes[0..@sizeOf(T)])`，它复制一份，不要求对齐。

### 其他

- `packed struct(u64)` 的字段从最低位开始排，用来描述硬件格式（页表项）很方便，编译器保证总宽度正好是 64 位。
- 元组可以在运行时拼接：`.{ p.pid, p.name } ++ args`（`proc.killCurrent` 用它把固定参数和调用者的参数合在一起交给 `print`）。
- 数组重复运算符 `**` 已经没有了：`[_]T{x} ** n` 会报 `binary operator '*' has whitespace on one side, but not the other`（`**` 不再是一个运算符，被拆成了两个 `*`）。把同一个值铺满数组用 `@splat`：`var table: [8]Process = @splat(.{});`（`proc.table`）。
- 编译期构造数组后要复制成 `const` 才能从块里返回：`const final = list; break :blk final;`（`proc.programs`）。
- Debug 模式默认不做段回收（gc-sections），会把整个 compiler_rt 链接进来；需要小体积的产物（这里是装进磁盘镜像的用户程序）要显式设置 `link_gc_sections = true`。
