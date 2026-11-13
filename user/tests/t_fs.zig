//! 回归测试：文件系统的系统调用（open、read、write、mkdir、unlink、chdir、fstat、readdir、lseek、rename、
//! link、mknod、symlink、readlink、lstat、getcwd）和设备文件（/dev/null、/dev/zero、/dev/console）。
//! - `run t_fs`：正常情况和边界情况，失败的项打印 "FAIL: ..."，最后打印检查了几项、失败了几项。
//!   所有东西建在 /t_fs 下面，结束时删干净（开始时也先删掉上一次留下的）。
//! - `run t_fs churn &`：掉电测试的写的一方，一直写到被杀（或者 QEMU 被杀）：往 /churn.dat 末尾追加记录，
//!   反复截断、重写 /churn/ 下面的几个文件。
//! - `run t_fs verify`：掉电之后重新启动时运行，检查 churn 写的东西：每个操作要么做完了、要么没做。
//! - `run t_fs scrubfile`：建 /scrub.dat 给 scrub 的测试用（见 scrubFile）。

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

fn fork() usize {
    return sys.fork() catch |err| {
        sys.print("FAIL: fork: {s}\n", .{@errorName(err)});
        sys.exit(200);
    };
}

fn waitStatus(pid: usize) u32 {
    const r = (sys.wait(pid, false) catch null) orelse return 999;
    return r.status;
}

/// 打开，失败就算一项失败并退出（后面的检查都依赖它）。
fn mustOpen(path: []const u8, flags: sys.OpenFlags) sys.Fd {
    return sys.open(path, flags) catch |err| {
        sys.print("FAIL: open {s}: {s}\n", .{ path, @errorName(err) });
        sys.exit(201);
    };
}

fn sizeOf(fd: sys.Fd) u64 {
    const st = sys.fstat(fd) catch return 999_999_999;
    return st.size;
}

/// 整个文件读出来（最多 buf.len 字节），每次最多读 chunk 字节。
fn readAll(path: []const u8, buf: []u8, chunk: usize) usize {
    const fd = sys.open(path, .{}) catch return 0;
    defer sys.close(fd) catch {};
    var len: usize = 0;
    while (len < buf.len) {
        const n = sys.read(fd, buf[len..@min(buf.len, len + chunk)]) catch break;
        if (n == 0) break;
        len += n;
    }
    return len;
}

fn writeAll(fd: sys.Fd, bytes: []const u8) bool {
    const n = sys.write(fd, bytes) catch return false;
    return n == bytes.len;
}

/// 删掉 path 和它下面的所有东西（不存在就算了）。用 lstat 看种类：指向目录的符号链接只删链接自己，
/// 不能跟着它走进去（指向 / 的链接会把整个文件系统删掉）。
fn removeTree(path: []const u8) void {
    const st = sys.lstat(path) catch return;
    if (st.kind == .dir) {
        if (sys.open(path, .{})) |fd| {
            defer sys.close(fd) catch {};
            var ent: abi.Dirent = undefined;
            // 边列边删：readdir 的位置是键，删掉的名字不影响后面的
            while (sys.readdir(fd, &ent) catch false) {
                var buf: [abi.max_path]u8 = undefined;
                const child = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, ent.name[0..ent.name_len] }) catch continue;
                removeTree(child);
            }
        } else |_| {}
    }
    sys.unlink(path) catch {};
}

fn pattern(seed: u64, i: usize) u8 {
    return @truncate(seed *% 131 +% i *% 7 +% (i >> 8));
}

fn fillPattern(buf: []u8, seed: u64) void {
    for (buf, 0..) |*c, i| c.* = pattern(seed, i);
}

fn isPattern(buf: []const u8, seed: u64) bool {
    for (buf, 0..) |c, i| if (c != pattern(seed, i)) return false;
    return true;
}

/// 大文件：跨过内联的上限（512 字节），占好几页
const big = 40_000;
var big_buf: [big]u8 = undefined;
var read_buf: [big + 100]u8 = undefined;

