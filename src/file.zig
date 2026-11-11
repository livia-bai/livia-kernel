//! 打开的文件，照 xv6 的 file.c 写。进程用 fd（Process.files 的下标）指代一个 File，
//! File 是串口（console）、管道的一端，或者文件系统里的一个文件、目录（inode，见 fsys.zig）。
//!
//! - 文件表 table 是全局的，File 带引用计数：fork 复制 fd 表、dup 复制 fd，都只是让两个 fd
//!   指向同一个 File（ref 加 1），所以父子进程共用读写位置、共用管道的一端。
//!   最后一个引用关掉时（close、进程结束）才真正关掉：管道的一端关了，另一端会读到结尾或写失败。
//! - init 打开串口作为 0、1、2 号 fd，其他进程都从它那里 fork 继承；pipe 系统调用创建管道；
//!   open 系统调用打开文件系统里的文件、目录。
//!
//! 锁都在每个 File 里，没有整张表的锁：
//! - File.lock（自旋锁）保护这个槽位的 ref：分配槽位（逐个槽位拿锁看 ref 是不是 0）、dup、close。
//!   几个 hart 同时打开、关闭不同的文件不用排队。
//! - 打开的是什么（open：可读、可写，和 Target：串口、管道、inode、设备，各带各的字段）在分配出来、交给 fd 之前
//!   一次填好，之后只有文件的读写位置会变，读写时不用拿 File.lock；管道的状态由管道自己的锁保护（pipe.zig）。
//! - File.pos_lock（睡眠锁）保护文件系统里的文件的读写位置 off：读写、lseek、readdir 的整个过程拿着它，
//!   fork、dup 共用同一个 File 的进程同时读写时排队，off 不会乱。拿它在文件系统的锁之前（见 fsys.zig）。

const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page = @import("page.zig");
const proc = @import("proc.zig");
const pipe = @import("pipe.zig");
const fsys = @import("fsys.zig");
const fs = @import("fs.zig");
const abi = @import("abi.zig");
const Spinlock = @import("spinlock.zig").Spinlock;
const Sleeplock = @import("sleeplock.zig").Sleeplock;

/// 整个系统最多同时有多少个打开的文件。每个进程最多 abi.max_fds 个 fd，但它们大多指向同一个串口。
pub const max_files = 128;

pub const File = struct {
    /// 保护 ref
    lock: Spinlock = .init("file", .leaf),
    /// 引用数：有多少个 fd 指向它。为 0 表示这个槽位空着
    ref: u32 = 0,
    /// 打开的是什么。ref 不为 0 时才有意义：分配槽位时（alloc）一次填好，之后只有文件的读写位置会变
    open: Open = undefined,
    /// 保护文件系统里的文件的读写位置（Target.inode.off），见文件开头
    pos_lock: Sleeplock = .init("file pos", .file_pos),
};

pub const Open = struct {
    readable: bool,
    writable: bool,
    target: Target,
};

/// 打开的东西，每种只带它自己用得着的字段：对串口读 pipe、对管道读 ino 这类错误编译器就能拦住
pub const Target = union(enum) {
    /// init 打开的串口（不在文件系统里）
    console,
    /// 管道的一端（读端还是写端看 readable、writable）
    pipe: *pipe.Pipe,
    /// 文件系统里的文件、目录
    inode: Inode,
    /// 文件系统里的设备文件：读写交给 dev 指的设备
    device: struct { ino: u64, dev: Device },
};

pub const Inode = struct {
    ino: u64,
    /// 下一次读写的位置（pos_lock）。目录的是 readdir 的 cookie
    off: u64 = 0,
    /// open_append：每次写之前先把 off 挪到文件末尾
    append: bool = false,
};

/// 内核认识的设备（abi.Major 里有名字的那几个）。openDevice 把设备号换成它，之后读写时不会碰到不认识的设备号
pub const Device = enum { console, null, zero };

var table: [max_files]File = @splat(.{});

