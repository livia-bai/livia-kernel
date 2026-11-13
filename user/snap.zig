//! 文件系统的快照：`snap` 把现在的样子保存下来，打印编号；`snap ls` 列出保存的快照；`snap rm ID...` 删掉。
//! 保存的快照只读地出现在 /.snap/编号/ 下：`ls /.snap/27/`、`cat /.snap/27/notes.txt`、`cp /.snap/27/f /f`。
//! 最多 4 个；删掉一个有文件打开着的快照是 Busy。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const cmd = sys.arg(1) orelse {
        const id = sys.snapshot() catch |err| {
            sys.fprint(sys.stderr, "snap: {s}\n", .{@errorName(err)});
            return 1;
        };
        sys.print("snapshot {d}: /.snap/{d}/\n", .{ id, id });
        return 0;
    };
    if (std.mem.eql(u8, cmd, "ls") and sys.argv.len == 2) {
        var ids: [16]u64 = undefined;
        const n = sys.snaplist(&ids) catch |err| {
            sys.fprint(sys.stderr, "snap: {s}\n", .{@errorName(err)});
            return 1;
        };
        for (ids[0..@min(n, ids.len)]) |id| sys.print("{d}\n", .{id});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "rm") and sys.argv.len > 2) {
        var status: u8 = 0;
        for (sys.argv[2..]) |a| {
            const s = a.slice();
            const id = std.fmt.parseInt(u64, s, 10) catch {
                sys.fprint(sys.stderr, "snap: not a snapshot id: '{s}'\n", .{s});
                status = 1;
                continue;
            };
            sys.snapdel(id) catch |err| {
                sys.fprint(sys.stderr, "snap: {d}: {s}\n", .{ id, @errorName(err) });
                status = 1;
            };
        }
        return status;
    }
    sys.fprint(sys.stderr, "usage: snap [ls | rm ID...]\n", .{});
    return 2;
}