pub fn main() u8 {
    if (sys.arg(1)) |a| {
        if (std.mem.eql(u8, a, "churn")) churn();
        if (std.mem.eql(u8, a, "verify")) return verify();
        if (std.mem.eql(u8, a, "scrubfile")) return scrubFile();
    }

    // 串口、管道的 fstat
    {
        const st = sys.fstat(sys.stdout) catch abi.Stat{ .ino = 9, .size = 9, .kind = .file };
        expect(st.kind == .console and st.ino == 0, "fstat stdout: kind {d} ino {d}", .{ @backingInt(st.kind), st.ino });
        const p = sys.pipe() catch .{ 0, 0 };
        expect((sys.fstat(p[0]) catch abi.Stat{ .ino = 0, .size = 0, .kind = .file }).kind == .pipe, "fstat pipe", .{});
        sys.close(p[0]) catch {};
        sys.close(p[1]) catch {};
        expect(sys.readdir(sys.stdin, @ptrFromInt(0x1000)) == error.NotDir, "readdir on the console", .{});
    }

    removeTree("/t_fs");
    sys.mkdir("/t_fs") catch |err| {
        sys.print("FAIL: mkdir /t_fs: {s}\n", .{@errorName(err)});
        return 1;
    };

    // 建文件、写、读回来；关掉再打开，内容还在
    {
        expect(sys.open("/t_fs/a", .{}) == error.NotFound, "open a missing file", .{});
        const fd = mustOpen("/t_fs/a", .{ .read = false, .write = true, .create = true });
        expect(sizeOf(fd) == 0, "new file size {d}", .{sizeOf(fd)});
        expect(writeAll(fd, "hello"), "write hello", .{});
        const st = sys.fstat(fd) catch abi.Stat{ .ino = 0, .size = 0, .kind = .dir };
        expect(st.kind == .file and st.size == 5 and st.ino > 1, "fstat: kind {d} size {d} ino {d}", .{ @backingInt(st.kind), st.size, st.ino });
        var buf: [16]u8 = undefined;
        expect(sys.read(fd, &buf) == error.BadFd, "read a write-only fd", .{});
        sys.close(fd) catch {};

        const r = mustOpen("/t_fs/a", .{});
        expect(sys.write(r, "x") == error.BadFd, "write a read-only fd", .{});
        var n = sys.read(r, &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "hello"), "read back \"{s}\"", .{buf[0..n]});
        n = sys.read(r, &buf) catch 99;
        expect(n == 0, "read at the end: {d}", .{n});
        sys.close(r) catch {};

        // 已经有了的话 create 不截断，trunc 才截
        const c = mustOpen("/t_fs/a", .{ .write = true, .create = true });
        expect(sizeOf(c) == 5, "create on an existing file kept {d} bytes", .{sizeOf(c)});
        sys.close(c) catch {};
        const t = mustOpen("/t_fs/a", .{ .write = true, .truncate = true });
        expect(sizeOf(t) == 0, "truncate: size {d}", .{sizeOf(t)});
        expect(writeAll(t, "abc"), "write after truncate", .{});
        sys.close(t) catch {};
        n = readAll("/t_fs/a", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "abc"), "after truncate: \"{s}\"", .{buf[0..n]});
    }

    // 读写位置：dup、fork 出来的 fd 共用一个位置；各自 open 的各有各的
    {
        const fd = mustOpen("/t_fs/b", .{ .read = true, .write = true, .create = true });
        const d = sys.dup(fd) catch fd;
        expect(writeAll(fd, "ab") and writeAll(d, "cd"), "write through dup", .{});
        sys.close(d) catch {};
        const pid = fork();
        if (pid == 0) sys.exit(if (writeAll(fd, "ef")) 0 else 1);
        expect(waitStatus(pid) == 0, "child writes through the inherited fd", .{});
        expect(writeAll(fd, "gh"), "write after the child", .{});
        var buf: [16]u8 = undefined;
        var n = readAll("/t_fs/b", &buf, 3);
        expect(std.mem.eql(u8, buf[0..n], "abcdefgh"), "shared offset: \"{s}\"", .{buf[0..n]});
        // 位置在末尾，读到 0
        n = sys.read(fd, &buf) catch 99;
        expect(n == 0, "read at the shared offset: {d}", .{n});
        sys.close(fd) catch {};

        // 两个各自打开的 fd：第二个从 0 开始，覆盖前面的字节
        const x = mustOpen("/t_fs/b", .{ .write = true });
        expect(writeAll(x, "XY"), "overwrite", .{});
        sys.close(x) catch {};
        n = readAll("/t_fs/b", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "overwrite at 0: \"{s}\"", .{buf[0..n]});
    }

    // 大文件：分几次写（中途从内联换成数据块），换几种大小读回来
    {
        fillPattern(&big_buf, 1);
        const fd = mustOpen("/t_fs/big", .{ .write = true, .create = true });
        var off: usize = 0;
        var ok = true;
        while (off < big) : (off += 3000) ok = ok and writeAll(fd, big_buf[off..@min(big, off + 3000)]);
        expect(ok, "write {d} bytes in 3000-byte pieces", .{big});
        expect(sizeOf(fd) == big, "big file size {d}", .{sizeOf(fd)});
        sys.close(fd) catch {};
        for ([_]usize{ 1, 100, 4096, 5000, big + 100 }) |chunk| {
            if (chunk == 1) continue; // 一次一个字节太慢（每次一个系统调用），下面单独读一段
            @memset(&read_buf, 0);
            const n = readAll("/t_fs/big", &read_buf, chunk);
            expect(n == big and isPattern(read_buf[0..n], 1), "read big back in {d}-byte pieces: {d} bytes", .{ chunk, n });
        }
        // 一次写 40000 字节（一个事务写 10 页），再整个读回来
        fillPattern(&big_buf, 2);
        const w = mustOpen("/t_fs/big", .{ .write = true, .truncate = true });
        expect(writeAll(w, &big_buf), "write {d} bytes at once", .{big});
        sys.close(w) catch {};
        const n = readAll("/t_fs/big", &read_buf, read_buf.len);
        expect(n == big and isPattern(read_buf[0..n], 2), "read big back at once: {d} bytes", .{n});
    }

    // 坏指针：路径、读写的缓冲区、fstat、readdir 的结果都不能指到内核里
    {
        const kernel: usize = 0x80200000;
        const bad_path: [*]const u8 = @ptrFromInt(kernel);
        expect(sys.open(bad_path[0..4], .{}) == error.BadAddress, "open with a kernel pointer", .{});
        expect(sys.mkdir(bad_path[0..4]) == error.BadAddress, "mkdir with a kernel pointer", .{});
        const fd = mustOpen("/t_fs/b", .{ .read = true, .write = true });
        const bad: [*]u8 = @ptrFromInt(kernel);
        expect(sys.read(fd, bad[0..8]) == error.BadAddress, "read into kernel memory", .{});
        // 读失败不挪位置
        var buf: [16]u8 = undefined;
        var n = sys.read(fd, &buf) catch 0;
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "offset after a failed read: \"{s}\"", .{buf[0..n]});
        // 写到一半出错（前一半是好的用户内存，后一半是没映射的地址）：整个写作废，文件不变
        const stack_top: usize = 0x80000000; // 用户地址空间的末尾，再往上不是用户内存
        const half: [*]const u8 = @ptrFromInt(stack_top - 2000);
        expect(sys.write(fd, half[0..6000]) == error.BadAddress, "write running off the end of the stack", .{});
        expect(sizeOf(fd) == 8, "size after a failed write: {d}", .{sizeOf(fd)});
        expect(sys.fstat(fd) != error.BadAddress, "fstat", .{});
        const ret = sys.syscall(.fstat, fd, kernel, 0);
        expect(abi.errnoOf(ret) == .fault, "fstat into kernel memory", .{});
        sys.close(fd) catch {};
        n = readAll("/t_fs/b", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "XYcdefgh"), "content after a failed write: \"{s}\"", .{buf[0..n]});
    }

    // 目录：mkdir、错误、readdir、chdir
    {
        expect(sys.mkdir("/t_fs/d") != error.Exists, "mkdir /t_fs/d", .{});
        expect(sys.mkdir("/t_fs/d") == error.Exists, "mkdir twice", .{});
        expect(sys.mkdir("/t_fs/a/x") == error.NotDir, "mkdir under a file", .{});
        expect(sys.mkdir("/t_fs/nope/x") == error.NotFound, "mkdir under a missing directory", .{});
        expect(sys.mkdir("/t_fs/d/..") == error.InvalidArgument, "mkdir ..", .{});
        expect(sys.open("/t_fs/d", .{ .write = true }) == error.IsDir, "open a directory for writing", .{});
        expect(sys.open("/t_fs/d", .{ .write = true, .create = true }) == error.IsDir, "create over a directory", .{});
        expect(sys.open("/t_fs", .{ .read = true }) != error.IsDir, "open a directory read-only", .{});
        const dfd = mustOpen("/t_fs/d", .{});
        var buf: [16]u8 = undefined;
        expect(sys.read(dfd, &buf) == error.IsDir, "read a directory", .{});
        const st = sys.fstat(dfd) catch abi.Stat{ .ino = 0, .size = 1, .kind = .file };
        expect(st.kind == .dir and st.size == 0, "fstat a directory: kind {d} size {d}", .{ @backingInt(st.kind), st.size });
        var ent: abi.Dirent = undefined;
        expect((sys.readdir(dfd, &ent) catch true) == false, "readdir an empty directory", .{});
        sys.close(dfd) catch {};
        const ffd = mustOpen("/t_fs/a", .{});
        expect(sys.readdir(ffd, &ent) == error.NotDir, "readdir a file", .{});
        sys.close(ffd) catch {};

        // 名字太长
        var long: [abi.max_name + 1]u8 = @splat('n');
        expect(sys.mkdir(&long) == error.NameTooLong, "mkdir a 256-byte name", .{});
        expect(sys.open(&long, .{ .write = true, .create = true }) == error.NameTooLong, "create a 256-byte name", .{});
        var longest: [abi.max_name]u8 = @splat('m');
        @memcpy(longest[0..7], "/t_fs/d");
        longest[7] = '/';
        expect(sys.mkdir(&longest) != error.NameTooLong, "mkdir a name of {d} bytes", .{longest.len - 8});
        var path: [abi.max_path + 1]u8 = @splat('/');
        expect(sys.open(&path, .{}) == error.NameTooLong, "a 257-byte path", .{});
        expect(sys.open(path[0..abi.max_path], .{}) != error.NameTooLong, "a 256-byte path (the root)", .{});

        // 一个目录里 30 个文件，readdir 每个名字正好列出一次；readdir 写结果失败时不挪位置
        sys.mkdir("/t_fs/many") catch {};
        var i: usize = 0;
        while (i < 30) : (i += 1) {
            var nb: [32]u8 = undefined;
            const p = std.fmt.bufPrint(&nb, "/t_fs/many/f{d}", .{i}) catch unreachable;
            const fd = mustOpen(p, .{ .write = true, .create = true });
            _ = writeAll(fd, p);
            sys.close(fd) catch {};
        }
        var seen: u32 = 0;
        var dup_seen = false;
        const mfd = mustOpen("/t_fs/many", .{});
        expect(abi.errnoOf(sys.syscall(.readdir, mfd, 0x80200000, 0)) == .fault, "readdir into kernel memory", .{});
        var count: usize = 0;
        while (sys.readdir(mfd, &ent) catch false) : (count += 1) {
            const name = ent.name[0..ent.name_len];
            const k = std.fmt.parseUnsigned(u5, name[1..], 10) catch 31;
            if (k < 30 and name[0] == 'f' and ent.kind == .file) {
                if (seen & (@as(u32, 1) << k) != 0) dup_seen = true;
                seen |= @as(u32, 1) << k;
            }
        }
        sys.close(mfd) catch {};
        expect(count == 30 and seen == (1 << 30) - 1 and !dup_seen, "readdir listed {d} names, mask 0x{x}", .{ count, seen });

        // chdir：相对路径从当前目录开始；子进程 chdir 不影响父进程
        expect(sys.chdir("/t_fs/a") == error.NotDir, "chdir to a file", .{});
        expect(sys.chdir("/t_fs/nope") == error.NotFound, "chdir to a missing directory", .{});
        expect(sys.chdir("/t_fs/many") != error.NotFound, "chdir /t_fs/many", .{});
        const n = readAll("f7", &buf, 16);
        expect(std.mem.eql(u8, buf[0..n], "/t_fs/many/f7"), "relative open: \"{s}\"", .{buf[0..n]});
        const pid = fork();
        if (pid == 0) {
            sys.chdir("..") catch sys.exit(1);
            sys.exit(if (readAll("b", &buf, 16) == 8) 0 else 2);
        }
        expect(waitStatus(pid) == 0, "child chdir ..", .{});
        expect(readAll("f8", &buf, 16) == 13, "parent's cwd after the child's chdir", .{});
        expect(sys.mkdir("./sub/../sub2") == error.NotFound, "path through a missing directory", .{});
        expect(sys.mkdir("sub") != error.NotFound, "relative mkdir", .{});
        expect(sys.chdir("../../t_fs/./many/sub") != error.NotFound, "chdir with .. and .", .{});
        expect(sys.chdir("/") != error.NotFound, "chdir /", .{});
        expect(readAll("t_fs/b", &buf, 16) == 8, "relative to /", .{});

        // 删除
        expect(sys.unlink("/t_fs/many") == error.NotEmpty, "unlink a non-empty directory", .{});
        expect(sys.unlink("/t_fs/many/.") == error.InvalidArgument, "unlink .", .{});
        expect(sys.unlink("/t_fs/zzz") == error.NotFound, "unlink a missing file", .{});
        expect(sys.unlink("/") == error.InvalidArgument, "unlink /", .{});
        // 打开着的文件被删了：只删名字，fd 照常能读（和 Unix 一样，最后一个关掉才删，更多见 t_unlink）
        const ofd = mustOpen("/t_fs/many/f0", .{});
        expect(sys.unlink("/t_fs/many/f0") != error.NotFound, "unlink an open file", .{});
        expect((sys.read(ofd, &buf) catch 999) != 999, "read a deleted file that is still open", .{});
        sys.close(ofd) catch {};
        expect(sys.open("/t_fs/many/f0", .{}) == error.NotFound, "open after unlink", .{});
    }

    // 并发：4 个进程同时往同一个 fd（共用位置）追加 100 字节的记录，同时各自写自己的文件。
    // 每次 write 是一个事务、拿着文件系统的锁，所以记录不会交错、不会互相覆盖
    {
        const procs = 4;
        const records = 20;
        const rec = 100;
        const shared = mustOpen("/t_fs/shared", .{ .write = true, .create = true });
        var pids: [procs]usize = undefined;
        for (&pids, 0..) |*pid, k| {
            pid.* = fork();
            if (pid.* != 0) continue;
            var nb: [32]u8 = undefined;
            const own = std.fmt.bufPrint(&nb, "/t_fs/own{d}", .{k}) catch unreachable;
            const fd = sys.open(own, .{ .write = true, .create = true }) catch sys.exit(1);
            var r: [rec]u8 = @splat(@intCast('A' + k));
            var j: usize = 0;
            while (j < records) : (j += 1) {
                r[1] = @intCast(j);
                if (!writeAll(shared, &r)) sys.exit(2);
                var page: [1500]u8 = undefined;
                fillPattern(&page, k * 100 + j);
                if (!writeAll(fd, &page)) sys.exit(3);
                if (j % 4 == 0) sys.yield();
            }
            sys.exit(0);
        }
        var ok = true;
        for (pids) |pid| ok = ok and waitStatus(pid) == 0;
        expect(ok, "concurrent writers exited with 0", .{});
        expect(sizeOf(shared) == procs * records * rec, "shared file size {d}", .{sizeOf(shared)});
        sys.close(shared) catch {};
        const n = readAll("/t_fs/shared", &read_buf, read_buf.len);
        var next: [procs]u8 = @splat(0);
        var bad: usize = 0;
        var i: usize = 0;
        while (i + rec <= n) : (i += rec) {
            const r = read_buf[i..][0..rec];
            const k = r[0] -% 'A';
            if (k >= procs or r[1] != next[k]) {
                bad += 1;
                continue;
            }
            next[k] += 1;
            for (r[2..]) |c| if (c != r[0]) {
                bad += 1;
                break;
            };
        }
        expect(n == procs * records * rec and bad == 0, "shared records: {d} bytes, {d} bad", .{ n, bad });
        for (0..procs) |k| {
            var nb: [32]u8 = undefined;
            const own = std.fmt.bufPrint(&nb, "/t_fs/own{d}", .{k}) catch unreachable;
            const m = readAll(own, &read_buf, read_buf.len);
            var good = m == records * 1500;
            var j: usize = 0;
            while (good and j < records) : (j += 1) good = isPattern(read_buf[j * 1500 ..][0..1500], k * 100 + j);
            expect(good, "{s}: {d} bytes", .{ own, m });
        }
    }

    testLseek();
    testAppend();
    testRename();
    testLink();
    testDevices();
    testSymlinks();
    testGetcwd();

    removeTree("/t_fs");
    expect(sys.open("/t_fs", .{}) == error.NotFound, "everything removed", .{});

    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}

