//! 用户程序的系统调用封装和格式化输出，用户程序通过 `@import("sys")` 使用。

const std = @import("std");
/// 和内核共用的系统调用约定（调用号、错误码、ProcInfo 等），用户程序用 sys.abi 访问。
pub const abi = @import("abi");

/// 做系统调用 n：按 abi.params 把 args（一个元组）里的参数放进 a0..a5，返回值原样返回（错误时是 -errno，用 check 换成错误）。
/// 参数的个数、种类在编译期和 abi.params 对一遍（内核的 dispatch 也按同一张表取参数），写错了编译不过：
///   int    整数、枚举、bool              fd     一个 Fd
///   bytes  一段内存（切片、数组的指针）    array  一个切片（长度是元素个数）
///   ptr    一个指针（结果写在那里）
pub fn call(comptime n: abi.Syscall, args: anytype) usize {
    const params = comptime abi.paramsOf(@tagName(n));
    if (args.len != params.len) @compileError(std.fmt.comptimePrint("sys.call(.{s}): {d} arguments, abi.params says {d}", .{ @tagName(n), args.len, params.len }));
    var regs: [6]usize = @splat(0);
    comptime var r = 0;
    inline for (params, 0..) |param, i| {
        const a = args[i];
        const A = @TypeOf(a);
        switch (param) {
            .int, .fd => regs[r] = switch (@typeInfo(A)) {
                .int, .comptime_int => if (@typeInfo(A) == .int and @typeInfo(A).int.signedness == .signed)
                    @bitCast(@as(isize, a))
                else
                    a,
                .@"enum" => @backingInt(a),
                .bool => @intFromBool(a),
                else => @compileError("sys.call(." ++ @tagName(n) ++ "): " ++ @typeName(A) ++ " is not an integer"),
            },
            .bytes => {
                const b: []const u8 = std.mem.sliceAsBytes(@as([]const std.meta.Elem(A), a));
                regs[r] = @intFromPtr(b.ptr);
                regs[r + 1] = b.len;
            },
            .array => {
                if (@typeInfo(A) != .pointer or @typeInfo(A).pointer.size != .slice) @compileError("sys.call(." ++ @tagName(n) ++ "): " ++ @typeName(A) ++ " is not a slice");
                regs[r] = @intFromPtr(a.ptr);
                regs[r + 1] = a.len;
            },
            .ptr => regs[r] = switch (@typeInfo(A)) {
                .pointer => @intFromPtr(a),
                .optional => if (a) |x| @intFromPtr(x) else 0,
                else => @compileError("sys.call(." ++ @tagName(n) ++ "): " ++ @typeName(A) ++ " is not a pointer"),
            },
        }
        r += comptime param.regs();
    }
    return raw(n, regs);
}

/// 原始的系统调用：六个寄存器原样交给内核，返回值原样返回。回归测试用它传坏参数，测边界情况。
pub fn raw(n: abi.Syscall, regs: [6]usize) usize {
    return asm volatile ("ecall"
        : [ret] "={a0}" (-> usize),
        : [n] "{a7}" (@backingInt(n)),
          [arg0] "{a0}" (regs[0]),
          [arg1] "{a1}" (regs[1]),
          [arg2] "{a2}" (regs[2]),
          [arg3] "{a3}" (regs[3]),
          [arg4] "{a4}" (regs[4]),
          [arg5] "{a5}" (regs[5]),
        : .{ .memory = true });
}

/// raw 的简写：前三个参数，其余是 0。
pub fn syscall(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize) usize {
    return raw(n, .{ arg0, arg1, arg2, 0, 0, 0 });
}

pub fn syscall4(n: abi.Syscall, arg0: usize, arg1: usize, arg2: usize, arg3: usize) usize {
    return raw(n, .{ arg0, arg1, arg2, arg3, 0, 0 });
}

/// 命令行参数，start.zig 在调用 main 之前设好。内核把它们放在栈顶，程序运行期间一直有效。
pub var argv: []const abi.Arg = &.{};

/// 第 i 个命令行参数，没有就是 null。按惯例第 0 个是程序名。
pub fn arg(i: usize) ?[]const u8 {
    return if (i < argv.len) argv[i].slice() else null;
}

pub fn exit(code: u8) noreturn {
    _ = call(.exit, .{code});
    unreachable;
}

/// 系统调用的错误：每个错误码一个名字（abi.Error，内核和用户程序共用那张表），再加上不认识的错误码（Unexpected：
/// 比这个程序新的内核加的）。所有的封装都返回它，出错信息直接打印 @errorName。
pub const Error = abi.Error || error{Unexpected};

/// 系统调用的返回值是错误码的话换成错误，否则原样返回。
pub fn check(ret: usize) Error!usize {
    const e = abi.errnoOf(ret) orelse return ret;
    return abi.errorOf(e) orelse error.Unexpected;
}

