const std = @import("std");
/// 和内核、用户程序共用的常量（进程表大小、用户地址空间……），导出进 config.json 给 tools/qemu_test.py
const abi_consts = @import("src/abi.zig");

// 磁盘镜像：共 disk_blocks 块，前 fs_blocks 块是文件系统，后面是原始区域（见下面的 mkfs）
const disk_blocks = 8192;
const fs_blocks = 7168;

// QEMU：virt 机器，128 MiB 内存，QEMU 自带的 OpenSBI（-bios default）。zig build run 和 qemu_test.py 共用（config.json）
const qemu_machine = [_][]const u8{ "qemu-system-riscv64", "-machine", "virt", "-m", "128M", "-nographic", "-bios", "default" };
/// zig build run 给几个 hart
const run_smp = 4;
/// 磁盘：virtio 块设备，用现代（version 2）的 virtio-mmio 接口（QEMU 默认是旧版的）。
/// -drive 的选项后面还要接 file=镜像（zig build run 再加 snapshot=on）
const qemu_disk_global = [_][]const u8{ "-global", "virtio-mmio.force-legacy=false" };
const qemu_drive = "if=none,format=raw,id=disk";
const qemu_disk_device = [_][]const u8{ "-device", "virtio-blk-device,drive=disk,bus=virtio-mmio-bus.0" };

/// zig-out/config.json 的内容：测试脚本要知道、又已经在 Zig 里定义了的东西，只在这里定义一次（tools/qemu_test.py 读它）。
const Config = struct {
    max_procs: usize = abi_consts.max_procs,
    max_args: usize = abi_consts.max_args,
    block_size: usize = abi_consts.block_size,
    fs_blocks: usize = fs_blocks,
    raw_blocks: usize = disk_blocks - fs_blocks,
    user_space: [2]usize = .{ abi_consts.user_base, abi_consts.user_end },
    /// 用户栈下面那一页保护页（src/vm.zig 的 heap_limit..stack_limit）
    user_stack_guard: [2]usize = .{ abi_consts.user_end - abi_consts.user_stack_max - 4096, abi_consts.user_end - abi_consts.user_stack_max },
    qemu: []const []const u8 = &qemu_machine,
    run_smp: usize = run_smp,
    /// 接磁盘的参数，file= 之后要接上镜像的路径
    qemu_disk: []const []const u8 = &(qemu_disk_global ++ .{"-drive"}),
    qemu_drive: []const u8 = qemu_drive ++ ",file=",
    qemu_disk_device: []const []const u8 = &qemu_disk_device,
};

