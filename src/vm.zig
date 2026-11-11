//! Sv39 分页。虚拟地址 39 位，拆成 VPN[2] | VPN[1] | VPN[0] | 页内偏移（9 + 9 + 9 + 12 位）。
//! 页表有三级，每级 512 项、每项 8 字节，一张页表正好一页。CPU 从 satp 指向的根页表开始，
//! 用 VPN[2]、VPN[1]、VPN[0] 依次索引：某一项的 R/W/X 有一位为 1 就是叶子，映射到此为止；
//! 全为 0 则指向下一级页表。在第 2、1 级就停下的叶子是 1 GiB、2 MiB 的大页。
//!
//! 内核的映射：物理内存和外设都按“虚拟地址 = 物理地址”恒等映射，所以开分页前后地址不变，
//! 页分配器给出的物理地址也能直接当指针用。代码 R-X、只读数据 R--、其余 RW-，都不带 U 位，
//! U 模式访问不到。
//!
//! 用户地址空间：根页表的第 1 项（0x4000_0000..0x8000_0000，1 GiB）专门留给用户程序。
//! 内核的映射都不落在这一项里（外设在第 0 项，内存从第 2 项开始），所以每个进程的根页表
//! 直接复制内核根页表的其他项、共用下面的页表即可，陷入内核时不用切换页表。
//!
//! 按需分页（demand paging）：用户地址空间（Space）里只记着“哪些地址可以有页、页从哪来”——程序的各个段
//! （内容在程序文件里）、堆、栈，页表里一开始几乎什么都没有。用户程序第一次访问某一页时缺页，
//! fault 才分配一页，段里的页从程序文件读进来，堆和栈的是清零的页。内核替用户程序读写用户内存
//! （copyFromUser 这些）时也一样。所以 exec 一个大程序、sbrk 一大块内存都不用先分配，用到多少分配多少。
//!
//! fork 写时复制（copy-on-write）：子进程的地址空间不复制页，而是和父进程映射同一批物理页
//! （page.zig 记引用数）。可写的页两边都改成只读、标上 cow，谁先写谁触发缺页，由 breakCow 复制一份。
//!
//! 内核栈下面的保护页（kstack.zig）：内核的恒等映射跳过这些页（init 的 guards），内核栈溢出时撞上它们缺页。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");
const page = @import("page.zig");
const dtb = @import("dtb.zig");
const uart = @import("uart.zig");
const plic = @import("plic.zig");
const virtio_disk = @import("virtio_disk.zig");
const spinlock = @import("spinlock.zig");
const proc = @import("proc.zig");
const fsys = @import("fsys.zig");
const abi = @import("abi.zig");
const kstat = @import("kstat.zig");

pub const user_base = abi.user_base;
pub const user_end = abi.user_end;

/// 页表项。A（访问过）和 D（写过）位直接置 1：规范允许硬件在它们为 0 时触发缺页异常，
/// 而不是自动置位，这个内核不需要靠它们统计页面使用情况。
pub const Pte = packed struct(u64) {
    v: bool = false,
    r: bool = false,
    w: bool = false,
    x: bool = false,
    u: bool = false,
    /// 全局映射：所有地址空间都有，切换地址空间时 TLB 里的这些项不用作废
    g: bool = false,
    a: bool = false,
    d: bool = false,
    /// RSW（留给软件用的两位）的第 0 位：写时复制的页。W 清掉了，写的时候触发缺页，
    /// 由 breakCow 复制一份（或者发现只剩自己在用）再改回可写。只出现在用户映射里
    cow: bool = false,
    rsw: u1 = 0,
    ppn: u44 = 0,
    reserved: u10 = 0,

    fn isLeaf(pte: Pte) bool {
        return pte.r or pte.w or pte.x;
    }

    fn addr(pte: Pte) usize {
        return @as(usize, pte.ppn) << 12;
    }
};

pub const PageTable = [512]Pte;

pub const Perm = struct {
    r: bool = false,
    w: bool = false,
    x: bool = false,
    u: bool = false,
};

pub const MapError = error{ OutOfMemory, AlreadyMapped };

// 链接脚本（linker.ld）里定义的符号，标出内核镜像各段的边界，都按页对齐
extern const __text_start: u8;
extern const __rodata_start: u8;
extern const __data_start: u8;
extern const __kernel_end: u8;

pub fn kernelEnd() usize {
    return @intFromPtr(&__kernel_end);
}

pub var kernel_root: *PageTable = undefined;

/// 建立内核页表并打开分页。guards 是内核栈下面的保护页（kstack.guardPages，按地址排好序），都在 .bss 里，不映射。
pub fn init(memory: dtb.Region, guards: []const usize) MapError!void {
    const text = @intFromPtr(&__text_start);
    const rodata = @intFromPtr(&__rodata_start);
    const data = @intFromPtr(&__data_start);
    const end = kernelEnd();
    const mem_end = std.mem.alignBackward(usize, memory.end(), page.size);
    if (text < memory.base or end > mem_end) @panic("kernel image is outside of RAM");

    kernel_root = @ptrCast(try page.alloc());
    try map(kernel_root, text, text, rodata - text, .{ .r = true, .x = true });
    try map(kernel_root, rodata, rodata, data - rodata, .{ .r = true });
    try mapExcept(kernel_root, data, end, guards, .{ .r = true, .w = true });
    // 内核之后的内存：页分配器管理的页、页表、设备树都在这里。
    // 内核之前是 OpenSBI，S 模式本来就无权访问（被 PMP 挡住），不映射。
    try map(kernel_root, end, end, mem_end - end, .{ .r = true, .w = true });
    try mapMmio(uart.base, uart.mmio_size);
    try mapMmio(plic.base, plic.mmio_size);
    try mapMmio(virtio_disk.mmio_base, virtio_disk.mmio_size);

    activate(kernel_root);
}

/// 其他 hart 启动时调用：内核页表已经由启动 hart 建好，启动后不再改，各个 hart 共用，打开分页就行。
pub fn initHart() void {
    activate(kernel_root);
}

/// 恒等映射 [start, end)，跳过 holes 里的页（按地址排好序，都按页对齐）。洞之间的每一段照常尽量用大页。
fn mapExcept(root: *PageTable, start: usize, end: usize, holes: []const usize, perm: Perm) MapError!void {
    var va = start;
    for (holes) |h| {
        std.debug.assert(h % page.size == 0 and h >= va and h + page.size <= end);
        if (h > va) try map(root, va, va, h - va, perm);
        va = h + page.size;
    }
    if (end > va) try map(root, va, va, end - va, perm);
}

fn mapMmio(base: usize, size: usize) MapError!void {
    try map(kernel_root, base, base, std.mem.alignForward(usize, size, page.size), .{ .r = true, .w = true });
}

/// 切换到 root 描述的地址空间。
pub fn activate(root: *PageTable) void {
    kstat.add(.tlb_full_flushes, 2);
    riscv.sfenceVma();
    riscv.write(.satp, riscv.satp_sv39 | (@intFromPtr(root) >> 12));
    riscv.sfenceVma();
}

