//! mkfs：在主机上生成磁盘镜像，build.zig 构建时运行它（对应 xv6 的 mkfs/mkfs.c）。
//!
//!   mkfs <输出文件> <总块数> <文件系统的块数> <文件>...
//!
//! 磁盘的前一部分是文件系统：格式化，建 /bin，把给的每个文件装成 /bin/<文件名>；
//! 建 /dev 和里面的设备文件 console、null、zero（abi.Major）。
//! 后一部分（文件系统之后的块）是“原始区域”，readblock/writeblock 系统调用只能读写这里（见 fsys.zig），
//! 填上固定的图案：第 b 块（从原始区域的开头算）的第 i 个字节是 (b * 131 + i) % 251，回归测试 t_disk 照着它检查。
//!
//! 用的就是内核的文件系统代码（fs.zig、ctree.zig、bio.zig），磁盘是内存里的一块数组。
//! 这个文件是一个单独的主机程序的根，和内核、单元测试是不同的编译，所以可以和它们共用 src/ 下的文件。

const std = @import("std");
const fs = @import("fs.zig");
const ctree = @import("ctree.zig");
const bio = @import("bio.zig");
const abi = @import("abi.zig");

const block_size = fs.block_size;

var disk: [][block_size]u8 = &.{};
var vol: ctree.Volume = .{};

fn transfer(block: u64, data: *[block_size]u8, write: bool) bio.IoError!void {
    if (write) disk[block] = data.* else data.* = disk[block];
}

const SliceIn = struct {
    data: []const u8,
    pub fn get(i: SliceIn, at: usize, dst: []u8) error{BadAddress}!void {
        @memcpy(dst, i.data[at..][0..dst.len]);
    }
};

fn usage() noreturn {
    std.debug.print("usage: mkfs <output> <total blocks> <file system blocks> <file>...\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) usage();
    const total = std.fmt.parseUnsigned(u64, args[2], 10) catch usage();
    const fs_blocks = std.fmt.parseUnsigned(u64, args[3], 10) catch usage();
    if (fs_blocks > total) usage();

    disk = try arena.alloc([block_size]u8, total);
    for (disk) |*b| @memset(b, 0);
    bio.init(.{ .blocks = total, .transfer = transfer });
    try fs.Fs.format(&vol, fs_blocks);
    var f = try fs.Fs.mount(&vol);
    _ = try f.run(fs.Fs.create, .{ fs.root_ino, "/bin", fs.Kind.dir });
    for (args[4..]) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        var name_buf: [fs.max_name + 5]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "/bin/{s}", .{std.fs.path.basename(path)});
        const ino = try f.run(fs.Fs.create, .{ fs.root_ino, name, fs.Kind.file });
        _ = try f.run(fs.Fs.write, .{ ino, 0, data.len, SliceIn{ .data = data } });
    }
    _ = try f.run(fs.Fs.create, .{ fs.root_ino, "/dev", fs.Kind.dir });
    for ([_]abi.Major{ .console, .null, .zero }) |m| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "/dev/{s}", .{@tagName(m)});
        _ = try f.run(fs.Fs.mknod, .{ fs.root_ino, name, @backingInt(m) });
    }
    _ = try f.check();

    // 原始区域
    for (disk[fs_blocks..], 0..) |*blk, b| {
        for (blk, 0..) |*c, i| c.* = @intCast((b * 131 + i) % 251);
    }

    var flat = try arena.alloc(u8, total * block_size);
    for (disk, 0..) |blk, i| @memcpy(flat[i * block_size ..][0..block_size], &blk);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = flat });
}
