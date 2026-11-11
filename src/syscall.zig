//! 系统调用。用户程序执行 ecall 陷入内核后，handleTrap 把它交给 dispatch。
//! 调用约定见 abi.zig。处理期间中断是关着的，系统调用都很短，不会长时间占着 CPU；
//! 要等待的（yield、sleep、read、write 管道、wait）在里面切回调度器，轮到这个进程时再从切走的地方返回。
//!
//! 文件相关的调用（read、write、close、dup、pipe）照 xv6 的 sysfile.c：fd 是当前进程 fd 表的下标，
//! 先在这里查出 File，再交给 file.zig。

const std = @import("std");
const abi = @import("abi.zig");
const uart = @import("uart.zig");
const timer = @import("timer.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const sbi = @import("sbi.zig");
const proc = @import("proc.zig");
const file = @import("file.zig");
const bio = @import("bio.zig");
const fsys = @import("fsys.zig");
const fs = @import("fs.zig");
const kstack = @import("kstack.zig");
const Fs = fsys.Fs;

comptime {
    // 符号链接的目标、getcwd 的结果都是路径
    std.debug.assert(fs.max_symlink == abi.max_path);
}
const TrapFrame = @import("trap.zig").TrapFrame;

/// 返回值会写回用户程序的 a0。
pub fn dispatch(frame: *TrapFrame) usize {
    const args = frame.regs[10..16]; // a0..a5
    const number: abi.Syscall = @fromBackingInt(frame.regs[17]); // a7
    return switch (number) {
        .exit => proc.exit(@truncate(args[0])),
        .write => write(args[0], args[1], args[2]),
        .getpid => proc.current().?.pid,
        .uptime => timer.uptimeMs(),
        .yield => yield(),
        .sleep => sleep(args[0]),
        .read => read(args[0], args[1], args[2]),
        .fork => fork(),
        .exec => exec(args[0], args[1], args[2], args[3]),
        .wait => wait(args[0], args[1], args[2]),
        .kill => kill(args[0]),
        .getppid => proc.parentPid(),
        .setfg => setfg(args[0]),
        .procinfo => procinfo(args[0], args[1]),
        .meminfo => meminfo(args[0]),
        .shutdown => shutdown(),
        .close => close(args[0]),
        .dup => dup(args[0]),
        .pipe => pipe(args[0]),
        .sbrk => sbrk(args[0]),
        .blockcount => fsys.raw_count,
        .readblock => readBlock(args[0], args[1]),
        .writeblock => writeBlock(args[0], args[1]),
        .open => open(args[0], args[1], args[2]),
        .mkdir => pathOp(args[0], args[1], .mkdir),
        .unlink => pathOp(args[0], args[1], .unlink),
        .chdir => pathOp(args[0], args[1], .chdir),
        .fstat => fstat(args[0], args[1]),
        .readdir => readdir(args[0], args[1]),
        .scrub => scrub(args[0]),
        .rename => rename(args[0], args[1], args[2], args[3]),
        .lseek => lseek(args[0], args[1], args[2]),
        .link => link(args[0], args[1], args[2], args[3]),
        .mknod => mknod(args[0], args[1], args[2]),
        .symlink => symlink(args[0], args[1], args[2], args[3]),
        .readlink => readlink(args[0], args[1], args[2], args[3]),
        .getcwd => getcwd(args[0], args[1]),
        .lstat => lstat(args[0], args[1], args[2]),
        _ => abi.fail(.nosys),
    };
}

fn space() *vm.Space {
    return &proc.current().?.space;
}

fn yield() usize {
    proc.yield();
    return 0;
}

/// 睡至少 ms 毫秒，按 tick 向上取整（乘法和加法都是饱和的，ms 再大也不溢出）。
/// 和 xv6 的 sys_sleep 一样：拿着 timer.lock 睡在 &timer.ticks 上，每个 tick 叫醒一次，醒来自己数够了没有。
/// 被 kill 了就提前返回，回到陷阱处理程序后结束。
fn sleep(ms: usize) usize {
    const n = (ms *| timer.tick_hz +| 999) / 1000;
    timer.lock.acquire();
    defer timer.lock.release();
    const start = timer.ticks;
    while (timer.ticks - start < n and !proc.isKilled()) proc.sleep(&timer.ticks, &timer.lock);
    return 0;
}

// ---- 错误码 ----

/// 内核里的错误（按名字）对应哪个错误码。errno 在编译期查这张表：系统调用处理函数里可能出现的每一个错误都要在这里，
/// 不在的编译不过，所以新加的错误不会悄悄变成 EIO（在这个内核里 EIO 的意思是“磁盘上的数据不对”）。
const errnos = .{
    // 文件系统（fs.Error，含 ctree.Error）
    .NotFound = .noent,
    .Exists = .exist,
    .NotDir = .notdir,
    .IsDir = .isdir,
    .NotEmpty = .notempty,
    .NameTooLong = .nametoolong,
    .InvalidName = .inval,
    .NoSpace = .nospc,
    .FileTooBig = .fbig,
    .IsDirLink = .perm,
    .TooManyLinks = .mlink,
    .SymlinkLoop = .loop,
    .NotSymlink = .inval,
    .TextBusy = .txtbsy,
    .NoDevice = .nodev,
    // 磁盘上的东西不对：校验和、结构（Corrupt），没有能用的超级块，块号超出磁盘（指针坏了），
    // 条目的数据太大（只能是树坏了：fs.zig 自己不会写这么大的条目）
    .Corrupt = .io,
    .NotFormatted = .io,
    .DiskTooLarge = .io,
    .OutOfRange = .io,
    .TooBig = .io,
    .IoError = .io,
    // 用户内存
    .BadAddress = .fault,
    // 打开的文件（file.Error）
    .NotReadable = .badf,
    .NotWritable = .badf,
    .BrokenPipe = .pipe,
    .NotSeekable = .spipe,
    .InvalidArgument = .inval,
    .TooManyFiles = .nfile,
    .NoSuchDevice = .nxio,
    // 进程、内存
    .OutOfMemory = .nomem,
    .TooManyProcesses = .again,
    .NoSuchProgram = .noent,
    .BadElf = .noexec,
    .NoChildren = .child,
    .NoSuchProcess = .srch,
    .PermissionDenied = .perm,
};

/// 错误换成错误码（见 errnos）。err 的错误集是什么都行，只要里面每个错误都在表里。
fn errno(err: anytype) abi.Errno {
    switch (err) {
        inline else => |e| {
            const name = @errorName(e);
            if (!@hasField(@TypeOf(errnos), name)) @compileError("syscall.errnos has no errno for error." ++ name);
            return @field(errnos, name);
        },
    }
}

/// 出错的系统调用的返回值。
fn failWith(err: anytype) usize {
    return abi.fail(errno(err));
}

/// fd 对应的打开的文件，fd 超出范围或者没有打开时返回 null。
fn fileOf(fd: usize) ?*file.File {
    if (fd >= abi.max_fds) return null;
    return proc.current().?.files[fd];
}

/// 当前进程最小的空闲 fd，指向 f（f 的引用已经算好了）。fd 表满了返回 null。
fn installFd(f: *file.File) ?usize {
    const files = &proc.current().?.files;
    for (files, 0..) |*slot, fd| {
        if (slot.* == null) {
            slot.* = f;
            return fd;
        }
    }
    return null;
}

/// 写 fd。中途遇到坏地址就停下，返回已经写出的字节数；一个字节都没写出才返回错误（见 file.write）。
/// 用户内存是拿着锁（串口的输出锁、管道的锁、文件系统的写锁）复制的，那时读不了盘：
/// 来源在程序文件的页里（比如字符串常量）、还没读进来的话，先读好（vm.prefault）。
fn write(fd: usize, ptr: usize, len: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    vm.prefault(space(), ptr, len);
    return file.write(f, space(), ptr, len) catch |err| failWith(err);
}

/// 读 fd。先检查整个目标范围可写：从串口的缓冲区取出来的字符放不回去，不能取出来之后才发现写不进去。
/// 检查时顺便把还没分配的页都分配好（按需分页），之后拿着锁写进去时不用再读盘。
/// 检查之前先按文件的种类把 len 截到这一次最多能读到的量（file.readLimit）：只分配真会写到的页。
fn read(fd: usize, ptr: usize, len: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    if (len == 0) return 0;
    const n = file.readLimit(f, len);
    vm.checkUser(space(), ptr, n, true) catch return abi.fail(.fault);
    return file.read(f, space(), ptr, n) catch |err| failWith(err);
}

fn close(fd: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    proc.current().?.files[fd] = null;
    file.close(f);
    return 0;
}

fn dup(fd: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    const new = installFd(file.dup(f)) orelse {
        file.close(f);
        return abi.fail(.mfile);
    };
    return new;
}

/// 创建管道，把读端、写端的 fd 写进 fds_ptr（两个 u32）。任何一步失败都把已经做了的撤销掉。
fn pipe(fds_ptr: usize) usize {
    // 先检查能写：fd 装进 fd 表以后再失败，就要再一个个撤销
    vm.checkUser(space(), fds_ptr, 2 * @sizeOf(u32), true) catch return abi.fail(.fault);
    const r, const w = file.openPipe() catch |err| return failWith(err);
    const files = &proc.current().?.files;
    const rfd = installFd(r) orelse {
        file.close(r);
        file.close(w);
        return abi.fail(.mfile);
    };
    const wfd = installFd(w) orelse {
        files[rfd] = null;
        file.close(r);
        file.close(w);
        return abi.fail(.mfile);
    };
    const fds = [2]u32{ @intCast(rfd), @intCast(wfd) };
    vm.copyToUser(space(), fds_ptr, std.mem.asBytes(&fds)) catch unreachable; // 上面检查过了
    return 0;
}

fn sbrk(increment: usize) usize {
    return proc.sbrk(@bitCast(increment)) catch |err| failWith(err);
}

/// 原始区域的第 blockno 块在磁盘上是第几块（fsys.raw_base 起）。块号超出原始区域是 InvalidArgument
/// （不是 OutOfRange：那是文件系统里的指针坏了，EIO）。通过了这里，bio 就不会再报 NoDevice、OutOfRange。
fn rawBlock(blockno: usize) error{ NoDevice, InvalidArgument }!u64 {
    if (fsys.raw_count == 0) return error.NoDevice;
    if (blockno >= fsys.raw_count) return error.InvalidArgument;
    return fsys.raw_base + blockno;
}

/// 读原始区域的一块到用户内存。先检查整个目标范围可写（顺便复制好写时复制的页），之后的 copyToUser 一定成功。
fn readBlock(blockno: usize, ptr: usize) usize {
    vm.checkUser(space(), ptr, abi.block_size, true) catch return abi.fail(.fault);
    const n = rawBlock(blockno) catch |err| return failWith(err);
    const b = bio.read(n) catch unreachable; // rawBlock 检查过了
    defer bio.release(b);
    vm.copyToUser(space(), ptr, b.data) catch unreachable;
    return 0;
}

/// 用户内存的一块写到磁盘。整块覆盖，不用先读；先检查来源可读，复制到一半失败的话缓冲区里会留下半新半旧的内容。
fn writeBlock(blockno: usize, ptr: usize) usize {
    vm.checkUser(space(), ptr, abi.block_size, false) catch return abi.fail(.fault);
    const n = rawBlock(blockno) catch |err| return failWith(err);
    const b = bio.get(n) catch unreachable; // rawBlock 检查过了
    defer bio.release(b);
    vm.copyFromUser(space(), b.data, ptr) catch unreachable;
    b.valid = true;
    bio.write(b);
    return 0;
}

// ---- 文件系统 ----

/// 把用户给的路径复制进 buf。
fn userPath(ptr: usize, len: usize, buf: *[abi.max_path]u8) error{ NameTooLong, BadAddress }![]const u8 {
    if (len > buf.len) return error.NameTooLong;
    try vm.copyFromUser(space(), buf[0..len], ptr);
    return buf[0..len];
}

/// 打开路径 path，返回 fd（见 abi.Syscall.open）。
fn open(path_ptr: usize, path_len: usize, flags: usize) usize {
    const access = flags & 3;
    if (access == 3 or flags & ~(3 | abi.open_create | abi.open_trunc | abi.open_append) != 0) return abi.fail(.inval);
    const readable = access != abi.open_write;
    const writable = access != abi.open_read;
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return failWith(err);
    const cwd = proc.current().?.cwd;
    // 可能要建文件、截断的才拿写锁，只是打开已有的文件在快照上找
    const modifies = flags & abi.open_create != 0 or (flags & abi.open_trunc != 0 and writable);
    const result = if (modifies) blk: {
        const root = fsys.writer() catch return abi.fail(.nodev);
        defer fsys.unlock();
        break :blk openPath(root, cwd, path, flags, writable);
    } else blk: {
        var r = fsys.reader() catch return abi.fail(.nodev);
        defer r.end();
        break :blk openPath(&r.fs, cwd, path, flags, writable);
    };
    const st = result catch |err| return failWith(err);
    // 设备文件：读写交给设备，文件系统里只有它的 inode
    const opened = if (st.kind == .device)
        file.openDevice(st.ino, @fromBackingInt(st.major), readable, writable)
    else
        file.openInode(st.ino, readable, writable, flags & abi.open_append != 0);
    const f = opened catch |err| return failWith(err);
    return installFd(f) orelse {
        file.close(f);
        return abi.fail(.mfile);
    };
}

/// 找到（或者建好、截断）要打开的 inode，返回它的 Stat。root 是读者的话 flags 里不会有要改文件系统的（见 open）。
/// 跟着符号链接走；没有并且带 open_create 时建文件，最后一段是悬空的符号链接的话建的是它指向的那个（createFollow）。
/// 正在运行的程序文件不能截断（TextBusy，见 fsys.holdText）。
fn openPath(root: *Fs, cwd: u64, path: []const u8, flags: usize, writable: bool) (fs.Error || error{TextBusy})!fs.Stat {
    const ino = root.resolve(cwd, path) catch |err| switch (err) {
        error.NotFound => if (flags & abi.open_create != 0) return root.stat(try root.run(Fs.createFollow, .{ cwd, path })) else return err,
        else => return err,
    };
    const st = try root.stat(ino);
    if (st.kind == .dir and writable) return error.IsDir;
    if (flags & abi.open_trunc != 0 and writable and st.size > 0) { // 设备、目录的 size 是 0
        try fsys.beginModify(ino);
        defer fsys.endModify();
        try root.run(Fs.truncate, .{ino});
    }
    return st;
}

const PathOp = enum { mkdir, unlink, chdir };

/// mkdir、unlink、chdir：只有一个路径参数。
fn pathOp(path_ptr: usize, path_len: usize, op: PathOp) usize {
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return failWith(err);
    const p = proc.current().?;
    switch (op) {
        .mkdir, .unlink => {
            const root = fsys.writer() catch return abi.fail(.nodev);
            defer fsys.unlock();
            if (op == .mkdir) {
                _ = root.run(Fs.create, .{ p.cwd, path, .dir }) catch |err| return failWith(err);
            } else {
                // 删掉正在运行的程序文件的最后一个名字：TextBusy
                const guarded = fsys.beginRemove(root, p.cwd, path) catch return abi.fail(.txtbsy);
                defer if (guarded) fsys.endModify();
                root.run(Fs.unlink, .{ p.cwd, path }) catch |err| return failWith(err);
            }
        },
        .chdir => {
            var r = fsys.reader() catch return abi.fail(.nodev);
            defer r.end();
            const ino = r.fs.resolve(p.cwd, path) catch |err| return failWith(err);
            const st = r.fs.stat(ino) catch |err| return failWith(err);
            if (st.kind != .dir) return abi.fail(.notdir);
            p.cwd = ino;
        },
    }
    return 0;
}

/// 两个路径都先复制进内核，再拿着文件系统的写锁一个事务改名（fs.Fs.rename）。
/// 新名字已经有了、是正在运行的程序文件的最后一个名字的话，它会被换掉（删掉）：TextBusy。
/// 两个名字是同一个 inode 时 rename 什么都不做，不用检查。
fn rename(old_ptr: usize, old_len: usize, new_ptr: usize, new_len: usize) usize {
    var old_buf: [abi.max_path]u8 = undefined;
    var new_buf: [abi.max_path]u8 = undefined;
    const old = userPath(old_ptr, old_len, &old_buf) catch |err| return failWith(err);
    const new = userPath(new_ptr, new_len, &new_buf) catch |err| return failWith(err);
    const cwd = proc.current().?.cwd;
    const root = fsys.writer() catch return abi.fail(.nodev);
    defer fsys.unlock();
    const same = if (root.resolveNoFollow(cwd, old)) |a| (if (root.resolveNoFollow(cwd, new)) |b| a == b else |_| false) else |_| false;
    const guarded = if (same) false else fsys.beginRemove(root, cwd, new) catch return abi.fail(.txtbsy);
    defer if (guarded) fsys.endModify();
    root.run(Fs.rename, .{ cwd, old, new }) catch |err| return failWith(err);
    return 0;
}

/// 硬链接：两个路径都先复制进内核，再拿着写锁一个事务做完（fs.Fs.link）。
fn link(old_ptr: usize, old_len: usize, new_ptr: usize, new_len: usize) usize {
    var old_buf: [abi.max_path]u8 = undefined;
    var new_buf: [abi.max_path]u8 = undefined;
    const old = userPath(old_ptr, old_len, &old_buf) catch |err| return failWith(err);
    const new = userPath(new_ptr, new_len, &new_buf) catch |err| return failWith(err);
    const root = fsys.writer() catch return abi.fail(.nodev);
    defer fsys.unlock();
    root.run(Fs.link, .{ proc.current().?.cwd, old, new }) catch |err| return failWith(err);
    return 0;
}

/// 建设备文件。设备号是 u16、不能是 0；不认识的设备号也能建（打开时才报 ENXIO，和 Unix 一样）。
fn mknod(path_ptr: usize, path_len: usize, major: usize) usize {
    if (major == 0 or major > std.math.maxInt(u16)) return abi.fail(.inval);
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return failWith(err);
    const root = fsys.writer() catch return abi.fail(.nodev);
    defer fsys.unlock();
    _ = root.run(Fs.mknod, .{ proc.current().?.cwd, path, @as(u16, @intCast(major)) }) catch |err| return failWith(err);
    return 0;
}

/// 建符号链接：两个路径都先复制进内核，再拿着写锁一个事务做完（fs.Fs.symlink）。target 原样存下，不检查它在不在。
fn symlink(target_ptr: usize, target_len: usize, path_ptr: usize, path_len: usize) usize {
    var target_buf: [abi.max_path]u8 = undefined;
    var path_buf: [abi.max_path]u8 = undefined;
    const target = userPath(target_ptr, target_len, &target_buf) catch |err| return failWith(err);
    const path = userPath(path_ptr, path_len, &path_buf) catch |err| return failWith(err);
    const root = fsys.writer() catch return abi.fail(.nodev);
    defer fsys.unlock();
    _ = root.run(Fs.symlink, .{ proc.current().?.cwd, target, path }) catch |err| return failWith(err);
    return 0;
}

/// 符号链接的目标写进用户内存，放不下就截断（和 Linux 一样），返回写了几个字节。在快照上读。
fn readlink(path_ptr: usize, path_len: usize, buf_ptr: usize, buf_len: usize) usize {
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return failWith(err);
    var r = fsys.reader() catch return abi.fail(.nodev);
    defer r.end();
    const ino = r.fs.resolveNoFollow(proc.current().?.cwd, path) catch |err| return failWith(err);
    var target: [fs.max_symlink]u8 = undefined;
    const t = r.fs.readlink(ino, &target) catch |err| return failWith(err);
    const n = @min(t.len, buf_len);
    vm.copyToUser(space(), buf_ptr, t[0..n]) catch return abi.fail(.fault);
    return n;
}

/// 当前目录的绝对路径（fs.Fs.dirPath，沿着 parent 往上找名字），在快照上找。
fn getcwd(buf_ptr: usize, buf_len: usize) usize {
    var r = fsys.reader() catch return abi.fail(.nodev);
    defer r.end();
    var out: [abi.max_path]u8 = undefined;
    const path = r.fs.dirPath(proc.current().?.cwd, &out) catch |err| return abi.fail(switch (err) {
        error.NameTooLong => .range, // 比 max_path 还长：用户的缓冲区不会比它大，当作放不下
        else => errno(err),
    });
    if (path.len > buf_len) return abi.fail(.range);
    vm.copyToUser(space(), buf_ptr, path) catch return abi.fail(.fault);
    return path.len;
}

/// path 自己（是符号链接的话不跟着走）的 Stat。
fn lstat(path_ptr: usize, path_len: usize, ptr: usize) usize {
    var buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &buf) catch |err| return failWith(err);
    var r = fsys.reader() catch return abi.fail(.nodev);
    defer r.end();
    const ino = r.fs.resolveNoFollow(proc.current().?.cwd, path) catch |err| return failWith(err);
    const s = r.fs.stat(ino) catch |err| return failWith(err);
    vm.copyToUser(space(), ptr, std.mem.asBytes(&abiStat(s))) catch return abi.fail(.fault);
    return 0;
}

