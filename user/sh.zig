//! shell：读一行命令，执行，再读下一行。由 init 启动，对应 xv6 的 user/sh.c（功能多一些）。
//!
//! 它是一个普通的用户程序，内核里的功能都通过系统调用使用：程序用 fork + exec 启动（带上命令行参数），
//! 前台运行时用 setfg 告诉内核按 Ctrl-C 该杀谁，再 wait 它结束；`a | b` 用 pipe、dup、close 接起来；
//! `ps`、`mem` 用 procinfo、meminfo，`cd`、`pwd` 用 chdir、getcwd。
//!
//! 一行命令的处理（docs/shell.md）：
//! - 词法（lex）：按空格分词，认出运算符 `| & ; && || < > >>`；引号（'...' 原样，"..." 里展开变量）、
//!   反斜杠转义；`$?`、`$NAME`、`${NAME}`、`$1` 这些变量在这时展开；`#` 开始的是注释。
//! - 一次解析、执行一个管道（到 `;`、`&`、`&&`、`||` 为止），所以 `A=1; echo $A` 里的 $A 已经是新的值。
//!   不在引号里的 `*`、`?` 按文件名匹配展开（glob）。
//! - 内置命令（cd、pwd、exit...）在 shell 自己里运行，别的在 /bin 里找程序。
//!
//! 交互时（标准输入是串口）自己回显、处理退格，上下方向键翻历史，Tab 补全；`sh 文件` 或者标准输入不是串口时
//! 一行一行地读命令执行（脚本），`sh -c 命令` 只执行这一行。

const std = @import("std");
const sys = @import("sys");
const abi = sys.abi;

/// 一个管道最多几个程序。进程表只有 abi.max_procs 个槽位，init、shell 和管道的“组长”（见 runLeader）占三个。
const max_stages = 8;
/// 一行最长多少字节
const line_max = 512;

// ---- shell 的状态 ----

/// 上一个命令的退出码（$?）
var status: u8 = 0;
/// 最后一个后台进程的 pid（$!）
var last_bg: usize = 0;
/// 位置参数：$0 是 params[0]（交互时是 "sh"，脚本是脚本的路径），$1... 是后面的
var params: []const abi.Arg = &.{};
/// 从文件读命令时那个文件的 fd（`sh 文件`）。子进程运行程序之前关掉它，不留给程序
var script_fd: ?sys.Fd = null;
/// cd - 回到的目录
var prev_dir: [abi.max_path]u8 = undefined;
var prev_dir_len: usize = 0;

var line: [line_max]u8 = undefined;

pub fn main() u8 {
    const args = sys.argv;
    params = args[0..@min(1, args.len)];
    if (args.len >= 2 and std.mem.eql(u8, args[1].slice(), "-c")) {
        // sh -c 命令 [$0 [$1...]]：和 Unix 的 sh 一样，命令后面的参数从 $0 开始
        if (args.len < 3) {
            sys.print("usage: sh -c COMMANDS [NAME [ARGS...]]\n", .{});
            return 2;
        }
        if (args.len > 3) params = args[3..];
        execute(args[2].slice());
        return status;
    }
    if (args.len >= 2) {
        // sh 文件 [参数...]：$0 是文件，$1... 是参数
        const path = args[1].slice();
        const fd = sys.open(path, .{}) catch |err| {
            sys.print("sh: {s}: {s}\n", .{ path, @errorName(err) });
            return 127;
        };
        script_fd = fd;
        params = args[1..];
        return runScript(fd);
    }
    if (!isConsole(sys.stdin)) return runScript(sys.stdin); // sh < 文件、... | sh
    sys.print("Type 'help' for commands.\n", .{});
    while (true) {
        reapBackground();
        sys.print("> ", .{});
        const l = readLine();
        addHistory(l);
        execute(l);
    }
}

fn isConsole(fd: sys.Fd) bool {
    const st = sys.fstat(fd) catch return false;
    return st.kind == .console or (st.kind == .device and st.major == @backingInt(abi.Major.console));
}

/// 一行一行地执行 fd 里的命令，读完了以最后一个命令的退出码结束。
fn runScript(fd: sys.Fd) u8 {
    while (readScriptLine(fd)) |l| {
        reapBackground();
        execute(l);
    }
    return status;
}

/// 回收已经结束的后台进程。它们结束时内核已经打印过信息了，不回收的话会一直占着进程表的槽位。
fn reapBackground() void {
    while (sys.wait(null, true) catch null) |_| {}
}

// ---- 读一行：脚本 ----

var in_buf: [1024]u8 = undefined;
var in_start: usize = 0;
var in_end: usize = 0;
var in_eof = false;

/// 从 fd 读一行（去掉行尾的 \n、\r），读完了返回 null。超过 line_max 的行报错，当作空行。
fn readScriptLine(fd: sys.Fd) ?[]const u8 {
    var len: usize = 0;
    var too_long = false;
    var got = false;
    while (true) {
        if (in_start == in_end) {
            if (in_eof) break;
            const n = sys.read(fd, &in_buf) catch 0;
            if (n == 0) {
                in_eof = true;
                break;
            }
            in_start = 0;
            in_end = n;
        }
        const c = in_buf[in_start];
        in_start += 1;
        got = true;
        if (c == '\n') break;
        if (len < line.len) {
            line[len] = c;
            len += 1;
        } else {
            too_long = true;
        }
    }
    if (!got) return null;
    if (too_long) {
        sys.print("sh: line too long (at most {d} bytes)\n", .{line_max});
        return "";
    }
    return std.mem.trimEnd(u8, line[0..len], "\r");
}

// ---- 读一行：交互 ----

/// 历史：最近 hist_max 行，第 i 行（从 0 数）在 hist[i % hist_max]
const hist_max = 16;
var hist: [hist_max][line_max]u8 = undefined;
var hist_lens: [hist_max]usize = undefined;
var hist_count: usize = 0;

