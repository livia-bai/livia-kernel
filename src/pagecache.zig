//! 程序文件的页缓存：按（inode 号、页在文件里的偏移、这一页来自文件的字节数）记住读进来的程序页，
//! 同一个程序再 exec 时不用再读盘，几个进程运行同一个程序时只读的页（代码、只读数据）只有一份。
//!
//! - 缓存自己拿着每一页的一个引用（page.share）。缺页时（vm.fault）先查缓存：有就再加一个引用、直接映射；
//!   没有才分配、从程序文件读，读完放进缓存。可写的段的页按写时复制映射（cow），第一次写时 breakCow 复制一份，
//!   缓存里的那一页不会被改。
//! - 缓存的页内容就是文件里的内容，所以文件内容一变就要作废（invalidate）：改内容之前（fsys.beginModify，
//!   那时没有进程在运行它）、删掉它的时候。运行期间程序文件不能改（TextBusy），所以映射着的页不会过时。
//! - 只有缓存还拿着的页（引用数是 1）可以随时丢掉：表满了时换掉一个这样的页；缺页时没有内存了，先 shrink
//!   丢掉所有这样的页再试一次。meminfo 把它们算作空闲（和 Linux 的 available 一个意思）。
//! - 锁：lock 是叶子锁，拿着它不调用 page.free（free 要拿页分配器的锁，也是叶子锁）：先从表里摘下来，放开锁再 free。
//!   page.share 是原子操作，不拿锁。

const std = @import("std");
const page = @import("page.zig");
const kstat = @import("kstat.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

/// 最多缓存多少页（4 KiB 一页，1 MiB）
pub const max_pages = 256;

const Entry = struct {
    ino: u64 = 0,
    off: u64 = 0,
    len: usize = 0,
    page: ?*align(page.size) page.Page = null,

    fn matches(e: Entry, ino: u64, off: u64, len: usize) bool {
        return e.page != null and e.ino == ino and e.off == off and e.len == len;
    }
};

var lock: Spinlock = .init("page cache", .leaf);
var entries: [max_pages]Entry = @splat(.{});
/// 表满了时从这里开始找能换掉的（轮着来）
var hand: usize = 0;

/// 程序文件 ino 从 off 起 len 字节（len ≤ 一页，其余是 0）的那一页，在缓存里的话多拿一个引用返回给调用方。
pub fn lookup(ino: u64, off: u64, len: usize) ?*align(page.size) page.Page {
    lock.acquire();
    defer lock.release();
    for (&entries) |*e| {
        if (e.matches(ino, off, len)) {
            page.share(e.page.?);
            return e.page.?;
        }
    }
    return null;
}

/// 刚读进来的页 p（调用方拿着它的一个引用）放进缓存，返回调用方该映射的页（还是调用方的一个引用）。
/// 别人已经放进去了同一页（两个进程同时缺这一页）就用缓存里的那一页，放掉 p。表满了又没有能换掉的就不缓存。
pub fn insert(ino: u64, off: u64, len: usize, p: *align(page.size) page.Page) *align(page.size) page.Page {
    var victim: ?*align(page.size) page.Page = null;
    var result = p;
    {
        lock.acquire();
        defer lock.release();
        for (&entries) |*e| {
            if (e.matches(ino, off, len)) {
                page.share(e.page.?);
                result = e.page.?;
                break;
            }
        } else if (freeSlot()) |e| {
            victim = e.page;
            page.share(p); // 缓存自己的引用
            e.* = .{ .ino = ino, .off = off, .len = len, .page = p };
        }
    }
    if (victim) |v| page.free(v);
    if (result != p) page.free(p);
    return result;
}

/// 一个空的槽位，或者一个只有缓存还拿着的页的槽位（调用方之后放掉它原来的页）。都没有返回 null。调用方拿着 lock。
fn freeSlot() ?*Entry {
    for (&entries) |*e| if (e.page == null) return e;
    for (0..entries.len) |_| {
        const e = &entries[hand];
        hand = (hand + 1) % entries.len;
        if (page.isExclusive(e.page.?)) return e;
    }
    return null;
}

/// 程序文件 ino 的内容要变了（或者它被删了）：缓存里它的页都不要了。调用方保证这时没有地址空间映射着它们。
pub fn invalidate(ino: u64) void {
    while (true) {
        const p = blk: {
            lock.acquire();
            defer lock.release();
            for (&entries) |*e| {
                if (e.page != null and e.ino == ino) {
                    const p = e.page.?;
                    e.* = .{};
                    break :blk p;
                }
            }
            return;
        };
        page.free(p);
    }
}

/// 丢掉所有只有缓存还拿着的页（没有内存了）。返回丢了几页。
pub fn shrink() usize {
    var n: usize = 0;
    while (true) {
        const p = blk: {
            lock.acquire();
            defer lock.release();
            for (&entries) |*e| {
                if (e.page != null and page.isExclusive(e.page.?)) {
                    const p = e.page.?;
                    e.* = .{};
                    break :blk p;
                }
            }
            return n;
        };
        page.free(p);
        n += 1;
    }
}

pub const Counts = struct {
    /// 缓存着的页
    cached: usize = 0,
    /// 其中只有缓存还拿着的（随时可以丢掉）
    reclaimable: usize = 0,
};

pub fn counts() Counts {
    lock.acquire();
    defer lock.release();
    var c: Counts = .{};
    for (entries) |e| if (e.page) |p| {
        c.cached += 1;
        if (page.isExclusive(p)) c.reclaimable += 1;
    };
    return c;
}

/// 测试用：清空（不放掉页）。
pub fn testReset() void {
    entries = @splat(.{});
    hand = 0;
}

test "放进去、找得到、多一个引用；同一页放两次用第一次的；作废、shrink 放掉只有缓存拿着的页" {
    var mem: [8 * page.size]u8 align(page.size) = undefined;
    const base = @intFromPtr(&mem);
    page.init(base, base + mem.len, &.{});
    testReset();
    defer testReset();
    const free0 = page.freePages();
    const a = try page.alloc();
    const got = insert(5, 0, 100, a);
    try std.testing.expectEqual(a, got);
    try std.testing.expect(!page.isExclusive(a)); // 缓存 + 调用方
    try std.testing.expectEqual(null, lookup(5, 0, 99)); // 长度不同不算同一页
    try std.testing.expectEqual(null, lookup(6, 0, 100));
    const again = lookup(5, 0, 100).?;
    try std.testing.expectEqual(a, again);
    // 两个进程同时读进来同一页：第二个用缓存里的，自己那一页放掉
    const b = try page.alloc();
    try std.testing.expectEqual(a, insert(5, 0, 100, b));
    // 三个调用方的引用都放掉：只剩缓存，算作可以丢掉的
    page.free(a);
    page.free(a);
    page.free(a);
    try std.testing.expectEqual(Counts{ .cached = 1, .reclaimable = 1 }, counts());
    try std.testing.expectEqual(free0 - 1, page.freePages());
    // 另一页还有人用着：shrink 不动它；作废放掉缓存的引用
    const c = insert(7, 4096, 4096, try page.alloc());
    try std.testing.expectEqual(1, shrink());
    try std.testing.expectEqual(Counts{ .cached = 1, .reclaimable = 0 }, counts());
    invalidate(7);
    try std.testing.expectEqual(Counts{}, counts());
    try std.testing.expect(page.isExclusive(c));
    page.free(c);
    try std.testing.expectEqual(free0, page.freePages());
}