fn abiStat(s: fs.Stat) abi.Stat {
    return .{ .ino = s.ino, .size = s.size, .kind = @fromBackingInt(@backingInt(s.kind)), .major = s.major, .nlink = s.nlink };
}

fn lseek(fd: usize, offset: usize, whence: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    return file.seek(f, @bitCast(offset), whence) catch |err| failWith(err);
}

fn fstat(fd: usize, ptr: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    var st: abi.Stat = .{ .ino = 0, .size = 0, .kind = .console };
    switch (f.kind) {
        .none => unreachable,
        .console => {},
        .pipe => st.kind = .pipe,
        .inode, .device => {
            var r = fsys.reader() catch return abi.fail(.nodev);
            defer r.end();
            const s = r.fs.stat(f.ino) catch |err| return failWith(err);
            st = abiStat(s);
        },
    }
    vm.copyToUser(space(), ptr, std.mem.asBytes(&st)) catch return abi.fail(.fault);
    return 0;
}

/// 目录 fd 的下一个目录项：读写位置 off 就是 fs.readdir 的 cookie。写进用户内存成功了才往后挪。
/// 拿着 pos_lock，共用这个 fd 的进程不会拿到同一项；在快照上找。
fn readdir(fd: usize, ptr: usize) usize {
    const f = fileOf(fd) orelse return abi.fail(.badf);
    if (f.kind != .inode) return abi.fail(.notdir);
    vm.prefault(space(), ptr, @sizeOf(abi.Dirent)); // 下面拿着 pos_lock 写进用户内存，那时读不了盘
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    var r = fsys.reader() catch return abi.fail(.nodev);
    defer r.end();
    var ent: abi.Dirent = undefined;
    const found = r.fs.readdir(f.ino, f.off, &ent.name) catch |err| return failWith(err);
    const d = found orelse return 0;
    ent.ino = d.ino;
    ent.kind = @fromBackingInt(@backingInt(d.kind));
    ent.name_len = @intCast(d.name_len);
    ent._pad = @splat(0);
    @memset(ent.name[d.name_len..], 0);
    vm.copyToUser(space(), ptr, std.mem.asBytes(&ent)) catch return abi.fail(.fault);
    f.off = d.next;
    return 1;
}

