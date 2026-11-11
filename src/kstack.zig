//! 内核用的栈和它们下面的保护页。
//!
//! 内核的栈都是静态数组（页分配器一次只给一页，给不出连续的几页）：
//! - 每个 hart 一块启动栈（boot）：kmain / kmainSecondary 在上面初始化，之后归这个 hart 的调度器用。
//! - 每个 hart 一块陷阱栈（trap）：S 模式里来的陷阱（调度器开中断时来的中断、内核自己的异常）都在它上面处理
//!   （trap.zig 的 trapEntry）。内核栈溢出、撞到保护页时，缺页异常也是在它上面处理的，所以能干净地 panic。
//! - 每个进程槽位一块内核栈（process）：进程陷入内核（系统调用、U 模式的异常和中断）时用。
//!
//! 每块栈都是 Stack(n)：最底下一页是保护页，上面是 n 字节的栈。vm.init 建内核页表时不映射保护页
//! （guardPages 列出它们），栈往下溢出一碰到它就触发缺页异常，而不是悄悄改掉下面紧挨着的那块栈
//! （进程 i 的内核栈往下溢出，正好是进程 i-1 内核栈的最顶上，那里是它的 TrapFrame）。
//! 保护页本身是 .bss 里的一页物理内存，只是不映射，内核不再访问它（_start 清零 .bss 时还没开分页）。
//!
//! 栈最底下还有 canary.zig 的金丝雀：保护页只能发现越过栈底的访问；用到了离栈底不到 256 字节的地方、
//! 或者一个很大的栈帧整个跨过了保护页，靠金丝雀在之后的检查里发现。

const std = @import("std");
const hart = @import("hart.zig");
const abi = @import("abi.zig");
const canary = @import("canary.zig");

const page_size = 4096;

/// 一块带保护页的栈：guard 是保护页（不映射），stack 是栈本身，栈顶是 stack 的末尾（top）。
pub fn Stack(comptime size: usize) type {
    comptime std.debug.assert(size % page_size == 0);
    return extern struct {
        guard: [page_size]u8 align(page_size),
        stack: [size]u8,

        pub const stack_size = size;

        /// 栈顶（栈往低地址长，sp 从这里开始）
        pub fn top(s: *@This()) usize {
            return @intFromPtr(&s.stack) + size;
        }
    };
}

/// 启动栈 32 KiB：实测 Debug 模式下跑完全部 QEMU 测试，最深用了约 18 KiB（kmain 那一串初始化），safe 模式下约 4.7 KiB。
/// 这些数是 shutdown 时 deepest 量的（见 docs/process.md），qemu_test.py 检查余量。
pub const Boot = Stack(32 * 1024);
/// 陷阱栈 16 KiB：中断处理程序都很浅，最深的是 panic（格式化输出）
pub const Trap = Stack(16 * 1024);
/// 进程的内核栈 24 KiB：实测 Debug 模式下最深的是文件系统的系统调用，约 16 KiB（见 docs/process.md）。
/// 原来是 16 KiB，Debug 模式下只剩 2.4 KiB 的余量，调大了
pub const Process = Stack(24 * 1024);

/// main.zig 用 @export 导出成 boot_stacks：_start、secondaryEntry 的汇编按名字取地址
pub var boot: [hart.max]Boot = undefined;
pub var trap: [hart.max]Trap = undefined;
/// 槽位 i 的进程用 process[i]（proc.stackOf）
pub var process: [abi.max_procs]Process = undefined;

pub const guard_count = boot.len + trap.len + process.len;

/// 启动 hart 的 kmain 一开始调用（别的 hart 还没启动、没有进程、还没有陷阱）：把所有的栈都写上金丝雀的图案，
/// deepest 之后才量得出每块栈用到过多深；顺便写好了每块栈底的金丝雀。启动 hart 自己的启动栈正在用，
/// 只写到当前的 sp 往下留出 1 KiB 的地方（paint 自己和它调用的 memset 的栈帧都在这 1 KiB 里）。
pub fn paintAll(boot_hart: usize) void {
    for (&process) |*s| canary.paint(&s.stack);
    for (&trap) |*s| canary.paint(&s.stack);
    for (&boot, 0..) |*s, i| if (i != boot_hart) canary.paint(&s.stack);
    paintBelowSp(&boot[boot_hart].stack);
}

noinline fn paintBelowSp(stack: []u8) void {
    const sp = asm volatile ("mv %[sp], sp"
        : [sp] "=r" (-> usize),
    );
    const end = sp - 1024 - @intFromPtr(stack.ptr);
    std.debug.assert(end >= canary.size and end < stack.len);
    canary.paint(stack[0..end]);
}

/// 各种栈用到过的最深处（字节，从栈顶算），取所有 hart、所有进程槽位里最大的。见 paintAll。
pub const Usage = struct { process: usize = 0, boot: usize = 0, trap: usize = 0 };

/// 量一遍所有的栈（shutdown 时打印，qemu_test.py 检查还有多少余量）。正在用的栈也量，读到的是某一时刻的值。
pub fn deepest() Usage {
    var u: Usage = .{};
    for (&process) |*s| u.process = @max(u.process, canary.used(&s.stack));
    for (&boot) |*s| u.boot = @max(u.boot, canary.used(&s.stack));
    for (&trap) |*s| u.trap = @max(u.trap, canary.used(&s.stack));
    return u;
}

/// addr 是不是落在某一块内核栈（不含保护页）里。
pub fn contains(addr: usize) bool {
    for (&boot) |*s| if (inStack(addr, &s.stack)) return true;
    for (&trap) |*s| if (inStack(addr, &s.stack)) return true;
    for (&process) |*s| if (inStack(addr, &s.stack)) return true;
    return false;
}

