//! 列出目录：`ls [路径...]`，不给路径时是当前目录。每个名字一行：种类、链接数、字节数（设备文件是设备号，
//! 符号链接是目标的长度）、名字；符号链接后面再跟着 `-> 目标`。
//! 给的是文件（或者符号链接，不管它指向什么）的话只列它自己；给的是目录，或者指向目录的符号链接，列出里面的东西。
//! 给了几个路径时，每个目录前面先打印一行 `路径:`。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

pub fn main() u8 {
    var status: u8 = 0;
    if (sys.argv.len <= 1) return list(".", false);
    for (sys.argv[1..]) |a| status |= list(a.slice(), sys.argv.len > 2);
    return status;
}

fn kindName(k: abi.FileKind) []const u8 {
    return switch (k) {
        .file => "file",
        .dir => "dir",
        .device => "dev",
        .symlink => "link",
        else => "?",
    };
}

fn list(path: []const u8, header: bool) u8 {
    // 打开会跟着符号链接走：是目录（或者指向目录）的才列里面的东西，别的用 lstat 列它自己
    const fd = sys.open(path, .{}) catch |err| return single(path, err);
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    if (st.kind != .dir) return single(path, null);
    if (header) sys.print("{s}:\n", .{path});
    var ent: abi.Dirent = undefined;
    while (sys.readdir(fd, &ent) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    }) {
        const name = ent.name[0..ent.name_len];
        // 大小、链接数用 lstat 查：路径是 目录/名字。查不到的（太长了）记成 0
        var buf: [abi.max_path]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, name }) catch name;
        const st_ent = sys.lstat(full) catch abi.Stat{ .ino = 0, .size = 0, .kind = ent.kind };
        printEntry(ent.kind, st_ent, name, full);
    }
    return 0;
}

/// 列 path 自己（lstat，不跟着符号链接走）。open 失败的原因是 open_err：lstat 也失败的话报 open 的错，
/// 这样悬空的符号链接也列得出来，真的没有的报 NotFound。
fn single(path: []const u8, open_err: ?sys.Error) u8 {
    const st = sys.lstat(path) catch |err| {
        sys.print("ls: {s}: {s}\n", .{ path, @errorName(open_err orelse err) });
        return 1;
    };
    printEntry(st.kind, st, path, path);
    return 0;
}

fn printEntry(kind: abi.FileKind, st: abi.Stat, name: []const u8, path: []const u8) void {
    const size = if (kind == .device) st.major else st.size;
    if (kind == .symlink) {
        var buf: [abi.max_path]u8 = undefined;
        const target = sys.readlink(path, &buf) catch "?";
        sys.print("{s:<4} {d:>2} {d:>8} {s} -> {s}\n", .{ kindName(kind), st.nlink, size, name, target });
    } else {
        sys.print("{s:<4} {d:>2} {d:>8} {s}\n", .{ kindName(kind), st.nlink, size, name });
    }
}
