//! 回归测试：删掉还有人用着的文件（和 Unix 一样，只删名字，最后一个使用者放开时才删内容）。
//! - 打开着的文件：删掉之后路径找不到了，fd 照常读写，fstat 的链接数是 0，scrub 数出一个孤儿；
//!   关掉之后孤儿没了，块都还回来。
//! - fork 之后两个进程都打开着：一个关掉、删掉，另一个照常读，它结束之后才真正删掉。
//! - 正在运行的程序文件：可以删；删掉之后它还能按需从文件里读页（只读数据里 32 KiB 的表，删掉之后才第一次碰）。
//! - `t_unlink hold`：建一个文件、打开着删掉，然后一直睡着。qemu_test.py 在这时杀掉 QEMU（掉电），
//!   下次启动挂载时应该删掉这个孤儿。
//! 失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。

const std = @import("std");
const sys = @import("sys");

var failures: u8 = 0;
var checks: usize = 0;

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

const page = 4096;

/// 只读数据段里的 8 页，按页对齐（不和别的只读数据共用一页），删掉程序文件之后子进程才第一次读它们
const table: [8 * page]u8 align(page) = blk: {
    @setEvalBranchQuota(100_000);
    var t: [8 * page]u8 = undefined;
    for (&t, 0..) |*c, i| c.* = @truncate(i * 31 + i / page);
    break :blk t;
};

fn pattern(i: usize) u8 {
    return @truncate(i * 7 + 3);
}

fn fillPattern(buf: []u8, base: usize) void {
    for (buf, 0..) |*c, i| c.* = pattern(base + i);
}

fn freeBlocks() u64 {
    return (sys.scrub() catch |err| {
        expect(false, "scrub: {s}", .{@errorName(err)});
        return 0;
    }).free_blocks;
}

fn orphans() u64 {
    return (sys.scrub() catch return 999).orphans;
}

/// 建 path，写 3 页，返回一个可读写的 fd。
fn createFile(path: []const u8) ?sys.Fd {
    const fd = sys.open(path, .{ .read = true, .write = true, .create = true, .truncate = true }) catch |err| {
        expect(false, "create {s}: {s}", .{ path, @errorName(err) });
        return null;
    };
    var buf: [page]u8 = undefined;
    for (0..3) |p| {
        fillPattern(&buf, p * page);
        sys.writeAll(fd, &buf) catch |err| expect(false, "write {s}: {s}", .{ path, @errorName(err) });
    }
    return fd;
}

/// 从头读 fd 的 3 页，核对内容。
fn verify(fd: sys.Fd, what: []const u8) bool {
    _ = sys.lseek(fd, 0, .set) catch return false;
    var buf: [page]u8 = undefined;
    var off: usize = 0;
    while (off < 3 * page) {
        const n = sys.read(fd, &buf) catch return false;
        if (n == 0) break;
        for (buf[0..n], 0..) |c, i| {
            if (c != pattern(off + i)) {
                expect(false, "{s}: byte {d} is {d}", .{ what, off + i, c });
                return false;
            }
        }
        off += n;
    }
    return off == 3 * page;
}

/// 1. 打开着删掉
fn openThenUnlink() void {
    const before = freeBlocks();
    const fd = createFile("/tunlink/a") orelse return;
    sys.unlink("/tunlink/a") catch |err| expect(false, "unlink an open file: {s}", .{@errorName(err)});
    expect(sys.open("/tunlink/a", .{}) == error.NotFound, "the name is gone after unlink", .{});
    const st = sys.fstat(fd) catch unreachable;
    expect(st.nlink == 0 and st.size == 3 * page, "fstat after unlink: nlink {d}, size {d}", .{ st.nlink, st.size });
    expect(verify(fd, "read after unlink"), "read after unlink", .{});
    // 还能写：把第 1 页改掉再改回来
    _ = sys.lseek(fd, page, .set) catch {};
    var buf: [page]u8 = @splat(0xaa);
    sys.writeAll(fd, &buf) catch |err| expect(false, "write after unlink: {s}", .{@errorName(err)});
    _ = sys.lseek(fd, page, .set) catch {};
    fillPattern(&buf, page);
    sys.writeAll(fd, &buf) catch {};
    expect(verify(fd, "read after writing an unlinked file"), "read after writing an unlinked file", .{});
    expect(orphans() == 1, "scrub: {d} orphans, expected 1", .{orphans()});
    const held = freeBlocks();
    expect(held + 3 <= before, "the unlinked file's blocks were freed early: {d} free before, {d} while open", .{ before, held });
    sys.close(fd) catch {};
    expect(orphans() == 0, "scrub: {d} orphans after close", .{orphans()});
    const after = freeBlocks();
    expect(after >= held + 3, "closing the last fd did not free the blocks: {d} while open, {d} after", .{ held, after });
}

