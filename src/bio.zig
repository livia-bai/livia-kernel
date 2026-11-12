//! 缓冲区缓存（buffer cache），照 xv6 的 bio.c 写：在内存里缓存磁盘上最近用过的块，
//! 同一个块读第二次不用再等磁盘；同时保证同一个块在内存里只有一份，几个进程要改它时排队（睡眠锁）。
//!
//! - nbuf 个缓冲区，每个装一个 4 KiB 的块（abi.block_size，正好一页）。
//!   照 xv6 lock lab 的做法按块号散列成 nbucket 个桶，每个桶一把锁：找已经缓存着的块只拿它那个桶的锁，
//!   读写不同块的进程不用排队。要一个不在缓存里的块时（换块），从所有桶里找最久没用（stamp 最小）、
//!   没人在用（refcnt 为 0）的缓冲区换掉，挪进新块的桶。
//! - read 返回拿着睡眠锁的缓冲区，内容就是磁盘上的；改完调用 write 写回磁盘（同步：写完才返回）；
//!   用完调用 release。拿着缓冲区的期间，别的进程要同一个块会睡着等。
//! - 磁盘读写交给 Device（内核里是 virtio_disk，单元测试里是一块内存）。设备可能有写缓存：
//!   write 返回只说明设备收到了，flush 返回之后之前写的块才一定落盘（文件系统提交时要靠它排好顺序，ctree.zig）。
//!
//! 锁：
//! - 每个桶的 lock（自旋锁）保护桶里的链表，和桶里每个缓冲区的 refcnt、blockno、stamp。
//! - evict_lock（自旋锁）让换块一个一个来：拿着它的才能把缓冲区从一个桶挪到另一个桶，
//!   所以同一个块不会被两个进程同时换进来、在缓存里有两份。拿着它可以再拿桶的锁（evict_lock → 桶），
//!   找换掉哪个时会同时拿着两个桶的锁，但只有拿着 evict_lock 的才这样做，不会互相等。
//!   所有缓冲区都有人在用时，拿着它睡下，等 release 叫醒。
//! - 每个缓冲区的睡眠锁保护 valid 和 data。拿到睡眠锁之后才读写磁盘，读写时睡着等，不占 CPU。

const std = @import("std");
const abi = @import("abi.zig");
const proc = @import("proc.zig");
const kstat = @import("kstat.zig");
const Spinlock = @import("spinlock.zig").Spinlock;
const Sleeplock = @import("sleeplock.zig").Sleeplock;

pub const block_size = abi.block_size;
/// 缓冲区的个数
pub const nbuf = 64;
/// 桶的个数。取质数，块号连续的块散到不同的桶里
const nbucket = 13;
/// 还没装过块的缓冲区的 blockno（check 不让任何块号等于它）
const no_block = std.math.maxInt(u64);

/// 磁盘：有多少块，怎么读写一块（同步，做完才返回，可以睡），怎么让写过的块都落盘。
pub const Device = struct {
    blocks: u64,
    transfer: *const fn (block: u64, data: *[block_size]u8, write: bool) void,
    /// 让之前写完的块都真正落到盘上（设备有写缓存时，写完的块可能还在缓存里，掉电会丢、落盘的顺序也不定）。
    /// null：设备没有写缓存，写完就落盘了（mkfs、大部分单元测试）
    flush: ?*const fn () void = null,
};

pub const Buf = struct {
    /// 保护 valid 和 data，拿着它才能读写磁盘
    lock: Sleeplock = .init("buf", .buf),
    /// 所在的桶的锁。有几个人拿着（或者在等）这个缓冲区；为 0 时可以换成别的块
    refcnt: u32 = 0,
    /// 所在的桶的锁。装的是哪个块，决定了在哪个桶里
    blockno: u64 = no_block,
    /// 所在的桶的锁。最后一次放开（refcnt 变成 0）的时刻，换块时换掉最小的（最久没用）
    stamp: u64 = 0,
    /// data 是不是这个块在磁盘上的内容（换成别的块之后为 false，第一次 read 时才去读）
    valid: bool = false,
    /// 桶里链表的节点
    node: std.DoublyLinkedList.Node = .{},
    data: *align(4096) [block_size]u8,
};

