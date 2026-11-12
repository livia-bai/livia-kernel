//! 回归测试：virtio 磁盘和缓冲区缓存（blockcount、readblock、writeblock）。
//! 磁盘是 build.zig 生成的 4 MiB 镜像，第 b 块的第 i 个字节是 (b * 131 + i) % 251（original）。
//! 这个程序改写其中几段（见下面的 written、workers），qemu_test.py 在 QEMU 退出之后读镜像文件，
//! 检查这些块在磁盘上真的变了、别的块没变。同一次启动里再运行一遍也能通过（改写过的块两种内容都认）。
//! 失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。

const std = @import("std");
const sys = @import("sys");
const block_size = sys.block_size;

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

const disk_blocks = 1024;

fn original(b: u64, i: usize) u8 {
    return @intCast((b * 131 + i) % 251);
}

/// 单个进程改写的块：第一块、最后一块和 100..140，内容是 original 取反
fn isWritten(b: u64) bool {
    return b == 0 or b == disk_blocks - 1 or (b >= 100 and b < 140);
}

fn inverted(b: u64, i: usize) u8 {
    return ~original(b, i);
}

/// 并发的工作进程：第 k 个改写 [worker_base + k * worker_len, + worker_len)，内容和 k 有关；
/// 同时都去读 [shared_base, + shared_len)，几个进程等同一个块
const workers = 6;
const worker_base = 200;
const worker_len = 50;
const shared_base = 500;
const shared_len = 64;

fn workerOf(b: u64) ?u64 {
    if (b < worker_base or b >= worker_base + workers * worker_len) return null;
    return (b - worker_base) / worker_len;
}

fn workerPattern(k: u64, b: u64, i: usize) u8 {
    return @truncate(b *% 7 +% i *% 3 +% k *% 29 +% 1);
}

fn fill(dst: *[block_size]u8, comptime pattern: anytype, args: anytype) void {
    for (dst, 0..) |*c, i| c.* = @call(.auto, pattern, args ++ .{i});
}

fn matches(blk: *const [block_size]u8, comptime pattern: anytype, args: anytype) bool {
    for (blk, 0..) |c, i| {
        if (c != @call(.auto, pattern, args ++ .{i})) return false;
    }
    return true;
}

var buf: [block_size]u8 = undefined;

fn read(b: u64) bool {
    sys.readBlock(b, &buf) catch |err| {
        expect(false, "readBlock({d}): {s}", .{ b, @errorName(err) });
        return false;
    };
    return true;
}

