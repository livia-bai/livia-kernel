//! 回归测试：fork、exec、wait、kill、getppid、setfg、procinfo、meminfo 的正常情况和边界情况。
//! 每项检查失败时打印 "FAIL: ..."，最后打印通过的项数，退出码是失败的项数。
//! 由 shell 前台运行（父进程是 sh）。期望的输出见 tools/qemu_test.py。
//! - `run t_fork fill &`：把进程表填满（qemu_test.py 测 shell 在表满时的报错）：一直 fork 到失败，打印个数，
//!   然后睡下去，等着被 kill。子进程每 50 ms 看一次父进程，父进程没了（交给了 init）就结束。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

var failures: u8 = 0;
var checks: usize = 0;

fn check(ok: bool, comptime what: []const u8, args: anytype) void {
    checks += 1;
    if (!ok) {
        failures += 1;
        sys.print("FAIL: " ++ what ++ "\n", args);
    }
}

fn errno(ret: usize) ?abi.Errno {
    return abi.errnoOf(ret);
}

/// fork 一个子进程，子进程运行 body 之后以它的返回值结束。返回子进程的 pid。
fn spawn(comptime body: fn () u8) usize {
    const pid = sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
    if (pid == 0) sys.exit(body());
    return pid;
}

var shared: u32 = 1;

fn childChangesMemory() u8 {
    shared = 2; // 只改自己那一份
    return if (sys.getppid() == parent_pid) 7 else 99;
}

fn sleepForever() u8 {
    sys.sleep(1_000_000);
    return 0;
}

fn sleepShort() u8 {
    sys.sleep(100);
    return 3;
}

fn orphanMaker() u8 {
    // 孙进程等父进程（也就是这个子进程）结束之后，看自己的父进程是不是变成了 init
    const pid = sys.fork() catch return 1;
    if (pid == 0) {
        sys.sleep(50);
        sys.print("orphan's parent is pid {d}\n", .{sys.getppid()});
        sys.exit(0);
    }
    return 0;
}

fn execHello() u8 {
    sys.print("child pid {d} execs hello\n", .{sys.getpid()});
    sys.exec("hello", &.{"hello"}) catch {};
    return 1;
}

var parent_pid: usize = 0;