/// 改了当前 hart 正在用的页表之后刷新 TLB（va 为 null 时整个刷掉，否则只刷这一页）。
/// 单元测试在主机上运行，没有 TLB 可刷。
fn flushTlb(va: ?usize) void {
    if (comptime !builtin.cpu.arch.isRISCV()) return;
    if (va) |a| riscv.sfenceVmaPage(a) else {
        kstat.inc(.tlb_full_flushes);
        riscv.sfenceVma();
    }
}

/// 第 level 级（0、1、2）一个叶子映射的大小：4 KiB、2 MiB、1 GiB。
fn levelSize(level: u2) usize {
    return @as(usize, 1) << (12 + 9 * @as(u6, level));
}

fn vpn(va: usize, level: u2) usize {
    return (va >> (12 + 9 * @as(u6, level))) & 0x1ff;
}

/// 把虚拟地址 [va, va+size) 映射到物理地址 [pa, pa+size)，地址和长度都要按页对齐。
/// 对齐条件和剩余长度允许时就用大页，这样 128 MiB 内存只需要几张页表。
pub fn map(root: *PageTable, va: usize, pa: usize, size: usize, perm: Perm) MapError!void {
    std.debug.assert(va % page.size == 0 and pa % page.size == 0 and size % page.size == 0);
    // 叶子必须至少可读或可执行（R/W/X 全为 0 表示指向下一级页表），可写必须可读（W 无 R 是保留组合）
    std.debug.assert((perm.r or perm.x) and (perm.r or !perm.w));
    // 用户映射只能落在用户区里，内核映射不能落进用户区，否则进程之间会共用页表（见文件开头）
    const in_user = va >= user_base and va + size <= user_end;
    const overlaps_user = va < user_end and va + size > user_base;
    std.debug.assert(if (perm.u) in_user else !overlaps_user);

    var offset: usize = 0;
    while (offset < size) {
        const level: u2 = for ([_]u2{ 2, 1 }) |l| {
            const s = levelSize(l);
            if ((va + offset) % s == 0 and (pa + offset) % s == 0 and size - offset >= s) break l;
        } else 0;
        const pte = try walk(root, va + offset, level);
        if (pte.v) return error.AlreadyMapped;
        pte.* = .{
            .v = true,
            .r = perm.r,
            .w = perm.w,
            .x = perm.x,
            .u = perm.u,
            .g = !perm.u,
            .a = true,
            .d = true,
            .ppn = @intCast((pa + offset) >> 12),
        };
        offset += levelSize(level);
    }
}

/// 找到 va 在第 level 级页表里的那一项，途中缺的页表现场分配。
fn walk(root: *PageTable, va: usize, level: u2) MapError!*Pte {
    var table = root;
    var l: u2 = 2;
    while (l > level) : (l -= 1) {
        const pte = &table[vpn(va, l)];
        if (!pte.v) {
            const next = try page.alloc();
            pte.* = .{ .v = true, .ppn = @intCast(@intFromPtr(next) >> 12) };
        } else if (pte.isLeaf()) {
            return error.AlreadyMapped; // 已经被一个大页覆盖了
        }
        table = @ptrFromInt(pte.addr());
    }
    return &table[vpn(va, level)];
}

// ---- 用户地址空间 ----

/// 用户栈最多 1 MiB：[stack_limit, stack_top)。按需分配，用到哪一页才分配哪一页
pub const stack_max = abi.user_stack_max;
pub const stack_top = user_end;
pub const stack_limit = stack_top - stack_max;
/// 栈的下面留一页保护页：堆最多长到它下面为止，栈溢出时撞到它（缺页，结束进程），而不是悄悄写进堆里
pub const heap_limit = stack_limit - page.size;

/// 一个程序最多几个要加载的段（ELF 的 PT_LOAD）。user/linker.ld 链接出来的是 3 个
pub const max_segments = 8;

/// 程序的一个段，exec 时只记下来（proc.load），里面的页第一次被访问时才分配（fault）：
/// 段在文件里的那部分（从程序文件的 file_off 开始的 file_size 字节）读进来，剩下的（.bss）是 0。
pub const Segment = struct {
    /// 段的起点（按页对齐）和终点（向上对齐到页）
    start: usize,
    end: usize,
    perm: Perm,
    file_off: u64,
    file_size: u64,
};

/// 段的内容从哪读。
pub const Backing = union(enum) {
    none,
    /// 嵌在内核里的字节：init（第一个进程要在挂载文件系统之前加载）、单元测试
    bytes: []const u8,
    /// 文件系统里的程序文件（exec），inode 号。有地址空间用着它时它不能改、不能删（fsys.holdText），
    /// 所以什么时候读，读到的都是 exec 时的那个版本
    file: u64,

    fn read(b: Backing, off: u64, dst: []u8) error{IoError}!void {
        switch (b) {
            .none => unreachable, // 有文件内容的段一定有 backing
            // 段在不在镜像里，proc.loadSegment 检查过了
            .bytes => |bytes| @memcpy(dst, bytes[off..][0..dst.len]),
            .file => |ino| try fsys.readText(ino, off, dst),
        }
    }
};

/// 一个用户地址空间：根页表，和按需分页要知道的“哪些地址可以有页、页从哪来”。
/// 页表里只有已经访问过的页；用户区里别的地址按下面的顺序看（regionOf）：
///   segments               程序的各个段：权限按段，内容从 backing 读
///   [heap_start, brk)      堆（sbrk）：可读写，清零。按页算，brk 所在的那一页整页都能用
///   [stack_limit, user_end) 栈：可读写，清零
/// 都不是的地址（包括栈下面的保护页）访问时缺页，结束进程。
/// 只有它所属的进程自己读写（没有线程），不用加锁。
pub const Space = struct {
    root: *PageTable,
    segments: [max_segments]Segment = undefined,
    nsegments: usize = 0,
    backing: Backing = .none,
    /// 堆的起点（最后一个段之后的页边界）和当前的末尾，见 proc.sbrk
    heap_start: usize = 0,
    brk: usize = 0,

    /// 记下一个段。段按页对齐，不能和已有的段重叠（Overlap），最多 max_segments 个（TooMany）。
    pub fn addSegment(s: *Space, seg: Segment) error{ Overlap, TooMany }!void {
        std.debug.assert(seg.start % page.size == 0 and seg.end % page.size == 0 and seg.start < seg.end);
        std.debug.assert(seg.start >= user_base and seg.end <= heap_limit and seg.file_size <= seg.end - seg.start);
        for (s.segments[0..s.nsegments]) |o| {
            if (seg.start < o.end and o.start < seg.end) return error.Overlap;
        }
        if (s.nsegments == max_segments) return error.TooMany;
        s.segments[s.nsegments] = seg;
        s.nsegments += 1;
    }

    /// 页 base（按页对齐）该是什么样的，不在任何区域里返回 null。
    fn regionOf(s: *const Space, base: usize) ?Region {
        for (s.segments[0..s.nsegments]) |seg| {
            if (base < seg.start or base >= seg.end) continue;
            const o = base - seg.start;
            return .{
                .perm = seg.perm,
                .file_off = seg.file_off + o,
                .file_len = if (o < seg.file_size) @intCast(@min(page.size, seg.file_size - o)) else 0,
            };
        }
        const rw: Region = .{ .perm = .{ .r = true, .w = true } };
        if (base >= s.heap_start and base < std.mem.alignForward(usize, s.brk, page.size)) return rw;
        if (base >= stack_limit and base < stack_top) return rw;
        return null;
    }
};