/// lseek：三种 whence、挪到末尾之后再写是洞、负的位置和坏的 whence、dup 出来的 fd 共用位置、
/// 串口和管道不能挪、目录只能挪回 0 重新列。
fn testLseek() void {
    var buf: [64]u8 = undefined;
    const fd = mustOpen("/t_fs/seek", .{ .write = true, .create = true });
    defer sys.close(fd) catch {};
    _ = writeAll(fd, "0123456789");
    expect((sys.lseek(fd, 3, .set) catch 99) == 3, "lseek set", .{});
    var n = sys.read(fd, buf[0..4]) catch 0;
    expect(n == 4 and std.mem.eql(u8, buf[0..4], "3456"), "read after lseek set: \"{s}\"", .{buf[0..n]});
    expect((sys.lseek(fd, -2, .cur) catch 99) == 5, "lseek cur -2", .{});
    expect((sys.lseek(fd, 0, .cur) catch 99) == 5, "lseek cur 0 tells the position", .{});
    expect((sys.lseek(fd, -1, .end) catch 99) == 9, "lseek end -1", .{});
    n = sys.read(fd, &buf) catch 0;
    expect(n == 1 and buf[0] == '9', "read the last byte", .{});
    expect((sys.read(fd, &buf) catch 99) == 0, "read at the end", .{});
    // 挪到末尾之后再写：中间是 0
    expect((sys.lseek(fd, 5, .end) catch 99) == 15, "lseek past the end", .{});
    _ = writeAll(fd, "X");
    expect(sizeOf(fd) == 16, "size after writing past the end: {d}", .{sizeOf(fd)});
    _ = sys.lseek(fd, 8, .set) catch 0;
    n = sys.read(fd, &buf) catch 0;
    expect(n == 8 and std.mem.eql(u8, buf[0..8], "89\x00\x00\x00\x00\x00X"), "the hole reads as zeros", .{});
    // 出错时位置不变
    _ = sys.lseek(fd, 4, .set) catch 0;
    expect(sys.lseek(fd, -5, .cur) == error.InvalidArgument, "lseek to a negative position", .{});
    expect(sys.lseek(fd, -17, .end) == error.InvalidArgument, "lseek before the start from the end", .{});
    expect(sys.syscall(.lseek, fd, 0, 3) == sys.abi.fail(.inval), "lseek with a bad whence", .{});
    expect(sys.lseek(fd, std.math.maxInt(i64), .set) catch 0 == std.math.maxInt(i64), "lseek to the largest position", .{});
    expect(sys.lseek(fd, 1, .cur) == error.InvalidArgument, "lseek past the largest position", .{});
    expect(sys.write(fd, "x") == error.FileTooBig, "write at the largest position", .{});
    _ = sys.lseek(fd, 4, .set) catch 0;
    // dup 出来的 fd 共用位置
    const d = sys.dup(fd) catch fd;
    _ = sys.lseek(d, 2, .set) catch 0;
    n = sys.read(fd, buf[0..1]) catch 0;
    expect(n == 1 and buf[0] == '2', "dup shares the position with lseek", .{});
    if (d != fd) sys.close(d) catch {};
    // 串口、管道、坏 fd
    expect(sys.lseek(sys.stdout, 0, .set) == error.NotSeekable, "lseek the console", .{});
    const p = sys.pipe() catch .{ 0, 0 };
    expect(sys.lseek(p[0], 0, .set) == error.NotSeekable, "lseek a pipe", .{});
    sys.close(p[0]) catch {};
    sys.close(p[1]) catch {};
    expect(sys.lseek(99, 0, .set) == error.BadFd, "lseek a bad fd", .{});
    // 目录：lseek(0, set) 从头再列一遍
    const dir = mustOpen("/t_fs", .{});
    defer sys.close(dir) catch {};
    var ent: sys.abi.Dirent = undefined;
    var first: usize = 0;
    while (sys.readdir(dir, &ent) catch false) first += 1;
    expect((sys.lseek(dir, 0, .set) catch 99) == 0, "rewind a directory", .{});
    var second: usize = 0;
    while (sys.readdir(dir, &ent) catch false) second += 1;
    expect(first > 0 and first == second, "readdir after rewinding: {d} then {d}", .{ first, second });
    expect(sys.lseek(dir, 1, .set) == error.InvalidArgument, "lseek a directory elsewhere", .{});
    expect(sys.lseek(dir, 0, .end) == error.InvalidArgument, "lseek a directory from the end", .{});
}