const Bucket = struct {
    lock: Spinlock = .init("bcache bucket", .bucket),
    list: std.DoublyLinkedList = .{},

    /// 桶里装着块 blockno 的缓冲区。调用方拿着 lock。
    fn find(bk: *Bucket, blockno: u64) ?*Buf {
        var it = bk.list.first;
        while (it) |n| : (it = n.next) {
            const b: *Buf = @fieldParentPtr("node", n);
            if (b.blockno == blockno) return b;
        }
        return null;
    }
};

var buckets: [nbucket]Bucket = @splat(.{});
var evict_lock: Spinlock = .init("bcache evict", .cond);
var bufs: [nbuf]Buf = undefined;
var datas: [nbuf][block_size]u8 align(4096) = undefined;
/// LRU 的时钟：每次有缓冲区变成没人用时加 1，记进它的 stamp
var clock: std.atomic.Value(u64) = .init(0);
/// 正在换块的进程个数（拿着 evict_lock 时加减）。release 看到它不为 0 才去拿 evict_lock 叫醒等着的进程
var evicting: std.atomic.Value(usize) = .init(0);
/// evict_lock。找不到能换掉的缓冲区的进程排在这里，release 放出一个没人用的缓冲区时叫醒
var evict_waiters: proc.WaitQueue = .{};
var device: ?Device = null;

pub const Error = error{ NoDevice, OutOfRange };

/// 清空缓存，换上磁盘 dev（null 表示没有磁盘）。kmain 调用一次；单元测试每次换一块内存当磁盘。
pub fn init(dev: ?Device) void {
    device = dev;
    for (&buckets) |*bk| bk.list = .{};
    for (&bufs, &datas) |*b, *d| {
        b.* = .{ .data = d };
        buckets[0].list.append(&b.node); // 还没装块的都放在第 0 个桶里，反正谁也找不到它们
    }
}

/// 磁盘有多少块，没有磁盘时是 0。
pub fn blockCount() u64 {
    return if (device) |d| d.blocks else 0;
}

fn check(blockno: u64) Error!Device {
    const dev = device orelse return error.NoDevice;
    if (blockno >= dev.blocks) return error.OutOfRange;
    return dev;
}

fn bucketOf(blockno: u64) *Bucket {
    return &buckets[blockno % nbucket];
}

/// 块 blockno 的缓冲区，拿着睡眠锁返回，不读磁盘：valid 为 false 时内容是别的块留下的。
/// 要整块覆盖的调用方用它，省掉一次读；覆盖完把 valid 设成 true，再 write。
/// 所有缓冲区都有人在用时睡着等。只能由进程调用。
pub fn get(blockno: u64) Error!*Buf {
    _ = try check(blockno);
    const bk = bucketOf(blockno);
    bk.lock.acquire();
    if (bk.find(blockno)) |b| {
        b.refcnt += 1;
        bk.lock.release();
        b.lock.acquire();
        return b;
    }
    bk.lock.release();
    const b = evict(bk, blockno);
    b.lock.acquire();
    return b;
}

/// 块 blockno 不在缓存里：换掉一个最久没用的缓冲区，挪进桶 bk，refcnt 为 1。
fn evict(bk: *Bucket, blockno: u64) *Buf {
    evict_lock.acquire();
    defer evict_lock.release();
    // 先登记再找：release 在找完之后才把某个缓冲区放成没人用的话，一定看得到 evicting 不为 0，会来叫醒
    _ = evicting.fetchAdd(1, .seq_cst);
    defer _ = evicting.fetchSub(1, .seq_cst);
    while (true) {
        // 放开桶的锁到拿到 evict_lock 之间，别人可能已经把这个块换进来了。
        // 换进来都要拿着 evict_lock，所以现在查一次就够了：之后没人能再换进它
        bk.lock.acquire();
        if (bk.find(blockno)) |b| {
            b.refcnt += 1;
            bk.lock.release();
            return b;
        }
        bk.lock.release();
        if (takeOldest()) |b| {
            b.blockno = blockno;
            b.valid = false;
            b.refcnt = 1;
            bk.lock.acquire();
            bk.list.prepend(&b.node);
            bk.lock.release();
            return b;
        }
        evict_waiters.wait(&evict_lock);
    }
}