const Region = struct {
    perm: Perm,
    /// 这一页开头的 file_len 个字节来自文件的 file_off，其余是 0
    file_off: u64 = 0,
    file_len: usize = 0,
};

/// 新建一个空的用户地址空间：复制内核的根页表（第 1 项在内核页表里是空的，留给用户程序）。
pub fn createUserSpace() error{OutOfMemory}!Space {
    const root: *PageTable = @ptrCast(try page.allocUninit()); // 整页马上被覆盖
    @memcpy(root, kernel_root); // 不写成 root.* = kernel_root.*：Debug 模式下会先在栈上复制一份 4 KiB
    return .{ .root = root };
}

/// 释放用户地址空间：用户区里的页、装这些页的页表，最后是根页表本身；还有对程序文件的占用（releaseBacking）。
/// 调用前要先切回别的地址空间。
pub fn destroyUserSpace(s: *Space) void {
    for (vpn(user_base, 2)..vpn(user_end - 1, 2) + 1) |i| freeTree(s.root[i], 2);
    page.free(@ptrCast(@alignCast(s.root)));
    releaseBacking(s);
}

/// 不再从程序文件读页了：放开对它的占用（fsys.releaseText），它又可以改、可以删了。
/// 进程结束时（proc.finish）就调用，不用等父进程回收；之后这个地址空间不会再缺页。
pub fn releaseBacking(s: *Space) void {
    switch (s.backing) {
        .file => |ino| fsys.releaseText(ino),
        else => {},
    }
    s.backing = .none;
}

fn freeTree(pte: Pte, level: u2) void {
    if (!pte.v) return;
    if (!pte.isLeaf() and level > 0) {
        const table: *PageTable = @ptrFromInt(pte.addr());
        for (table) |child| freeTree(child, level - 1);
    }
    // 叶子是用户的页（用户映射只用 4 KiB 的页），非叶子是页表，都还给页分配器。
    // 和别的进程共用的页（写时复制）只是放掉一个引用，最后一个用它的进程释放时才真正回到空闲链表
    page.free(@ptrFromInt(pte.addr()));
}

/// 分配一页清零的物理内存，映射到用户地址 va，返回这一页（内核通过恒等映射访问它）。单元测试用来直接摆好页。
pub fn allocUserPage(root: *PageTable, va: usize, perm: Perm) MapError!*align(page.size) page.Page {
    const p = try page.alloc();
    errdefer page.free(p);
    var user_perm = perm;
    user_perm.u = true;
    try map(root, va, @intFromPtr(p), page.size, user_perm);
    return p;
}

/// 把用户区 [alignForward(new_end), alignForward(old_end)) 里已经分配了的页取消映射并释放
/// （new_end <= old_end），用来缩小堆（sbrk）。没访问过的页本来就没有，跳过。
/// 因此空出来的第 0 级页表也释放掉：不然堆长到很大再缩回来，每 2 MiB 会留下一张空页表，直到进程结束。
/// 第 1 级页表（整个用户区只有一张）留着：它很可能还有栈的映射，空了也只是一页，地址空间释放时一起释放。
/// 改的可能是正在用的页表，调用方要刷新 TLB。
pub fn shrinkUser(root: *PageTable, old_end: usize, new_end: usize) void {
    std.debug.assert(new_end <= old_end);
    const start = std.mem.alignForward(usize, new_end, page.size);
    var va = start;
    while (va < old_end) : (va += page.size) {
        const pte = leafOf(root, va) orelse continue;
        page.free(@ptrFromInt(pte.addr()));
        pte.* = .{};
    }
    var region = std.mem.alignBackward(usize, start, levelSize(1));
    while (region < old_end) : (region += levelSize(1)) {
        const l2 = root[vpn(region, 2)];
        if (!l2.v or l2.isLeaf()) continue;
        const l1: *Pte = &@as(*PageTable, @ptrFromInt(l2.addr()))[vpn(region, 1)];
        if (!l1.v or l1.isLeaf()) continue;
        const table: *PageTable = @ptrFromInt(l1.addr());
        for (table) |pte| {
            if (pte.v) break;
        } else {
            page.free(@ptrCast(@alignCast(table)));
            l1.* = .{};
        }
    }
}

/// 找到用户地址 va 的第 0 级页表项（已经映射了的 4 KiB 页），没有就返回 null。不分配页表。
fn leafOf(root: *PageTable, va: usize) ?*Pte {
    var table = root;
    var l: u2 = 2;
    while (l > 0) : (l -= 1) {
        const pte = table[vpn(va, l)];
        if (!pte.v or pte.isLeaf()) return null;
        table = @ptrFromInt(pte.addr());
    }
    const pte = &table[vpn(va, 0)];
    return if (pte.v) pte else null;
}

/// 复制一个用户地址空间（fork 用），写时复制：新建一个地址空间，页表照 src 的结构建一份，
/// 但用户区里的页一页都不复制，叶子指向和 src 同一个物理页（引用数加 1）。
/// 可写的页在两边都改成只读、标上 cow：之后谁先写谁触发缺页，由 breakCow 给它复制一份，所以两边仍然各改各的。
/// 本来就只读的页（代码、只读数据）不会被写，一直共用。需要新分配的只有子进程的页表。
/// src 里还没访问过的页，dst 里也没有：以后谁访问谁按需分配（段的内容从同一个程序文件读，所以和 src 的一样）。
/// 段、堆、程序文件都照抄，程序文件多一个占用（fsys.dupText）。
///
/// src 是当前 hart 正在用的地址空间（fork 的父进程），改了它的页表项，最后刷新 TLB。
/// 中途内存不够时 dst 整个释放掉；src 里已经改成 cow 的页留着不改回去：以后写的时候 breakCow
/// 发现只剩自己在用，直接改回可写，不用复制。
pub fn cloneUserSpace(src: *Space) error{OutOfMemory}!Space {
    defer flushTlb(null);
    var dst = try createUserSpace();
    errdefer destroyUserSpace(&dst);
    for (vpn(user_base, 2)..vpn(user_end - 1, 2) + 1) |i| try cloneTree(dst.root, &src.root[i], 2, i * levelSize(2));
    dst.segments = src.segments;
    dst.nsegments = src.nsegments;
    dst.heap_start = src.heap_start;
    dst.brk = src.brk;
    switch (src.backing) {
        .file => |ino| fsys.dupText(ino),
        else => {},
    }
    dst.backing = src.backing;
    return dst;
}