pub const Fd = usize;
pub const stdin: Fd = abi.stdin;
pub const stdout: Fd = abi.stdout;
pub const stderr: Fd = abi.stderr;

/// 写 fd，返回写出的字节数（串口、管道遇到坏地址时可能比 bytes.len 少；文件要么全写、要么返回错误）。
pub fn write(fd: Fd, bytes: []const u8) Error!usize {
    return check(call(.write, .{ fd, bytes }));
}

/// 把 bytes 全部写进 fd。
pub fn writeAll(fd: Fd, bytes: []const u8) Error!void {
    var done: usize = 0;
    while (done < bytes.len) done += try write(fd, bytes[done..]);
}

pub fn getpid() usize {
    return call(.getpid, .{});
}

/// 父进程的 pid，init 是 0。
pub fn getppid() usize {
    return call(.getppid, .{});
}

/// 开机以来的毫秒数。
pub fn uptime() u64 {
    return call(.uptime, .{});
}

/// 让出 CPU，让别的进程先运行。
pub fn yield() void {
    _ = call(.yield, .{});
}

/// 睡至少 ms 毫秒，期间不占 CPU。
pub fn sleep(ms: u64) void {
    _ = call(.sleep, .{ms});
}

/// 从 fd 读最多 buf.len 个字节，返回读到的字节数，0 表示读到了结尾。没有数据时阻塞（串口、管道）。
/// 从串口读时不回显；单独按 Ctrl-D 读到 0。
pub fn read(fd: Fd, buf: []u8) Error!usize {
    return check(call(.read, .{ fd, buf }));
}

// ---- 文件系统 ----

pub const OpenFlags = struct {
    read: bool = true,
    write: bool = false,
    /// 没有这个文件就建一个空的
    create: bool = false,
    /// 截成 0 字节（要能写）
    truncate: bool = false,
    /// 每次写都写在文件末尾
    append: bool = false,

    fn bits(f: OpenFlags) usize {
        var b: usize = if (f.read and f.write) abi.open_rdwr else if (f.write) abi.open_write else abi.open_read;
        if (f.create) b |= abi.open_create;
        if (f.truncate) b |= abi.open_trunc;
        if (f.append) b |= abi.open_append;
        return b;
    }
};

/// 打开文件或目录，返回 fd。
pub fn open(path: []const u8, flags: OpenFlags) Error!Fd {
    return check(call(.open, .{ path, flags.bits() }));
}

/// 建一个空目录。
pub fn mkdir(path: []const u8) Error!void {
    _ = try check(call(.mkdir, .{path}));
}

/// 删掉一个文件或空目录。
pub fn unlink(path: []const u8) Error!void {
    _ = try check(call(.unlink, .{path}));
}

/// 换当前目录。
pub fn chdir(path: []const u8) Error!void {
    _ = try check(call(.chdir, .{path}));
}

pub fn fstat(fd: Fd) Error!abi.Stat {
    var st: abi.Stat = undefined;
    _ = try check(call(.fstat, .{ fd, &st }));
    return st;
}

/// 把 old 改名成 new（见 abi.Syscall.rename）。
pub fn rename(old: []const u8, new: []const u8) Error!void {
    _ = try check(call(.rename, .{ old, new }));
}

/// 硬链接：给文件 old 再起一个名字 new（见 abi.Syscall.link）。
pub fn link(old: []const u8, new: []const u8) Error!void {
    _ = try check(call(.link, .{ old, new }));
}

/// 建一个设备文件（见 abi.Syscall.mknod）。
pub fn mknod(path: []const u8, major: abi.Major) Error!void {
    _ = try check(call(.mknod, .{ path, major }));
}

/// 建符号链接 path，指向 target（见 abi.Syscall.symlink）。
pub fn symlink(target: []const u8, path: []const u8) Error!void {
    _ = try check(call(.symlink, .{ target, path }));
}

/// 符号链接 path 的目标，写进 buf，返回写了的那一段（放不下就截断）。不是符号链接是 InvalidArgument。
pub fn readlink(path: []const u8, buf: []u8) Error![]const u8 {
    const n = try check(call(.readlink, .{ path, buf }));
    return buf[0..n];
}

/// 当前目录的绝对路径，写进 buf，返回那一段。
pub fn getcwd(buf: []u8) Error![]const u8 {
    const n = try check(call(.getcwd, .{buf}));
    return buf[0..n];
}

/// path 自己的 Stat：是符号链接的话不跟着走（open + fstat 是跟着走的）。
pub fn lstat(path: []const u8) Error!abi.Stat {
    var st: abi.Stat = undefined;
    _ = try check(call(.lstat, .{ path, &st }));
    return st;
}