/// O_APPEND：lseek 到开头再写也写在末尾；几个进程各自 open（不共用位置）同时追加，记录不丢、不互相覆盖。
fn testAppend() void {
    var buf: [64]u8 = undefined;
    {
        const fd = mustOpen("/t_fs/log", .{ .write = true, .create = true, .append = true });
        defer sys.close(fd) catch {};
        _ = writeAll(fd, "one ");
        _ = sys.lseek(fd, 0, .set) catch 0;
        _ = writeAll(fd, "two ");
        expect((sys.lseek(fd, 0, .cur) catch 0) == 8, "position after an append is the end", .{});
        // 别的 fd 把文件写长了，追加的照样接在后面
        const other = mustOpen("/t_fs/log", .{ .write = true });
        _ = sys.lseek(other, 0, .end) catch 0;
        _ = writeAll(other, "three ");
        sys.close(other) catch {};
        _ = writeAll(fd, "four");
        const n = readAll("/t_fs/log", &buf, 64);
        expect(std.mem.eql(u8, buf[0..n], "one two three four"), "appended: \"{s}\"", .{buf[0..n]});
        // 不能写的 fd 带着 append 也不能写
        const ro = mustOpen("/t_fs/log", .{ .append = true });
        expect(sys.write(ro, "x") == error.BadFd, "append on a read-only fd", .{});
        sys.close(ro) catch {};
    }
    // 4 个进程各自打开同一个文件追加：没有 append 的话各自从 0 开始写，会互相覆盖
    const procs = 4;
    const records = 25;
    const rec = 50;
    var pids: [procs]usize = undefined;
    for (&pids, 0..) |*pid, k| {
        pid.* = fork();
        if (pid.* != 0) continue;
        const fd = sys.open("/t_fs/appends", .{ .write = true, .create = true, .append = true }) catch sys.exit(1);
        var r: [rec]u8 = @splat(@intCast('a' + k));
        for (0..records) |j| {
            r[1] = @intCast(j);
            if (!writeAll(fd, &r)) sys.exit(2);
            if (j % 5 == 0) sys.yield();
        }
        sys.exit(0);
    }
    var ok = true;
    for (pids) |pid| ok = ok and waitStatus(pid) == 0;
    expect(ok, "appenders exited with 0", .{});
    const n = readAll("/t_fs/appends", &read_buf, read_buf.len);
    var next: [procs]u8 = @splat(0);
    var bad: usize = 0;
    var i: usize = 0;
    while (i + rec <= n) : (i += rec) {
        const r = read_buf[i..][0..rec];
        const k = r[0] -% 'a';
        if (k >= procs or r[1] != next[k] or !std.mem.allEqual(u8, r[2..], r[0])) {
            bad += 1;
            continue;
        }
        next[k] += 1;
    }
    expect(n == procs * records * rec and bad == 0, "appended records: {d} bytes, {d} bad", .{ n, bad });
}

