//! 加载程序：读 ELF 文件的程序头，把各个段记进一个新的用户地址空间（vm.Space），再把命令行参数放到用户栈的顶上。
//! proc.exec、proc.userinit 用它。这里只依赖 vm.Space 和读文件的那一点（Source），不碰进程表，
//! 所以整个可以在主机上测（文件末尾的单元测试加载真正的用户程序）。
//!
//! 按需分页：这里不分配页、不读段的内容，只记下每个段在文件里的位置（vm.Region，区域表的一项），页在第一次被访问时才分配、
//! 从程序文件读进来（vm.fault）。栈也一样，只有 pushArgs 写参数的最顶上一页。

const std = @import("std");
const elf = std.elf;
const abi = @import("abi.zig");
const page = @import("page.zig");
const vm = @import("vm.zig");
const fs = @import("fs.zig");
const fsys = @import("fsys.zig");

/// 加载好的程序：入口，栈指针（也是栈上 Arg 数组的地址），参数个数。
pub const Image = struct {
    entry: usize,
    sp: usize,
    argc: usize,
};

/// ELF 文件从哪来：嵌在内核里的字节（init、单元测试），或者文件系统里的一个文件（exec，在调用方的快照上读）。
/// 这里只用来读文件头和程序头；段的内容由 vm.Backing 按需读。
pub const Source = union(enum) {
    bytes: []const u8,
    file: struct { fs: *fs.Fs, ino: u64, size: u64 },

    fn size(src: Source) u64 {
        return switch (src) {
            .bytes => |b| b.len,
            .file => |f| f.size,
        };
    }

    /// 读 [off, off + dst.len)。偏移和长度来自 ELF 文件本身，可能是坏的：超出文件是 BadElf。
    fn read(src: Source, off: u64, dst: []u8) LoadError!void {
        if (off > src.size() or src.size() - off < dst.len) return error.BadElf;
        switch (src) {
            .bytes => |b| @memcpy(dst, b[off..][0..dst.len]),
            .file => |f| {
                const n = f.fs.read(f.ino, off, dst.len, fsys.KernelOut{ .buf = dst }) catch return error.IoError;
                if (n != dst.len) return error.IoError; // 文件在 stat 之后变短了：同一个快照，不应该发生
            },
        }
    }
};

/// 把程序加载进一个新的地址空间 space（记下各个段、堆的起点，backing 由调用方设好），把命令行参数复制到栈顶。
/// 失败时由调用方释放 space。
pub fn loadImage(space: *vm.Space, src: Source, args: []const []const u8) LoadError!Image {
    const entry = try load(space, src);
    return .{ .entry = entry, .sp = try pushArgs(space, args), .argc = args.len };
}

/// 把命令行参数复制到用户栈的顶端，返回栈上 Arg 数组的地址，新程序的 sp 就从这里开始：
///
///   stack_top
///   参数的字节    各个参数依次往下放，不以 0 结尾
///   （对齐到 16）
///   Arg 数组      argc 个 { ptr, len }，ptr 指向上面的字节    <- 返回值（16 字节对齐，RISC-V 的 sp 要求）
///
/// 参数最多 abi.max_args 个、总共 abi.max_arg_bytes 字节，加起来远小于一页，栈的最顶上一页一定放得下。
/// 栈也是按需分配的：复制参数时分配最顶上那一页，没有内存就是 OutOfMemory（栈里只能有这一种失败）。
fn pushArgs(space: *vm.Space, args: []const []const u8) error{OutOfMemory}!usize {
    std.debug.assert(args.len <= abi.max_args);
    var argv: [abi.max_args]abi.Arg = undefined;
    var sp: usize = vm.stack_top;
    for (args, argv[0..args.len]) |a, *arg| {
        sp -= a.len;
        vm.copyToUser(space, sp, a) catch return error.OutOfMemory;
        arg.* = .{ .ptr = sp, .len = a.len };
    }
    std.debug.assert(vm.stack_top - sp <= abi.max_arg_bytes);
    sp = std.mem.alignBackward(usize, sp - args.len * @sizeOf(abi.Arg), 16);
    vm.copyToUser(space, sp, std.mem.sliceAsBytes(argv[0..args.len])) catch return error.OutOfMemory;
    return sp;
}

pub const LoadError = error{ BadElf, OutOfMemory, IoError };

