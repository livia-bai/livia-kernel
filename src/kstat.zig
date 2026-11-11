//! 内核自己的计数器（kstat 系统调用、用户程序 kstat 读出来）：wakeup 调了几次、真叫醒了几个，各种缺页，
//! TLB 全量刷新，缓冲区缓存的命中，提交次数……改性能之前先看它们，确认热点在哪，改完再看一次。
//!
//! 有哪些计数器由 abi.Counters 的字段决定（内核、用户程序共用那个结构体，名字和顺序只写一次）。
//! 每个 hart 一份，只有这个 hart 自己加（不用原子的读改写，也不用锁）；kstat 系统调用把所有 hart 的加起来，
//! 读别的 hart 的那一份时它可能正在加，读到的是某一时刻的值。单元测试在主机上运行，hart.id() 总是 0，也照常计数。

const std = @import("std");
const abi = @import("abi.zig");
const hart = @import("hart.zig");

/// 计数器的名字：abi.Counters 的字段
pub const Counter = std.meta.FieldEnum(abi.Counters);
const n = std.meta.fieldNames(abi.Counters).len;

comptime {
    // 每个字段都是 u64，Counters 才能当成 [n]u64 读写
    for (@typeInfo(abi.Counters).@"struct".field_types) |t| std.debug.assert(t == u64);
    std.debug.assert(@sizeOf(abi.Counters) == n * 8);
}

var counts: [hart.max][n]std.atomic.Value(u64) = @splat(@splat(.init(0)));

/// 当前 hart 的计数器 c 加 by。只有这个 hart 写自己的那一份，所以先读再写就够了（不是读改写的原子操作）；
/// 用原子的读、写，是为了 sum 在别的 hart 上读它时没有数据竞争。
pub inline fn add(comptime c: Counter, by: u64) void {
    const v = &counts[hart.id()][@backingInt(c)];
    v.store(v.load(.monotonic) +% by, .monotonic);
}

pub inline fn inc(comptime c: Counter) void {
    add(c, 1);
}

/// 所有 hart 的计数加起来。
pub fn sum() abi.Counters {
    var out: abi.Counters = .{};
    const words: *[n]u64 = @ptrCast(&out);
    for (&counts) |*per_hart| {
        for (words, per_hart) |*o, *v| o.* +%= v.load(.monotonic);
    }
    return out;
}

test "计数器按名字加，sum 把它们放回同名的字段" {
    const before = sum();
    inc(.syscalls);
    add(.bio_misses, 3);
    const after = sum();
    try std.testing.expectEqual(before.syscalls + 1, after.syscalls);
    try std.testing.expectEqual(before.bio_misses + 3, after.bio_misses);
    try std.testing.expectEqual(before.bio_hits, after.bio_hits);
}