/// rename：改名、换目录、换掉已有的文件；打开着的 fd、当前目录在改名之后照常；各种错误。
fn testRename() void {
    var buf: [64]u8 = undefined;
    sys.mkdir("/t_fs/r") catch {};
    sys.mkdir("/t_fs/r/sub") catch {};
    {
        const fd = mustOpen("/t_fs/r/a", .{ .write = true, .create = true });
        _ = writeAll(fd, "aaa");
        sys.close(fd) catch {};
    }
    expect(sys.rename("/t_fs/r/a", "/t_fs/r/b") != error.NotFound, "rename in the same directory", .{});
    expect(sys.open("/t_fs/r/a", .{}) == error.NotFound, "old name is gone", .{});
    expect(readAll("/t_fs/r/b", &buf, 64) == 3, "new name has the content", .{});
    // 打开着的 fd 改名之后照常读写
    const fd = mustOpen("/t_fs/r/b", .{ .read = true, .write = true });
    expect(sys.rename("/t_fs/r/b", "/t_fs/r/sub/c") != error.NotFound, "rename into another directory", .{});
    _ = sys.lseek(fd, 0, .end) catch 0;
    expect(writeAll(fd, "+fd"), "write through an fd after rename", .{});
    sys.close(fd) catch {};
    var n = readAll("/t_fs/r/sub/c", &buf, 64);
    expect(std.mem.eql(u8, buf[0..n], "aaa+fd"), "content after rename: \"{s}\"", .{buf[0..n]});
    // 当前目录的上一级被改名：当前目录照常，.. 走到新名字
    sys.chdir("/t_fs/r/sub") catch {};
    expect(sys.rename("/t_fs/r", "/t_fs/r2") != error.NotFound, "rename the parent of the cwd", .{});
    expect(readAll("c", &buf, 64) == 6, "relative path after the parent was renamed", .{});
    expect(readAll("../sub/c", &buf, 64) == 6, ".. after the parent was renamed", .{});
    sys.chdir("/") catch {};
    // 换掉已有的文件
    {
        const f = mustOpen("/t_fs/r2/old", .{ .write = true, .create = true });
        _ = writeAll(f, "old");
        sys.close(f) catch {};
    }
    expect(sys.rename("/t_fs/r2/sub/c", "/t_fs/r2/old") != error.NotFound, "rename over an existing file", .{});
    n = readAll("/t_fs/r2/old", &buf, 64);
    expect(std.mem.eql(u8, buf[0..n], "aaa+fd"), "replaced file: \"{s}\"", .{buf[0..n]});
    // 错误
    sys.mkdir("/t_fs/r2/d") catch {};
    expect(sys.rename("/t_fs/r2/nope", "/t_fs/r2/x") == error.NotFound, "rename a missing file", .{});
    expect(sys.rename("/t_fs/r2", "/t_fs/r2/sub/r2") == error.InvalidArgument, "rename a directory into itself", .{});
    expect(sys.rename("/t_fs/r2/old", "/t_fs/r2/d") == error.IsDir, "rename a file over a directory", .{});
    expect(sys.rename("/t_fs/r2/d", "/t_fs/r2/old") == error.NotDir, "rename a directory over a file", .{});
    expect(sys.rename("/t_fs/r2/sub", "/t_fs") == error.NotEmpty, "rename over a non-empty directory", .{});
    expect(sys.rename("/t_fs/r2/old", "/") == error.InvalidArgument, "rename to /", .{});
    expect(sys.rename(@as([*]const u8, @ptrFromInt(0x8020_0000))[0..4], "/x") == error.BadAddress, "rename from a kernel pointer", .{});
    const long: [sys.abi.max_path + 1]u8 = @splat('x');
    expect(sys.rename("/t_fs/r2/old", &long) == error.NameTooLong, "rename to a 257-byte path", .{});
    // sub 里的 c 已经挪走了，是空的：目录可以换掉它
    expect(if (sys.rename("/t_fs/r2/d", "/t_fs/r2/sub")) |_| true else |_| false, "rename a directory over an empty one", .{});
    expect(sys.open("/t_fs/r2/d", .{}) == error.NotFound, "old name of the directory is gone", .{});
}

fn nlinkOf(path: []const u8) u32 {
    const fd = sys.open(path, .{}) catch return 999;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return 999;
    return st.nlink;
}

fn inoOf(path: []const u8) u64 {
    const fd = sys.open(path, .{}) catch return 0;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return 0;
    return st.ino;
}

