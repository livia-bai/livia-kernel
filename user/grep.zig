//! 找出含有某个模式的行：`grep [-v] [-i] [-n] [-c] [-q] PATTERN [FILE...]`，不给文件名时读标准输入。
//!
//! 模式是简单的正则表达式（照 xv6 的 grep，出自 Kernighan 和 Pike 的《程序设计实践》）：
//! `^` 行首、`$` 行尾、`.` 任意一个字符、`c*` 零个或多个 c、`\c` 字符 c 本身，别的字符就是它自己。
//!
//!   -v  打印不匹配的行      -i  不分大小写      -n  行前面加上行号
//!   -c  只打印匹配的行数    -q  什么都不打印，只看退出码
//! 给了几个文件时，每行前面加上 `文件名:`。
//! 退出码：有匹配的行是 0，没有是 1，出错（打不开文件、用法不对）是 2。配合 `&&`、`||` 用：
//! `grep -q root /etc/x && echo found`。

const std = @import("std");
const sys = @import("sys");

const Options = struct {
    invert: bool = false,
    ignore_case: bool = false,
    number: bool = false,
    count: bool = false,
    quiet: bool = false,
};

var opts: Options = .{};
var pattern: []const u8 = "";

pub fn main() u8 {
    var i: usize = 1;
    while (i < sys.argv.len) : (i += 1) {
        const a = sys.argv[i].slice();
        if (a.len < 2 or a[0] != '-') break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        }
        for (a[1..]) |c| switch (c) {
            'v' => opts.invert = true,
            'i' => opts.ignore_case = true,
            'n' => opts.number = true,
            'c' => opts.count = true,
            'q' => opts.quiet = true,
            else => return usage(),
        };
    }
    if (i >= sys.argv.len) return usage();
    pattern = sys.argv[i].slice();
    const files = sys.argv[i + 1 ..];
    var found = false;
    var failed = false;
    if (files.len == 0) {
        found = grep(sys.stdin, "stdin", null) catch return 2;
    } else for (files) |f| {
        const fd = sys.open(f.slice(), .{}) catch |err| {
            sys.fprint(sys.stderr, "grep: {s}: {s}\n", .{ f.slice(), @errorName(err) });
            failed = true;
            continue;
        };
        defer sys.close(fd) catch {};
        const hit = grep(fd, f.slice(), if (files.len > 1) f.slice() else null) catch {
            failed = true;
            continue;
        };
        found = found or hit;
        if (found and opts.quiet) break;
    }
    if (failed and !(found and opts.quiet)) return 2;
    return if (found) 0 else 1;
}

var buf: [4096]u8 = undefined;

/// 处理一个文件，返回有没有匹配的行。prefix 不为 null 时每行前面加上 `prefix:`。
fn grep(fd: sys.Fd, name: []const u8, prefix: ?[]const u8) error{Failed}!bool {
    var r = sys.LineReader.init(fd, &buf);
    var lineno: u64 = 0;
    var matches: u64 = 0;
    while (true) {
        const line = (r.next() catch |err| {
            sys.fprint(sys.stderr, "grep: {s}: {s}\n", .{ name, @errorName(err) });
            return error.Failed;
        }) orelse break;
        lineno += 1;
        if (match(pattern, line) == opts.invert) continue;
        matches += 1;
        if (opts.quiet) return true;
        if (opts.count) continue;
        output(prefix, if (opts.number) lineno else null, line) catch return error.Failed;
    }
    if (opts.count) {
        if (prefix) |p| sys.print("{s}:", .{p});
        sys.print("{d}\n", .{matches});
    }
    return matches > 0;
}

var out: [buf.len + 2 * sys.abi.max_path]u8 = undefined;

/// 输出一行：`文件名:`、`行号:`、内容、换行拼好了一次写出去，不会和别的进程的输出交错在一行中间。
fn output(prefix: ?[]const u8, lineno: ?u64, line: []const u8) sys.Error!void {
    var w: std.Io.Writer = .fixed(&out);
    if (prefix) |p| w.print("{s}:", .{p}) catch {};
    if (lineno) |n| w.print("{d}:", .{n}) catch {};
    const head = w.buffered();
    if (head.len + line.len + 1 > out.len) {
        // 拼不下（文件名太长）：分几次写
        try sys.writeAll(sys.stdout, head);
        try sys.writeAll(sys.stdout, line);
        return sys.writeAll(sys.stdout, "\n");
    }
    @memcpy(out[head.len..][0..line.len], line);
    out[head.len + line.len] = '\n';
    return sys.writeAll(sys.stdout, out[0 .. head.len + line.len + 1]);
}

/// 模式 re 在 text 里有没有匹配的地方。
fn match(re: []const u8, text: []const u8) bool {
    if (re.len > 0 and re[0] == '^') return matchHere(re[1..], text);
    var t = text;
    while (true) {
        if (matchHere(re, t)) return true;
        if (t.len == 0) return false;
        t = t[1..];
    }
}

/// re 能不能匹配 text 的开头。
fn matchHere(re: []const u8, text: []const u8) bool {
    if (re.len == 0) return true;
    const atom = atomLen(re);
    if (re.len > atom and re[atom] == '*') return matchStar(re[0..atom], re[atom + 1 ..], text);
    if (re.len == 1 and re[0] == '$') return text.len == 0;
    if (text.len > 0 and matchAtom(re[0..atom], text[0])) return matchHere(re[atom..], text[1..]);
    return false;
}

/// `c*`：零个或多个 atom，然后 re 匹配剩下的（照 Pike 的写法，先试最短的）。
fn matchStar(atom: []const u8, re: []const u8, text: []const u8) bool {
    var t = text;
    while (true) {
        if (matchHere(re, t)) return true;
        if (t.len == 0 or !matchAtom(atom, t[0])) return false;
        t = t[1..];
    }
}

/// 一个“字符”在模式里占几个字节：`\c` 两个，别的一个。
fn atomLen(re: []const u8) usize {
    return if (re[0] == '\\' and re.len > 1) 2 else 1;
}

fn matchAtom(atom: []const u8, c: u8) bool {
    if (atom.len == 2) return eq(atom[1], c); // \c
    if (atom[0] == '.') return true;
    return eq(atom[0], c);
}

fn eq(a: u8, b: u8) bool {
    return if (opts.ignore_case) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

fn usage() u8 {
    sys.fprint(sys.stderr, "usage: grep [-vincq] PATTERN [FILE...]\n", .{});
    return 2;
}
