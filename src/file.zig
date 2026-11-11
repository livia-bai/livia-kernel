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
//! - kind、readable、ino 等字段在分配出来、交给 fd 之前填好，之后就不变了，读写时不用拿锁；
//!   管道的状态由管道自己的锁保护（pipe.zig）。
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

/// console 是 init 打开的串口；device 是打开文件系统里的设备文件得到的（读写交给 major 指的设备）
pub const Kind = enum { none, console, pipe, inode, device };

pub const File = struct {
    /// 保护 ref
    lock: Spinlock = .init("file"),
    /// 引用数：有多少个 fd 指向它。为 0 表示这个槽位空着
    ref: u32 = 0,
    kind: Kind = .none,
    readable: bool = false,
    writable: bool = false,
    pipe: *pipe.Pipe = undefined,
    /// kind 为 inode、device 时：文件系统里的 inode 号；inode 的还有下一次读写的位置（pos_lock）
    ino: u64 = 0,
    /// kind 为 device 时：哪个设备
    major: abi.Major = .console,
    off: u64 = 0,
    /// open_append：每次写之前先把 off 挪到文件末尾
    append: bool = false,
    /// 保护 off，见文件开头
    pos_lock: Sleeplock = .init("file pos"),

    /// 刚分配到的槽位：除了两把锁和 ref，字段都回到初始值。不写成 f.* = .{...}：那会连锁一起覆盖掉，
    /// 而别的 hart 可能正拿着这个槽位的 lock 在看它的 ref（alloc 逐个槽位看）
    fn reset(f: *File) void {
        f.kind = .none;
        f.readable = false;
        f.writable = false;
        f.pipe = undefined;
        f.ino = 0;
        f.major = .console;
        f.off = 0;
        f.append = false;
    }
};

var table: [max_files]File = @splat(.{});

pub const Error = error{ NotReadable, NotWritable, BadAddress, BrokenPipe, NotSeekable, InvalidArgument, TextBusy } || fs.Error;

/// 分配一个空的 File（ref = 1），由调用方填好其他字段。一次只拿一个槽位的锁。
fn alloc() error{TooManyFiles}!*File {
    for (&table) |*f| {
        f.lock.acquire();
        defer f.lock.release();
        if (f.ref == 0) {
            f.ref = 1;
            f.reset();
            return f;
        }
    }
    return error.TooManyFiles;
}

/// 打开串口，可读可写。
pub fn openConsole() error{TooManyFiles}!*File {
    const f = try alloc();
    f.kind = .console;
    f.readable = true;
    f.writable = true;
    return f;
}

/// 创建一个管道，返回读端和写端。
pub fn openPipe() error{ TooManyFiles, OutOfMemory }![2]*File {
    const r = try alloc();
    errdefer close(r);
    const w = try alloc();
    errdefer close(w);
    const p = try pipe.create();
    r.kind = .pipe;
    r.readable = true;
    r.pipe = p;
    w.kind = .pipe;
    w.writable = true;
    w.pipe = p;
    return .{ r, w };
}

/// 打开文件系统里的 inode ino，读写位置从 0 开始。
pub fn openInode(ino: u64, readable: bool, writable: bool, append: bool) error{TooManyFiles}!*File {
    const f = try alloc();
    f.kind = .inode;
    f.ino = ino;
    f.readable = readable;
    f.writable = writable;
    f.append = append;
    return f;
}

/// 打开文件系统里的设备文件 ino（设备号 major）。内核没有这个设备是 NoSuchDevice。
pub fn openDevice(ino: u64, major: abi.Major, readable: bool, writable: bool) error{ TooManyFiles, NoSuchDevice }!*File {
    switch (major) {
        .console, .null, .zero => {},
        _ => return error.NoSuchDevice,
    }
    const f = try alloc();
    f.kind = .device;
    f.ino = ino;
    f.major = major;
    f.readable = readable;
    f.writable = writable;
    return f;
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
    const kind = f.kind;
    const p = f.pipe;
    const writable = f.writable;
    f.reset();
    f.lock.release();
    // 放开 File 的锁之后再关管道：管道的锁和 File 的锁不嵌套，就不用规定加锁的顺序
    if (kind == .pipe) pipe.close(p, writable);
}

/// 一次 read 最多能从 f 读到多少字节：串口、管道一次最多给出缓冲区里有的，/dev/null 什么都没有。
/// read 系统调用先按它截短 len 再检查、分配目标范围：程序给一个很大的缓冲区读串口、管道时，
/// 实际只会写进开头的一小段，不该为整个缓冲区提前分配好所有的页（按需分页省下的内存就白省了）。
pub fn readLimit(f: *const File, len: usize) usize {
    return switch (f.kind) {
        .none => unreachable,
        .console => @min(len, uart.rx_capacity),
        .pipe => @min(len, pipe.size),
        .inode => len,
        .device => switch (f.major) {
            .console => @min(len, uart.rx_capacity),
            .null => 0,
            .zero => len,
            _ => unreachable, // openDevice 不会打开不认识的设备
        },
    };
}

/// 从 f 读最多 len 个字节到用户地址空间 space 的 ptr，返回读到的字节数，0 表示读到了结尾。
/// 调用方先检查过 [ptr, ptr+len) 可写（见 syscall.read）。
pub fn read(f: *File, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    if (!f.readable) return error.NotReadable;
    return switch (f.kind) {
        .none => unreachable,
        .console => consoleRead(space, ptr, len),
        .pipe => pipe.read(f.pipe, space, ptr, len),
        .inode => inodeRead(f, space, ptr, len),
        .device => switch (f.major) {
            .console => consoleRead(space, ptr, len),
            .null => 0,
            .zero => zeroRead(space, ptr, len),
            _ => unreachable, // openDevice 不会打开不认识的设备
        },
    };
}

