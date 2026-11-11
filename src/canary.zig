//! 栈底的“金丝雀”（canary）：发现内核栈溢出。
//!
//! 内核栈（每个进程一块，proc.zig）和启动栈（每个 hart 一块，main.zig）都是静态数组里挨着的一段，
//! 两侧没有保护页（内核内存是用大页恒等映射的），溢出不会触发缺页，而是悄悄踩坏紧挨着的下一块：
//! 进程 i 的内核栈往下溢出，正好写进进程 i-1 内核栈的最顶上，那里放的是它的 TrapFrame。
//!
//! 所以在每块栈最底下的 size 字节写上固定的图案，栈用到这里就会改掉它。栈开始用之前 set，
//! 之后在经常经过的地方（切回调度器、回到 U 模式、调度器每一轮）check，图案变了就 panic，
//! 在被踩坏的数据造成别的怪现象之前停下。
//!
//! 这是尽力而为的检查：一个很大、只写了一部分的栈帧可能整个跨过金丝雀，它没被改，下面的数据却被改了。
//! 留 size 字节而不是一个字，就是为了让这种情况少一些。
//!
//! 同一个图案还用来量栈用到过多深（高水位）：启动时把整块栈都写上（paint），之后从栈底往上找第一个被改过的字（used），
//! 它以上就是用到过的部分（kstack.deepest）。

const std = @import("std");

/// 栈最底下留给金丝雀的字节数
pub const size = 256;

/// 图案：每个字都一样。不用 0：.bss 清零之后、栈从没用到过的地方本来就是 0
const word: u64 = 0x57ac_ca9a_57ac_ca9a;

fn words(stack: []u8) *[size / 8]u64 {
    return @ptrCast(@alignCast(stack[0..size]));
}

/// stack 当成按 8 字节对齐的字（长度向下取整到 8 的倍数）。
fn allWords(stack: []u8) []u64 {
    return @as([*]u64, @ptrCast(@alignCast(stack.ptr)))[0 .. stack.len / 8];
}

/// 在栈 stack（整块，低地址在前）的最底下写上图案。栈还没开始用、或者这块栈当前没人用时调用。
pub fn set(stack: []u8) void {
    @memset(words(stack), word);
}

/// 把 region（栈最底下的一段，或者整块栈）都写上图案。栈从没用到过的地方保持图案，used 才量得出用到过多深。
/// 包含了 set 写的那 size 字节。region 里不能有正在用的栈帧。
pub fn paint(region: []u8) void {
    @memset(allWords(region), word);
}

/// 栈 stack 用到过的最深处离栈顶多少字节：从栈底往上第一个不是图案的字以上都算用到过。
/// 栈可能正被别的 hart 用着（shutdown 时量），所以逐个字原子地读，读到的是某一时刻的值。
/// 前提是这块栈用之前 paint 过；金丝雀被改过的话，结果就是整块栈。
pub fn used(stack: []u8) usize {
    const ws = allWords(stack);
    for (ws, 0..) |*w, i| {
        if (@atomicLoad(u64, w, .monotonic) != word) return stack.len - i * 8;
    }
    return 0;
}

/// 图案还在不在。
pub fn intact(stack: []u8) bool {
    for (words(stack)) |w| {
        if (w != word) return false;
    }
    return true;
}

/// 图案被改了就 panic，what 说明是哪块栈。
pub fn check(stack: []u8, comptime what: []const u8, args: anytype) void {
    if (!intact(stack)) std.debug.panic("kernel stack overflow: " ++ what, args);
}

test "高水位：paint 之后没用过是 0，用到哪里量到哪里" {
    var stack: [1024]u8 align(16) = undefined;
    paint(&stack);
    try std.testing.expect(intact(&stack));
    try std.testing.expectEqual(0, used(&stack));
    stack[1023] = 0; // 栈顶的一个字节
    try std.testing.expectEqual(8, used(&stack));
    stack[600] = 0;
    try std.testing.expectEqual(1024 - 600, used(&stack));
    stack[3] = 0; // 金丝雀被改了：整块
    try std.testing.expectEqual(1024, used(&stack));
}

test "金丝雀：写上之后完好，栈底任何一个字节被改了都能发现" {
    var stack: [1024]u8 align(16) = @splat(0);
    try std.testing.expect(!intact(&stack)); // 没写过
    set(&stack);
    try std.testing.expect(intact(&stack));
    stack[size] = 1; // 金丝雀之上是栈本身，随便用
    try std.testing.expect(intact(&stack));
    for ([_]usize{ 0, 100, size - 1 }) |i| {
        set(&stack);
        stack[i] ^= 0xff;
        try std.testing.expect(!intact(&stack));
    }
}