/// 检查整个文件系统（fs.Fs.check）。先作废缓冲区缓存：要核对的是磁盘上的内容，校验和只在读盘时核对。
/// 拿着文件系统的写锁：没有做到一半的修改，当前的树就是已提交的树。读者照常读（它们只会把块读进缓存）。
fn scrub(ptr: usize) usize {
    vm.checkUser(space(), ptr, @sizeOf(abi.ScrubInfo), true) catch return abi.fail(.fault);
    const root = fsys.writer() catch return abi.fail(.nodev);
    defer fsys.unlock();
    bio.invalidate();
    const st = root.check() catch |err| return failWith(err);
    const info: abi.ScrubInfo = .{
        .files = st.files,
        .devices = st.devices,
        .symlinks = st.symlinks,
        .dirs = st.dirs,
        .data_blocks = st.data_blocks,
        .nodes = st.tree.nodes,
        .items = st.tree.items,
        .height = st.tree.height,
        .free_blocks = root.vol.free_count,
        .blocks = root.vol.blocks,
        .generation = root.vol.generation,
    };
    vm.copyToUser(space(), ptr, std.mem.asBytes(&info)) catch unreachable; // 上面检查过了
    return 0;
}

fn fork() usize {
    return proc.fork() catch |err| failWith(err);
}