pub const Error = error{ NotReadable, NotWritable, BadAddress, BrokenPipe, NotSeekable, InvalidArgument, TextBusy } || fs.Error;

/// 分配一个 File（ref = 1），填上 open。一次只拿一个槽位的锁。
/// 只改 ref 和 open，不写成 f.* = .{...}：那会连锁一起覆盖掉，而别的 hart 可能正拿着这个槽位的锁在看它的 ref。
fn alloc(open: Open) error{TooManyFiles}!*File {
    for (&table) |*f| {
        f.lock.acquire();
        defer f.lock.release();
        if (f.ref == 0) {
            f.ref = 1;
            f.open = open;
            return f;
        }
    }
    return error.TooManyFiles;
}

/// 打开串口，可读可写。
pub fn openConsole() error{TooManyFiles}!*File {
    return alloc(.{ .readable = true, .writable = true, .target = .console });
}

/// 创建一个管道，返回读端和写端。任何一步失败都把已经做了的撤销掉。
pub fn openPipe() error{ TooManyFiles, OutOfMemory }![2]*File {
    const p = try pipe.create();
    const r = alloc(.{ .readable = true, .writable = false, .target = .{ .pipe = p } }) catch |err| {
        pipe.close(p, false);
        pipe.close(p, true);
        return err;
    };
    const w = alloc(.{ .readable = false, .writable = true, .target = .{ .pipe = p } }) catch |err| {
        close(r);
        pipe.close(p, true);
        return err;
    };
    return .{ r, w };
}

/// 打开文件系统里的 inode ino，读写位置从 0 开始。
pub fn openInode(ino: u64, readable: bool, writable: bool, append: bool) error{TooManyFiles}!*File {
    return alloc(.{ .readable = readable, .writable = writable, .target = .{ .inode = .{ .ino = ino, .append = append } } });
}

/// 打开文件系统里的设备文件 ino（设备号 major）。内核没有这个设备是 NoSuchDevice。
pub fn openDevice(ino: u64, major: abi.Major, readable: bool, writable: bool) error{ TooManyFiles, NoSuchDevice }!*File {
    const dev: Device = switch (major) {
        .console => .console,
        .null => .null,
        .zero => .zero,
        _ => return error.NoSuchDevice,
    };
    return alloc(.{ .readable = readable, .writable = writable, .target = .{ .device = .{ .ino = ino, .dev = dev } } });
}

/// 多一个引用（dup、fork），返回同一个 File。
pub fn dup(f: *File) *File {
    f.lock.acquire();
    defer f.lock.release();
    std.debug.assert(f.ref > 0);
    f.ref += 1;
    return f;
}

/// 少一个引用。是最后一个的话腾出槽位，再关掉底下的东西（管道的一端）。
pub fn close(f: *File) void {
    f.lock.acquire();
    std.debug.assert(f.ref > 0);
    f.ref -= 1;
    if (f.ref > 0) {
        f.lock.release();
        return;
    }
    const open = f.open;
    f.open = undefined;
    f.lock.release();
    // 放开 File 的锁之后再关管道：管道的锁和 File 的锁不嵌套，就不用规定加锁的顺序
    switch (open.target) {
        .pipe => |p| pipe.close(p, open.writable),
        else => {},
    }
}

/// 打开的文件在文件系统里的 inode 号（fstat 用），串口、管道没有。
pub fn inodeOf(f: *const File) ?u64 {
    return switch (f.open.target) {
        .console, .pipe => null,
        .inode => |i| i.ino,
        .device => |d| d.ino,
    };
}

/// 一次 read 最多能从 f 读到多少字节：串口、管道一次最多给出缓冲区里有的，/dev/null 什么都没有。
/// read 系统调用先按它截短 len 再检查、分配目标范围：程序给一个很大的缓冲区读串口、管道时，
/// 实际只会写进开头的一小段，不该为整个缓冲区提前分配好所有的页（按需分页省下的内存就白省了）。
pub fn readLimit(f: *const File, len: usize) usize {
    return switch (f.open.target) {
        .console => @min(len, uart.rx_capacity),
        .pipe => @min(len, pipe.size),
        .inode => len,
        .device => |d| switch (d.dev) {
            .console => @min(len, uart.rx_capacity),
            .null => 0,
            .zero => len,
        },
    };
}