/// 读 ELF 文件的各个 PT_LOAD 段，记进地址空间 space（vm.Space.addSegment），设好堆的起点（最后一个段之后的页边界：
/// 段的最后一页属于段，堆从下一页开始，权限不会和段混在一起），返回入口地址。
/// 不分配页、不读段的内容：都等程序访问到时按需做（vm.fault）。栈也一样，只有 pushArgs 写参数的最顶上一页。
/// 文件头和程序头每次读一个到栈上（几十字节）。
pub fn load(space: *vm.Space, src: Source) LoadError!usize {
    const Ehdr = elf.Elf64.Ehdr;
    const Phdr = elf.Elf64.Phdr;
    var ehdr_bytes: [@sizeOf(Ehdr)]u8 = undefined;
    try src.read(0, &ehdr_bytes); // 比文件头还短是 BadElf
    const ehdr = std.mem.bytesToValue(Ehdr, &ehdr_bytes);
    if (!std.mem.eql(u8, &ehdr.ident.magic, elf.MAGIC) or ehdr.ident.class != .@"64" or
        ehdr.ident.data != .@"2LSB" or ehdr.type != .EXEC or ehdr.machine != .RISCV or
        ehdr.phentsize != @sizeOf(Phdr))
    {
        return error.BadElf;
    }

    var brk: usize = vm.user_base;
    for (0..ehdr.phnum) |i| {
        const offset = std.math.add(usize, ehdr.phoff, i * @sizeOf(Phdr)) catch return error.BadElf;
        var phdr_bytes: [@sizeOf(Phdr)]u8 = undefined;
        try src.read(offset, &phdr_bytes);
        const phdr = std.mem.bytesToValue(Phdr, &phdr_bytes);
        if (phdr.type != .LOAD or phdr.memsz == 0) continue;
        try loadSegment(space, src, phdr);
        brk = @max(brk, std.mem.alignForward(usize, phdr.vaddr + phdr.memsz, page.size));
    }
    // 入口要在一个可执行的段里：不然第一条指令就缺页，与其让它运行起来再被结束，不如 exec 时就拒绝
    const entry_ok = for (space.segments()) |seg| {
        if (ehdr.entry >= seg.start and ehdr.entry < seg.end and seg.perm.x) break true;
    } else false;
    if (!entry_ok) return error.BadElf;
    space.setHeap(brk);
    return ehdr.entry;
}

fn loadSegment(space: *vm.Space, src: Source, phdr: elf.Elf64.Phdr) LoadError!void {
    // 段要从页边界开始（user/linker.ld 保证），整段落在用户区里、在堆能长到的最高处（栈下面的保护页）之下，
    // 文件内容不能超出镜像。段必须可读：R/W/X 全为 0 的页表项会被 CPU 当成指向下一级页表的指针，
    // 而只写不读的组合在 RISC-V 里是保留的。
    const end = std.math.add(usize, phdr.vaddr, phdr.memsz) catch return error.BadElf;
    if (phdr.vaddr % page.size != 0 or phdr.vaddr < vm.user_base or end > vm.heap_limit or
        phdr.filesz > phdr.memsz or phdr.offset > src.size() or src.size() - phdr.offset < phdr.filesz or
        !phdr.flags.R)
    {
        return error.BadElf;
    }
    space.addSegment(.{
        .start = phdr.vaddr,
        .end = std.mem.alignForward(usize, end, page.size),
        .perm = .{ .r = phdr.flags.R, .w = phdr.flags.W, .x = phdr.flags.X },
        .source = .{ .file = .{ .off = phdr.offset, .size = phdr.filesz } },
    }) catch return error.BadElf; // 两个段重叠了，或者段太多
}

/// 测试用的“物理内存”，用法见 vm.zig 里的测试。
var test_memory: [256 * page.size]u8 align(page.size) = undefined;

