//! 物理页分配器：把空闲内存切成 4 KiB 的页，用单链表串起来，分配和释放都是 O(1)。
//! 链表节点就放在空闲页自己的开头，所以记账不需要额外的内存。
//!
//! 内核对所有物理内存做了恒等映射（见 vm.zig），开分页前后都可以直接用物理地址访问页，
//! 所以这里的接口直接返回指针。只在启动时、系统调用和缺页异常里使用，不能在中断处理程序里调用。
//!
//! 每个 hart 一条空闲链表（照 xv6 lock lab 的 kalloc）：分配、释放都只拿当前 hart 自己那条的锁，
//! 几个 hart 同时分配不用排队。自己那条空了才去别的 hart 那里拿一批（steal）。
//!
//! 每一页有一个引用数：fork 之后父子进程共用同一页（写时复制，见 vm.cloneUserSpace），
//! 每多一个地址空间映射它就加 1（share），free 减 1，减到 0 才真正放回空闲链表。
//! 引用数用原子操作改，不用锁。引用数数组放在管理范围最开头的几页里（128 MiB 内存是 8 页）。

const std = @import("std");
const dtb = @import("dtb.zig");
const hart = @import("hart.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const size = 4096;
pub const Page = [size]u8;

/// 一个 hart 的空闲页
const Pool = struct {
    /// 保护 list 和 count。分配、释放拿自己的，steal 拿别人的；一次只拿一把
    lock: Spinlock = .init("page", .leaf),
    list: std.SinglyLinkedList = .{},
    count: usize = 0,
};

var pools: [hart.max]Pool = @splat(.{});
/// 自己的链表空了时，从别的 hart 一次拿多少页过来：一页一页地拿的话，接下来每次分配都要去拿别人的锁
const steal_batch = 32;
/// 归分配器管的地址范围（不含引用数数组本身），用来检查 free 收到的地址
var range: dtb.Region = .{ .base = 0, .size = 0 };
/// 每一页的引用数，按 (地址 - range.base) / size 下标。空闲页是 0。只用原子操作读写（@atomicRmw 等）。
/// 一页最多被 abi.max_procs 个进程共用，u8 足够；溢出说明引用数记错了，直接 panic
var refs: []u8 = &.{};
pub var total_pages: usize = 0;

/// 把 [start, end) 中不和 reserved 重叠的整页都放进空闲链表。最开头的几页留给引用数数组。
/// 启动时只有启动 hart 在运行，所有页都放进它的链表，别的 hart 用的时候再来拿。
pub fn init(start: usize, end: usize, reserved: []const dtb.Region) void {
    const first = std.mem.alignForward(usize, start, size);
    const hi = std.mem.alignBackward(usize, end, size);
    // 数组按整个范围的页数分配（略多于真正要管的页数，多出来的几项不用）
    const n = (hi - first) / size;
    const lo = first + std.mem.alignForward(usize, n, size); // 每页一个字节，占满整页
    if (isReserved(first, lo - first, reserved)) @panic("page.init: no room for the reference counts");
    refs = @as([*]u8, @ptrFromInt(first))[0..n];
    @memset(refs, 0);
    range = .{ .base = lo, .size = hi - lo };
    for (&pools) |*p| {
        p.list = .{};
        p.count = 0;
    }
    const pool = &pools[hart.id()];
    // 从高地址往低地址插到表头，这样先分配出去的是低地址的页，调试时更好认
    var addr = hi;
    while (addr > lo) {
        addr -= size;
        if (isReserved(addr, size, reserved)) continue;
        pool.list.prepend(@ptrFromInt(addr));
        pool.count += 1;
    }
    total_pages = pool.count;
}

/// [addr, addr+len) 是否和某个保留区重叠（哪怕只重叠一个字节）。
fn isReserved(addr: usize, len: usize, reserved: []const dtb.Region) bool {
    for (reserved) |r| {
        if (addr + len > r.base and addr < r.end()) return true;
    }
    return false;
}

/// 当前空闲的页数：各个 hart 的链表加起来。逐个拿锁读，别的 hart 正在分配、释放时只是某一瞬间前后的值。
pub fn freePages() usize {
    var n: usize = 0;
    for (&pools) |*p| {
        p.lock.acquire();
        n += p.count;
        p.lock.release();
    }
    return n;
}

/// 页 page 的引用数。不是分配器管的地址就 panic（who 是调用方的名字，打印在 panic 信息里）。
fn refOf(comptime who: []const u8, page: *align(size) Page) *u8 {
    const addr = @intFromPtr(page);
    if (addr < range.base or addr >= range.end()) {
        std.debug.panic(who ++ ": 0x{x} was not handed out by the page allocator", .{addr});
    }
    return &refs[(addr - range.base) / size];
}

/// 分配一页并清零，引用数为 1。
pub fn alloc() error{OutOfMemory}!*align(size) Page {
    const page = try allocUninit();
    @memset(page, 0);
    return page;
}

/// 分配一页，不清零（内容是上一个用它的人留下的），引用数为 1。只给马上整页覆盖它的调用方用
/// （写时复制、复制根页表），省掉一次白做的清零。
pub fn allocUninit() error{OutOfMemory}!*align(size) Page {
    const pool = &pools[hart.id()];
    pool.lock.acquire();
    var node = pool.list.popFirst();
    if (node != null) pool.count -= 1;
    pool.lock.release();
    if (node == null) node = steal(pool);
    const page: *align(size) Page = @ptrCast(@alignCast(node orelse return error.OutOfMemory));
    // 从空闲链表里摘下来的页只有自己知道，别人不会同时改它的引用数
    @atomicStore(u8, refOf("page.alloc", page), 1, .release);
    return page;
}

/// 从别的 hart 的链表里拿最多 steal_batch 页：一页返回给调用方，其余的放进 own。都空了返回 null。
/// 一次只拿一把锁（先放开别人的，再拿自己的），两个 hart 互相 steal 也不会死锁。
/// 内核代码不会被抢占，steal 期间一直在同一个 hart 上，own 不会变成别的 hart 的。
fn steal(own: *Pool) ?*std.SinglyLinkedList.Node {
    for (&pools) |*p| {
        if (p == own) continue;
        var got: std.SinglyLinkedList = .{};
        var n: usize = 0;
        p.lock.acquire();
        while (n < steal_batch) : (n += 1) got.prepend(p.list.popFirst() orelse break);
        p.count -= n;
        p.lock.release();
        const first = got.popFirst() orelse continue;
        own.lock.acquire();
        while (got.popFirst()) |x| {
            own.list.prepend(x);
            own.count += 1;
        }
        own.lock.release();
        return first;
    }
    return null;
}

/// 放掉一个引用。最后一个引用放掉时，这一页回到当前 hart 的空闲链表。
pub fn free(page: *align(size) Page) void {
    const old = @atomicRmw(u8, refOf("page.free", page), .Sub, 1, .acq_rel);
    if (old == 0) std.debug.panic("page.free: 0x{x} is already free", .{@intFromPtr(page)});
    if (old > 1) return;
    const pool = &pools[hart.id()];
    pool.lock.acquire();
    defer pool.lock.release();
    pool.list.prepend(@ptrCast(page));
    pool.count += 1;
}

/// 多一个引用：又有一个地址空间映射了这一页（fork 时父子共用，见 vm.cloneUserSpace）。
/// 调用方自己拿着一个引用，所以引用数不会同时被别人减到 0。
pub fn share(page: *align(size) Page) void {
    const old = @atomicRmw(u8, refOf("page.share", page), .Add, 1, .monotonic);
    if (old == 0) std.debug.panic("page.share: 0x{x} is free", .{@intFromPtr(page)});
    if (old == std.math.maxInt(u8)) std.debug.panic("page.share: 0x{x} has too many references", .{@intFromPtr(page)});
}

/// 这一页是不是只有一个引用。是的话别人不会再拿到它（只有映射着它的进程自己 fork 才会加引用），
/// 写时复制时就不用复制，直接归自己（见 vm.breakCow）。
pub fn isExclusive(page: *align(size) Page) bool {
    return @atomicLoad(u8, refOf("page.isExclusive", page), .acquire) == 1;
}

test "先分配低地址、分配时清零、跳过保留区、释放后能再用" {
    var mem: [9 * size]u8 align(size) = undefined;
    @memset(&mem, 0xaa);
    const base = @intFromPtr(&mem);
    // 第 0 页放引用数；第 3 页被保留（哪怕只保留了 1 个字节，整页都不能用）
    init(base, base + mem.len, &.{.{ .base = base + 3 * size, .size = 1 }});
    try std.testing.expectEqual(7, total_pages);

    const a = try alloc();
    const b = try alloc();
    const c = try alloc();
    try std.testing.expectEqual(base + size, @intFromPtr(a));
    try std.testing.expectEqual(base + 2 * size, @intFromPtr(b));
    try std.testing.expectEqual(base + 4 * size, @intFromPtr(c));
    try std.testing.expect(std.mem.allEqual(u8, c, 0));
    try std.testing.expectEqual(4, freePages());

    free(b);
    try std.testing.expectEqual(@intFromPtr(b), @intFromPtr(try alloc())); // 刚释放的页最先被拿走
    for (0..4) |_| _ = try alloc();
    try std.testing.expectError(error.OutOfMemory, alloc());
}

test "共用的页：最后一个引用放掉才回到空闲链表" {
    var mem: [4 * size]u8 align(size) = undefined;
    const base = @intFromPtr(&mem);
    init(base, base + mem.len, &.{});
    const before = freePages();
    const p = try alloc();
    try std.testing.expect(isExclusive(p));
    share(p);
    share(p);
    try std.testing.expect(!isExclusive(p));
    free(p);
    free(p);
    try std.testing.expect(isExclusive(p));
    try std.testing.expectEqual(before - 1, freePages());
    free(p);
    try std.testing.expectEqual(before, freePages());
    // 释放之后再分配，引用数重新从 1 开始
    try std.testing.expectEqual(p, try alloc());
    try std.testing.expect(isExclusive(p));
}

test "自己的链表空了就从别的 hart 那里拿一批" {
    var mem: [(steal_batch + 4) * size]u8 align(size) = undefined;
    const base = @intFromPtr(&mem);
    init(base, base + mem.len, &.{});
    const total = freePages();
    // 主机上 hart.id() 总是 0：把它的页都挪到 hart 1 的链表上，假装是 hart 1 释放的
    while (pools[0].list.popFirst()) |n| {
        pools[1].list.prepend(n);
        pools[0].count -= 1;
        pools[1].count += 1;
    }
    const p = try alloc();
    try std.testing.expectEqual(steal_batch - 1, pools[0].count); // 拿了一批，一页给了调用方
    try std.testing.expectEqual(total - steal_batch, pools[1].count);
    try std.testing.expectEqual(total - 1, freePages());
    free(p);
    // 把剩下的都分配完：先用自己的，再去拿 hart 1 剩下的，最后 OutOfMemory
    var pages: [steal_batch + 4]*align(size) Page = undefined;
    for (pages[0..total]) |*x| x.* = try alloc();
    try std.testing.expectError(error.OutOfMemory, alloc());
    try std.testing.expectEqual(0, freePages());
    for (pages[0..total]) |x| free(x);
    try std.testing.expectEqual(total, freePages());
}