/// 从所有桶里找 refcnt 为 0、stamp 最小的缓冲区，从它的桶里摘下来返回（不在任何桶里，别人找不到它）；
/// 都有人在用返回 null。调用方拿着 evict_lock。一直拿着目前最好的候选所在的桶的锁，
/// 这样它的 refcnt 不会在找完之前被别人加上去。
fn takeOldest() ?*Buf {
    var best: ?*Buf = null;
    var best_bk: ?*Bucket = null;
    for (&buckets) |*bk| {
        bk.lock.acquire();
        var found = false;
        var it = bk.list.first;
        while (it) |n| : (it = n.next) {
            const b: *Buf = @fieldParentPtr("node", n);
            if (b.refcnt == 0 and (best == null or b.stamp < best.?.stamp)) {
                best = b;
                found = true;
            }
        }
        if (found) {
            if (best_bk) |old| old.lock.release();
            best_bk = bk;
        } else {
            bk.lock.release();
        }
    }
    const b = best orelse return null;
    best_bk.?.list.remove(&b.node);
    best_bk.?.lock.release();
    return b;
}

/// 块 blockno 的缓冲区，拿着睡眠锁返回，内容是磁盘上的（不在缓存里就读进来）。
pub fn read(blockno: u64) Error!*Buf {
    const b = try get(blockno);
    _ = load(b);
    return b;
}

/// get 拿到的缓冲区内容无效的话从磁盘读进来。返回这次是不是真的读了磁盘：
/// 文件系统只在读盘时验校验和，缓存里的内容验过了就不用每次都算（ctree.zig）。
/// 发现内容不对的调用方把 valid 设回 false，下次再读盘。
pub fn load(b: *Buf) bool {
    std.debug.assert(b.lock.holding());
    if (b.valid) {
        kstat.inc(.bio_hits);
        return false;
    }
    kstat.inc(.bio_misses);
    kstat.inc(.disk_reads);
    device.?.transfer(b.blockno, b.data, false);
    b.valid = true;
    return true;
}

/// 没人在用的缓冲区都作废（valid = false），之后读它们都重新读盘。scrub 用：要核对的是磁盘上的内容，
/// 不是缓存里的（校验和只在读盘时核对）。写都是同步的，缓存里没有还没写下去的内容，作废不会丢东西；
/// refcnt 为 0 说明没人拿着、也没人在等它的睡眠锁，所以拿着桶的锁就能改 valid。
pub fn invalidate() void {
    for (&buckets) |*bk| {
        bk.lock.acquire();
        defer bk.lock.release();
        var it = bk.list.first;
        while (it) |n| : (it = n.next) {
            const b: *Buf = @fieldParentPtr("node", n);
            if (b.refcnt == 0) b.valid = false;
        }
    }
}

/// 把缓冲区写回磁盘，写完才返回。调用方拿着它的睡眠锁。
pub fn write(b: *Buf) void {
    std.debug.assert(b.lock.holding() and b.valid);
    kstat.inc(.disk_writes);
    device.?.transfer(b.blockno, b.data, true);
}

/// 等之前写的块（write 返回过的）都落盘。只能由进程调用（要睡着等设备）。
pub fn flush() void {
    kstat.inc(.disk_flushes);
    if (device.?.flush) |f| f();
}