pub const Whence = enum(usize) { set = abi.seek_set, cur = abi.seek_cur, end = abi.seek_end };

/// 挪 fd 的读写位置，返回新的位置（见 abi.Syscall.lseek）。
pub fn lseek(fd: Fd, offset: i64, whence: Whence) Error!u64 {
    return check(call(.lseek, .{ fd, offset, whence }));
}

/// 检查整个文件系统（见 abi.Syscall.scrub）。坏了是 IoError。
pub fn scrub() Error!abi.ScrubInfo {
    var info: abi.ScrubInfo = undefined;
    _ = try check(call(.scrub, .{&info}));
    return info;
}

/// 目录 fd 的下一个目录项写进 ent，返回 true；列完了返回 false。
pub fn readdir(fd: Fd, ent: *abi.Dirent) Error!bool {
    return try check(call(.readdir, .{ fd, ent })) == 1;
}

pub fn close(fd: Fd) Error!void {
    _ = try check(call(.close, .{fd}));
}

/// 返回编号最小的空闲 fd，它和 fd 指向同一个文件。
pub fn dup(fd: Fd) Error!Fd {
    return check(call(.dup, .{fd}));
}

/// 创建管道，返回 { 读端, 写端 }。
pub fn pipe() Error![2]Fd {
    var fds: [2]u32 = undefined;
    _ = try check(call(.pipe, .{&fds}));
    return .{ fds[0], fds[1] };
}

/// 把堆的末尾移动 increment 字节，返回原来的末尾。sbrk(0) 只查询。
/// 新增的内存清零；increment 为正时，返回值就是新内存的起点。
pub fn sbrk(increment: isize) Error!usize {
    return check(call(.sbrk, .{increment}));
}

/// 磁盘块的大小。
pub const block_size = abi.block_size;

/// 磁盘有多少块，没有磁盘时是 0。
pub fn blockCount() u64 {
    return call(.blockcount, .{});
}

/// 把磁盘的第 n 块读进 buf。
pub fn readBlock(n: u64, buf: *[block_size]u8) Error!void {
    _ = try check(call(.readblock, .{ n, buf }));
}

/// 把 buf 写到磁盘的第 n 块，写完才返回。
pub fn writeBlock(n: u64, buf: *const [block_size]u8) Error!void {
    _ = try check(call(.writeblock, .{ n, buf }));
}

/// 复制当前进程。父进程得到子进程的 pid，子进程得到 0。
pub fn fork() Error!usize {
    return check(call(.fork, .{}));
}

/// 换成文件系统里的程序 name 运行（name 里没有 '/' 时在 /bin 里找），命令行参数是 args（按惯例第一个是程序名）。
/// 成功时不返回。
/// 最多 abi.max_args 个参数，加起来最多 abi.max_arg_bytes 字节。
pub fn exec(name: []const u8, args: []const []const u8) Error!noreturn {
    if (args.len > abi.max_args) return error.ArgsTooLong;
    var a: [abi.max_args]abi.Arg = undefined;
    for (args, a[0..args.len]) |s, *x| x.* = .of(s);
    return execRaw(name, a[0..args.len]);
}

/// 和 exec 一样，参数已经是 Arg 数组（比如转交自己的 argv）。
pub fn execRaw(name: []const u8, args: []const abi.Arg) Error!noreturn {
    const ret = call(.exec, .{ name, args });
    _ = try check(ret);
    unreachable; // exec 成功时不返回
}

pub const WaitResult = struct {
    pid: usize,
    /// 正常退出时是退出码（0..255），被杀时是 abi.killed_status
    status: u32,
};

/// 等子进程结束并回收它。pid 为 null 时等任意一个子进程。
/// nohang 为 true 时不阻塞：有子进程但都还没结束就返回 null。
pub fn wait(pid: ?usize, nohang: bool) Error!?WaitResult {
    var status: u32 = 0;
    const ret = call(.wait, .{ pid orelse abi.wait_any, &status, if (nohang) abi.wait_nohang else 0 });
    _ = try check(ret);
    if (ret == 0) return null;
    return .{ .pid = ret, .status = status };
}

/// 结束进程 pid。只做标记，它回到 U 模式之前才真正结束。
pub fn kill(pid: usize) Error!void {
    _ = try check(call(.kill, .{pid}));
}

/// 设置前台进程（按 Ctrl-C 时内核结束它），null 表示没有。
pub fn setfg(pid: ?usize) Error!void {
    _ = try check(call(.setfg, .{pid orelse 0}));
}

/// 把进程信息写进 buf，返回进程总数（可能比 buf.len 大，多出来的没写）。
pub fn procinfo(buf: []abi.ProcInfo) usize {
    return call(.procinfo, .{buf});
}