/// link：两个名字是同一个文件，链接数，删掉一个另一个照常，打开着的 fd，各种错误。
fn testLink() void {
    var buf: [64]u8 = undefined;
    sys.mkdir("/t_fs/l") catch {};
    {
        const fd = mustOpen("/t_fs/l/a", .{ .write = true, .create = true });
        _ = writeAll(fd, "first");
        sys.close(fd) catch {};
    }
    expect(nlinkOf("/t_fs/l/a") == 1, "nlink of a new file: {d}", .{nlinkOf("/t_fs/l/a")});
    expect(if (sys.link("/t_fs/l/a", "/t_fs/l/b")) |_| true else |_| false, "link", .{});
    expect(inoOf("/t_fs/l/a") == inoOf("/t_fs/l/b") and inoOf("/t_fs/l/a") != 0, "two names, one inode", .{});
    expect(nlinkOf("/t_fs/l/a") == 2 and nlinkOf("/t_fs/l/b") == 2, "nlink after link", .{});
    // 从一个名字写，另一个名字读到
    {
        const fd = mustOpen("/t_fs/l/b", .{ .write = true, .append = true });
        _ = writeAll(fd, "+b");
        sys.close(fd) catch {};
    }
    var n = readAll("/t_fs/l/a", &buf, 64);
    expect(std.mem.eql(u8, buf[0..n], "first+b"), "write through one name, read through the other: \"{s}\"", .{buf[0..n]});
    // 删掉一个名字：另一个照常，打开着的 fd 也照常
    const fd = mustOpen("/t_fs/l/b", .{});
    expect(if (sys.unlink("/t_fs/l/a")) |_| true else |_| false, "unlink one of two names", .{});
    expect(sys.open("/t_fs/l/a", .{}) == error.NotFound, "unlinked name is gone", .{});
    expect(nlinkOf("/t_fs/l/b") == 1, "nlink after unlinking one name", .{});
    n = sys.read(fd, &buf) catch 0;
    expect(n == 7, "read an fd after another name was unlinked: {d}", .{n});
    sys.close(fd) catch {};
    // 链接到别的目录、用相对路径；rename 到同一个文件的另一个名字什么都不做
    sys.mkdir("/t_fs/l/sub") catch {};
    sys.chdir("/t_fs/l") catch {};
    expect(if (sys.link("b", "sub/c")) |_| true else |_| false, "link into another directory, relative paths", .{});
    sys.chdir("/") catch {};
    expect(if (sys.rename("/t_fs/l/b", "/t_fs/l/sub/c")) |_| true else |_| false, "rename onto another link of the same file", .{});
    expect(nlinkOf("/t_fs/l/b") == 2 and nlinkOf("/t_fs/l/sub/c") == 2, "rename onto the same file changes nothing", .{});
    // 错误
    expect(sys.link("/t_fs/l/sub", "/t_fs/l/d") == error.PermissionDenied, "link a directory", .{});
    expect(sys.link("/t_fs/l/b", "/t_fs/l/sub/c") == error.Exists, "link onto an existing name", .{});
    expect(sys.link("/t_fs/l/nope", "/t_fs/l/x") == error.NotFound, "link a missing file", .{});
    expect(sys.link("/t_fs/l/b", "/t_fs/l/nope/x") == error.NotFound, "link into a missing directory", .{});
    expect(sys.link("/t_fs/l/b", "/t_fs/l/b/x") == error.NotDir, "link under a file", .{});
    expect(sys.link("/t_fs/l/b", "/t_fs/l/..") == error.InvalidArgument, "link to ..", .{});
    expect(sys.link(@as([*]const u8, @ptrFromInt(0x8020_0000))[0..4], "/x") == error.BadAddress, "link from a kernel pointer", .{});
    // 删掉最后一个名字：没了
    expect(if (sys.unlink("/t_fs/l/b")) |_| true else |_| false, "unlink", .{});
    expect(if (sys.unlink("/t_fs/l/sub/c")) |_| true else |_| false, "unlink the last name", .{});
    expect(sys.open("/t_fs/l/sub/c", .{}) == error.NotFound, "file is gone after the last unlink", .{});
}

/// 设备文件：mkfs 建的 /dev 下的三个，mknod 建新的；读写、fstat、lseek、readdir，不认识的设备号。
fn testDevices() void {
    var buf: [64]u8 = undefined;
    // /dev/null：读是结尾，写什么都收下（坏指针也不看）
    {
        const fd = mustOpen("/dev/null", .{ .read = true, .write = true });
        defer sys.close(fd) catch {};
        expect((sys.read(fd, &buf) catch 99) == 0, "read /dev/null", .{});
        expect((sys.write(fd, "discarded") catch 0) == 9, "write /dev/null", .{});
        const st = sys.fstat(fd) catch std.mem.zeroes(abi.Stat);
        expect(st.kind == .device and st.major == @backingInt(abi.Major.null) and st.size == 0 and st.nlink == 1 and st.ino != 0, "fstat /dev/null", .{});
        expect(sys.lseek(fd, 0, .set) == error.NotSeekable, "lseek /dev/null", .{});
        var ent: abi.Dirent = undefined;
        expect(sys.readdir(fd, &ent) == error.NotDir, "readdir /dev/null", .{});
    }
    // /dev/zero：读出来都是 0
    {
        const fd = mustOpen("/dev/zero", .{});
        defer sys.close(fd) catch {};
        @memset(&read_buf, 0xaa);
        const n = sys.read(fd, &read_buf) catch 0;
        expect(n == read_buf.len and std.mem.allEqual(u8, &read_buf, 0), "read {d} bytes of /dev/zero", .{n});
        expect(sys.write(fd, "x") == error.BadFd, "write a read-only /dev/zero", .{});
    }
    // /dev/console：写到串口上
    {
        const fd = mustOpen("/dev/console", .{ .write = true });
        defer sys.close(fd) catch {};
        expect((sys.write(fd, "t_fs: hello via /dev/console\n") catch 0) == 29, "write /dev/console", .{});
    }
    // mknod：自己建一个 null，可以链接、改名、删；不认识的设备号能建不能打开
    expect(if (sys.mknod("/t_fs/mynull", .null)) |_| true else |_| false, "mknod", .{});
    expect(sys.mknod("/t_fs/mynull", .zero) == error.Exists, "mknod an existing name", .{});
    {
        const fd = mustOpen("/t_fs/mynull", .{ .write = true });
        expect((sys.write(fd, "gone") catch 0) == 4, "write a device made by mknod", .{});
        sys.close(fd) catch {};
    }
    expect(if (sys.link("/t_fs/mynull", "/t_fs/null2")) |_| true else |_| false, "link a device", .{});
    expect(nlinkOf("/t_fs/null2") == 2, "nlink of a linked device", .{});
    expect(sys.mknod("/t_fs/weird", @fromBackingInt(999)) != error.InvalidArgument, "mknod an unknown device", .{});
    expect(sys.open("/t_fs/weird", .{}) == error.NoSuchDevice, "open an unknown device", .{});
    expect(sys.mknod("/t_fs/zero_major", @fromBackingInt(0)) == error.InvalidArgument, "mknod major 0", .{});
    expect(sys.mknod("/t_fs/nope/x", .null) == error.NotFound, "mknod in a missing directory", .{});
    // 设备文件不能当目录、程序
    expect(sys.chdir("/dev/null") == error.NotDir, "chdir to a device", .{});
    expect(sys.open("/dev/null/x", .{}) == error.NotDir, "path through a device", .{});
    expect(sys.exec("/dev/zero", &.{"zero"}) == error.BadElf, "exec a device", .{});
    for ([_][]const u8{ "/t_fs/mynull", "/t_fs/null2", "/t_fs/weird" }) |p| sys.unlink(p) catch expect(false, "unlink {s}", .{p});
}

fn succeeded(r: anytype) bool {
    return if (r) |_| true else |_| false;
}

