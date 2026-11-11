//! 回归测试：按需分页。
//! - 程序的页用到才从文件读进来：一个 256 KiB 的只读数组和一个 128 KiB 的数据数组，碰之前不占内存，
//!   碰了才占，读到的是文件里的内容；数据页可写，fork 之后各改各的。
//! - 内核替程序读写还没读进来的页（write 写管道、文件，read、readdir、fstat、wait 的输出参数）也行：
//!   这些有的是拿着锁复制的，要先准备好（vm.pinSrc 这些），没准备好的话拿着锁时缺页。
//! - 栈按需长，最多 1 MiB。
//! - 正在运行的程序文件不能改、不能删（TextBusy）：复制一份 spin 运行起来，试着写它、截断它、删它、
//!   用 rename 换掉它；改名、删掉它的另一个硬链接可以；它结束之后又都可以了。
//! 失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

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

/// 只读数据段里的 256 KiB，每个字节都是 7（在程序文件里，按需读进来）
const big: [64 * page]u8 = @splat(7);
/// 数据段里的 128 KiB，每个字节都是 3
var data: [32 * page]u8 = @splat(3);

fn freePages() u64 {
    return sys.meminfo().free_pages;
}

/// big 的第 i 页的地址：用 volatile 读，编译器不能把读出来的值当成常量 7
fn bigPage(i: usize) [*]const volatile u8 {
    return @ptrCast(&big[i * page]);
}

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "deep")) return deepStack();
    }
    lazyPages();
    kernelAccess();
    stack();
    textBusy();
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

/// 1. 只读数组、数据数组的页碰了才读进来，内容来自文件
fn lazyPages() void {
    // 先把 meminfo 自己要用的页都用过一遍
    _ = freePages();
    const before = freePages();
    var sum: usize = 0;
    for (0..16) |i| sum += bigPage(i)[100];
    const used = before -| freePages();
    expect(sum == 16 * 7, "big[] read back {d}, expected {d}", .{ sum, 16 * 7 });
    expect(used >= 16 and used <= 18, "reading 16 pages of a read-only array used {d} pages", .{used});
    sys.print("reading 16 untouched pages of the program used {d} pages\n", .{used});

    // 数据页：内容来自文件，可写；fork 之后子进程改的父进程看不到
    const d: [*]volatile u8 = @ptrCast(&data);
    expect(d[5 * page] == 3, "data[] read back {d}", .{d[5 * page]});
    d[6 * page] = 9;
    const pid = sys.fork() catch unreachable;
    if (pid == 0) {
        // 父进程没碰过的页（第 7 页）、碰过的页（第 6 页）
        const ok = d[7 * page] == 3 and d[6 * page] == 9;
        d[7 * page] = 1;
        d[6 * page] = 1;
        sys.exit(if (ok) 0 else 1);
    }
    const r = (sys.wait(pid, false) catch null).?;
    expect(r.status == 0, "child saw wrong data: status {d}", .{r.status});
    expect(d[7 * page] == 3 and d[6 * page] == 9, "child's writes leaked into the parent", .{});
}

/// 2. 内核替程序访问还没读进来的页
fn kernelAccess() void {
    // write 到管道：来源是 big 里没碰过的一页（拿着管道的锁复制）
    {
        const p = sys.pipe() catch unreachable;
        const n = sys.write(p[1], big[20 * page ..][0..100]) catch 0;
        var buf: [100]u8 = undefined;
        const m = sys.read(p[0], &buf) catch 0;
        expect(n == 100 and m == 100 and std.mem.allEqual(u8, &buf, 7), "pipe write from an untouched page: {d} {d}", .{ n, m });
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
    }
    // write 到串口（拿着输出锁）：这一行就是从没碰过的页里来的
    const line = "this line comes from a page that was never touched\n";
    expect((sys.write(sys.stdout, line) catch 0) == line.len, "console write from an untouched page", .{});
    // write 到文件（拿着文件系统的写锁），再读回到 data 里没碰过的页（read 先检查、分配好整个目标）
    {
        sys.mkdir("/tdemand") catch {};
        const fd = sys.open("/tdemand/f", .{ .write = true, .create = true, .truncate = true }) catch {
            expect(false, "create /tdemand/f", .{});
            return;
        };
        const n = sys.write(fd, big[24 * page ..][0 .. 2 * page]) catch 0;
        expect(n == 2 * page, "file write from untouched pages: {d}", .{n});
        _ = sys.lseek(fd, 0, .set) catch {};
        sys.close(fd) catch {};
        const rd = sys.open("/tdemand/f", .{}) catch unreachable;
        const got = sys.read(rd, data[10 * page ..][0 .. 2 * page]) catch 0;
        expect(got == 2 * page and std.mem.allEqual(u8, data[10 * page ..][0 .. 2 * page], 7), "read into untouched data pages: {d}", .{got});
        // fstat、readdir（拿着读写位置的锁）写进没碰过的数据页
        const st: *abi.Stat = @ptrCast(@alignCast(&data[13 * page]));
        expect(sys.syscall(.fstat, rd, @intFromPtr(st), 0) == 0 and st.size == 2 * page, "fstat into an untouched page", .{});
        sys.close(rd) catch {};
        const dir = sys.open("/tdemand", .{}) catch unreachable;
        const ent: *abi.Dirent = @ptrCast(@alignCast(&data[14 * page]));
        expect(sys.syscall(.readdir, dir, @intFromPtr(ent), 0) == 1 and ent.name_len == 1 and ent.name[0] == 'f', "readdir into an untouched page", .{});
        sys.close(dir) catch {};
        sys.unlink("/tdemand/f") catch {};
    }
    // wait 的结束状态（拿着进程的锁写）写进没碰过的数据页
    {
        const pid = sys.fork() catch unreachable;
        if (pid == 0) sys.exit(77);
        const status: *u32 = @ptrCast(@alignCast(&data[15 * page]));
        expect(sys.syscall(.wait, pid, @intFromPtr(status), 0) == pid and status.* == 77, "wait status into an untouched page: {d}", .{status.*});
    }
}