pub fn meminfo() abi.MemInfo {
    var info: abi.MemInfo = undefined;
    _ = call(.meminfo, .{&info});
    return info;
}

/// 内核的计数器和栈的高水位（见 abi.KStat）。
pub fn kstat() abi.KStat {
    var info: abi.KStat = undefined;
    _ = call(.kstat, .{&info});
    return info;
}

/// 把文件系统现在的样子保存成一个快照，返回它的编号（之后在 /.snap/编号/ 下只读地看得到）。
pub fn snapshot() Error!u64 {
    return check(call(.snapshot, .{}));
}

/// 保存的快照的编号写进 ids，返回一共有几个（可能比 ids.len 多）。
pub fn snaplist(ids: []u64) Error!usize {
    return check(call(.snaplist, .{ids}));
}

pub fn snapdel(id: u64) Error!void {
    _ = try check(call(.snapdel, .{id}));
}

pub fn shutdown() noreturn {
    _ = call(.shutdown, .{});
    unreachable;
}

// 和内核的 uart.zig 一样，接入 std.Io.Writer，用标准库做格式化，输出走 write 系统调用。
// 一次 print 的输出先攒在缓冲区里，最后用一次 write 写出去：write 在内核里是关着中断整段输出的，
// 所以一行不会被别的进程的输出从中间打断（超过缓冲区大小的部分会多写几次）。
// 写到哪个 fd 由包着 Writer 的 FdWriter 决定。
const FdWriter = struct {
    fd: Fd,
    writer: std.Io.Writer,

    fn init(fd: Fd, buffer: []u8) FdWriter {
        return .{ .fd = fd, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    /// 先写出缓冲区里攒着的内容，再写 data（缓冲区放不下时才会走到这里），返回写出的 data 字节数。
    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("writer", w);
        try self.put(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.put(bytes);
            n += bytes.len;
        }
        // 最后一段要重复 splat 次（用于填充对齐等）
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.put(pattern);
        return n + pattern.len * splat;
    }

    fn put(self: *FdWriter, bytes: []const u8) std.Io.Writer.Error!void {
        writeAll(self.fd, bytes) catch return error.WriteFailed;
    }

    /// 输出失败（比如 fd 是读端已经关了的管道）时悄悄丢掉没写出去的部分。
    fn print(self: *FdWriter, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch {};
        self.writer.flush() catch {};
        self.writer.end = 0;
    }
};

var stdout_buffer: [256]u8 = undefined;
var stdout_writer: FdWriter = .init(stdout, &stdout_buffer);

/// 格式化输出到标准输出（fd 1）。
pub fn print(comptime fmt: []const u8, args: anytype) void {
    stdout_writer.print(fmt, args);
}

/// 格式化输出到 fd。
pub fn fprint(fd: Fd, comptime fmt: []const u8, args: anytype) void {
    if (fd == stdout) return print(fmt, args);
    var buffer: [256]u8 = undefined;
    var w: FdWriter = .init(fd, &buffer);
    w.print(fmt, args);
}

// ---- 按行读 ----

/// 带缓冲区地按行读一个 fd（head、tail、grep、xargs 用）。
pub const LineReader = struct {
    fd: Fd,
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,

    pub fn init(fd: Fd, buf: []u8) LineReader {
        return .{ .fd = fd, .buf = buf };
    }

    /// 下一行，不含结尾的 '\n'（最后一行没有 '\n' 也算一行），读到结尾返回 null。
    /// 返回的切片指向缓冲区，下一次调用之后就失效了。比缓冲区还长的行截成几段返回，每段都当成一行。
    pub fn next(r: *LineReader) Error!?[]const u8 {
        const line = try r.nextRaw() orelse return null;
        return if (line.len > 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
    }

    /// 和 next 一样，但是带着结尾的 '\n'（有的话）：原样输出一行时用它，一次 write 写完整行，
    /// 不会和别的进程（比如内核打印的 [proc] 那一行）的输出交错在一行中间。
    pub fn nextRaw(r: *LineReader) Error!?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, r.buf[r.start..r.end], '\n')) |i| {
                const line = r.buf[r.start..][0 .. i + 1];
                r.start += i + 1;
                return line;
            }
            if (r.eof or r.end - r.start == r.buf.len) {
                // 结尾的半行，或者一整个缓冲区都没有换行
                if (r.start == r.end) return null;
                const line = r.buf[r.start..r.end];
                r.start = r.end;
                return line;
            }
            // 把剩下的半行挪到开头，再读一些
            std.mem.copyForwards(u8, r.buf, r.buf[r.start..r.end]);
            r.end -= r.start;
            r.start = 0;
            const n = try read(r.fd, r.buf[r.end..]);
            if (n == 0) r.eof = true;
            r.end += n;
        }
    }
};