fn inStack(addr: usize, stack: []const u8) bool {
    const lo = @intFromPtr(stack.ptr);
    return addr >= lo and addr - lo < stack.len;
}

/// 沿帧指针链取调用栈：RISC-V 的帧指针（s0）指向调用者的 sp（栈帧的上沿），fp - 8 存着返回地址，
/// fp - 16 存着调用者的帧指针（内核编译时保留帧指针，见 build.zig）。从 fp 开始往上走，返回地址依次放进 out。
/// 帧指针不对齐、或者它下面那 16 字节不在 in_stack 认可的栈里就停下（panic 时栈可能已经坏了，
/// 不能顺着一个坏指针去读）；陷阱处理程序的帧把链接到被打断的代码的栈上，所以链可以跨过几块栈。
pub fn backtrace(fp_start: usize, in_stack: *const fn (usize) bool, out: []usize) []usize {
    var fp = fp_start;
    var n: usize = 0;
    while (n < out.len) {
        if (fp % 8 != 0 or fp < 16 or !in_stack(fp - 16) or !in_stack(fp - 1)) break;
        const words: *const [2]usize = @ptrFromInt(fp - 16);
        const prev = words[0];
        const ra = words[1];
        if (ra == 0) break;
        out[n] = ra;
        n += 1;
        if (prev == fp) break;
        fp = prev;
    }
    return out[0..n];
}

/// 所有保护页的地址（vm.init 不映射它们），按地址从低到高。
/// 三个数组在 .bss 里谁先谁后由链接器定，所以要排序。用插入排序：std.mem.sort 在栈上放一个 4 KiB 的缓存，
/// 这里是在启动栈上调用的（kmain 那一串初始化是启动栈用得最深的地方）。
pub fn guardPages() [guard_count]usize {
    var out: [guard_count]usize = undefined;
    for (&boot, out[0..boot.len]) |*s, *g| g.* = @intFromPtr(&s.guard);
    for (&trap, out[boot.len..][0..trap.len]) |*s, *g| g.* = @intFromPtr(&s.guard);
    for (&process, out[boot.len + trap.len ..]) |*s, *g| g.* = @intFromPtr(&s.guard);
    std.sort.insertion(usize, &out, {}, std.sort.asc(usize));
    return out;
}

/// addr 落在谁的保护页里（内核栈溢出时 trap.zig 用它说明是哪块栈）。
pub const Owner = union(enum) {
    boot: usize,
    trap: usize,
    process: usize,
};

pub fn guardOwner(addr: usize) ?Owner {
    for (&boot, 0..) |*s, i| if (inGuard(addr, &s.guard)) return .{ .boot = i };
    for (&trap, 0..) |*s, i| if (inGuard(addr, &s.guard)) return .{ .trap = i };
    for (&process, 0..) |*s, i| if (inGuard(addr, &s.guard)) return .{ .process = i };
    return null;
}

fn inGuard(addr: usize, guard: *[page_size]u8) bool {
    const g = @intFromPtr(guard);
    return addr >= g and addr - g < page_size;
}

var test_frames: [64]usize align(8) = @splat(0);

fn inTestFrames(addr: usize) bool {
    return inStack(addr, std.mem.sliceAsBytes(&test_frames));
}

test "调用栈：沿帧指针链走，链断了、指针出了栈都停下" {
    // 三个栈帧：fp 指向帧的上沿，fp-16 是上一个 fp，fp-8 是返回地址
    const base = @intFromPtr(&test_frames);
    const f0 = base + 8 * 8; // 最里面的
    const f1 = base + 20 * 8;
    const f2 = base + 40 * 8;
    test_frames[6] = f1;
    test_frames[7] = 0x8020_0010;
    test_frames[18] = f2;
    test_frames[19] = 0x8020_0020;
    test_frames[38] = 0x1234_0000; // 指向栈外：走到这里就停
    test_frames[39] = 0x8020_0030;
    var out: [8]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 0x8020_0010, 0x8020_0020, 0x8020_0030 }, backtrace(f0, &inTestFrames, &out));
    // out 满了就停
    try std.testing.expectEqual(2, backtrace(f0, &inTestFrames, out[0..2]).len);
    // 不对齐、不在栈里的起点
    try std.testing.expectEqual(0, backtrace(f0 + 1, &inTestFrames, &out).len);
    try std.testing.expectEqual(0, backtrace(0x1000, &inTestFrames, &out).len);
}

test "保护页：每块栈一页，按页对齐，排好序；栈底下面一页就是保护页" {
    const guards = guardPages();
    for (guards, 0..) |g, i| {
        try std.testing.expect(g % page_size == 0);
        if (i > 0) try std.testing.expect(guards[i - 1] < g);
    }
    const s = &process[3];
    try std.testing.expectEqual(@intFromPtr(&s.stack), @intFromPtr(&s.guard) + page_size);
    try std.testing.expectEqual(Owner{ .process = 3 }, guardOwner(@intFromPtr(&s.stack) - 1).?);
    try std.testing.expectEqual(Owner{ .boot = 1 }, guardOwner(@intFromPtr(&boot[1].guard)).?);
    try std.testing.expectEqual(Owner{ .trap = 0 }, guardOwner(@intFromPtr(&trap[0].guard) + 100).?);
    try std.testing.expectEqual(null, guardOwner(@intFromPtr(&s.stack)));
    try std.testing.expectEqual(null, guardOwner(s.top() - 1));
}
