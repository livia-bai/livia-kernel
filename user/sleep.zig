//! 睡一会儿：`sleep SECONDS`，可以带小数（`sleep 0.25`，精确到毫秒）。
//! 睡着的时候不占 CPU；按 Ctrl-C 可以提前结束它。

const std = @import("std");
const sys = @import("sys");

pub fn main() u8 {
    const a = sys.arg(1) orelse return usage();
    if (sys.argv.len != 2) return usage();
    const ms = parseSeconds(a) orelse {
        sys.fprint(sys.stderr, "sleep: invalid time: '{s}'\n", .{a});
        return 2;
    };
    sys.sleep(ms);
    return 0;
}

/// "1"、"1.5"、".25"、"2." 换成毫秒，小数点后超过 3 位的部分不要。
fn parseSeconds(s: []const u8) ?u64 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    const int = s[0..dot];
    const frac = if (dot < s.len) s[dot + 1 ..] else "";
    if (int.len == 0 and frac.len == 0) return null;
    const whole: u64 = if (int.len == 0) 0 else std.fmt.parseInt(u64, int, 10) catch return null;
    var ms: u64 = 0;
    for (0..3) |i| {
        const c: u8 = if (i < frac.len) frac[i] else '0';
        if (c < '0' or c > '9') return null;
        ms = ms * 10 + (c - '0');
    }
    for (frac) |c| if (c < '0' or c > '9') return null;
    return std.math.add(u64, std.math.mul(u64, whole, 1000) catch return null, ms) catch null;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: sleep SECONDS\n", .{});
    return 2;
}