fn cloneTree(dst: *PageTable, pte: *Pte, level: u2, va: usize) error{OutOfMemory}!void {
    if (!pte.v) return;
    if (pte.isLeaf()) {
        std.debug.assert(level == 0 and pte.u); // 用户映射只用 4 KiB 的页
        // 先建好 dst 这边的页表（可能失败），再改 src、加引用：失败时这一页还没动过
        const leaf = walk(dst, va, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.AlreadyMapped => unreachable, // dst 是新的，按 src 的结构逐页映射，不会重复
        };
        if (pte.w) {
            pte.w = false;
            pte.cow = true;
        }
        page.share(@ptrFromInt(pte.addr()));
        leaf.* = pte.*;
        return;
    }
    const table: *PageTable = @ptrFromInt(pte.addr());
    for (table, 0..) |*child, i| try cloneTree(dst, child, level - 1, va + i * levelSize(level - 1));
}

pub const CowError = error{ NotCow, OutOfMemory };

/// 写时复制：用户地址 va 所在的页是 cow 页的话，让地址空间 root 能写它。
/// 还有别的地址空间在用这一页，就复制一份换上、放掉自己对旧页的引用；只剩自己在用了
/// （别人已经复制走了，或者已经结束了），就不用复制，直接改回可写。
/// 不是 cow 页（没有映射、本来就只读、本来就可写、不在用户区）返回 NotCow，什么都不改。
/// root 是当前 hart 正在用的地址空间（或者还没用过的新地址空间），最后刷新这一页的 TLB。
pub fn breakCow(root: *PageTable, va: usize) CowError!void {
    if (va < user_base or va >= user_end) return error.NotCow;
    const pte = leafOf(root, va) orelse return error.NotCow;
    if (!pte.cow) return error.NotCow;
    const old: *align(page.size) page.Page = @ptrFromInt(pte.addr());
    // 只有映射着这一页的进程自己 fork 才会给它加引用，所以这里看到“只剩自己”，之后也不会变。
    // 看到还有别人的话，先复制、再放掉引用：别人这时也可能在复制它，放掉之前内容一定还在
    if (!page.isExclusive(old)) {
        const new = try page.allocUninit(); // 整页马上被覆盖
        @memcpy(new, old);
        pte.ppn = @intCast(@intFromPtr(new) >> 12);
        page.free(old);
    }
    pte.w = true;
    pte.cow = false;
    flushTlb(va);
}

/// 缺页时要做的访问。
pub const Access = enum { read, write, exec };

pub const FaultError = error{
    /// 这个地址不该有页（不在任何区域里、在保护页里、不在用户区），或者区域不允许这样访问（写代码段、执行数据段）
    BadAddress,
    /// 没有物理内存分配新的页（按需分页）
    OutOfMemory,
    /// 没有物理内存复制写时复制的页
    CowOutOfMemory,
    /// 从程序文件读页时读不出来
    IoError,
};

/// 缺页：用户地址 va 那一页还没有、或者不允许这样访问。处理完返回之后，重新执行那次访问就能成功（按需分页）；
/// 返回错误的话，那次访问本来就不该成功（用户程序访问的是坏地址，结束它），或者没法让它成功（没内存、读不出来）。
/// - 没有映射：看它落在哪个区域里（Space.regionOf），区域允许这样访问的话分配一页，段里的页从程序文件读内容，
///   再按区域的权限映射上。段里的页要读盘、睡着等，所以调用方不能拿着锁（拿着锁要访问用户内存的，先 pin，见下面）。
/// - 映射了、但是写时复制的页，要写它：breakCow。
/// - 映射了、权限也够：什么都不做（不会发生，除非 TLB 里留着旧的项）。
/// 用户程序访问时由陷阱处理程序调用，内核替用户程序访问用户内存时由 copyFromUser、pin 这些调用。
/// 改的是当前 hart 正在用的地址空间（或者还没用过的新地址空间），最后刷新这一页的 TLB。
pub fn fault(s: *Space, va: usize, access: Access) FaultError!void {
    if (va < user_base or va >= user_end) return error.BadAddress;
    const base = std.mem.alignBackward(usize, va, page.size);
    if (leafOf(s.root, base)) |pte| {
        if (allows(.{ .r = pte.r, .w = pte.w, .x = pte.x }, access)) return;
        if (access == .write and pte.cow) {
            kstat.inc(.faults_cow);
            return breakCow(s.root, base) catch |err| switch (err) {
                error.NotCow => unreachable,
                error.OutOfMemory => error.CowOutOfMemory,
            };
        }
        return error.BadAddress;
    }
    const r = s.regionOf(base) orelse return error.BadAddress;
    if (!allows(r.perm, access)) return error.BadAddress;
    if (r.file_len > 0) kstat.inc(.faults_file) else kstat.inc(.faults_zero);
    const p = try page.alloc(); // 清零的：段里文件之外的部分（.bss）、堆、栈都是 0
    errdefer page.free(p);
    if (r.file_len > 0) try s.backing.read(r.file_off, p[0..r.file_len]);
    var perm = r.perm;
    perm.u = true;
    map(s.root, base, @intFromPtr(p), page.size, perm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory, // 要新的页表，没有内存了
        error.AlreadyMapped => unreachable, // 上面看过了没有；读盘时睡着也没人会改这个地址空间
    };
    flushTlb(base);
}

fn allows(perm: Perm, access: Access) bool {
    return switch (access) {
        .read => perm.r,
        .write => perm.w,
        .exec => perm.x,
    };
}

/// 内核替用户程序访问用户内存时（copyFromUser、pin 这些）可能缺页，缺页可能要读盘、睡着等，所以调用方不能拿着锁：
/// 拿着自旋锁不能睡；拿着睡眠锁也不行：可能正拿着缓冲区的睡眠锁，再去拿别的缓冲区就可能和别的进程互相等。
/// 拿着文件系统的快照（读者）可以：再拿一个快照不用等谁。要拿着锁访问用户内存的，先 pin，拿着锁时用 Pinned* 复制。
fn assertMaySleep(comptime what: []const u8) void {
    if (spinlock.heldCount() != 0 or proc.sleeplocksHeld() != 0) std.debug.panic(what ++ " while holding a lock (pin the range first)", .{});
}

/// 按页表把用户地址 va 翻译成物理地址。要求这一页是 U 模式可读的（write 为 true 时还要可写），
/// 否则返回 null。
fn translateUser(root: *PageTable, va: usize, write: bool) ?usize {
    if (va < user_base or va >= user_end) return null;
    var table = root;
    var l: u2 = 2;
    while (true) : (l -= 1) {
        const pte = table[vpn(va, l)];
        if (!pte.v) return null;
        if (pte.isLeaf()) {
            if (!pte.u or !pte.r or (write and !pte.w)) return null;
            return pte.addr() + va % levelSize(l);
        }
        if (l == 0) return null; // 第 0 级必须是叶子
        table = @ptrFromInt(pte.addr());
    }
}

/// translateUser，翻译不了的话先按缺页处理（fault：按需分配、复制写时复制的页）再翻译一次。
/// 处理不了（坏地址、没内存、读不出来）返回 null（和 Linux 一样，系统调用返回 -EFAULT）。
fn userPage(s: *Space, va: usize, write: bool) ?usize {
    if (translateUser(s.root, va, write)) |pa| return pa;
    fault(s, va, if (write) .write else .read) catch return null;
    return translateUser(s.root, va, write);
}