/// 填满进程表，见文件开头。
fn fill() noreturn {
    var n: usize = 0;
    while (sys.fork()) |pid| : (n += 1) {
        if (pid == 0) {
            while (sys.getppid() != 1) sys.sleep(50);
            sys.exit(0);
        }
    } else |_| {}
    sys.print("t_fork: filled the process table with {d} children\n", .{n});
    while (true) sys.sleep(1_000_000);
}

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "fill")) fill();
    }
    parent_pid = sys.getpid();
    const sh = sys.getppid();

    // fork：子进程得到 0、父进程得到子进程的 pid；地址空间是复制的；wait 拿到退出码
    {
        const pid = spawn(childChangesMemory);
        check(pid > parent_pid, "fork returned pid {d}", .{pid});
        const r = (sys.wait(pid, false) catch null).?;
        check(r.pid == pid and r.status == 7, "wait -> pid {d} status {d}", .{ r.pid, r.status });
        check(shared == 1, "child's write leaked into the parent: {d}", .{shared});
    }

    // nohang：子进程还没结束时返回 null；之后照常等到
    {
        const pid = spawn(sleepShort);
        check((sys.wait(pid, true) catch null) == null, "wait nohang returned a result", .{});
        const r = (sys.wait(null, false) catch null).?;
        check(r.pid == pid and r.status == 3, "wait any -> pid {d} status {d}", .{ r.pid, r.status });
    }

    // 没有子进程、等别人的子进程、坏的 options
    check(sys.wait(null, false) == error.NoChildren, "wait with no children", .{});
    check(sys.wait(sh, false) == error.NoChildren, "wait for a process that is not a child", .{});
    check(errno(sys.syscall(.wait, abi.wait_any, 0, 2)) == .inval, "wait with bad options", .{});

    // 状态写不进去时返回 EFAULT，子进程还在，可以再等；status_ptr = 0 时不写状态
    {
        const pid = spawn(sleepShort);
        const kernel_addr: usize = 0x8020_0000;
        check(errno(sys.syscall(.wait, pid, kernel_addr, 0)) == .fault, "wait with a bad status pointer", .{});
        check(sys.syscall(.wait, pid, 0, 0) == pid, "wait again after EFAULT", .{});
    }

    // kill：睡着的子进程被叫醒、结束，状态是 killed_status
    {
        const pid = spawn(sleepForever);
        sys.yield(); // 让它先睡下去
        sys.kill(pid) catch |err| check(false, "kill child: {s}", .{@errorName(err)});
        const r = (sys.wait(pid, false) catch null).?;
        check(r.status == abi.killed_status, "killed child status {d}", .{r.status});
    }
    check(sys.kill(1) == error.PermissionDenied, "kill init", .{});
    check(sys.kill(9999) == error.NoSuchProcess, "kill a missing pid", .{});
    check(sys.setfg(9999) == error.NoSuchProcess, "setfg a missing pid", .{});

    // exec：失败时原来的程序照常运行；成功时 pid 不变
    check(sys.exec("nope", &.{}) == error.NotFound, "exec a missing program", .{});
    check(sys.exec("", &.{}) == error.NotFound, "exec an empty name", .{});
    check(sys.exec("/bin/nope", &.{}) == error.NotFound, "exec a missing path", .{});
    const long_name: [40]u8 = @splat('x');
    check(sys.exec(&long_name, &.{}) == error.NotFound, "exec a long name", .{});
    const too_long: [abi.max_path + 1]u8 = @splat('x');
    check(sys.exec(&too_long, &.{}) == error.NameTooLong, "exec a {d}-byte name", .{too_long.len});
    check(sys.exec(too_long[0 .. abi.max_path - 4], &.{}) == error.NameTooLong, "exec a name too long for /bin/", .{});
    check(sys.exec("t_noperm", &.{}) == error.BadElf, "exec a bad ELF", .{});
    check(sys.exec("/bin", &.{}) == error.BadElf, "exec a directory", .{});
    check(sys.exec("/bin/hello/x", &.{}) == error.NotDir, "exec under a file", .{});
    check(errno(sys.syscall(.exec, 0x8020_0000, 5, 0)) == .fault, "exec with a bad name pointer", .{});
    {
        const pid = spawn(execHello);
        const r = (sys.wait(pid, false) catch null).?;
        check(r.status == 0, "exec'd hello exited with {d}", .{r.status});
    }

    // 孤儿交给 init
    {
        const pid = spawn(orphanMaker);
        _ = sys.wait(pid, false) catch {};
        sys.sleep(200); // 等孙进程打印
    }

    // 进程表满了：fork 返回 EAGAIN；全部杀掉、回收之后不漏页（qemu_test.py 比较前后的 mem）
    {
        var pids: [abi.max_procs]usize = undefined;
        var n: usize = 0;
        while (sys.fork()) |pid| {
            if (pid == 0) sys.exit(sleepForever());
            pids[n] = pid;
            n += 1;
        } else |err| check(err == error.TooManyProcesses, "fork error {s}", .{@errorName(err)});
        sys.print("forked {d} children before the table was full\n", .{n});
        for (pids[0..n]) |pid| sys.kill(pid) catch {};
        for (pids[0..n]) |pid| {
            const r = (sys.wait(pid, false) catch null).?;
            check(r.status == abi.killed_status, "status {d}", .{r.status});
        }
    }

    // procinfo：n = 0 时只返回总数；坏指针 EFAULT；能找到自己
    {
        var buf: [abi.max_procs]abi.ProcInfo = undefined;
        const total = sys.procinfo(buf[0..0]);
        check(total == 3, "procinfo total {d} (init, sh, t_fork)", .{total});
        check(errno(sys.syscall(.procinfo, 0x8020_0000, 1, 0)) == .fault, "procinfo with a bad pointer", .{});
        const n = sys.procinfo(&buf);
        var found = false;
        for (buf[0..n]) |p| {
            if (p.pid != parent_pid) continue;
            found = true;
            check(p.ppid == sh and p.state == .running, "procinfo of self: ppid {d} state {s}", .{ p.ppid, @tagName(p.state) });
            check(std.mem.eql(u8, p.name[0..p.name_len], "t_fork"), "procinfo name", .{});
        }
        check(found, "procinfo did not list this process", .{});
    }

    // meminfo、read 的坏参数；去掉了的 listprog（15）
    check(errno(sys.syscall(.meminfo, 0x8020_0000, 0, 0)) == .fault, "meminfo with a bad pointer", .{});
    check(sys.meminfo().page_size == 4096, "meminfo page size", .{});
    check(errno(sys.syscall(@fromBackingInt(15), 0, 0, 0)) == .nosys, "syscall 15 (was listprog)", .{});
    check(errno(sys.syscall(.read, sys.stdin, 0x8020_0000, 4)) == .fault, "read into kernel memory", .{});
    check(sys.syscall(.read, sys.stdin, 0, 0) == 0, "read of length 0", .{});

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