pub fn build(b: *std.Build) void {
    // rv64imac：不启用 F/D 浮点扩展（和 Linux 内核一样），
    // 这样编译器保证不会生成浮点指令，陷阱处理时也就不用保存浮点寄存器。
    // zicsr 是读写 CSR 的 csrr/csrw 指令，zifencei 是 fence.i，LLVM 里需要单独打开。
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
        .cpu_features_add = std.Target.riscv.featureSet(&.{ .m, .a, .c, .zicsr, .zifencei }),
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // 内核链接在 0x80200000，超出了默认 medlow 模型能寻址的 ±2GiB 范围，
            // medany 改用 PC 相对寻址，代码放在哪都能访问到。
            .code_model = .medany,
            // 保留帧指针（s0）：panic 时沿着它打印调用栈（kstack.backtrace），所有优化模式都要
            .omit_frame_pointer = false,
        }),
    });
    // -Dlock-jitter=true：拿锁、放锁时随机空转一会儿，拉大竞争窗口（spinlock.zig 的 jitter，qemu_test.py --jitter 用）
    const options = b.addOptions();
    options.addOption(bool, "lock_jitter", b.option(bool, "lock-jitter", "Spin for a random while around spinlock acquire/release to widen race windows") orelse false);
    kernel.root_module.addOptions("build_options", options);
    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);

    // 用户程序：每个程序以 user/start.zig 为根文件、<目录>/<名字>.zig 作为 program 模块，
    // 各自编译成一个 ELF，链接到用户地址空间（默认用 user/linker.ld）。选中的程序由 mkfs 装进磁盘镜像的 /bin，
    // 内核运行时从那里加载（exec）；只有 init 作为匿名模块嵌进内核（@embedFile("init")）：
    // 第一个进程要在挂载文件系统之前加载。
    // -Dtest-programs=true 时再加上 user/tests/ 里的回归测试程序（tools/qemu_test.py 用）。
    const UserProgram = struct {
        name: []const u8,
        dir: []const u8 = "user",
        linker_script: []const u8 = "user/linker.ld",
    };
    // init 是内核启动的第一个进程，它再启动 sh（shell），两个都必须有
    const user_programs = [_]UserProgram{
        .{ .name = "init" },  .{ .name = "sh" },    .{ .name = "hello" },
        .{ .name = "fault" }, .{ .name = "spin" },  .{ .name = "ticker" },
        .{ .name = "echo" },  .{ .name = "cat" },   .{ .name = "wc" },
        .{ .name = "ls" },    .{ .name = "mkdir" }, .{ .name = "rm" },
        .{ .name = "scrub" }, .{ .name = "mv" },    .{ .name = "ln" },
        .{ .name = "test" },  .{ .name = "expr" },  .{ .name = "seq" },
        .{ .name = "sleep" }, .{ .name = "head" },  .{ .name = "tail" },
        .{ .name = "grep" },  .{ .name = "cp" },    .{ .name = "touch" },
        .{ .name = "tee" },   .{ .name = "xargs" }, .{ .name = "kstat" },
    };
    const test_programs = [_]UserProgram{
        .{ .name = "t_sys", .dir = "user/tests" },
        .{ .name = "t_wx", .dir = "user/tests" },
        .{ .name = "t_stack", .dir = "user/tests" },
        .{ .name = "t_priv", .dir = "user/tests" },
        .{ .name = "t_panic", .dir = "user/tests" },
        .{ .name = "t_time", .dir = "user/tests" },
        .{ .name = "t_fp", .dir = "user/tests" },
        .{ .name = "t_sleep", .dir = "user/tests" },
        .{ .name = "t_fork", .dir = "user/tests" },
        .{ .name = "t_read", .dir = "user/tests" },
        .{ .name = "t_args", .dir = "user/tests" },
        .{ .name = "t_pipe", .dir = "user/tests" },
        .{ .name = "t_sbrk", .dir = "user/tests" },
        .{ .name = "t_smp", .dir = "user/tests" },
        .{ .name = "t_cow", .dir = "user/tests" },
        .{ .name = "t_ipi", .dir = "user/tests" },
        .{ .name = "t_disk", .dir = "user/tests" },
        .{ .name = "t_fs", .dir = "user/tests" },
        .{ .name = "t_fsmp", .dir = "user/tests" },
        .{ .name = "t_demand", .dir = "user/tests" },
        // 数据段没有任何权限，用来验证 ELF 加载器会拒绝它
        .{ .name = "t_noperm", .dir = "user/tests", .linker_script = "user/tests/noperm.ld" },
    };
    const with_tests = b.option(bool, "test-programs", "Also embed the regression test programs in user/tests/") orelse false;
    const all_programs = user_programs ++ test_programs;
    const programs: []const UserProgram = if (with_tests) &all_programs else &user_programs;

    // zig build test：在主机上运行单元测试（src/tests.zig），测设备树解析、页分配器、页表、ELF 加载器这些纯逻辑。
    // 用户程序的 ELF 也交给单元测试，用来测 ELF 加载器。
    // -Dtest-filter=名字的一部分：只跑名字里含这一段的测试
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

    const abi = b.createModule(.{ .root_source_file = b.path("src/abi.zig") });
    const sys = b.createModule(.{
        .root_source_file = b.path("user/sys.zig"),
        .imports = &.{.{ .name = "abi", .module = abi }},
    });
    // 选中的程序的 ELF，mkfs 把它们装进磁盘镜像的 /bin
    var program_bins: std.ArrayListUnmanaged(std.Build.LazyPath) = .empty;
    for (all_programs, 0..) |p, i| {
        const program = b.addExecutable(.{
            .name = p.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("user/start.zig"),
                .target = target,
                .optimize = optimize,
                .code_model = .medany,
                // 调试信息和栈回溯用的 unwind 表对用户程序都没用，去掉之后嵌进内核的 ELF 小很多
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
        // Debug 模式默认不回收没用到的段，会把整个 compiler_rt 带进来，体积大两倍多
        program.link_gc_sections = true;
        unit_tests.root_module.addAnonymousImport(p.name, .{ .root_source_file = program.getEmittedBin() });
        if (i >= programs.len) continue; // 没被选中的测试程序只给单元测试用
        if (std.mem.eql(u8, p.name, "init")) kernel.root_module.addAnonymousImport(p.name, .{ .root_source_file = program.getEmittedBin() });
        program_bins.append(b.allocator, program.getEmittedBin()) catch @panic("OOM");
        // 另外安装一份到 zig-out/user/，方便用 llvm-readelf 等工具查看（内核用的是磁盘镜像里的那份）
        const install = b.addInstallArtifact(program, .{ .dest_dir = .{ .override = .{ .custom = "user" } } });
        b.getInstallStep().dependOn(&install.step);
    }

    // 磁盘镜像：32 MiB，disk_blocks（8192）个 4 KiB 的块。前 fs_blocks（7168）块是文件系统，由主机上的 mkfs（src/mkfs.zig，
    // 和内核用同一份文件系统代码）生成，用户程序装在 /bin 里；后 1024 块是原始区域，填固定的图案
    // （第 b 块的第 i 个字节是 (b * 131 + i) % 251），回归测试 t_disk 和 qemu_test.py 照着它检查读写。
    // 装到 zig-out/disk.img。
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

    // zig build run：用 QEMU 的 virt 机器启动内核。
    // -bios default 使用 QEMU 自带的 OpenSBI 固件，它在 M 模式完成初始化后
    // 以 S 模式跳到 0x80200000 执行内核。按 Ctrl-A 再按 X 退出 QEMU。
    const qemu = b.addSystemCommand(&qemu_machine);
    qemu.addArgs(&.{ "-smp", b.fmt("{d}", .{run_smp}), "-kernel" });
    qemu.addArtifactArg2(kernel, .{});
    // snapshot=on：写只进临时的覆盖层，QEMU 退出就丢掉，生成的镜像不会被改
    qemu.addArgs(&(qemu_disk_global ++ .{"-drive"}));
    qemu.addPrefixedFileArg(qemu_drive ++ ",snapshot=on,file=", disk);
    qemu.addArgs(&qemu_disk_device);
    qemu.addPassthruArgs();

    // zig-out/config.json（见 Config）
    const config = std.json.Stringify.valueAlloc(b.allocator, Config{}, .{ .whitespace = .indent_2 }) catch @panic("OOM");
    const config_file = b.addWriteFiles().add("config.json", config);
    b.getInstallStep().dependOn(&b.addInstallFile(config_file, "config.json").step);

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&qemu.step);
}