/// 从用户地址 src 复制 dst.len 个字节到内核缓冲区 dst。
/// 系统调用收到的指针都要经过这里（或者 pin）：每一页都检查是否属于用户空间、是否允许 U 模式读，
/// 用户程序就没法借系统调用读到内核的内存。sstatus.SUM 始终为 0，内核不会直接解引用用户指针。
/// 还没分配的页和用户程序自己访问一样按需分配（fault），可能读盘，所以不能拿着锁调用。
pub fn copyFromUser(s: *Space, dst: []u8, src: usize) error{BadAddress}!void {
    assertMaySleep("copyFromUser");
    var done: usize = 0;
    while (done < dst.len) {
        const va = std.math.add(usize, src, done) catch return error.BadAddress;
        const pa = userPage(s, va, false) orelse return error.BadAddress;
        const n = @min(dst.len - done, page.size - va % page.size);
        @memcpy(dst[done..][0..n], @as([*]const u8, @ptrFromInt(pa))[0..n]);
        done += n;
    }
}

/// 把内核缓冲区 src 复制到用户地址 dst。每一页都要求 U 模式可读可写：
/// 用户程序不能借系统调用改写内核的内存，也不能改写自己的只读页（比如代码段）。
/// 写时复制的页先复制一份（breakCow），和用户程序自己写它一样，不会改到共用这一页的别的进程。
/// 中途失败时，前面的页已经写进去了；需要“要么全写、要么不写”的调用方先用 pinDst 检查。不能拿着锁调用。
pub fn copyToUser(s: *Space, dst: usize, src: []const u8) error{BadAddress}!void {
    assertMaySleep("copyToUser");
    var done: usize = 0;
    while (done < src.len) {
        const va = std.math.add(usize, dst, done) catch return error.BadAddress;
        const pa = userPage(s, va, true) orelse return error.BadAddress;
        const n = @min(src.len - done, page.size - va % page.size);
        @memcpy(@as([*]u8, @ptrFromInt(pa))[0..n], src[done..][0..n]);
        done += n;
    }
}

// ---- 先准备好、再拿着锁复制：Pinned ----
//
// 系统调用常常要拿着锁读写用户内存：写串口拿着输出锁、读写管道拿着管道锁、读写文件拿着缓冲区的睡眠锁……
// 拿着锁时不能缺页（可能要读盘、睡着等），所以要先把范围里的页都准备好，再拿锁复制。原来这是一条约定
// （先 vm.prefault 或者 checkUser，再 copyFromUser），漏了的话只有那一页恰好还没读进来时才出错，测试很难撞到。
// 现在拿着锁的复制只能通过 PinnedSrc / PinnedDst（copyFromUser 这些拿着锁调用会 panic）：它们只能由 pinSrc / pinDst 造出来，造的时候（不拿锁）
// 把页都准备好；它们的复制不缺页、不会失败，不用 catch unreachable。
//
// 这成立的前提：准备好之后，只有这个进程自己会改它的地址空间（没有线程、不换出页），而它正在这个系统调用里。
// 以后加了线程或者换页，pin 就要真的把页钉住（记一个引用，不许换出、不许 unmap）。

/// 一段准备好了、可以读的用户内存（pinSrc 给的）：拿着锁时用 copyIn 读它。
pub const PinnedSrc = struct {
    space: *Space,
    va: usize,
    len: usize,

    /// 从这段的 off 处复制 dst.len 个字节到 dst。超出这段是内核的错。
    pub fn copyIn(p: PinnedSrc, off: usize, dst: []u8) void {
        std.debug.assert(off <= p.len and dst.len <= p.len - off);
        var done: usize = 0;
        while (done < dst.len) {
            const va = p.va + off + done;
            const pa = translateUser(p.space.root, va, false) orelse std.debug.panic("pinned page 0x{x} is gone", .{va});
            const n = @min(dst.len - done, page.size - va % page.size);
            @memcpy(dst[done..][0..n], @as([*]const u8, @ptrFromInt(pa))[0..n]);
            done += n;
        }
    }

    /// fs.write 的 in
    pub fn get(p: PinnedSrc, at: usize, dst: []u8) error{}!void {
        p.copyIn(at, dst);
    }
};

/// 一段准备好了、可以写的用户内存（pinDst 给的，写时复制的页已经复制好了）：拿着锁时用 copyOut 写它。
pub const PinnedDst = struct {
    space: *Space,
    va: usize,
    len: usize,

    /// 把 src 复制到这段的 off 处。超出这段是内核的错。
    pub fn copyOut(p: PinnedDst, off: usize, src: []const u8) void {
        std.debug.assert(off <= p.len and src.len <= p.len - off);
        var done: usize = 0;
        while (done < src.len) {
            const va = p.va + off + done;
            const pa = translateUser(p.space.root, va, true) orelse std.debug.panic("pinned page 0x{x} is gone", .{va});
            const n = @min(src.len - done, page.size - va % page.size);
            @memcpy(@as([*]u8, @ptrFromInt(pa))[0..n], src[done..][0..n]);
            done += n;
        }
    }

    /// fs.read 的 out
    pub fn put(p: PinnedDst, at: usize, bytes: []const u8) error{}!void {
        p.copyOut(at, bytes);
    }
};

/// 准备好 [va, va+len) 从头开始、能准备好的最长的一段，返回它的长度：每一页都要 U 模式可读（write 为 true 时还要可写），
/// 还没分配的页分配好、程序文件的页读进来、写时复制的页（write 为 true 时）复制好。碰到坏地址、没内存就停下。
/// 前面已经准备好的页留着（内容没变）。可能读盘，不能拿着锁调用。
fn prepare(s: *Space, va: usize, len: usize, write: bool) usize {
    assertMaySleep("pin");
    if (len == 0) return 0;
    const end = std.math.add(usize, va, len) catch std.math.maxInt(usize);
    var addr = va;
    while (addr < end) {
        _ = userPage(s, addr, write) orelse break;
        addr = std.math.add(usize, std.mem.alignBackward(usize, addr, page.size), page.size) catch return end - va;
    }
    return @min(addr, end) - va;
}

/// 准备好整个 [va, va+len) 用来读，有一个字节不行就是 BadAddress（之后拿着锁读它一定成功）。
pub fn pinSrc(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedSrc {
    if (prepare(s, va, len, false) < len) return error.BadAddress;
    return .{ .space = s, .va = va, .len = len };
}

/// 和 pinSrc 一样，但只要开头能读的那一段（可能是 0 字节）：write 系统调用写串口、管道时遇到坏地址，
/// 写出前面的部分、返回写了多少。
pub fn pinSrcPrefix(s: *Space, va: usize, len: usize) PinnedSrc {
    return .{ .space = s, .va = va, .len = prepare(s, va, len, false) };
}

/// 准备好整个 [va, va+len) 用来写，有一个字节不行就是 BadAddress。
pub fn pinDst(s: *Space, va: usize, len: usize) error{BadAddress}!PinnedDst {
    if (prepare(s, va, len, true) < len) return error.BadAddress;
    return .{ .space = s, .va = va, .len = len };
}

/// 测试用的“物理内存”：页分配器管理这块数组，页表就建在里面。
var test_memory: [600 * page.size]u8 align(page.size) = undefined;

fn testInit() void {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
}

test "对齐和长度允许时用大页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    // 2 MiB + 4 KiB：一个 2 MiB 的大页（第 1 级叶子）加一个 4 KiB 的页（第 0 级叶子），需要第 1、0 级各一张页表
    try map(kernel_root, 0x8000_0000, 0x8000_0000, (2 << 20) + page.size, .{ .r = true, .w = true });
    try std.testing.expectEqual(before - 2, page.freePages());
    // 1 GiB 对齐的 1 GiB：根页表里的一项就够了，不需要新的页表
    try map(kernel_root, 0xc000_0000, 0xc000_0000, 1 << 30, .{ .r = true, .w = true });
    try std.testing.expectEqual(before - 2, page.freePages());
    // 已经被大页覆盖的地址不能再映射
    try std.testing.expectError(error.AlreadyMapped, map(kernel_root, 0x8010_0000, 0x8010_0000, page.size, .{ .r = true }));
}