/// 符号链接：symlink、readlink、lstat；open、chdir、exec 跟着走，unlink、rename、link 对链接自己；
/// open_create 穿过悬空的链接建目标；环是 SymlinkLoop；坏指针、截断。
fn testSymlinks() void {
    var buf: [64]u8 = undefined;
    var tbuf: [abi.max_path]u8 = undefined;
    sys.mkdir("/t_fs/s") catch {};
    sys.mkdir("/t_fs/s/dir") catch {};
    {
        const fd = mustOpen("/t_fs/s/dir/f", .{ .write = true, .create = true });
        _ = writeAll(fd, "via link");
        sys.close(fd) catch {};
    }
    expect(succeeded(sys.symlink("dir/f", "/t_fs/s/rel")), "symlink (relative target)", .{});
    expect(succeeded(sys.symlink("/t_fs/s/dir", "/t_fs/s/abs")), "symlink (absolute target, a directory)", .{});
    // open 跟着走；lstat 不跟；readlink 读出目标，放不下就截断
    var n = readAll("/t_fs/s/rel", &buf, 64);
    expect(std.mem.eql(u8, buf[0..n], "via link"), "read through a relative symlink: \"{s}\"", .{buf[0..n]});
    n = readAll("/t_fs/s/abs/f", &buf, 64);
    expect(n == 8, "read through a symlink to a directory: {d}", .{n});
    const lst = sys.lstat("/t_fs/s/rel") catch std.mem.zeroes(abi.Stat);
    expect(lst.kind == .symlink and lst.size == 5 and lst.nlink == 1 and lst.ino != inoOf("/t_fs/s/dir/f"), "lstat a symlink: kind {d} size {d}", .{ @backingInt(lst.kind), lst.size });
    expect(inoOf("/t_fs/s/rel") == inoOf("/t_fs/s/dir/f"), "open + fstat follows the symlink", .{});
    expect((sys.lstat("/t_fs/s/dir/f") catch std.mem.zeroes(abi.Stat)).kind == .file, "lstat a file", .{});
    const t = sys.readlink("/t_fs/s/abs", &tbuf) catch "";
    expect(std.mem.eql(u8, t, "/t_fs/s/dir"), "readlink: \"{s}\"", .{t});
    const short = sys.readlink("/t_fs/s/abs", tbuf[0..3]) catch "";
    expect(std.mem.eql(u8, short, "/t_"), "readlink into a short buffer truncates: \"{s}\"", .{short});
    expect(sys.readlink("/t_fs/s/dir/f", &tbuf) == error.InvalidArgument, "readlink a file", .{});
    expect(sys.readlink("/t_fs/s/nope", &tbuf) == error.NotFound, "readlink a missing name", .{});
    expect(sys.readlink("/t_fs/s/abs", @as([*]u8, @ptrFromInt(0x8020_0000))[0..8]) == error.BadAddress, "readlink into a kernel pointer", .{});
    expect(sys.lstat(@as([*]const u8, @ptrFromInt(0x8020_0000))[0..4]) == error.BadAddress, "lstat a kernel pointer", .{});
    // 目录里建东西、chdir 穿过链接
    {
        const fd = mustOpen("/t_fs/s/abs/g", .{ .write = true, .create = true });
        sys.close(fd) catch {};
    }
    expect(sys.open("/t_fs/s/dir/g", .{}) != error.NotFound, "create through a symlinked directory", .{});
    expect(succeeded(sys.chdir("/t_fs/s/abs")), "chdir through a symlink", .{});
    expect(inoOf(".") == inoOf("/t_fs/s/dir"), "cwd is the target directory", .{});
    expect(inoOf("..") == inoOf("/t_fs/s"), ".. after chdir through a symlink is the target's parent", .{});
    sys.chdir("/") catch {};
    // 悬空的链接：open 是 NotFound，带 create 时建它指向的文件
    expect(succeeded(sys.symlink("made", "/t_fs/s/dangling")), "symlink to a missing file", .{});
    expect(sys.open("/t_fs/s/dangling", .{}) == error.NotFound, "open a dangling symlink", .{});
    expect((sys.lstat("/t_fs/s/dangling") catch std.mem.zeroes(abi.Stat)).kind == .symlink, "lstat a dangling symlink", .{});
    {
        const fd = sys.open("/t_fs/s/dangling", .{ .write = true, .create = true }) catch 99;
        expect(fd != 99, "open_create through a dangling symlink", .{});
        if (fd != 99) {
            _ = writeAll(fd, "made");
            sys.close(fd) catch {};
        }
    }
    n = readAll("/t_fs/s/made", &buf, 64);
    expect(std.mem.eql(u8, buf[0..n], "made"), "open_create made the target: \"{s}\"", .{buf[0..n]});
    expect(sys.mkdir("/t_fs/s/dangling") == error.Exists, "mkdir over a symlink", .{});
    // 环
    expect(succeeded(sys.symlink("loop2", "/t_fs/s/loop1")), "symlink loop1", .{});
    expect(succeeded(sys.symlink("loop1", "/t_fs/s/loop2")), "symlink loop2", .{});
    expect(sys.open("/t_fs/s/loop1", .{}) == error.SymlinkLoop, "open a symlink loop", .{});
    expect(sys.open("/t_fs/s/loop1", .{ .write = true, .create = true }) == error.SymlinkLoop, "create through a symlink loop", .{});
    expect(sys.chdir("/t_fs/s/loop2/x") == error.SymlinkLoop, "chdir through a symlink loop", .{});
    expect(sys.exec("/t_fs/s/loop1", &.{"loop"}) == error.SymlinkLoop, "exec a symlink loop", .{});
    // exec 跟着走：进程名是链接的名字
    expect(succeeded(sys.symlink("/bin/echo", "/t_fs/s/say")), "symlink to a program", .{});
    {
        const pid = fork();
        if (pid == 0) {
            sys.exec("/t_fs/s/say", &.{ "say", "t_fs: exec through a symlink" }) catch {};
            sys.exit(99);
        }
        expect(waitStatus(pid) == 0, "exec through a symlink", .{});
    }
    // 错误：已有的名字、空的和太长的目标
    expect(sys.symlink("x", "/t_fs/s/rel") == error.Exists, "symlink onto an existing name", .{});
    expect(sys.symlink("", "/t_fs/s/empty") == error.NotFound, "symlink with an empty target", .{});
    const long: [abi.max_path + 1]u8 = @splat('a');
    expect(sys.symlink(&long, "/t_fs/s/long") == error.NameTooLong, "symlink with a too long target", .{});
    expect(succeeded(sys.symlink(long[0..abi.max_path], "/t_fs/s/long")), "symlink with the longest target", .{});
    const longest: []const u8 = sys.readlink("/t_fs/s/long", &tbuf) catch "";
    expect(longest.len == abi.max_path, "readlink the longest target: {d}", .{longest.len});
    expect(sys.symlink(@as([*]const u8, @ptrFromInt(0x8020_0000))[0..4], "/t_fs/s/k") == error.BadAddress, "symlink from a kernel pointer", .{});
    // rename、link、unlink 对的是链接自己
    expect(succeeded(sys.rename("/t_fs/s/rel", "/t_fs/s/rel2")), "rename a symlink", .{});
    expect(inoOf("/t_fs/s/rel2") == inoOf("/t_fs/s/dir/f"), "a renamed symlink still works", .{});
    expect(succeeded(sys.link("/t_fs/s/rel2", "/t_fs/s/hard")), "hard link to a symlink", .{});
    expect((sys.lstat("/t_fs/s/hard") catch std.mem.zeroes(abi.Stat)).nlink == 2, "nlink of a hard-linked symlink", .{});
    expect(nlinkOf("/t_fs/s/dir/f") == 1, "linking a symlink does not link its target", .{});
    for ([_][]const u8{ "/t_fs/s/rel2", "/t_fs/s/hard", "/t_fs/s/abs" }) |p| expect(succeeded(sys.unlink(p)), "unlink symlink {s}", .{p});
    expect(sys.open("/t_fs/s/dir/f", .{}) != error.NotFound, "unlinking a symlink keeps its target", .{});
    // 指向 / 的链接：removeTree 不能跟着它走进去
    expect(succeeded(sys.symlink("/", "/t_fs/s/root")), "symlink to /", .{});
}