/// 读一行：可打印字符回显并追加（行满了就忽略），退格删掉最后一个字符，Ctrl-U 清掉整行，回车结束；
/// 上下方向键（ESC [ A、ESC [ B）翻历史，Tab 补全。别的控制字符和转义序列忽略。
/// Ctrl-C 不会读到：内核在串口中断里就把它截下了。
fn readLine() []const u8 {
    var len: usize = 0;
    var pos = hist_count; // 正在看的历史：hist_count 是正在编辑的新行
    while (true) {
        const c = readByte() orelse continue; // 读到 0 是按了 Ctrl-D，忽略
        switch (c) {
            '\r', '\n' => {
                sys.print("\n", .{});
                return line[0..len];
            },
            // 退格：光标左移，用空格盖掉，再左移
            0x08, 0x7f => if (len > 0) {
                len -= 1;
                sys.print("\x08 \x08", .{});
            },
            0x15 => len = setLine(len, ""), // Ctrl-U
            '\t' => len = complete(len),
            0x1b => switch (escape()) {
                'A' => if (pos > hist_count -| hist_max and pos > 0) {
                    pos -= 1;
                    len = setLine(len, histAt(pos));
                },
                'B' => if (pos < hist_count) {
                    pos += 1;
                    len = setLine(len, if (pos == hist_count) "" else histAt(pos));
                },
                else => {},
            },
            ' '...'~' => len = insert(len, &.{c}),
            else => {},
        }
    }
}

fn readByte() ?u8 {
    var c: [1]u8 = undefined;
    // 缓冲区在自己的栈上，不会出错
    if ((sys.read(sys.stdin, &c) catch 0) == 0) return null;
    return c[0];
}

/// ESC 之后的转义序列（方向键是 ESC [ A 这样），返回最后一个字节；不是 ESC [ 开头的返回 0。
fn escape() u8 {
    const b = readByte() orelse return 0;
    if (b != '[' and b != 'O') return 0;
    while (true) {
        const f = readByte() orelse return 0;
        if (f >= 0x40 and f <= 0x7e) return f; // 中间可能有数字、分号（比如 Delete 是 ESC [ 3 ~）
    }
}

/// 把正在编辑的行（长 len）换成 text：先退格擦掉，再回显新的。返回新的长度。
fn setLine(len: usize, text: []const u8) usize {
    for (0..len) |_| sys.print("\x08 \x08", .{});
    return insert(0, text);
}

/// 在行末追加 text（放不下的部分丢掉）并回显，返回新的长度。
fn insert(len: usize, text: []const u8) usize {
    const n = @min(text.len, line.len - len);
    @memcpy(line[len..][0..n], text[0..n]);
    sys.print("{s}", .{text[0..n]});
    return len + n;
}

fn histAt(i: usize) []const u8 {
    return hist[i % hist_max][0..hist_lens[i % hist_max]];
}

/// 记进历史：空行、和上一行一样的不记。
fn addHistory(l: []const u8) void {
    if (std.mem.trim(u8, l, " ").len == 0) return;
    if (hist_count > 0 and std.mem.eql(u8, histAt(hist_count - 1), l)) return;
    const slot = hist_count % hist_max;
    @memcpy(hist[slot][0..l.len], l);
    hist_lens[slot] = l.len;
    hist_count += 1;
}

// ---- Tab 补全 ----

/// 补全光标前的那个词：是命令名的位置（行首，或者 |、;、& 后面）就在内置命令和 /bin 里找，否则按路径找。
/// 只有一个候选就补全它（目录后面加 /，别的加空格）；几个候选有更长的公共前缀就补到公共前缀，
/// 否则把候选列出来，再重新打印提示符和这一行。返回新的长度。
fn complete(len: usize) usize {
    const cur = line[0..len];
    var ws = len;
    while (ws > 0 and std.mem.indexOfScalar(u8, " |;&<>", cur[ws - 1]) == null) ws -= 1;
    const word = cur[ws..];
    if (std.mem.indexOfAny(u8, word, "'\"\\$*?") != null) return len; // 引号、变量、模式不补全
    var k = ws;
    while (k > 0 and cur[k - 1] == ' ') k -= 1;
    const command = (k == 0 or std.mem.indexOfScalar(u8, "|;&", cur[k - 1]) != null) and
        std.mem.indexOfScalar(u8, word, '/') == null;
    resetNames();
    var base = word;
    var dir_part: []const u8 = "";
    if (command) {
        for (std.meta.fieldNames(Builtin)) |b| {
            if (std.mem.startsWith(u8, b, word)) addName(b, false);
        }
        if (std.mem.startsWith(u8, "run", word)) addName("run", false);
        if (std.mem.startsWith(u8, "time", word)) addName("time", false);
        addDirNames("/bin", "/bin/", .{ .prefix = word });
    } else {
        const slash = std.mem.lastIndexOfScalar(u8, word, '/');
        dir_part = if (slash) |i| word[0 .. i + 1] else "";
        base = word[dir_part.len..];
        addDirNames(if (dir_part.len == 0) "." else dir_part, dir_part, .{ .prefix = base });
    }
    if (name_count == 0) return len;
    sortNames();
    // 公共前缀
    var common = names[0].len;
    for (names[1..name_count]) |n| common = @min(common, std.mem.indexOfDiff(u8, names[0], n) orelse n.len);
    if (name_count == 1) {
        const l = insert(len, names[0][base.len..]);
        return insert(l, if (name_dirs[0]) "/" else " ");
    }
    if (common > base.len) return insert(len, names[0][base.len..common]);
    sys.print("\n", .{});
    for (names[0..name_count]) |n| sys.print("{s}  ", .{n});
    sys.print("\n> {s}", .{cur});
    return len;
}

// ---- 名字列表（列程序、补全、glob 共用） ----