/// `t_disk eio N`：QEMU 用 blkdebug 让原始区域第 N 块的读写都失败（qemu_test.py 的 case_disk_errors）。
/// 读写它都得到 IoError，内核不 panic；它两边的块照常能读，读出来的是镜像里的内容。
fn ioErrors(b: u64) u8 {
    for (0..2) |_| { // 两遍：第一次失败之后缓冲区不能被当成有效的
        expect(sys.readBlock(b, &buf) == sys.Error.IoError, "readBlock({d}) should fail with IoError", .{b});
        fill(&buf, inverted, .{b});
        expect(sys.writeBlock(b, &buf) == sys.Error.IoError, "writeBlock({d}) should fail with IoError", .{b});
    }
    for ([_]u64{ b - 1, b + 1 }) |n| {
        expect(read(n) and matches(&buf, original, .{n}), "block {d} next to the failing one", .{n});
    }
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

pub fn main() u8 {
    if (sys.arg(1)) |a| if (std.mem.eql(u8, a, "eio")) {
        return ioErrors(std.fmt.parseInt(u64, sys.arg(2) orelse "", 10) catch {
            sys.print("usage: t_disk [eio BLOCK]\n", .{});
            return 2;
        });
    };
    expect(sys.blockCount() == disk_blocks, "blockCount() = {d}, expected {d}", .{ sys.blockCount(), disk_blocks });

    // 1. 每一块都读一遍（比缓冲区多得多，一路换掉旧的），内容和镜像一样
    var bad: usize = 0;
    for (0..disk_blocks) |b| {
        if (!read(b)) break;
        const ok = matches(&buf, original, .{b}) or
            (isWritten(b) and matches(&buf, inverted, .{b})) or
            (if (workerOf(b)) |k| matches(&buf, workerPattern, .{ k, b }) else false);
        if (!ok) bad += 1;
    }
    expect(bad == 0, "{d} blocks differ from the disk image", .{bad});

    // 2. 坏参数：块号超出磁盘、指针指向只读的代码页、没有映射的地址、内核；失败的写不改磁盘
    const E = sys.Error;
    expect(sys.readBlock(disk_blocks, &buf) == E.InvalidArgument, "readBlock past the end", .{});
    expect(sys.readBlock(std.math.maxInt(u64), &buf) == E.InvalidArgument, "readBlock(maxInt)", .{});
    expect(sys.writeBlock(disk_blocks, &buf) == E.InvalidArgument, "writeBlock past the end", .{});
    const code: *[block_size]u8 = @ptrFromInt(@intFromPtr(&main) & ~@as(usize, block_size - 1));
    expect(sys.readBlock(50, code) == E.BadAddress, "readBlock into the code segment", .{});
    for ([_]usize{ 0x6000_0000, 0x8020_0000 }) |addr| {
        expect(sys.writeBlock(50, @ptrFromInt(addr)) == E.BadAddress, "writeBlock from 0x{x}", .{addr});
    }
    expect(read(50) and matches(&buf, original, .{50}), "block 50 changed by a failed write", .{});
    // 跨页的用户缓冲区
    const heap = sys.sbrk(2 * block_size) catch unreachable;
    const straddling: *[block_size]u8 = @ptrFromInt(heap + 100);
    expect((sys.readBlock(51, straddling) catch null) != null and matches(straddling, original, .{51}), "readBlock across a page boundary", .{});

    // 3. 写：马上读回来（缓存里的），再把缓存挤满别的块之后读回来（磁盘上的）
    for (0..disk_blocks) |b| {
        if (!isWritten(b)) continue;
        fill(&buf, inverted, .{b});
        sys.writeBlock(b, &buf) catch |err| expect(false, "writeBlock({d}): {s}", .{ b, @errorName(err) });
    }
    for (0..2) |round| {
        bad = 0;
        for (0..disk_blocks) |b| {
            if (isWritten(b) and (!read(b) or !matches(&buf, inverted, .{b}))) bad += 1;
        }
        expect(bad == 0, "round {d}: {d} written blocks read back wrong", .{ round, bad });
        for (600..700) |b| _ = read(b);
    }

    // 4. 几个进程同时读写（多核时在不同的 hart 上）：各写各的块再读回来；同时读同一批块
    var pids: [workers]usize = undefined;
    for (&pids, 0..) |*pid, k| {
        pid.* = sys.fork() catch unreachable;
        if (pid.* == 0) sys.exit(worker(k));
    }
    for (pids, 0..) |pid, k| {
        const r = (sys.wait(pid, false) catch null) orelse unreachable;
        expect(r.status == 0, "worker {d} failed at step {d}", .{ k, r.status });
    }

    // 5. 内核往写时复制的页里写：子进程读块到全局变量（和父进程共用的页），父进程的那一份不变
    @memset(&buf, 0x5a);
    const pid = sys.fork() catch unreachable;
    if (pid == 0) sys.exit(if ((sys.readBlock(52, &buf) catch null) != null and matches(&buf, original, .{52})) 0 else 1);
    const status = if (sys.wait(pid, false) catch null) |r| r.status else 999;
    expect(status == 0 and std.mem.allEqual(u8, &buf, 0x5a), "readBlock into a copy-on-write page: status {d}", .{status});

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

/// 返回 0 表示一切正常，否则是出错的那一步。
fn worker(k: u64) u8 {
    const first = worker_base + k * worker_len;
    var data: [block_size]u8 = undefined;
    for (first..first + worker_len) |b| {
        fill(&data, workerPattern, .{ k, b });
        sys.writeBlock(b, &data) catch return 1;
        // 隔几块读一次共用的块
        sys.readBlock(shared_base + b % shared_len, &data) catch return 2;
        if (!matches(&data, original, .{shared_base + b % shared_len})) return 3;
    }
    for (first..first + worker_len) |b| {
        sys.readBlock(b, &data) catch return 4;
        if (!matches(&data, workerPattern, .{ k, b })) return 5;
    }
    return 0;
}