test "mapExcept 跳过保护页，两边照常映射" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const base: usize = 0x8040_0000;
    const holes = [_]usize{ base + page.size, base + 5 * page.size };
    try mapExcept(kernel_root, base, base + (4 << 20), &holes, .{ .r = true, .w = true });
    for (0..1024) |i| {
        const va = base + i * page.size;
        const hole = std.mem.indexOfScalar(usize, &holes, va) != null;
        var table = kernel_root;
        var l: u2 = 2;
        const mapped = while (true) : (l -= 1) {
            const pte = table[vpn(va, l)];
            if (!pte.v) break false;
            if (pte.isLeaf()) break pte.addr() + va % levelSize(l) == va;
            table = @ptrFromInt(pte.addr());
        };
        try std.testing.expectEqual(!hole, mapped);
    }
}

test "copyFromUser 只读得到 U 模式可读的用户页，用户空间释放后不漏页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    try map(kernel_root, 0x8020_0000, 0x8020_0000, page.size, .{ .r = true, .x = true });
    const before = page.freePages();

    var space = try createUserSpace();
    const p0 = try allocUserPage(space.root, user_base, .{ .r = true, .w = true });
    const p1 = try allocUserPage(space.root, user_base + page.size, .{ .r = true });
    _ = try allocUserPage(space.root, user_base + 2 * page.size, .{ .x = true }); // 只能执行，不可读
    @memcpy(p0[page.size - 3 ..], "abc");
    @memcpy(p1[0..3], "def");

    var buf: [6]u8 = undefined;
    try copyFromUser(&space, &buf, user_base + page.size - 3); // 跨页
    try std.testing.expectEqualStrings("abcdef", &buf);
    const bad = [_]usize{
        user_base + 2 * page.size, // 不可读
        user_base + 3 * page.size, // 没有映射，也不在任何区域里
        0x8020_0000, // 内核的页：这个地址空间里有映射，但不在用户区、没有 U 位
        std.math.maxInt(usize) - 2, // 地址加长度溢出
    };
    for (bad) |va| try std.testing.expectError(error.BadAddress, copyFromUser(&space, &buf, va));

    // 释放的只是用户区的页和页表，和内核共用的页表不动
    destroyUserSpace(&space);
    try std.testing.expectEqual(before, page.freePages());
}

test "copyToUser 只写得进 U 模式可写的用户页；pin 检查整个范围，之后 Pinned 的复制不会失败" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var space = try createUserSpace();
    defer {
        destroyUserSpace(&space);
        std.testing.expectEqual(before, page.freePages()) catch @panic("leaked pages");
    }
    const p0 = try allocUserPage(space.root, user_base, .{ .r = true, .w = true });
    const p1 = try allocUserPage(space.root, user_base + page.size, .{ .r = true, .w = true });
    _ = try allocUserPage(space.root, user_base + 2 * page.size, .{ .r = true }); // 只读

    try copyToUser(&space, user_base + page.size - 2, "wxyz"); // 跨页
    try std.testing.expectEqualStrings("wx", p0[page.size - 2 ..]);
    try std.testing.expectEqualStrings("yz", p1[0..2]);
    try std.testing.expectError(error.BadAddress, copyToUser(&space, user_base + 2 * page.size, "a")); // 只读
    try std.testing.expectError(error.BadAddress, copyToUser(&space, user_base + 3 * page.size, "a")); // 没有映射

    _ = try pinDst(&space, user_base, 2 * page.size);
    _ = try pinSrc(&space, user_base, 3 * page.size);
    _ = try pinDst(&space, 0, 0); // 长度为 0：不检查地址
    try std.testing.expectError(error.BadAddress, pinDst(&space, user_base, 2 * page.size + 1));
    try std.testing.expectError(error.BadAddress, pinSrc(&space, user_base + 1, 3 * page.size));
    try std.testing.expectError(error.BadAddress, pinSrc(&space, user_base, std.math.maxInt(usize)));
    // 只要开头能读的一段：前 3 页可读，第 4 页没有映射
    try std.testing.expectEqual(3 * page.size - 10, pinSrcPrefix(&space, user_base + 10, 5 * page.size).len);
    try std.testing.expectEqual(0, pinSrcPrefix(&space, user_base + 3 * page.size, 10).len);
    try std.testing.expectEqual(0, pinSrcPrefix(&space, 0x8020_0000, 10).len);
    try std.testing.expectEqual(page.size, pinSrcPrefix(&space, user_end - page.size, std.math.maxInt(usize)).len); // 溢出
    // 拿着锁时用 Pinned 复制：不缺页、不会失败
    const dst = try pinDst(&space, user_base + page.size - 2, 4);
    dst.copyOut(0, "PQRS");
    var got: [4]u8 = undefined;
    (try pinSrc(&space, user_base + page.size - 2, 4)).copyIn(0, &got);
    try std.testing.expectEqualStrings("PQRS", &got);
}

/// 按需分页测试用的程序镜像：第 i 个字节是 i % 251
const test_image: [6000]u8 = blk: {
    @setEvalBranchQuota(10000);
    var b: [6000]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = i % 251;
    break :blk b;
};

/// 一个像 exec 刚加载完的地址空间，页表里还什么都没有：
///   代码段 2 页 r-x：镜像的 [0, 6000)（第 2 页后半是 0）
///   数据段 2 页 rw-：镜像的 [100, 110)，其余（.bss）是 0
///   堆从数据段之后开始，brk 在堆的第 1 页中间
fn testSpace() !Space {
    var s = try createUserSpace();
    s.backing = .{ .bytes = &test_image };
    try s.addSegment(.{ .start = user_base, .end = user_base + 2 * page.size, .perm = .{ .r = true, .x = true }, .file_off = 0, .file_size = 6000 });
    try s.addSegment(.{ .start = user_base + 2 * page.size, .end = user_base + 4 * page.size, .perm = .{ .r = true, .w = true }, .file_off = 100, .file_size = 10 });
    s.heap_start = user_base + 4 * page.size;
    s.brk = s.heap_start + 100;
    return s;
}