/// 把用户地址空间 space 里 [ptr, ptr+len) 的字节写进 f，返回写出的字节数。
/// 遇到坏地址时停下，返回已经写出的字节数；一个字节都没写出才返回 BadAddress。
pub fn write(f: *File, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    if (!f.writable) return error.NotWritable;
    return switch (f.kind) {
        .none => unreachable,
        .console => consoleWrite(space, ptr, len),
        .pipe => pipe.write(f.pipe, space, ptr, len),
        .inode => inodeWrite(f, space, ptr, len),
        .device => switch (f.major) {
            .console => consoleWrite(space, ptr, len),
            // 写什么都丢掉，也不看用户内存（和 Linux 的 /dev/null 一样）
            .null, .zero => len,
            _ => unreachable,
        },
    };
}

const zero_page: [page.size]u8 = @splat(0);

/// /dev/zero：把 len 个 0 写进用户内存。调用方先检查过目标可写。
fn zeroRead(space: *vm.Space, ptr: usize, len: usize) Error!usize {
    var done: usize = 0;
    while (done < len) {
        const n = @min(zero_page.len, len - done);
        vm.copyToUser(space, ptr + done, zero_page[0..n]) catch unreachable;
        done += n;
    }
    return len;
}

/// 用户内存先分块复制到内核缓冲区再输出，每块都经过 vm.copyFromUser 检查。
/// 每块都不跨页：一块失败就说明这一页整个不能读，前面的字节都已经写出去了。
/// 整个 write 拿着串口的输出锁，所以一次 write 的内容不会和别的 hart 的输出交错。
fn consoleWrite(space: *vm.Space, ptr: usize, len: usize) Error!usize {
    const out = uart.lockOutput();
    defer out.unlock();
    var buf: [128]u8 = undefined;
    var done: usize = 0;
    while (done < len) {
        const va = ptr + done;
        const chunk = buf[0..@min(buf.len, len - done, page.size - va % page.size)];
        vm.copyFromUser(space, chunk, va) catch return if (done == 0) error.BadAddress else done;
        out.write(chunk);
        done += chunk.len;
    }
    return done;
}

/// 从文件当前的位置读，位置往后挪读到的字节数。读目录是 IsDir（列目录用 readdir 系统调用）。
/// 在快照上读，不挡着别人读写文件系统。
fn inodeRead(f: *File, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    var r = try fsys.reader();
    defer r.end();
    const n = try r.fs.read(f.ino, f.off, len, fsys.UserOut{ .space = space, .ptr = ptr });
    f.off += n;
    return n;
}

/// 写到文件当前的位置（open_append 的是文件末尾），位置挪到写完的地方。整个写是一个事务：
/// 用户内存中途读不出来、磁盘满了，什么都不写，位置也不动。
/// 查文件末尾和写拿着同一次文件系统的写锁，几个进程同时往末尾追加不会写到同一个位置上。
fn inodeWrite(f: *File, space: *vm.Space, ptr: usize, len: usize) Error!usize {
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    const root = try fsys.writer();
    defer fsys.unlock();
    // 正在运行的程序文件不能改（按需分页还要从它读页，见 fsys.holdText）
    try fsys.beginModify(f.ino);
    defer fsys.endModify();
    const off = if (f.append) (try root.stat(f.ino)).size else f.off;
    const n = try root.run(fsys.Fs.write, .{ f.ino, off, len, fsys.UserIn{ .space = space, .ptr = ptr } });
    f.off = off + n;
    return n;
}

/// 挪文件的读写位置（lseek）：whence 是 abi.seek_*，offset 是有符号的。返回新的位置。
/// 串口、管道没有位置（NotSeekable）；目录的位置是 readdir 的 cookie，只能挪回 0（从头再列）。
/// 新的位置不能是负的，可以在文件末尾之后。
pub fn seek(f: *File, offset: i64, whence: usize) Error!u64 {
    if (f.kind != .inode) return error.NotSeekable;
    f.pos_lock.acquire();
    defer f.pos_lock.release();
    const st = blk: {
        var r = try fsys.reader();
        defer r.end();
        break :blk try r.fs.stat(f.ino);
    };
    if (st.kind == .dir) {
        if (whence != abi.seek_set or offset != 0) return error.InvalidArgument;
        f.off = 0;
        return 0;
    }
    const base: u64 = switch (whence) {
        abi.seek_set => 0,
        abi.seek_cur => f.off,
        abi.seek_end => st.size,
        else => return error.InvalidArgument,
    };
    const new = if (offset >= 0)
        std.math.add(u64, base, @intCast(offset)) catch return error.InvalidArgument
    else
        std.math.sub(u64, base, @abs(offset)) catch return error.InvalidArgument;
    if (new > std.math.maxInt(i64)) return error.InvalidArgument; // 返回值要能当成非负的有符号数
    f.off = new;
    return new;
}

/// Ctrl-D：在串口上表示“输入结束”，和 Unix 终端一样。
const ctrl_d = 0x04;

/// 从键盘缓冲区读最多 len 个字节。缓冲区为空时睡在 uart.rx_chan 上，串口中断叫醒它。
/// 读到 Ctrl-D 就停下：它前面有字符的话先返回这些字符，Ctrl-D 留到下一次 read，
/// 那一次读掉它、返回 0。所以单独按一次 Ctrl-D，read 返回 0。
fn consoleRead(space: *vm.Space, ptr: usize, len: usize) Error!usize {
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
        vm.copyToUser(space, ptr + done, buf[0..n]) catch unreachable; // 调用方检查过了
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
    try std.testing.expect(w.pipe.write_open); // 还有一个引用
    close(w);
    try std.testing.expect(!r.pipe.write_open);
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