/// 3. 栈按需长：在子进程里用掉约 512 KiB 的栈
fn stack() void {
    const before = freePages();
    const pid = sys.fork() catch unreachable;
    if (pid == 0) sys.exec("/bin/t_demand", &.{ "t_demand", "deep" }) catch sys.exit(99);
    const r = (sys.wait(pid, false) catch null).?;
    expect(r.status == 0, "using 512 KiB of stack: status {d}", .{r.status});
    expect(freePages() == before, "deep stack leaked {d} pages", .{before -| freePages()});
}

fn deepStack() u8 {
    const before = freePages();
    const ok = recurse(512) == 512 * 3;
    const used = before -| freePages();
    sys.print("512 KiB of stack used {d} pages\n", .{used});
    return if (ok and used >= 128) 0 else 1;
}

fn recurse(n: usize) usize {
    var buf: [1024]u8 = undefined;
    const v: *volatile [1024]u8 = &buf;
    v[n % 1024] = 3;
    if (n == 0) return 0;
    return recurse(n - 1) + v[n % 1024];
}

/// 4. 正在运行的程序文件不能改、不能删
fn textBusy() void {
    sys.mkdir("/tdemand") catch {};
    if (!copyFile("/bin/spin", "/tdemand/s")) {
        expect(false, "copy /bin/spin", .{});
        return;
    }
    // 没在运行：可以写（写回同样的内容）
    expect(rewrite("/tdemand/s"), "rewriting a program that is not running", .{});
    const pid = sys.fork() catch unreachable;
    if (pid == 0) {
        sys.exec("/tdemand/s", &.{"s"}) catch {};
        sys.exit(99);
    }
    sys.sleep(100); // 等它 exec 好
    expect(!rewrite("/tdemand/s"), "writing a running program succeeded", .{});
    {
        const fd = sys.open("/tdemand/s", .{ .write = true }) catch unreachable;
        expect(sys.write(fd, "x") == error.TextBusy, "write to a running program: not TextBusy", .{});
        sys.close(fd) catch {};
    }
    expect(sys.open("/tdemand/s", .{ .write = true, .truncate = true }) == error.TextBusy, "truncating a running program", .{});
    expect(sys.unlink("/tdemand/s") == error.TextBusy, "removing a running program", .{});
    _ = copyFile("/bin/hello", "/tdemand/h");
    expect(sys.rename("/tdemand/h", "/tdemand/s") == error.TextBusy, "renaming over a running program", .{});
    // 改名、多一个名字再删掉一个，都不碰内容：可以
    sys.rename("/tdemand/s", "/tdemand/s2") catch |err| expect(false, "renaming a running program: {s}", .{@errorName(err)});
    sys.link("/tdemand/s2", "/tdemand/s3") catch |err| expect(false, "linking a running program: {s}", .{@errorName(err)});
    sys.unlink("/tdemand/s3") catch |err| expect(false, "removing a second name of a running program: {s}", .{@errorName(err)});
    expect(sys.unlink("/tdemand/s2") == error.TextBusy, "removing the renamed running program", .{});
    sys.kill(pid) catch {};
    _ = sys.wait(pid, false) catch {};
    // 结束了：又可以改、可以删了
    expect(rewrite("/tdemand/s2"), "rewriting a program after it exited", .{});
    sys.rename("/tdemand/h", "/tdemand/s2") catch |err| expect(false, "renaming over a program after it exited: {s}", .{@errorName(err)});
    sys.unlink("/tdemand/s2") catch |err| expect(false, "removing a program after it exited: {s}", .{@errorName(err)});
    sys.unlink("/tdemand") catch {};
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

/// 把文件的第一个字节原样写回去，成功返回 true。
fn rewrite(path: []const u8) bool {
    const fd = sys.open(path, .{ .write = true }) catch return false;
    defer sys.close(fd) catch {};
    var b: [1]u8 = undefined;
    _ = sys.read(fd, &b) catch return false;
    _ = sys.lseek(fd, 0, .set) catch return false;
    return (sys.write(fd, &b) catch 0) == 1;
}