var name_bytes: [8192]u8 = undefined;
var name_used: usize = 0;
var names: [256][]const u8 = undefined;
/// names[i] 是不是目录（补全时在后面加 /）
var name_dirs: [256]bool = undefined;
var name_count: usize = 0;

fn resetNames() void {
    name_used = 0;
    name_count = 0;
}

/// 记下一个名字（复制进 name_bytes）。满了就不记了。
fn addName(name: []const u8, is_dir: bool) void {
    if (name_count == names.len or name.len > name_bytes.len - name_used) return;
    const dst = name_bytes[name_used..][0..name.len];
    @memcpy(dst, name);
    name_used += name.len;
    names[name_count] = dst;
    name_dirs[name_count] = is_dir;
    name_count += 1;
}

const Match = union(enum) { prefix: []const u8, glob: []const u8 };

/// 把目录 dir 里符合 m 的名字都记下来（readdir 给的是名字的散列的顺序，用完 sortNames）。
/// 以 . 开头的名字只有模式也以 . 开头时才算。prefix 是 dir 在命令行上的写法，查是不是目录时拼在名字前面。
fn addDirNames(dir: []const u8, prefix: []const u8, m: Match) void {
    const fd = sys.open(dir, .{}) catch return;
    defer sys.close(fd) catch {};
    const pat = switch (m) {
        inline else => |p| p,
    };
    var ent: abi.Dirent = undefined;
    while (sys.readdir(fd, &ent) catch false) {
        const name = ent.name[0..ent.name_len];
        if (name[0] == '.' and (pat.len == 0 or pat[0] != '.')) continue;
        const ok = switch (m) {
            .prefix => |p| std.mem.startsWith(u8, name, p),
            .glob => |p| globMatch(p, name),
        };
        if (!ok) continue;
        var is_dir = ent.kind == .dir;
        if (ent.kind == .symlink) {
            // 指向目录的符号链接也算目录：拼出路径打开看看
            var buf: [abi.max_path]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name })) |p| is_dir = isDir(p) else |_| {}
        }
        addName(name, is_dir);
    }
}

/// 按名字排序。用插入排序：std.mem.sort 是块排序，栈上有一个 512 项的缓存（这里是 8 KiB 的切片），
/// Debug 模式下把 16 KiB 的用户栈撑爆过。几十个名字用插入排序就够了。name_dirs 跟着一起挪。
fn sortNames() void {
    var i: usize = 1;
    while (i < name_count) : (i += 1) {
        const n = names[i];
        const d = name_dirs[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, n, names[j - 1]) == .lt) : (j -= 1) {
            names[j] = names[j - 1];
            name_dirs[j] = name_dirs[j - 1];
        }
        names[j] = n;
        name_dirs[j] = d;
    }
}