/// 用完了：放开睡眠锁。没人用了就记下现在的时刻（LRU），有进程在等空闲缓冲区的话叫醒它。
pub fn release(b: *Buf) void {
    b.lock.release();
    // 拿着睡眠锁时别人换不掉它（refcnt > 0），blockno 不会变，所以桶也不会变
    const bk = bucketOf(b.blockno);
    bk.lock.acquire();
    b.refcnt -= 1;
    const idle = b.refcnt == 0;
    if (idle) b.stamp = clock.fetchAdd(1, .monotonic) + 1;
    bk.lock.release();
    if (idle and evicting.load(.seq_cst) > 0) {
        evict_lock.acquire();
        evict_waiters.wakeAll(&evict_lock);
        evict_lock.release();
    }
}

// ---- 单元测试：一块内存当磁盘，记下读写了几次 ----

const test_blocks = 160;
var test_disk: [test_blocks][block_size]u8 = undefined;
var test_reads: usize = 0;
var test_writes: usize = 0;

fn testTransfer(block: u64, data: *[block_size]u8, write_: bool) void {
    if (write_) {
        test_writes += 1;
        test_disk[block] = data.*;
    } else {
        test_reads += 1;
        data.* = test_disk[block];
    }
}

fn testInit() void {
    for (&test_disk, 0..) |*blk, i| @memset(blk, @truncate(i));
    test_reads = 0;
    test_writes = 0;
    init(.{ .blocks = test_blocks, .transfer = testTransfer });
}

test "缓存命中不读磁盘；超出 nbuf 时换掉最久没用的块" {
    const expectEqual = std.testing.expectEqual;
    testInit();
    var b = try read(5);
    try expectEqual(5, b.data[0]);
    release(b);
    b = try read(5);
    release(b);
    try expectEqual(1, test_reads);

    // 再读 nbuf - 1 个别的块：块 5 还在缓存里（缓存正好装满）
    for (10..10 + nbuf - 1) |i| release(try read(i));
    try expectEqual(nbuf, test_reads);
    release(try read(5));
    try expectEqual(nbuf, test_reads);
    // 再读一个新块：换掉的是最久没用的块 10，不是刚用过的块 5
    release(try read(10 + nbuf + 20));
    release(try read(5));
    try expectEqual(nbuf + 1, test_reads);
    release(try read(10));
    try expectEqual(nbuf + 2, test_reads);
}

test "invalidate 之后重新读盘，拿着的缓冲区不受影响" {
    const expectEqual = std.testing.expectEqual;
    testInit();
    release(try read(3));
    const held = try read(4);
    try expectEqual(2, test_reads);
    test_disk[3][0] = 0xee; // 磁盘上变了，缓存里还是旧的
    var b = try read(3);
    try expectEqual(3, b.data[0]);
    release(b);
    invalidate();
    try std.testing.expect(held.valid); // 有人拿着的不作废
    b = try read(3);
    try expectEqual(0xee, b.data[0]);
    release(b);
    try expectEqual(3, test_reads);
    release(held);
}

test "write 写回磁盘；get 不读磁盘；拿着的缓冲区不会被换掉；超出范围、没有磁盘" {
    const expectEqual = std.testing.expectEqual;
    testInit();
    const b = try get(3);
    @memset(b.data, 0xab);
    b.valid = true;
    write(b);
    try expectEqual(0, test_reads);
    try expectEqual(1, test_writes);
    try expectEqual(0xab, test_disk[3][block_size - 1]);
    // 一直拿着块 3，把别的块读两遍、塞满整个缓存也换不掉它（再读块 3 的话是自己等自己，会 panic）
    for (0..2 * nbuf) |i| release(try read(4 + i % (test_blocks - 4)));
    try expectEqual(3, b.blockno);
    release(b);
    const reads = test_reads;
    release(try read(3));
    try expectEqual(reads, test_reads); // 还在缓存里，内容是写进去的
    try std.testing.expectError(error.OutOfRange, read(test_blocks));
    try std.testing.expectError(error.OutOfRange, get(std.math.maxInt(u64)));
    try expectEqual(test_blocks, blockCount());
    init(null);
    try std.testing.expectError(error.NoDevice, read(0));
    try expectEqual(0, blockCount());
}