/// 把程序的路径和命令行参数都复制进内核（参数放在栈上的 buf 里），再交给 proc.exec：
/// 参数在旧的地址空间里，换掉地址空间之前就要取出来。
/// 成功时返回 argc：handleTrap 把返回值写进 a0，正好是新程序看到的 argc（a1 由 proc.exec 设好）。
fn exec(path_ptr: usize, path_len: usize, argv_ptr: usize, argc: usize) usize {
    var path_buf: [abi.max_path]u8 = undefined;
    const path = userPath(path_ptr, path_len, &path_buf) catch |err| return failWith(err);

    if (argc > abi.max_args) return abi.fail(.toobig);
    var argv: [abi.max_args]abi.Arg = undefined;
    vm.copyFromUser(space(), std.mem.sliceAsBytes(argv[0..argc]), argv_ptr) catch return abi.fail(.fault);
    var buf: [abi.max_arg_bytes]u8 = undefined;
    var args: [abi.max_args][]const u8 = undefined;
    var used: usize = 0;
    for (argv[0..argc], args[0..argc]) |a, *arg| {
        if (a.len > buf.len - used) return abi.fail(.toobig);
        const dst = buf[used..][0..a.len];
        vm.copyFromUser(space(), dst, a.ptr) catch return abi.fail(.fault);
        arg.* = dst;
        used += a.len;
    }

    proc.exec(path, args[0..argc]) catch |err| return failWith(err);
    return argc;
}