/// name 是否匹配模式 pat：`*` 匹配任意多个字符（包括没有），`?` 匹配一个字符，别的字符要一样。
/// 回溯到上一个 `*` 的经典做法，最坏 O(len(pat) × len(name))。
fn globMatch(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null; // 上一个 * 在 pat 里的位置
    var star_n: usize = 0; // 那个 * 目前匹配到 name 的哪里
    while (n < name.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            // 让上一个 * 多吃一个字符，再试
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

// ---- 词法：分词、引号、变量 ----

const Op = enum { pipe, amp, semi, and_if, or_if, in, out, append };

const Word = struct {
    text: []const u8,
    /// 有不在引号里的 * 或 ?：要按文件名展开
    glob: bool,
};

const Token = union(enum) { word: Word, op: Op };

const ParseError = error{
    UnterminatedQuote,
    BadSubstitution,
    LineTooLong,
    EmptyCommand,
    TooManyArguments,
    TooManyStages,
    MissingFileName,
};

/// 展开好的词都放在这里（一个管道用一次，解析下一个管道之前清空）
var word_buf: [4096]u8 = undefined;
var word_len: usize = 0;

fn put(bytes: []const u8) ParseError!void {
    if (bytes.len > word_buf.len - word_len) return error.LineTooLong;
    @memcpy(word_buf[word_len..][0..bytes.len], bytes);
    word_len += bytes.len;
}

fn putNumber(n: usize) ParseError!void {
    var buf: [20]u8 = undefined;
    try put(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
}

/// 从 src[pos.*] 开始取下一个记号，pos 挪到它后面。行尾或者注释返回 null。
fn lex(src: []const u8, pos: *usize) ParseError!?Token {
    var i = pos.*;
    while (true) {
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i == src.len or src[i] == '#') {
            pos.* = src.len;
            return null;
        }
        const next: u8 = if (i + 1 < src.len) src[i + 1] else 0;
        const op: ?struct { Op, usize } = switch (src[i]) {
            '|' => if (next == '|') .{ .or_if, 2 } else .{ .pipe, 1 },
            '&' => if (next == '&') .{ .and_if, 2 } else .{ .amp, 1 },
            ';' => .{ .semi, 1 },
            '<' => .{ .in, 1 },
            '>' => if (next == '>') .{ .append, 2 } else .{ .out, 1 },
            else => null,
        };
        if (op) |o| {
            pos.* = i + o[1];
            return .{ .op = o[0] };
        }
        const start = word_len;
        var glob = false;
        var quoted = false;
        word: while (i < src.len) {
            const c = src[i];
            switch (c) {
                ' ', '\t', '|', '&', ';', '<', '>' => break :word,
                '\'' => {
                    // 单引号里什么都不展开，直到下一个单引号
                    const end = std.mem.indexOfScalarPos(u8, src, i + 1, '\'') orelse return error.UnterminatedQuote;
                    try put(src[i + 1 .. end]);
                    i = end + 1;
                    quoted = true;
                },
                '"' => {
                    // 双引号里展开变量，\ 只转义 " \ $
                    i += 1;
                    quoted = true;
                    while (true) {
                        if (i >= src.len) return error.UnterminatedQuote;
                        const d = src[i];
                        if (d == '"') {
                            i += 1;
                            break;
                        }
                        if (d == '\\' and i + 1 < src.len and std.mem.indexOfScalar(u8, "\"\\$", src[i + 1]) != null) {
                            try put(src[i + 1 .. i + 2]);
                            i += 2;
                        } else if (d == '$') {
                            i = try expand(src, i);
                        } else {
                            try put(src[i .. i + 1]);
                            i += 1;
                        }
                    }
                },
                '\\' => {
                    // 反斜杠让下一个字符失去特殊含义（行尾的反斜杠什么都不是）
                    if (i + 1 < src.len) try put(src[i + 1 .. i + 2]);
                    i += 2;
                    quoted = true;
                },
                '$' => i = try expand(src, i),
                else => {
                    if (c == '*' or c == '?') glob = true;
                    try put(src[i .. i + 1]);
                    i += 1;
                },
            }
        }
        i = @min(i, src.len);
        pos.* = i;
        // 不在引号里的变量展开成空的：不算一个词（和 sh 一样，`echo $NOPE x` 只有一个参数）
        if (word_len == start and !quoted) continue;
        return .{ .word = .{ .text = word_buf[start..word_len], .glob = glob } };
    }
}

/// 展开 src[i] 处的 `$`，返回它后面的位置：`$?` 退出码，`$$` shell 的 pid，`$!` 最后一个后台进程，
/// `$#` 参数个数，`$0`..`$9` 位置参数，`$NAME`、`${NAME}` 变量（没有就是空的）。别的 `$` 原样留着。
fn expand(src: []const u8, i: usize) ParseError!usize {
    const c: u8 = if (i + 1 < src.len) src[i + 1] else 0;
    switch (c) {
        '?' => try putNumber(status),
        '$' => try putNumber(sys.getpid()),
        '!' => try putNumber(last_bg),
        '#' => try putNumber(params.len -| 1),
        '0'...'9' => try put(param(c - '0')),
        '{' => {
            const end = std.mem.indexOfScalarPos(u8, src, i + 2, '}') orelse return error.BadSubstitution;
            const name = src[i + 2 .. end];
            if (!isName(name)) return error.BadSubstitution;
            try put(getVar(name) orelse "");
            return end + 1;
        },
        'a'...'z', 'A'...'Z', '_' => {
            var end = i + 1;
            while (end < src.len and isNameChar(src[end])) end += 1;
            try put(getVar(src[i + 1 .. end]) orelse "");
            return end;
        },
        else => {
            try put("$");
            return i + 1;
        },
    }
    return i + 2;
}

fn param(n: usize) []const u8 {
    return if (n < params.len) params[n].slice() else "";
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!isNameChar(c)) return false;
    return true;
}

// ---- 变量 ----

const max_vars = 32;
const Var = struct {
    name: [32]u8,
    name_len: usize,
    value: [abi.max_path]u8,
    value_len: usize,
};
var vars: [max_vars]Var = undefined;
var var_count: usize = 0;

fn findVar(name: []const u8) ?*Var {
    for (vars[0..var_count]) |*v| {
        if (std.mem.eql(u8, v.name[0..v.name_len], name)) return v;
    }
    return null;
}

fn getVar(name: []const u8) ?[]const u8 {
    const v = findVar(name) orelse return null;
    return v.value[0..v.value_len];
}

fn setVar(name: []const u8, value: []const u8) error{ TooManyVariables, NameTooLong, ValueTooLong }!void {
    if (name.len > 32) return error.NameTooLong;
    if (value.len > abi.max_path) return error.ValueTooLong;
    const v = findVar(name) orelse blk: {
        if (var_count == max_vars) return error.TooManyVariables;
        const v = &vars[var_count];
        var_count += 1;
        @memcpy(v.name[0..name.len], name);
        v.name_len = name.len;
        break :blk v;
    };
    @memcpy(v.value[0..value.len], value);
    v.value_len = value.len;
}

fn unsetVar(name: []const u8) void {
    const v = findVar(name) orelse return;
    v.* = vars[var_count - 1]; // 和最后一个换（顺序不要紧），两个都是全局的，不经过栈的大复制也没关系
    var_count -= 1;
}

/// `NAME=值` 形式的词：返回等号的位置。
fn assignment(word: []const u8) ?usize {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return null;
    return if (isName(word[0..eq])) eq else null;
}

// ---- 解析一个管道 ----

/// 一个要运行的命令：程序名（或者内置命令）是 args[0]。`< 文件`、`> 文件` 把标准输入、标准输出换成文件，
/// `>> 文件` 追加到文件末尾。
const Stage = struct {
    args: [abi.max_args][]const u8 = undefined,
    argc: usize = 0,
    in: ?[]const u8 = null,
    out: ?[]const u8 = null,
    /// out 是 `>>` 给的：追加，不截断
    append: bool = false,

    fn name(st: *const Stage) []const u8 {
        return st.args[0];
    }

    fn argv(st: *const Stage) []const []const u8 {
        return st.args[0..st.argc];
    }

    fn add(st: *Stage, word: []const u8) ParseError!void {
        if (st.argc == st.args.len) return error.TooManyArguments;
        st.args[st.argc] = word;
        st.argc += 1;
    }

    /// 去掉第一个词（前缀 run、time）
    fn shift(st: *Stage) void {
        std.mem.copyForwards([]const u8, st.args[0 .. st.argc - 1], st.args[1..st.argc]);
        st.argc -= 1;
    }
};

/// 管道后面是什么
const End = enum { line, semi, amp, and_if, or_if };

var stage_buf: [max_stages]Stage = undefined;

/// 从 src[pos.*] 开始解析一个管道：用 | 隔开的几个命令，到 ;、&、&&、|| 或者行尾为止。
/// 返回这几个命令（空的话说明什么都没有）和后面跟着的是什么。词是 word_buf 里的切片。
fn parsePipeline(src: []const u8, pos: *usize) ParseError!struct { []Stage, End } {
    word_len = 0;
    var n: usize = 0;
    var cur: ?*Stage = null; // 正在填的命令；刚遇到 | 时是 null
    const end: End = while (true) {
        const tok = try lex(src, pos) orelse break .line;
        switch (tok) {
            .word => |w| {
                const st = cur orelse try newStage(&n, &cur);
                // 匹配到文件名的话换成这些名字，一个都没有就原样留着（和 sh 一样）
                if (!(w.glob and !check_only and try expandGlob(st, w.text))) try st.add(w.text);
            },
            .op => |op| switch (op) {
                .in, .out, .append => {
                    const t = try lex(src, pos) orelse return error.MissingFileName;
                    const file = switch (t) {
                        .word => |w| w.text,
                        .op => return error.MissingFileName,
                    };
                    const st = cur orelse try newStage(&n, &cur);
                    if (op == .in) {
                        st.in = file;
                    } else {
                        st.out = file;
                        st.append = op == .append;
                    }
                },
                .pipe => {
                    const st = cur orelse return error.EmptyCommand;
                    if (st.argc == 0) return error.EmptyCommand;
                    cur = null;
                },
                .semi => break .semi,
                .amp => break .amp,
                .and_if => break .and_if,
                .or_if => break .or_if,
            },
        }
    };
    if (n == 0) {
        if (end == .line) return .{ stage_buf[0..0], end };
        return error.EmptyCommand; // `; ls`、`&& ls`
    }
    const last = cur orelse return error.EmptyCommand; // `ls |`
    if (last.argc == 0) return error.EmptyCommand; // `> f`
    return .{ stage_buf[0..n], end };
}

fn newStage(n: *usize, cur: *?*Stage) ParseError!*Stage {
    if (n.* == max_stages) return error.TooManyStages;
    const st = &stage_buf[n.*];
    st.* = .{};
    n.* += 1;
    cur.* = st;
    return st;
}

/// 把 pattern 按文件名展开，匹配到的按名字排序加进 st，返回匹配到了没有。
/// 只有最后一段能有 `*`、`?`：前面的目录部分原样用（`/bin/t_*` 可以，`/*/x` 不展开）。
fn expandGlob(st: *Stage, pattern: []const u8) ParseError!bool {
    const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir_part = if (slash) |i| pattern[0 .. i + 1] else "";
    const pat = pattern[dir_part.len..];
    if (pat.len == 0 or std.mem.indexOfAny(u8, dir_part, "*?") != null) return false;
    resetNames();
    addDirNames(if (dir_part.len == 0) "." else dir_part, dir_part, .{ .glob = pat });
    if (name_count == 0) return false;
    sortNames();
    for (names[0..name_count]) |n| {
        const start = word_len;
        try put(dir_part);
        try put(n);
        try st.add(word_buf[start..word_len]);
    }
    return true;
}

// ---- 执行 ----

/// 执行一行：一个一个管道地解析、执行。`A && B` 只有 A 成功（退出码 0）才执行 B，`A || B` 只有 A 失败才执行；
/// 跳过的命令不改 $?，所以 `false && x || y` 执行 y。
/// 先把整行检查一遍（checkSyntax）：后面写错了的话前面的也不执行。
fn execute(src: []const u8) void {
    checkSyntax(src) catch |err| return parseFailed(err);
    var pos: usize = 0;
    var run_next = true;
    var after: End = .line;
    while (true) {
        const stages, const end = parsePipeline(src, &pos) catch |err| return parseFailed(err);
        if (stages.len == 0) {
            if (after == .and_if or after == .or_if) parseFailed(error.EmptyCommand); // `ls &&`
            return;
        }
        if (run_next) runPipeline(stages, end == .amp);
        run_next = switch (end) {
            .line => return,
            .semi, .amp => true,
            .and_if => status == 0,
            .or_if => status != 0,
        };
        after = end;
    }
}

/// 只解析不执行，找出语法错误（引号没配对、空的命令、缺文件名、太多段）。不展开 glob，
/// 所以参数太多（展开之后才知道）要到执行到那里时才发现。变量照常展开：没有副作用。
fn checkSyntax(src: []const u8) ParseError!void {
    check_only = true;
    defer check_only = false;
    var pos: usize = 0;
    var after: End = .line;
    while (true) {
        const stages, const end = try parsePipeline(src, &pos);
        if (stages.len == 0) {
            if (after == .and_if or after == .or_if) return error.EmptyCommand; // `ls &&`
            return;
        }
        if (end == .line) return;
        after = end;
    }
}

/// checkSyntax 期间：不展开 glob
var check_only = false;

fn parseFailed(err: ParseError) void {
    sys.print("sh: {s}\n", .{switch (err) {
        error.UnterminatedQuote => "unterminated quote",
        error.BadSubstitution => "bad substitution (${NAME})",
        error.LineTooLong => "line too long after expansion",
        error.EmptyCommand => "empty command",
        error.TooManyArguments => std.fmt.comptimePrint("too many arguments (at most {d})", .{abi.max_args}),
        error.TooManyStages => std.fmt.comptimePrint("too many programs in the pipeline (at most {d})", .{max_stages}),
        error.MissingFileName => "missing file name after < or >",
    }});
    status = 2;
}

/// 运行一个管道，设好 $?。开头的 `time` 量运行时间，`run` 表示一定是程序（不当内置命令；`run` 单独一个时列出程序）。
fn runPipeline(stages: []Stage, background: bool) void {
    const first = &stages[0];
    var timed = false;
    var explicit = false;
    while (first.argc > 0) {
        if (!timed and std.mem.eql(u8, first.name(), "time")) {
            timed = true;
        } else if (!explicit and std.mem.eql(u8, first.name(), "run")) {
            explicit = true;
        } else break;
        first.shift();
    }
    if (first.argc == 0) {
        if (explicit and stages.len == 1) {
            listPrograms();
            status = 0;
        } else {
            parseFailed(error.EmptyCommand);
        }
        return;
    }
    const start = sys.uptime();
    status = runStages(stages, background, explicit);
    if (timed) {
        const ms = sys.uptime() - start;
        sys.print("real {d}.{d:0>2}s\n", .{ ms / 1000, ms % 1000 / 10 });
    }
}

fn runStages(stages: []Stage, background: bool, explicit: bool) u8 {
    if (!explicit and stages.len == 1 and !background) {
        const st = &stages[0];
        // 只有 NAME=值：设变量
        if (assignment(st.name()) != null and st.in == null and st.out == null) {
            for (st.argv()) |w| {
                const eq = assignment(w) orelse {
                    sys.print("sh: {s}: only NAME=VALUE words can follow an assignment\n", .{w});
                    return 1;
                };
                setVar(w[0..eq], w[eq + 1 ..]) catch |err| {
                    sys.print("sh: {s}: {s}\n", .{ w[0..eq], @errorName(err) });
                    return 1;
                };
            }
            return 0;
        }
        // 内置命令在 shell 自己里运行（cd、exit 这些只有这样才有用），重定向之后再换回来
        if (builtinOf(st.name())) |b| return runBuiltinHere(b, st);
    }
    for (stages) |*st| {
        if (!explicit and builtinOf(st.name()) != null) continue;
        if (!programExists(st.name())) {
            if (explicit) {
                sys.print("no such program: {s}\n", .{st.name()});
                listPrograms();
            } else {
                sys.print("unknown command: {s} (try 'help')\n", .{st.name()});
            }
            return 127;
        }
    }
    // 只有一个命令时子进程直接 exec 成它；管道由一个子进程（“组长”）去建，见 runLeader
    const pid = sys.fork() catch |err| {
        forkFailed(err);
        return 1;
    };
    if (pid == 0) {
        // 前台的话子进程自己先登记成前台进程，再 exec：父进程的 setfg 可能晚于子进程开始运行
        // （fork 之后先调度谁不一定），那样程序刚开始运行时按的 Ctrl-C 就没人管了
        if (!background) sys.setfg(sys.getpid()) catch {};
        if (script_fd) |fd| sys.close(fd) catch {};
        if (stages.len == 1) {
            redirect(&stages[0], null) catch sys.exit(1);
            execStage(&stages[0], explicit);
        }
        sys.exit(runLeader(stages, explicit));
    }
    const what = if (stages.len == 1) stages[0].name() else "pipeline";
    if (background) {
        sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, what });
        last_bg = pid;
        return 0;
    }
    // 前台：按 Ctrl-C 时内核杀掉它（和它的子孙，也就是管道里的各个程序）。等它结束、回收之后再打印提示符
    sys.setfg(pid) catch {};
    const r = sys.wait(pid, false) catch null;
    sys.setfg(null) catch {};
    return exitCode(if (r) |x| x.status else 1);
}

