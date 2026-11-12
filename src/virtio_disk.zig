//! virtio 块设备（virtio-blk）驱动，照 xv6 的 virtio_disk.c 写。QEMU 用 -device virtio-blk-device
//! 给 virt 机器接一块磁盘，它挂在 virtio-mmio 总线上：一组 MMIO 寄存器用来协商、配置，
//! 真正的请求通过内存里的一个“virtqueue”（三个环形数组）交给设备，设备用 DMA 直接读写内存，
//! 做完了改 used 环、发中断。规范：Virtual I/O Device (VIRTIO) Version 1.2，4.2 节（MMIO）、5.2 节（块设备）。
//!
//! - 只支持现代（version 2）的 virtio-mmio 接口。QEMU 默认给的是旧版（legacy，version 1），
//!   要加 -global virtio-mmio.force-legacy=false（build.zig 和 qemu_test.py 都加了）。
//! - 一个请求是三个描述符串成的链：请求头（读还是写、扇区号）、数据（一个 4 KiB 的块）、设备写回的状态字节。
//!   flush 请求没有数据，只有请求头和状态字节两个。
//! - 设备有写缓存时，写请求做完只说明设备收到了数据，掉电还可能丢、落盘的顺序也不保证。协商 VIRTIO_BLK_F_FLUSH，
//!   flush 请求做完之前写完的块才一定落盘（文件系统提交时靠它排顺序，见 ctree.Volume.commit）。设备不提供这个特性的话，
//!   规范要求它写完就落盘（write-through），flush 什么都不做。
//! - 发出请求的进程睡在这个请求上（rw），中断处理程序看到设备做完了就叫醒它（onInterrupt）。
//!   描述符不够用时睡在 free 上，有请求做完、放回描述符时被叫醒。
//! - 内核对物理内存是恒等映射，地址直接交给设备（DMA 用的是物理地址）。
//!
//! 外设地址和中断号按 QEMU virt 写死：8 个 virtio-mmio 槽位从 0x1000_1000 开始，每个 0x1000，
//! 第 i 个的中断号（PLIC 的中断源）是 i + 1。块设备挂在哪个槽位由 QEMU 的参数决定，init 逐个找。

const std = @import("std");
const abi = @import("abi.zig");
const uart = @import("uart.zig");
const proc = @import("proc.zig");
const Spinlock = @import("spinlock.zig").Spinlock;

pub const mmio_base: usize = 0x1000_1000;
const slot_size: usize = 0x1000;
const slots = 8;
/// 整个 virtio-mmio 区域的大小，分页时整块映射（vm.init）
pub const mmio_size: usize = slots * slot_size;

const block_size = abi.block_size;
const sector_size = 512;
const sectors_per_block = block_size / sector_size;

/// MMIO 寄存器的偏移（规范 4.2.2）。
const Reg = enum(usize) {
    magic = 0x000, // "virt"
    version = 0x004, // 2 = 现代接口
    device_id = 0x008, // 2 = 块设备，0 = 这个槽位没接设备
    device_features = 0x010,
    device_features_sel = 0x014,
    driver_features = 0x020,
    driver_features_sel = 0x024,
    queue_sel = 0x030,
    queue_num_max = 0x034,
    queue_num = 0x038,
    queue_ready = 0x044,
    queue_notify = 0x050,
    interrupt_status = 0x060,
    interrupt_ack = 0x064,
    status = 0x070,
    queue_desc_low = 0x080,
    queue_desc_high = 0x084,
    queue_driver_low = 0x090, // avail 环
    queue_driver_high = 0x094,
    queue_device_low = 0x0a0, // used 环
    queue_device_high = 0x0a4,
    config_generation = 0x0fc,
    capacity_low = 0x100, // 块设备的配置空间：容量（512 字节的扇区数），64 位
    capacity_high = 0x104,
};

const magic_value: u32 = 0x7472_6976; // 小端的 "virt"
const device_block: u32 = 2;

// status 寄存器的位（规范 2.1）
const status_acknowledge: u32 = 1;
const status_driver: u32 = 2;
const status_driver_ok: u32 = 4;
const status_features_ok: u32 = 8;

/// 特性位 VIRTIO_F_VERSION_1（第 32 位，在第 1 组特性的第 0 位）：现代接口必须协商它。
/// VIRTIO_BLK_F_FLUSH（第 0 组的第 9 位）：设备提供就要，有了它才能让写缓存落盘。
/// 别的特性一个都不要：不要只读盘（BLK_F_RO 这里不处理）、不要 event idx、不要间接描述符等。
const feature_version_1_word = 1;
const feature_version_1_bit: u32 = 1 << 0;
const feature_flush_bit: u32 = 1 << 9;

/// 描述符的个数（队列长度）。一个请求用三个，所以最多同时有 5 个请求在设备里。
const num = 16;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const desc_next: u16 = 1; // 链上还有下一个
const desc_write: u16 = 2; // 设备往这块内存里写（否则是设备读）