/// 等子进程结束，把结束状态写进 status_ptr（不为 0 时），回收它，返回它的 pid（见 proc.wait）。
/// 写状态失败时不回收，返回 -EFAULT：子进程还在，可以再 wait 一次。
fn wait(pid: usize, status_ptr: usize, options: usize) usize {
    if (options & ~abi.wait_nohang != 0) return abi.fail(.inval);
    const found = proc.wait(pid, options & abi.wait_nohang != 0, status_ptr) catch |err| return failWith(err);
    return found orelse 0;
}

fn kill(pid: usize) usize {
    proc.kill(pid, "kill()") catch |err| return failWith(err);
    return 0;
}

fn setfg(pid: usize) usize {
    proc.setForeground(pid) catch |err| return failWith(err);
    return 0;
}

/// 把进程表里每个在用的槽位写成一个 ProcInfo，最多写 n 个，返回进程总数（可能比 n 大）。
/// 每个槽位单独拿锁取一份（proc.info），不是同一瞬间的快照：别的 hart 上的进程可能正在 fork、结束。
fn procinfo(ptr: usize, n: usize) usize {
    var count: usize = 0;
    for (0..proc.max_procs) |i| {
        const info = proc.info(i) orelse continue;
        if (count < n) {
            const va = std.math.add(usize, ptr, count * @sizeOf(abi.ProcInfo)) catch return abi.fail(.fault);
            vm.copyToUser(space(), va, std.mem.asBytes(&info)) catch return abi.fail(.fault);
        }
        count += 1;
    }
    return count;
}

fn meminfo(ptr: usize) usize {
    const info: abi.MemInfo = .{ .free_pages = page.freePages(), .total_pages = page.total_pages, .page_size = page.size };
    vm.copyToUser(space(), ptr, std.mem.asBytes(&info)) catch return abi.fail(.fault);
    return 0;
}

/// 关机之前打印各种内核栈用到过的最深处（kstack.deepest），qemu_test.py 检查它们离栈底还有足够的余量。
fn shutdown() noreturn {
    const u = kstack.deepest();
    uart.print("[stack] deepest use: process {d} of {d}, boot {d} of {d}, trap {d} of {d} bytes\n", .{
        u.process, kstack.Process.stack_size, u.boot, kstack.Boot.stack_size, u.trap, kstack.Trap.stack_size,
    });
    sbi.shutdown();
}