/// wait 给的结束状态换成退出码：被杀了是 255。
fn exitCode(s: u32) u8 {
    return if (s > 255) 255 else @intCast(s);
}

fn forkFailed(err: sys.Error) void {
    switch (err) {
        error.TooManyProcesses => sys.print("sh: too many processes (at most {d})\n", .{abi.max_procs}),
        else => sys.print("sh: cannot fork: {s}\n", .{@errorName(err)}),
    }
}

/// 按 `<`、`>`、`>>` 换掉标准输入、标准输出（`>`、`>>` 的文件没有就建；`>` 截成 0 字节，`>>` 每次写都写在末尾）。
/// saved 不为 null 时（内置命令在 shell 自己里运行），先把原来的 fd dup 一份存起来，用完由 restore 换回去。
/// 打不开就说明原因、返回错误。
fn redirect(st: *const Stage, saved: ?*[2]?sys.Fd) error{Failed}!void {
    if (st.in) |path| try replaceFd(sys.stdin, path, .{}, saved);
    if (st.out) |path| try replaceFd(sys.stdout, path, .{ .read = false, .write = true, .create = true, .truncate = !st.append, .append = st.append }, saved);
}

fn replaceFd(target: sys.Fd, path: []const u8, flags: sys.OpenFlags, saved: ?*[2]?sys.Fd) error{Failed}!void {
    const fd = sys.open(path, flags) catch |err| {
        sys.print("sh: {s}: {s}\n", .{ path, @errorName(err) });
        return error.Failed;
    };
    if (saved) |s| s[target] = sys.dup(target) catch null;
    // close 再 dup：dup 返回最小的空闲 fd，正好是刚关掉的那个
    sys.close(target) catch {};
    _ = sys.dup(fd) catch {};
    sys.close(fd) catch {};
}