/// 从 f 读最多 dst.len 个字节到用户内存 dst（调用方 pin 好的，见 syscall.read），返回读到的字节数，0 表示读到了结尾。
pub fn read(f: *File, dst: vm.PinnedDst) Error!usize {
    if (!f.open.readable) return error.NotReadable;
    return switch (f.open.target) {
        .console => consoleRead(dst),
        .pipe => |p| pipe.read(p, dst),
        .inode => |*i| inodeRead(f, i, dst),
        .device => |d| switch (d.dev) {
            .console => consoleRead(dst),
            .null => 0,
            .zero => zeroRead(dst),
        },
    };
}

/// 把用户要写的 len 个字节写进 f，返回写出的字节数。src 是调用方 pin 好的开头那一段（vm.pinSrcPrefix），
/// 比 len 短说明后面是坏地址：串口、管道写出 src 这一段、返回写了多少，一个字节都没有才是 BadAddress；
/// 文件的一次写是一个事务，不全就是 BadAddress、什么都不写。
pub fn write(f: *File, src: vm.PinnedSrc, len: usize) Error!usize {
    if (!f.open.writable) return error.NotWritable;
    switch (f.open.target) {
        // 写什么都丢掉，也不看用户内存（和 Linux 的 /dev/null 一样）
        .device => |d| if (d.dev != .console) return len,
        else => {},
    }
    if (src.len == 0 and len > 0) return error.BadAddress;
    return switch (f.open.target) {
        .console, .device => consoleWrite(src),
        .pipe => |p| pipe.write(p, src),
        .inode => |*i| if (src.len < len) error.BadAddress else inodeWrite(f, i, src),
    };
}

const zero_page: [page.size]u8 = @splat(0);

/// /dev/zero：把 dst 整个填成 0。
fn zeroRead(dst: vm.PinnedDst) Error!usize {
    var done: usize = 0;
    while (done < dst.len) {
        const n = @min(zero_page.len, dst.len - done);
        dst.copyOut(done, zero_page[0..n]);
        done += n;
    }
    return dst.len;
}

/// 用户内存先分块复制到内核缓冲区再输出。整个 write 拿着串口的输出锁，所以一次 write 的内容不会和别的 hart 的输出交错；
/// 拿着锁不能缺页，src 是 pin 好的。
fn consoleWrite(src: vm.PinnedSrc) Error!usize {
    const out = uart.lockOutput();
    defer out.unlock();
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < src.len) {
        const chunk = buf[0..@min(buf.len, src.len - done)];
        src.copyIn(done, chunk);
        out.write(chunk);
        done += chunk.len;
    }
    return done;
}

/// 从文件当前的位置读，位置往后挪读到的字节数。读目录是 IsDir（列目录用 readdir 系统调用）。
/// 在快照上读，不挡着别人读写文件系统。
fn inodeRead(f: *File, i: *Inode, dst: vm.PinnedDst) Error!usize {
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    var r = try fsys.reader();
    defer r.end();
    const n = try r.fs.read(i.ino, i.off, dst.len, dst);
    i.off += n;
    return n;
}

/// 写到文件当前的位置（open_append 的是文件末尾），位置挪到写完的地方。整个写是一个事务：
/// 磁盘满了，什么都不写，位置也不动（用户内存 pin 好了，中途不会读不出来）。
/// 查文件末尾和写拿着同一次文件系统的写锁，几个进程同时往末尾追加不会写到同一个位置上。
fn inodeWrite(f: *File, i: *Inode, src: vm.PinnedSrc) Error!usize {
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    const root = try fsys.writer();
    defer fsys.unlock();
    // 正在运行的程序文件不能改（按需分页还要从它读页，见 fsys.holdText）
    try fsys.beginModify(i.ino);
    defer fsys.endModify();
    const off = if (i.append) (try root.stat(i.ino)).size else i.off;
    const n = try root.run(fsys.Fs.write, .{ i.ino, off, src.len, src });
    i.off = off + n;
    return n;
}