/// getcwd：根目录、深处、经过符号链接（真实路径）、放不下、被删掉的当前目录。
fn testGetcwd() void {
    var buf: [abi.max_path]u8 = undefined;
    var cwd = sys.getcwd(&buf) catch "";
    expect(std.mem.eql(u8, cwd, "/"), "getcwd at /: \"{s}\"", .{cwd});
    sys.mkdir("/t_fs/g") catch {};
    sys.mkdir("/t_fs/g/deeper") catch {};
    sys.symlink("/t_fs/g/deeper", "/t_fs/g/l") catch {};
    sys.chdir("/t_fs/g/l") catch {};
    cwd = sys.getcwd(&buf) catch "";
    expect(std.mem.eql(u8, cwd, "/t_fs/g/deeper"), "getcwd after chdir through a symlink: \"{s}\"", .{cwd});
    expect(sys.getcwd(buf[0..5]) == error.BufferTooSmall, "getcwd into a short buffer", .{});
    expect(sys.getcwd(@as([*]u8, @ptrFromInt(0x8020_0000))[0..64]) == error.BadAddress, "getcwd into a kernel pointer", .{});
    // 当前目录被删掉了：NotFound，chdir 走开之后照常
    expect(succeeded(sys.unlink("/t_fs/g/deeper")), "unlink the current directory", .{});
    expect(sys.getcwd(&buf) == error.NotFound, "getcwd in a removed directory", .{});
    sys.chdir("/") catch {};
}

// ---- 掉电测试 ----

/// /churn.dat 的一条记录：前 8 字节是序号，其余是和序号有关的图案
const churn_rec = 300;
/// /churn/ 下面的文件：每个都是 slots 个里的一个，长度只能是 0（刚建、还没写）或者 churn_file
const slots = 3;
const churn_file = 5000;

fn churnRecord(buf: *[churn_rec]u8, seq: u64) void {
    fillPattern(buf, seq);
    std.mem.writeInt(u64, buf[0..8], seq, .little);
}

fn churnPath(buf: []u8, slot: u64) []const u8 {
    return std.fmt.bufPrint(buf, "/churn/s{d}", .{slot}) catch unreachable;
}

/// 一直写，直到被杀。
fn churn() noreturn {
    removeTree("/churn");
    sys.unlink("/churn.dat") catch {};
    sys.mkdir("/churn") catch {};
    const log = mustOpen("/churn.dat", .{ .write = true, .create = true });
    sys.print("churn: started\n", .{});
    var seq: u64 = 0;
    while (true) : (seq += 1) {
        var r: [churn_rec]u8 = undefined;
        churnRecord(&r, seq);
        if (!writeAll(log, &r)) {
            sys.print("FAIL: churn: append {d}\n", .{seq});
            sys.exit(1);
        }
        var nb: [32]u8 = undefined;
        const p = churnPath(&nb, seq % slots);
        switch (seq % 3) {
            0 => sys.unlink(p) catch {},
            else => {
                const fd = sys.open(p, .{ .write = true, .create = true, .truncate = true }) catch continue;
                fillPattern(big_buf[0..churn_file], seq % slots);
                _ = writeAll(fd, big_buf[0..churn_file]);
                sys.close(fd) catch {};
            },
        }
    }
}

/// 建 /scrub.dat：3 页，第 i 页是 "scrub test page i\n" 重复到填满。内容是独一无二的，
/// qemu_test.py 关机之后能在磁盘镜像里按内容找到第 1 页的数据块，改坏它，再启动看 scrub 能不能发现。
fn scrubFile() u8 {
    const fd = mustOpen("/scrub.dat", .{ .write = true, .create = true, .truncate = true });
    defer sys.close(fd) catch {};
    const page = big_buf[0..4096];
    for (0..3) |i| {
        var line_buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "scrub test page {d}\n", .{i}) catch unreachable;
        for (page, 0..) |*c, j| c.* = line[j % line.len];
        if (!writeAll(fd, page)) {
            sys.print("FAIL: scrubfile: write page {d}\n", .{i});
            return 1;
        }
    }
    sys.print("scrubfile: written\n", .{});
    return 0;
}

fn verify() u8 {
    const fd = mustOpen("/churn.dat", .{});
    const size = sizeOf(fd);
    sys.close(fd) catch {};
    expect(size % churn_rec == 0, "churn.dat size {d} is not a whole number of records", .{size});
    var records: u64 = 0;
    var bad: u64 = 0;
    {
        const f = mustOpen("/churn.dat", .{});
        defer sys.close(f) catch {};
        var r: [churn_rec]u8 = undefined;
        while (true) : (records += 1) {
            var got: usize = 0;
            while (got < churn_rec) {
                const m = sys.read(f, r[got..]) catch break;
                if (m == 0) break;
                got += m;
            }
            if (got == 0) break;
            var want: [churn_rec]u8 = undefined;
            churnRecord(&want, records);
            if (got != churn_rec or !std.mem.eql(u8, &r, &want)) bad += 1;
        }
    }
    expect(bad == 0, "churn.dat: {d} of {d} records wrong", .{ bad, records });
    for (0..slots) |slot| {
        var nb: [32]u8 = undefined;
        const p = churnPath(&nb, slot);
        const m = readAll(p, &read_buf, read_buf.len);
        if (sys.open(p, .{})) |f| sys.close(f) catch {} else |_| continue; // 删掉了
        expect(m == 0 or (m == churn_file and isPattern(read_buf[0..m], slot)), "{s}: {d} bytes", .{ p, m });
    }
    sys.print("churn: {d} records intact\n", .{records - bad});
    removeTree("/churn");
    sys.unlink("/churn.dat") catch {};
    sys.print("{d} checks, {d} failed\n", .{ checks, failures });
    return failures;
}