/// 把 redirect 存起来的 fd 换回去：从小到大，dup 返回的最小空闲 fd 就是刚关掉的那个。
fn restore(saved: *[2]?sys.Fd) void {
    for (saved, 0..) |s, target| {
        const fd = s orelse continue;
        sys.close(target) catch {};
        _ = sys.dup(fd) catch {};
        sys.close(fd) catch {};
    }
}

/// 在子进程里换成要运行的程序（或者运行内置命令再结束）。exec 失败时（比如 ELF 不合法）说明原因，以 127 结束。
fn execStage(st: *const Stage, explicit: bool) noreturn {
    if (!explicit) if (builtinOf(st.name())) |b| sys.exit(runBuiltin(b, st.argv()));
    sys.exec(st.name(), st.argv()) catch |err| sys.print("sh: cannot load {s}: {s}\n", .{ st.name(), @errorName(err) });
    sys.exit(127);
}

/// 管道的“组长”（shell fork 出来的子进程，和 xv6 的 sh 一样）：依次 fork 出每个程序，
/// 第 i 个程序的标准输出接到一个新管道的写端，第 i+1 个程序的标准输入接到它的读端，然后等它们全部结束。
/// 返回最后一个程序的退出码（被杀了是 255），出错时是 1。
///
/// 各个程序都是组长的子进程，shell 把组长设为前台进程，按 Ctrl-C 时内核把组长和它们一起杀掉。
/// 组长自己必须关掉管道的两端：写端还开着的话，后面的程序永远读不到结尾。
fn runLeader(stages: []Stage, explicit: bool) u8 {
    var prev: ?sys.Fd = null; // 上一个程序输出的管道的读端
    var started: usize = 0;
    var last: usize = 0;
    var failed = false;
    for (stages, 0..) |*st, i| {
        const is_last = i == stages.len - 1;
        var p: [2]sys.Fd = undefined;
        if (!is_last) p = sys.pipe() catch |err| {
            sys.print("sh: cannot create a pipe: {s}\n", .{@errorName(err)});
            failed = true;
            break;
        };
        const pid = sys.fork() catch |err| {
            forkFailed(err);
            if (!is_last) {
                sys.close(p[0]) catch {};
                sys.close(p[1]) catch {};
            }
            failed = true;
            break;
        };
        if (pid == 0) {
            // close 再 dup：dup 返回最小的空闲 fd，正好是刚关掉的 0 或 1
            if (prev) |fd| {
                sys.close(sys.stdin) catch {};
                _ = sys.dup(fd) catch {};
                sys.close(fd) catch {};
            }
            if (!is_last) {
                sys.close(sys.stdout) catch {};
                _ = sys.dup(p[1]) catch {};
                sys.close(p[0]) catch {};
                sys.close(p[1]) catch {};
            }
            redirect(st, null) catch sys.exit(1); // 重定向优先于管道（和 Unix 的 sh 一样）
            execStage(st, explicit);
        }
        started += 1;
        last = pid;
        if (prev) |fd| sys.close(fd) catch {};
        prev = null;
        if (!is_last) {
            sys.close(p[1]) catch {};
            prev = p[0];
        }
    }
    if (prev) |fd| sys.close(fd) catch {};
    var code: u8 = 1;
    for (0..started) |_| {
        const r = (sys.wait(null, false) catch break) orelse break;
        if (r.pid == last and !failed) code = exitCode(r.status);
    }
    return code;
}