test "按需分页：段、堆、栈的页第一次访问时才分配；段的内容来自程序镜像，其余是 0；权限按区域" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var s = try testSpace();
    // 只有根页表
    try std.testing.expectEqual(before - 1, page.freePages());

    // 读代码段的第 2 页：分配 1 页 + 第 1、0 级页表各一张；文件之外的部分是 0
    var buf: [8]u8 = undefined;
    try copyFromUser(&s, &buf, user_base + 6000 - 4);
    try std.testing.expectEqualSlices(u8, &.{ test_image[5996], test_image[5997], test_image[5998], test_image[5999], 0, 0, 0, 0 }, &buf);
    try std.testing.expectEqual(before - 4, page.freePages());
    try std.testing.expect(leafOf(s.root, user_base) == null); // 第 1 页还没碰过
    // 数据段：开头 10 个字节来自镜像的 100 起，后面是 0，可写；.bss 那一页整页是 0
    try copyFromUser(&s, &buf, user_base + 2 * page.size + 6);
    try std.testing.expectEqualSlices(u8, &.{ 106, 107, 108, 109, 0, 0, 0, 0 }, &buf);
    try copyToUser(&s, user_base + 3 * page.size + 10, "bss!");
    try copyFromUser(&s, buf[0..4], user_base + 3 * page.size + 10);
    try std.testing.expectEqualStrings("bss!", buf[0..4]);

    // 权限按区域：代码段不能写、数据段不能执行；没分配过的页也不会因为越权的访问被分配
    const pages = page.freePages();
    try std.testing.expectError(error.BadAddress, copyToUser(&s, user_base, "x"));
    try std.testing.expectError(error.BadAddress, fault(&s, user_base, .write));
    try std.testing.expectError(error.BadAddress, fault(&s, user_base + 2 * page.size, .exec));
    try std.testing.expectEqual(pages, page.freePages());
    try fault(&s, user_base, .exec);
    try fault(&s, user_base, .exec); // 已经有了：什么都不做
    try std.testing.expectEqual(pages - 1, page.freePages());

    // 堆：brk 所在的那一页整页都能用，再往后不行；栈：[stack_limit, stack_top)，下面的保护页不行
    try copyToUser(&s, s.heap_start + page.size - 1, "h");
    try std.testing.expectError(error.BadAddress, copyToUser(&s, s.heap_start + page.size, "h"));
    try copyToUser(&s, stack_top - 1, "s");
    try copyToUser(&s, stack_limit, "s");
    try std.testing.expectError(error.BadAddress, copyToUser(&s, stack_limit - 1, "s"));
    try std.testing.expectError(error.BadAddress, fault(&s, heap_limit, .read));
    try std.testing.expectError(error.BadAddress, fault(&s, user_base - 1, .read));
    try std.testing.expectError(error.BadAddress, fault(&s, user_end, .read));

    // pin 也按需分配；整个范围都在区域里才通过
    _ = try pinDst(&s, s.heap_start, page.size);
    try std.testing.expectError(error.BadAddress, pinSrc(&s, s.heap_start, page.size + 1));

    destroyUserSpace(&s);
    try std.testing.expectEqual(before, page.freePages());
}

test "按需分页：段不能重叠，最多 max_segments 个；程序文件的页读不出来时什么都不改" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var s = try testSpace();
    const rx: Perm = .{ .r = true, .x = true };
    try std.testing.expectError(error.Overlap, s.addSegment(.{ .start = user_base + page.size, .end = user_base + 3 * page.size, .perm = rx, .file_off = 0, .file_size = 0 }));
    for (2..max_segments) |i| try s.addSegment(.{ .start = user_base + (10 + i) * page.size, .end = user_base + (11 + i) * page.size, .perm = rx, .file_off = 0, .file_size = 0 });
    try std.testing.expectError(error.TooMany, s.addSegment(.{ .start = user_base + 100 * page.size, .end = user_base + 101 * page.size, .perm = rx, .file_off = 0, .file_size = 0 }));

    // 换成“文件系统里的程序文件”：单元测试里没有挂载文件系统，读不出来，分配的页还回去；堆、.bss 这些清零的页照常分配
    s.backing = .{ .file = 1234 };
    const pages = page.freePages();
    try std.testing.expectError(error.IoError, fault(&s, user_base, .read));
    try std.testing.expectEqual(pages, page.freePages());
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BadAddress, copyFromUser(&s, &buf, user_base));
    try fault(&s, user_base + 3 * page.size, .write); // .bss
    try copyToUser(&s, s.heap_start, "heap");
    s.backing = .none; // 没有真的占用程序文件
    destroyUserSpace(&s);
    try std.testing.expectEqual(before, page.freePages());
}

test "cloneUserSpace 写时复制：只建页表、共用页；谁先写谁复制，两边互不影响，释放后不漏页" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var src = try createUserSpace();
    const data = try allocUserPage(src.root, user_base, .{ .r = true, .w = true });
    _ = try allocUserPage(src.root, user_base + page.size, .{ .r = true, .x = true });
    _ = try allocUserPage(src.root, user_end - page.size, .{ .r = true, .w = true }); // 栈：另一张第 0 级页表
    @memcpy(data[0..5], "hello");

    // 只分配了页表：根页表、第 1 级一张、第 0 级两张
    const cloned = page.freePages();
    var dst = try cloneUserSpace(&src);
    try std.testing.expectEqual(cloned - 4, page.freePages());
    // 两边的可写页都变成了 cow（只读），代码页不是 cow，仍然只读
    for ([_]*PageTable{ src.root, dst.root }) |root| {
        try std.testing.expect(leafOf(root, user_base).?.cow and !leafOf(root, user_base).?.w);
        try std.testing.expect(!leafOf(root, user_base + page.size).?.cow);
        try std.testing.expectEqual(leafOf(src.root, user_base).?.ppn, leafOf(root, user_base).?.ppn);
    }

    var buf: [5]u8 = undefined;
    try copyFromUser(&dst, &buf, user_base);
    try std.testing.expectEqualStrings("hello", &buf);
    // 子进程先写：复制一份，父进程的不变
    try copyToUser(&dst, user_base, "HELLO");
    try std.testing.expectEqual(cloned - 5, page.freePages());
    try copyFromUser(&src, &buf, user_base);
    try std.testing.expectEqualStrings("hello", &buf);
    try std.testing.expect(!leafOf(dst.root, user_base).?.cow and leafOf(dst.root, user_base).?.w);
    // 父进程再写：这一页只剩它在用了，直接改回可写，不复制，还是原来那一页
    try copyToUser(&src, user_base, "world");
    try std.testing.expectEqual(cloned - 5, page.freePages());
    try std.testing.expectEqual(@intFromPtr(data), leafOf(src.root, user_base).?.addr());
    try copyFromUser(&dst, &buf, user_base);
    try std.testing.expectEqualStrings("HELLO", &buf);
    // 代码页可读不可写（不是 cow，breakCow 不管），没映射的还是没映射
    try copyFromUser(&dst, &buf, user_base + page.size);
    try std.testing.expectError(error.BadAddress, copyToUser(&dst, user_base + page.size, "a"));
    try std.testing.expectError(error.NotCow, breakCow(dst.root, user_base + page.size));
    try std.testing.expectError(error.NotCow, breakCow(dst.root, user_base + 2 * page.size));
    try std.testing.expectError(error.NotCow, breakCow(dst.root, user_base)); // 已经复制过了
    try std.testing.expectError(error.BadAddress, copyFromUser(&dst, &buf, user_base + 2 * page.size));
    // pinDst 把 cow 页复制好
    _ = try pinDst(&dst, user_end - page.size, page.size);
    try std.testing.expect(leafOf(dst.root, user_end - page.size).?.w);
    try std.testing.expect(leafOf(src.root, user_end - page.size).?.cow);

    // 先释放父进程：共用的代码页、栈页还在被子进程用着，不能回到空闲链表
    destroyUserSpace(&src);
    try copyFromUser(&dst, &buf, user_base + page.size);
    // 子进程再 fork 一次，三方共用之后依次释放
    var grandchild = try cloneUserSpace(&dst);
    destroyUserSpace(&dst);
    try copyToUser(&grandchild, user_base, "again"); // 只剩它在用：不复制
    destroyUserSpace(&grandchild);
    try std.testing.expectEqual(before, page.freePages());
}