/// 挪文件的读写位置（lseek）：whence 是 abi.seek_*，offset 是有符号的。返回新的位置。
/// 串口、管道没有位置（NotSeekable）；目录的位置是 readdir 的 cookie，只能挪回 0（从头再列）。
/// 新的位置不能是负的，可以在文件末尾之后。
pub fn seek(f: *File, offset: i64, whence: usize) Error!u64 {
    const i = switch (f.open.target) {
        .inode => |*i| i,
        else => return error.NotSeekable,
    };
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    const st = blk: {
        var r = try fsys.reader();
        defer r.end();
        break :blk try r.fs.stat(i.ino);
    };
    if (st.kind == .dir) {
        if (whence != abi.seek_set or offset != 0) return error.InvalidArgument;
        i.off = 0;
        return 0;
    }
    const base: u64 = switch (whence) {
        abi.seek_set => 0,
        abi.seek_cur => i.off,
        abi.seek_end => st.size,
        else => return error.InvalidArgument,
    };
    const new = if (offset >= 0)
        std.math.add(u64, base, @intCast(offset)) catch return error.InvalidArgument
    else
        std.math.sub(u64, base, @abs(offset)) catch return error.InvalidArgument;
    if (new > std.math.maxInt(i64)) return error.InvalidArgument; // 返回值要能当成非负的有符号数
    i.off = new;
    return new;
}

/// Ctrl-D：在串口上表示“输入结束”，和 Unix 终端一样。
const ctrl_d = 0x04;

/// 从键盘缓冲区读最多 len 个字节。缓冲区为空时睡在 uart.rx_chan 上，串口中断叫醒它。
/// 读到 Ctrl-D 就停下：它前面有字符的话先返回这些字符，Ctrl-D 留到下一次 read，
/// 那一次读掉它、返回 0。所以单独按一次 Ctrl-D，read 返回 0。
fn consoleRead(dst: vm.PinnedDst) Error!usize {
    const len = dst.len;
    if (len == 0) return 0;
    uart.rx_lock.acquire();
    defer uart.rx_lock.release();
    while (!uart.hasInput()) {
        if (proc.isKilled()) return 0; // 回到陷阱处理程序后结束，返回值没人看
        proc.sleep(uart.rx_chan, &uart.rx_lock);
    }
    if (uart.peek() == ctrl_d) {
        _ = uart.read();
        return 0;
    }
    var buf: [64]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        var n: usize = 0;
        while (n < @min(buf.len, len - done)) : (n += 1) {
            const c = uart.peek() orelse break;
            if (c == ctrl_d) break;
            buf[n] = uart.read().?;
        }
        if (n == 0) break;
        dst.copyOut(done, buf[0..n]);
        done += n;
    }
    return done;
}

test "文件表：dup 加引用，最后一个 close 才关掉管道；表满了返回 TooManyFiles 且不漏" {
    const expectEqual = std.testing.expectEqual;
    var test_memory: [4 * page.size]u8 align(page.size) = undefined;
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    const before = page.freePages();

    const r, const w = try openPipe();
    try expectEqual(before - 1, page.freePages());
    _ = dup(w);
    close(w);
    try std.testing.expect(w.open.target.pipe.write_open); // 还有一个引用
    close(w);
    try std.testing.expect(!r.open.target.pipe.write_open);
    close(r);
    try expectEqual(before, page.freePages());

    // 只剩一个空槽位：openPipe 分配第二个 File 时失败，第一个也还回去
    var held: [max_files - 1]*File = undefined;
    for (&held) |*f| f.* = try openConsole();
    try expectEqual(error.TooManyFiles, openPipe());
    const last = try openConsole();
    close(last);
    for (held) |f| close(f);
    try expectEqual(before, page.freePages());
    for (table) |f| try expectEqual(0, f.ref);
}