/// 程序文件在不在。和内核的 exec 一样：名字里没有 '/' 的在 /bin 里找，有的按路径找（跟着符号链接走）。
fn programExists(name: []const u8) bool {
    var buf: [abi.max_path]u8 = undefined;
    const path = if (std.mem.indexOfScalar(u8, name, '/') != null)
        name
    else
        std.fmt.bufPrint(&buf, "/bin/{s}", .{name}) catch return false;
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return st.kind == .file;
}

fn isDir(path: []const u8) bool {
    const fd = sys.open(path, .{}) catch return false;
    defer sys.close(fd) catch {};
    const st = sys.fstat(fd) catch return false;
    return st.kind == .dir;
}

/// 列出 /bin 里的程序，按名字排序（readdir 给的是名字的散列的顺序）。
fn listPrograms() void {
    resetNames();
    addDirNames("/bin", "/bin/", .{ .prefix = "" });
    sortNames();
    sys.print("programs:", .{});
    for (names[0..name_count]) |name| sys.print(" {s}", .{name});
    sys.print("\n", .{});
}

// ---- 内置命令 ----

const Builtin = enum { help, cd, pwd, uptime, mem, disk, ps, jobs, kill, wait, history, set, unset, true, false, exit, shutdown };

fn builtinOf(name: []const u8) ?Builtin {
    return std.meta.stringToEnum(Builtin, name);
}

/// 在 shell 自己里运行内置命令：有重定向的话先换掉标准输入输出，运行完再换回来。
fn runBuiltinHere(b: Builtin, st: *const Stage) u8 {
    var saved: [2]?sys.Fd = .{ null, null };
    defer restore(&saved);
    redirect(st, &saved) catch return 1;
    return runBuiltin(b, st.argv());
}