/// 2. fork 之后两边都打开着
fn sharedAcrossFork() void {
    const fd = createFile("/tunlink/b") orelse return;
    const go = sys.pipe() catch unreachable;
    const pid = sys.fork() catch unreachable;
    if (pid == 0) {
        sys.close(go[1]) catch {};
        var b: [1]u8 = undefined;
        _ = sys.read(go[0], &b) catch {};
        sys.exit(if (verify(fd, "child") and (sys.fstat(fd) catch unreachable).nlink == 0) 0 else 1);
    }
    sys.close(go[0]) catch {};
    sys.close(fd) catch {};
    sys.unlink("/tunlink/b") catch |err| expect(false, "unlink a file the child has open: {s}", .{@errorName(err)});
    expect(orphans() == 1, "scrub: {d} orphans while the child holds the file", .{orphans()});
    _ = sys.write(go[1], "g") catch {};
    sys.close(go[1]) catch {};
    const r = (sys.wait(pid, false) catch null) orelse unreachable;
    expect(r.status == 0, "the child could not read the unlinked file (status {d})", .{r.status});
    expect(orphans() == 0, "scrub: {d} orphans after the child exited", .{orphans()});
}

/// 3. 删掉正在运行的程序文件：子进程 exec 一份自己的副本，等父进程删掉它之后才读只读数据
fn unlinkRunningProgram() void {
    if (!copyFile("/bin/t_unlink", "/tunlink/self")) {
        expect(false, "copy /bin/t_unlink", .{});
        return;
    }
    const ready = sys.pipe() catch unreachable;
    const go = sys.pipe() catch unreachable;
    const pid = sys.fork() catch unreachable;
    if (pid == 0) {
        var a: [2][4]u8 = undefined;
        const r = std.fmt.bufPrint(&a[0], "{d}", .{ready[1]}) catch unreachable;
        const g = std.fmt.bufPrint(&a[1], "{d}", .{go[0]}) catch unreachable;
        sys.exec("/tunlink/self", &.{ "self", "lazy", r, g }) catch {};
        sys.exit(99);
    }
    sys.close(ready[1]) catch {};
    sys.close(go[0]) catch {};
    var b: [1]u8 = undefined;
    expect((sys.read(ready[0], &b) catch 0) == 1, "the copy did not start", .{});
    sys.unlink("/tunlink/self") catch |err| expect(false, "unlink a running program: {s}", .{@errorName(err)});
    expect(sys.open("/tunlink/self", .{}) == error.NotFound, "the running program's name is gone", .{});
    _ = sys.write(go[1], "g") catch {};
    const r = (sys.wait(pid, false) catch null) orelse unreachable;
    expect(r.status == 0, "the running copy could not page in its read-only data after unlink (status {d})", .{r.status});
    expect(orphans() == 0, "scrub: {d} orphans after the program exited", .{orphans()});
    sys.close(ready[0]) catch {};
    sys.close(go[1]) catch {};
}

/// `t_unlink lazy READY GO`：告诉父进程开始了，等它删掉程序文件，再读只读数据里的表。
fn lazy(ready: sys.Fd, go: sys.Fd) u8 {
    _ = sys.write(ready, "r") catch return 2;
    var b: [1]u8 = undefined;
    _ = sys.read(go, &b) catch return 3;
    const v: *const volatile [8 * page]u8 = &table;
    for (0..v.len) |i| {
        if (v[i] != @as(u8, @truncate(i * 31 + i / page))) return 1;
    }
    return 0;
}

fn copyFile(from: []const u8, to: []const u8) bool {
    const in = sys.open(from, .{}) catch return false;
    defer sys.close(in) catch {};
    const out = sys.open(to, .{ .write = true, .create = true, .truncate = true }) catch return false;
    defer sys.close(out) catch {};
    var buf: [512]u8 = undefined;
    while (true) {
        const n = sys.read(in, &buf) catch return false;
        if (n == 0) return true;
        sys.writeAll(out, buf[0..n]) catch return false;
    }
}

pub fn main() u8 {
    if (sys.arg(1)) |mode| {
        if (std.mem.eql(u8, mode, "lazy")) {
            const r = std.fmt.parseInt(sys.Fd, sys.arg(2) orelse "", 10) catch return 4;
            const g = std.fmt.parseInt(sys.Fd, sys.arg(3) orelse "", 10) catch return 4;
            return lazy(r, g);
        }
        if (std.mem.eql(u8, mode, "hold")) {
            sys.mkdir("/tunlink") catch {};
            const fd = createFile("/tunlink/held") orelse return 1;
            sys.unlink("/tunlink/held") catch return 1;
            _ = fd;
            sys.print("hold: holding an unlinked file\n", .{});
            while (true) sys.sleep(1000);
        }
        sys.print("usage: t_unlink [hold]\n", .{});
        return 2;
    }
    sys.mkdir("/tunlink") catch {};
    openThenUnlink();
    sharedAcrossFork();
    unlinkRunningProgram();
    sys.unlink("/tunlink") catch |err| expect(false, "rmdir /tunlink: {s}", .{@errorName(err)});
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