/// 把 image 加载进一个新的地址空间，把每一页都碰一遍，检查完之后释放，确认没有漏页。返回入口。
fn testLoad(image: []const u8) !usize {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = image };
    defer {
        vm.destroyUserSpace(&space);
        std.testing.expectEqual(before, page.freePages()) catch @panic("leaked pages");
    }
    const entry = try load(&space, .{ .bytes = image });
    // 加载时一页都没分配（只有根页表）
    try std.testing.expectEqual(before - 1, page.freePages());
    // 入口可读，段里的每一页都读得到，栈的两端可读，栈下面的保护页、堆（还是空的）读不到
    var buf: [2]u8 = undefined;
    try std.testing.expect(entry >= vm.user_base and entry < vm.heap_limit);
    vm.copyFromUser(&space, &buf, entry) catch return error.BadElf;
    for (space.segments()) |seg| {
        var va = seg.start;
        while (va < seg.end) : (va += page.size) vm.copyFromUser(&space, &buf, va) catch return error.BadElf;
    }
    vm.copyFromUser(&space, &buf, vm.stack_limit) catch return error.BadElf;
    vm.copyFromUser(&space, &buf, vm.stack_top - 2) catch return error.BadElf;
    try std.testing.expectError(error.BadAddress, vm.copyFromUser(&space, &buf, vm.stack_limit - 2));
    try std.testing.expectError(error.BadAddress, vm.copyFromUser(&space, &buf, space.heapStart()));
    return entry;
}

test "加载真正的用户程序 hello：按需分页读到的段和 ELF 文件里的一样" {
    const image = @embedFile("hello");
    _ = try testLoad(image);
    // 段的第一个字节就是文件里 p_offset 处的字节
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = image };
    defer vm.destroyUserSpace(&space);
    _ = try load(&space, .{ .bytes = image });
    try std.testing.expect(space.segments().len >= 2);
    for (space.segments()) |seg| {
        const f = switch (seg.source) {
            .file => |f| f,
            .zero => continue,
        };
        if (f.size == 0) continue;
        var b: [1]u8 = undefined;
        try vm.copyFromUser(&space, &b, seg.start);
        try std.testing.expectEqual(image[f.off], b[0]);
    }
}

test "命令行参数复制到栈顶，Arg 数组 16 字节对齐，指向栈上的字节" {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    const hello: Source = .{ .bytes = @embedFile("hello") };
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = hello.bytes };
    defer vm.destroyUserSpace(&space);
    const image = try loadImage(&space, hello, &.{ "hello", "", "world!" });
    try std.testing.expectEqual(3, image.argc);
    try std.testing.expectEqual(0, image.sp % 16);
    try std.testing.expect(image.sp < vm.stack_top and vm.stack_top - image.sp <= 64);

    var argv: [3]abi.Arg = undefined;
    try vm.copyFromUser(&space, std.mem.sliceAsBytes(&argv), image.sp);
    const expected = [_][]const u8{ "hello", "", "world!" };
    for (argv, expected) |a, e| {
        var buf: [16]u8 = undefined;
        try std.testing.expect(a.ptr > image.sp and a.ptr + a.len <= vm.stack_top);
        try vm.copyFromUser(&space, buf[0..a.len], a.ptr);
        try std.testing.expectEqualStrings(e, buf[0..a.len]);
    }

    // 没有参数：sp 就是栈顶
    var empty_space = try vm.createUserSpace();
    empty_space.backing = .{ .bytes = hello.bytes };
    defer vm.destroyUserSpace(&empty_space);
    const empty = try loadImage(&empty_space, hello, &.{});
    try std.testing.expectEqual(vm.stack_top, empty.sp);
    // 堆从最后一个段之后的页边界开始，一开始是空的
    try std.testing.expect(space.heapStart() % page.size == 0 and space.heapStart() > vm.user_base and space.heapStart() <= vm.heap_limit);
    try std.testing.expectEqual(space.heapStart(), space.brk);
}

test "ELF 加载器拒绝坏文件" {
    const good = @embedFile("hello");
    const image = try std.testing.allocator.dupe(u8, good);
    defer std.testing.allocator.free(image);

    try std.testing.expectError(error.BadElf, testLoad(good[0..32])); // 比文件头还短
    image[0] = 0; // 魔数不对
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u16, image[18..20], @backingInt(elf.EM.X86_64), .little); // 不是 RISC-V
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u64, image[32..40], image.len - 8, .little); // 程序头表超出文件
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u64, image[24..32], 0x3000_0000, .little); // 入口不在任何段里
    try std.testing.expectError(error.BadElf, testLoad(image));
    // 数据段 R/W/X 全为 0（用 user/tests/noperm.ld 链接的）
    try std.testing.expectError(error.BadElf, testLoad(@embedFile("t_noperm")));
}