test "cloneUserSpace 之后，两边没访问过的页各自按需分配，内容都来自程序镜像；段和堆照抄" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var src = try testSpace();
    try copyToUser(&src, user_base + 2 * page.size, "parent"); // 数据段第 1 页：父进程改过
    var dst = try cloneUserSpace(&src);
    try std.testing.expectEqual(src.nsegments, dst.nsegments);
    try std.testing.expectEqual(src.brk, dst.brk);
    var buf: [6]u8 = undefined;
    try copyFromUser(&dst, &buf, user_base + 2 * page.size);
    try std.testing.expectEqualStrings("parent", &buf); // 共用的页
    // 代码段两边都没碰过：各自从镜像读
    try copyFromUser(&dst, buf[0..3], user_base + 251);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2 }, buf[0..3]);
    try std.testing.expect(leafOf(src.root, user_base) == null);
    try copyFromUser(&src, buf[0..3], user_base + 252);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, buf[0..3]);
    try std.testing.expect(leafOf(src.root, user_base).?.ppn != leafOf(dst.root, user_base).?.ppn);
    // .bss：子进程写的父进程看不到
    try copyToUser(&dst, user_base + 3 * page.size, "child");
    try copyFromUser(&src, buf[0..5], user_base + 3 * page.size);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0 }, buf[0..5]);
    destroyUserSpace(&src);
    destroyUserSpace(&dst);
    try std.testing.expectEqual(before, page.freePages());
}

test "cloneUserSpace、写时复制内存不够时不漏页，什么都不坏" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    var src = try createUserSpace();
    for (0..8) |i| _ = try allocUserPage(src.root, user_base + i * page.size, .{ .r = true, .w = true });
    _ = try allocUserPage(src.root, user_end - page.size, .{ .r = true, .w = true });
    // 只剩 3 页：根页表、第 1 级、第 0 级各一张之后，栈那一张第 0 级页表分配不到
    var hoard: std.SinglyLinkedList = .{};
    while (page.freePages() > 3) hoard.prepend(@ptrCast(try page.alloc()));
    try std.testing.expectError(error.OutOfMemory, cloneUserSpace(&src));
    try std.testing.expectEqual(3, page.freePages());
    // 父进程已经改成 cow 的页只剩自己在用，写的时候直接改回可写，不用内存
    while (page.freePages() > 0) hoard.prepend(@ptrCast(try page.alloc()));
    try copyToUser(&src, user_base, "ok");
    try copyToUser(&src, user_end - 2, "ok");

    // 真正共用的页：没有内存复制时返回 CowOutOfMemory / BadAddress，两边都不变
    for (0..4) |_| page.free(@ptrCast(@alignCast(hoard.popFirst().?)));
    var dst = try cloneUserSpace(&src);
    try std.testing.expectEqual(0, page.freePages());
    try std.testing.expectError(error.CowOutOfMemory, fault(&dst, user_base + page.size, .write));
    try std.testing.expectError(error.OutOfMemory, breakCow(dst.root, user_base + page.size));
    try std.testing.expectError(error.BadAddress, copyToUser(&dst, user_base + page.size, "x"));
    try std.testing.expectError(error.BadAddress, pinDst(&dst, user_base, 2 * page.size));
    try std.testing.expect(leafOf(dst.root, user_base + page.size).?.cow);
    try std.testing.expectEqual(leafOf(src.root, user_base + page.size).?.ppn, leafOf(dst.root, user_base + page.size).?.ppn);
    destroyUserSpace(&dst);
    destroyUserSpace(&src);
}

test "按需分配的堆：shrinkUser 只释放分配过的页和空出来的页表；内存不够时缺页失败，什么都不留" {
    testInit();
    kernel_root = @ptrCast(try page.alloc());
    var s = try testSpace();
    const heap = s.heap_start;
    _ = try copyToUser(&s, stack_top - 1, "s"); // 栈占着第 1 级页表
    const start = page.freePages();

    // 长 4 MiB（只是挪 brk），碰其中几页：只分配这几页和它们的第 0 级页表
    s.brk = heap + (4 << 20);
    try copyToUser(&s, heap, "a");
    try copyToUser(&s, heap + (3 << 20), "b");
    try copyToUser(&s, heap + (3 << 20) + 1, "c");
    const touched = page.freePages();
    try std.testing.expect(start - touched <= 2 + 3); // 2 页 + 最多 3 张第 0 级页表（堆跨了 3 个 2 MiB 区）

    // 缩到 1 MiB：后面那一页和它的页表释放了，前面那一页还在
    shrinkUser(s.root, s.brk, heap + (1 << 20));
    s.brk = heap + (1 << 20);
    try std.testing.expect(page.freePages() > touched);
    var buf: [1]u8 = undefined;
    try copyFromUser(&s, &buf, heap);
    try std.testing.expectEqualStrings("a", &buf);
    try std.testing.expectError(error.BadAddress, copyFromUser(&s, &buf, heap + (3 << 20)));
    // 再长回来：重新分配的页是清零的
    s.brk = heap + (4 << 20);
    try copyFromUser(&s, &buf, heap + (3 << 20));
    try std.testing.expectEqual(0, buf[0]);
    shrinkUser(s.root, s.brk, heap);
    s.brk = heap;
    try std.testing.expectEqual(start, page.freePages());

    // 内存不够：缺页失败，一页都不留
    s.brk = heap + 10 * page.size;
    var hoard: std.SinglyLinkedList = .{};
    while (page.freePages() > 0) hoard.prepend(@ptrCast(try page.alloc()));
    try std.testing.expectError(error.OutOfMemory, fault(&s, heap, .write));
    try std.testing.expectError(error.BadAddress, copyToUser(&s, heap, "z"));
    page.free(@ptrCast(@alignCast(hoard.popFirst().?)));
    // 只剩一页：页分到了，装它的第 0 级页表分不到，这一页也要还回去
    try std.testing.expectError(error.OutOfMemory, fault(&s, heap, .write));
    try std.testing.expectEqual(1, page.freePages());
    while (hoard.popFirst()) |n| page.free(@ptrCast(@alignCast(n)));
    destroyUserSpace(&s);
}