/// avail 环：驱动把请求链的第一个描述符的下标放进来（规范 2.7.6）。
const Avail = extern struct {
    flags: u16,
    idx: u16, // 驱动下一次往 ring 的哪一格放（只增不减，对 num 取模）
    ring: [num]u16,
    unused: u16,
};

/// used 环：设备做完的请求（规范 2.7.8）。
const Used = extern struct {
    flags: u16,
    idx: u16, // 设备下一次往 ring 的哪一格放
    ring: [num]extern struct { id: u32, len: u32 },
    unused: u16,
};

/// 请求头（规范 5.2.6）。
const Request = extern struct {
    type: u32,
    reserved: u32,
    sector: u64,
};
const request_in: u32 = 0; // 读：设备 → 内存
const request_out: u32 = 1; // 写：内存 → 设备
const request_flush: u32 = 4; // 之前做完的写都落盘

/// 设备通过 DMA 访问的内存。规范要求的对齐是 16（描述符表）、2（avail）、4（used），
/// 整个放在一页里，不跨页（物理上本来就连续，只是好认）。
const Queue = extern struct {
    desc: [num]Desc align(16),
    avail: Avail align(2),
    used: Used align(4),
    /// 每个请求链的第一个描述符对应一个请求头和一个状态字节
    requests: [num]Request,
    status: [num]u8,
};

var queue: Queue align(4096) = undefined;

/// 每个请求链（按第一个描述符的下标）的状态。由 lock 保护。
const Info = struct {
    /// 设备做完了没有。发出请求的进程拿着 lock 排在 waiters 里睡下，等它变成 true
    done: bool = false,
    waiters: proc.WaitQueue = .{},
};

/// 保护队列、描述符的分配、info 和 used_idx。加锁顺序：lock → 进程锁（睡下、叫醒）。
var lock: Spinlock = .init("virtio disk", .cond);
var free: [num]bool = @splat(true);
/// 等空闲描述符的进程
var free_waiters: proc.WaitQueue = .{};
var info: [num]Info = @splat(.{});
/// 驱动看到哪儿了：used 环里 [used_idx, used.idx) 是还没处理的
var used_idx: u16 = 0;

/// 找到的块设备的寄存器基址，没有就是 0
var base: usize = 0;
/// 设备在 PLIC 上的中断号，没有设备时是 0
pub var irq: u32 = 0;
/// 磁盘有多少个 4 KiB 的块，没有设备时是 0
pub var blocks: u64 = 0;
/// 协商到了 VIRTIO_BLK_F_FLUSH
var has_flush = false;

fn reg(r: Reg) *volatile u32 {
    return @ptrFromInt(base + @backingInt(r));
}

/// 找到块设备、协商、配置好队列（规范 3.1.1 的初始化顺序）。kmain 在开分页之后、plic.init 之前调用一次。
/// 找不到设备、或者设备只有旧版接口时打印警告，blocks 保持 0。
pub fn init() void {
    for (0..slots) |i| {
        base = mmio_base + i * slot_size;
        if (reg(.magic).* != magic_value or reg(.device_id).* != device_block) continue;
        if (reg(.version).* != 2) {
            uart.write("[warn] virtio disk uses the legacy interface; run QEMU with -global virtio-mmio.force-legacy=false\n");
            base = 0;
            return;
        }
        setup();
        irq = @intCast(i + 1);
        uart.print("[ok] virtio disk: {d} blocks of {d} KiB ({d} MiB), irq {d}, {s}\n", .{
            blocks, block_size / 1024, blocks * block_size >> 20, irq, if (has_flush) "flush" else "write-through",
        });
        return;
    }
    base = 0;
    uart.write("[warn] no virtio disk\n");
}

fn setup() void {
    const status = reg(.status);
    status.* = 0; // 复位
    status.* = status_acknowledge;
    status.* |= status_driver;

    // 特性：第 1 组只要 VERSION_1（第 0 位），第 0 组只要 BLK_F_FLUSH（设备提供的话）
    reg(.device_features_sel).* = feature_version_1_word;
    if (reg(.device_features).* & feature_version_1_bit == 0) @panic("virtio disk: device does not offer VIRTIO_F_VERSION_1");
    reg(.device_features_sel).* = 0;
    has_flush = reg(.device_features).* & feature_flush_bit != 0;
    reg(.driver_features_sel).* = 0;
    reg(.driver_features).* = if (has_flush) feature_flush_bit else 0;
    reg(.driver_features_sel).* = feature_version_1_word;
    reg(.driver_features).* = feature_version_1_bit;
    status.* |= status_features_ok;
    if (status.* & status_features_ok == 0) @panic("virtio disk: FEATURES_OK not accepted");

    // 队列 0
    reg(.queue_sel).* = 0;
    if (reg(.queue_ready).* != 0) @panic("virtio disk: queue 0 is already in use");
    if (reg(.queue_num_max).* < num) @panic("virtio disk: queue 0 is too short");
    reg(.queue_num).* = num;
    queue = std.mem.zeroes(Queue);
    setAddr(.queue_desc_low, .queue_desc_high, @intFromPtr(&queue.desc));
    setAddr(.queue_driver_low, .queue_driver_high, @intFromPtr(&queue.avail));
    setAddr(.queue_device_low, .queue_device_high, @intFromPtr(&queue.used));
    reg(.queue_ready).* = 1;

    status.* |= status_driver_ok;

    // 容量：64 位分两次读。读的过程中配置变了的话 config_generation 会变，重读
    while (true) {
        const gen = reg(.config_generation).*;
        const sectors = @as(u64, reg(.capacity_high).*) << 32 | reg(.capacity_low).*;
        if (reg(.config_generation).* == gen) {
            blocks = sectors / sectors_per_block;
            break;
        }
    }
}