fn runBuiltin(b: Builtin, args: []const []const u8) u8 {
    const arg1: ?[]const u8 = if (args.len > 1) args[1] else null;
    switch (b) {
        .help => sys.print(
            \\builtin commands:
            \\help          show this message
            \\cd [DIR]      change the current directory (default: /; cd -: the previous one)
            \\pwd           print the current directory
            \\uptime        time since boot
            \\mem           free physical pages
            \\disk          size of the raw disk area (the blocks after the file system)
            \\ps            list processes
            \\jobs          list the background processes started by this shell
            \\kill PID...   kill processes
            \\wait [PID]    wait for a background process (default: all of them)
            \\history       list the last commands (up/down arrows recall them, Tab completes names)
            \\set           list the variables (NAME=VALUE sets one, unset NAME... removes them)
            \\true, false   exit with 0, 1
            \\exit [N]      exit the shell with status N (init starts a new one)
            \\shutdown      power off through SBI
            \\running programs:
            \\NAME [ARGS...], run NAME [ARGS...]
            \\              run a user program and wait for it (run alone: list them)
            \\A | B         run A and B with A's output piped into B (up to 8 programs)
            \\... > F       write the output to file F (>> F: append to it; < F: read input from F)
            \\... &         run it in the background ($! is its pid)
            \\A ; B         run A, then B (A && B: B only if A succeeded; A || B: only if A failed)
            \\time A        run A and print how long it took
            \\'...' "..." \ quote spaces and special characters ($VAR still expands inside "...")
            \\$NAME $? $$   a variable, the status of the last command, the shell's pid
            \\*, ?          match file names (in the last part of a path)
            \\sh FILE [ARGS...], sh -c COMMANDS
            \\              run the commands in FILE ($1, $2... are ARGS), or COMMANDS
            \\
        , .{}),
        .uptime => {
            const ms = sys.uptime();
            sys.print("up {d}.{d:0>2}s\n", .{ ms / 1000, ms % 1000 / 10 });
        },
        .mem => {
            const m = sys.meminfo();
            sys.print("{d} of {d} pages free ({d} KiB), {d} KiB each\n", .{
                m.free_pages, m.total_pages, m.free_pages * m.page_size / 1024, m.page_size / 1024,
            });
        },
        .disk => {
            const n = sys.blockCount();
            if (n == 0) {
                sys.print("no disk\n", .{});
            } else {
                sys.print("{d} blocks of {d} KiB ({d} MiB)\n", .{ n, sys.block_size / 1024, n * sys.block_size >> 20 });
            }
        },
        .cd => return cd(args),
        .pwd => {
            var buf: [abi.max_path]u8 = undefined;
            const cwd = sys.getcwd(&buf) catch |err| {
                sys.print("pwd: {s}\n", .{@errorName(err)});
                return 1;
            };
            sys.print("{s}\n", .{cwd});
        },
        .ps => ps(false),
        .jobs => ps(true),
        .kill => return kill(args),
        .wait => return wait(arg1),
        .history => {
            for (hist_count -| hist_max..hist_count) |i| sys.print("{d:>4}  {s}\n", .{ i + 1, histAt(i) });
        },
        .set => {
            if (args.len > 1) {
                sys.print("usage: set (NAME=VALUE sets a variable)\n", .{});
                return 1;
            }
            for (vars[0..var_count]) |*v| sys.print("{s}={s}\n", .{ v.name[0..v.name_len], v.value[0..v.value_len] });
        },
        .unset => for (args[1..]) |name| unsetVar(name),
        .true => {},
        .false => return 1,
        .exit => {
            const code = if (arg1) |a| std.fmt.parseInt(u8, a, 10) catch {
                sys.print("usage: exit [N] (N is 0..255)\n", .{});
                return 2;
            } else status;
            sys.exit(code);
        },
        .shutdown => {
            sys.print("bye!\n", .{});
            sys.shutdown();
        },
    }
    return 0;
}

/// cd [DIR]：不给 DIR 回到 /，`cd -` 回到上一个目录（并打印它）。成功之后记下原来的目录给 cd - 用。
fn cd(args: []const []const u8) u8 {
    if (args.len > 2) {
        sys.print("usage: cd [DIR]\n", .{});
        return 1;
    }
    var dir: []const u8 = if (args.len > 1) args[1] else "/";
    var target: [abi.max_path]u8 = undefined;
    if (std.mem.eql(u8, dir, "-")) {
        if (prev_dir_len == 0) {
            sys.print("cd: no previous directory\n", .{});
            return 1;
        }
        @memcpy(target[0..prev_dir_len], prev_dir[0..prev_dir_len]);
        dir = target[0..prev_dir_len];
    }
    var here: [abi.max_path]u8 = undefined;
    const old = sys.getcwd(&here) catch "";
    sys.chdir(dir) catch |err| {
        sys.print("cd: {s}: {s}\n", .{ dir, @errorName(err) });
        return 1;
    };
    @memcpy(prev_dir[0..old.len], old);
    prev_dir_len = old.len;
    if (args.len > 1 and std.mem.eql(u8, args[1], "-")) sys.print("{s}\n", .{dir});
    return 0;
}

/// 列出进程（procinfo）。only_children 时只列这个 shell 的还没结束的子进程（jobs：后台进程）。
fn ps(only_children: bool) void {
    var buf: [abi.max_procs]abi.ProcInfo = undefined;
    const n = @min(sys.procinfo(&buf), buf.len);
    const me = sys.getpid();
    if (!only_children) sys.print("  PID  PPID STATE     TICKS NAME\n", .{});
    for (buf[0..n]) |p| {
        if (only_children) {
            if (p.ppid != me or p.state == .zombie) continue;
            sys.print("[{d}] {s:<8} {s}\n", .{ p.pid, @tagName(p.state), p.name[0..p.name_len] });
        } else {
            sys.print("{d:>5} {d:>5} {s:<8} {d:>6} {s}\n", .{ p.pid, p.ppid, @tagName(p.state), p.ticks, p.name[0..p.name_len] });
        }
    }
}

fn kill(args: []const []const u8) u8 {
    if (args.len < 2) {
        sys.print("usage: kill PID...\n", .{});
        return 1;
    }
    var code: u8 = 0;
    for (args[1..]) |a| {
        const pid = std.fmt.parseInt(usize, a, 10) catch {
            sys.print("usage: kill PID...\n", .{});
            code = 1;
            continue;
        };
        sys.kill(pid) catch |err| {
            switch (err) {
                error.NoSuchProcess => sys.print("kill: no such process: {d}\n", .{pid}),
                error.PermissionDenied => sys.print("kill: cannot kill pid {d}: permission denied\n", .{pid}),
                else => sys.print("kill: {s}\n", .{@errorName(err)}),
            }
            code = 1;
            continue;
        };
        // kill 只做标记。是自己的子进程（后台进程）的话，等它真的结束、回收它，
        // 这样“killed”那一行在下一个提示符之前。不是自己的子进程时 wait 立刻返回 NoChildren
        _ = sys.wait(pid, false) catch {};
    }
    return code;
}

/// wait [PID]：等后台进程 PID 结束，退出码就是它的；不给 PID 时等所有子进程结束。
fn wait(arg: ?[]const u8) u8 {
    const a = arg orelse {
        while (sys.wait(null, false) catch null) |_| {}
        return 0;
    };
    const pid = std.fmt.parseInt(usize, a, 10) catch {
        sys.print("usage: wait [PID]\n", .{});
        return 2;
    };
    const r = sys.wait(pid, false) catch {
        sys.print("wait: pid {d} is not a child of this shell\n", .{pid});
        return 127;
    };
    return exitCode(if (r) |x| x.status else 0);
}