fn setAddr(low: Reg, high: Reg, addr: usize) void {
    reg(low).* = @truncate(addr);
    reg(high).* = @truncate(addr >> 32);
}

/// 内存屏障：保证这之前对队列的读写，和之后的读写（包括 MMIO）不会被重排。
fn fence() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

/// 分配 n 个空闲的描述符，没有就返回 null。调用方拿着 lock。
fn allocDescs(comptime n: usize) ?[n]u16 {
    var idx: [n]u16 = undefined;
    var got: usize = 0;
    for (&free, 0..) |*f, i| {
        if (!f.*) continue;
        idx[got] = @intCast(i);
        got += 1;
        if (got == n) break;
    } else return null;
    for (idx) |i| free[i] = false;
    return idx;
}

/// 读（write 为 false）或写一个块，做完才返回（这期间进程睡着，CPU 给别的进程用）。
/// 只能由进程调用（要睡下）；data 在设备读写期间不能被别人碰，调用方拿着这个块的睡眠锁（bio.zig）。
pub fn rw(block: u64, data: *[block_size]u8, write: bool) void {
    std.debug.assert(block < blocks);
    submit(if (write) request_out else request_in, block * sectors_per_block, data);
}

/// 等之前做完的写都落盘（bio.Device.flush）。没协商到 flush 的设备是 write-through，不用做。
pub fn flush() void {
    if (has_flush) submit(request_flush, 0, null);
}

/// 发一个请求，等设备做完。data 为 null 的请求（flush）没有数据描述符。
/// 设备报错（状态字节不为 0）就 panic：QEMU 上只有内核传错了参数才会出现。
fn submit(kind: u32, sector: u64, data: ?*[block_size]u8) void {
    lock.acquire();
    defer lock.release();
    const idx = while (true) {
        if (allocDescs(3)) |idx| break idx;
        free_waiters.wait(&lock);
    };
    const head = idx[0];
    const q: *volatile Queue = &queue;

    q.requests[head] = .{ .type = kind, .reserved = 0, .sector = sector };
    q.status[head] = 0xff; // 设备做完会写成 0（成功）
    // 请求头 → [数据] → 状态字节。flush 没有数据，第二个描述符留着不用（一起分配、一起放回，简单）
    const status_desc = if (data != null) idx[2] else idx[1];
    q.desc[idx[0]] = .{ .addr = @intFromPtr(&queue.requests[head]), .len = @sizeOf(Request), .flags = desc_next, .next = idx[1] };
    if (data) |d| q.desc[idx[1]] = .{
        .addr = @intFromPtr(d),
        .len = block_size,
        .flags = desc_next | (if (kind == request_in) desc_write else 0),
        .next = idx[2],
    };
    q.desc[status_desc] = .{ .addr = @intFromPtr(&queue.status[head]), .len = 1, .flags = desc_write, .next = 0 };
    info[head].done = false;

    // 先把链放进 avail 环，再增加 idx：设备看到新的 idx 时，前面写的东西必须都已经可见
    q.avail.ring[q.avail.idx % num] = head;
    fence();
    q.avail.idx +%= 1;
    fence();
    reg(.queue_notify).* = 0; // 告诉设备队列 0 有新请求

    while (!info[head].done) info[head].waiters.wait(&lock);

    const status = q.status[head];
    if (status != 0) std.debug.panic("virtio disk: request type {d} at sector {d} failed with status {d}", .{ kind, sector, status });
    for (idx) |i| free[i] = true;
    free_waiters.wakeAll(&lock);
}

/// 中断处理：确认中断，把 used 环里新做完的请求标成 done，叫醒等它们的进程。
pub fn onInterrupt() void {
    lock.acquire();
    defer lock.release();
    // 先确认，再看 used 环：确认之后设备又做完的请求会再发一次中断，不会漏
    reg(.interrupt_ack).* = reg(.interrupt_status).* & 0x3;
    fence();
    const q: *volatile Queue = &queue;
    while (used_idx != q.used.idx) {
        fence();
        const id = q.used.ring[used_idx % num].id;
        info[id].done = true;
        info[id].waiters.wakeAll(&lock);
        used_idx +%= 1;
    }
}
