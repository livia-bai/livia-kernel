# shell

涉及文件：`user/sh.zig`（由 `user/init.zig` 启动，[user-programs.md](user-programs.md#init-和-sh)）

一个小的命令行：读一行，执行，再读下一行。它是一个**普通的用户程序**，运行在 U 模式，和 xv6 的 `user/sh.c` 一样，内核的功能都通过系统调用使用（[syscalls.md](syscalls.md)）：

| shell 做的事 | 用到的系统调用 |
| --- | --- |
| 读键盘、回显、行编辑 | `read`、`write`（0、1 号 fd，都是串口） |
| 运行程序（带参数） | `fork`、`exec`、`wait` |
| 管道 | `pipe`、`close`、`dup` |
| 重定向 `<`、`>`、`>>` | `open`、`close`、`dup` |
| `cd`、`pwd`、`cd -` | `chdir`、`getcwd` |
| 前台程序和 Ctrl-C | `setfg` |
| `ps`、`jobs`、`mem`、`uptime` | `procinfo`、`meminfo`、`uptime` |
| 检查程序在不在、列出 `/bin`、glob、Tab 补全 | `open`、`fstat`、`readdir` |
| `kill`、`wait`、`exit`、`shutdown` | `kill`、`wait`、`exit`、`shutdown` |
| 判断标准输入是不是串口（交互还是脚本） | `fstat` |

主循环（交互时）：

```zig
sys.print("Type 'help' for commands.\n", .{});
while (true) {
    reapBackground();
    sys.print("> ", .{});
    const l = readLine();
    addHistory(l);
    execute(l);
}
```

## 三种运行方式

`main` 看命令行参数和标准输入：

| 怎么启动 | 做什么 | `$0`、`$1`... |
| --- | --- | --- |
| `sh`，标准输入是串口（init 启动的就是这样） | 交互：打印提示符 `> `，自己回显、行编辑 | `$0` 是 `sh`，没有 `$1` |
| `sh 文件 [参数...]` | 打开文件，一行一行地执行，读完了以最后一个命令的退出码结束 | `$0` 是文件名，`$1`... 是参数 |
| `sh -c 命令 [名字 [参数...]]` | 只执行这一行 | 和 Unix 的 `sh -c` 一样：`$0` 是名字（没有就是 `sh`），`$1`... 是参数 |
| `sh`，标准输入不是串口（`sh < 文件`、`echo ... \| sh`） | 从标准输入一行一行地读命令执行，不打印提示符 | `$0` 是 `sh` |

“是不是串口”用 `fstat(0)` 看：种类是 `console`（init 打开的串口），或者设备号是 1 的设备文件（`/dev/console`）。

脚本（不是交互时）：
- 从文件读用一个 1 KiB 的缓冲区，按 `\n` 分行，去掉行尾的 `\r`；超过 512 字节的行打印 `sh: line too long (at most 512 bytes)`，当作空行。最后一行没有 `\n` 也执行。
- 每一行之前也回收结束了的后台进程。
- `sh 文件` 打开的那个 fd 在 `fork` 出来运行程序的子进程里先关掉，不留给程序。
- 脚本里出错（语法错误、找不到的程序）只是这一行不执行或者 `$?` 不是 0，接着执行下一行；`exit` 结束整个脚本。
- 脚本在子进程里运行，它的 `cd`、变量不影响交互的 shell。

## 输入处理（交互时）

`read` 系统调用不回显、不做行编辑（[syscalls.md](syscalls.md#read)），这些都由 shell 自己做。`readLine` 每次 `read` 一个字节：

| 字符 | 处理 |
| --- | --- |
| `\r` 或 `\n` | 换行，返回这一行 |
| `0x08`（Backspace）或 `0x7f`（Delete） | 行不为空时删掉最后一个字符，并输出 `\x08 \x08`（光标左移、用空格盖掉、再左移） |
| Ctrl-U（`0x15`） | 清掉整行（对每个字符输出一次 `\x08 \x08`） |
| `ESC [ A`、`ESC [ B`（上、下方向键） | 翻历史：把这一行换成上一条、下一条命令；下翻过最新的一条是空行 |
| Tab | 补全（[Tab 补全](#tab-补全)） |
| 可打印字符 `' '..'~'` | 行没满（512 字节）时追加并回显；满了就忽略 |
| 其他（别的转义序列、Ctrl-D） | 忽略。`ESC [` 之后一直读到 0x40..0x7e 之间的结束字节（比如 Delete 键是 `ESC [ 3 ~`），整个序列丢掉。Ctrl-D 单独按时 `read` 返回 0，也忽略 |

- 终端（QEMU `-nographic` 下就是你的终端）处于原始模式，按回车发送的是 `\r`，方向键发送的是 `ESC [ A` 这样的序列。
- 只能在行末编辑，左右方向键不移动光标（被忽略）。
- Ctrl-C 不会被读到：内核在串口中断里就把它截下了（[process.md](process.md#ctrl-c)）。
- 缓冲区为空时 `read` 在内核里睡着，不占 CPU，串口中断叫醒它。
- 前台程序运行期间 shell 在 `wait` 里睡着，不读键盘，这期间敲的字符留在内核的输入缓冲区里，程序结束后 shell 才读到、回显、执行。（如果前台程序自己调用 `read`，字符就被它读走了。）

**历史**：最近 16 行存在一个全局的环形数组里（每行 512 字节，共 8 KiB）。空行、和上一条一样的不记。翻历史的位置从“正在编辑的新行”开始，每次 `readLine` 重新开始。`history` 列出它们，编号从这个 shell 启动开始算（shell 重新启动之后历史就没了）。

### Tab 补全

按 Tab 时补全光标前的那个词（从最后一个空格或 `|;&<>` 之后开始）：

- 词在**命令名的位置**（行首，或者 `|`、`;`、`&` 后面）并且不含 `/`：候选是内置命令、`run`、`time` 和 `/bin` 里的程序。
- 否则按**路径**补全：词里最后一个 `/` 之前是目录（没有就是当前目录），之后是名字的开头，候选是那个目录里以它开头的名字（以 `.` 开头的名字只有输入了 `.` 才算）。
- 只有一个候选：补全它，目录（包括指向目录的符号链接）后面加 `/`，别的加空格。
- 几个候选并且有比输入的更长的公共前缀：补到公共前缀。比如 `he` 有 `help`、`hello` 两个候选，补成 `hel`。
- 否则把候选按名字排序列在下一行（两个空格隔开），再重新打印 `> ` 和这一行，接着编辑。
- 含引号、`\`、`$`、`*`、`?` 的词不补全。

## 一行命令怎么执行

```zig
fn execute(src: []const u8) void {
    checkSyntax(src) catch |err| return parseFailed(err);   // 先整行检查一遍
    while (true) {
        const stages, const end = parsePipeline(src, &pos) ...;   // 解析一个管道，展开好变量、glob
        if (run_next) runPipeline(stages, end == .amp);
        run_next = switch (end) { .line => return, .semi, .amp => true,
                                  .and_if => status == 0, .or_if => status != 0 };
    }
}
```

一行是用 `;`、`&`、`&&`、`||` 隔开的几个**管道**，每个管道是用 `|` 隔开的几个**命令**。

- **先检查整行的语法**（`checkSyntax`）：把每个管道解析一遍但不执行（也不展开 glob）。引号没配对、空的命令、`>` 后面没有文件名、管道超过 8 段这些错误在执行任何命令之前就发现，整行都不执行，`$?` 是 2。参数太多要展开 glob 之后才知道，所以到执行那个管道时才发现（前面的已经执行了）。
- **一次解析、执行一个管道**：变量在解析时展开，所以 `X=1; echo $X` 里的 `$X` 已经是 1；glob 也在这时展开，前面的命令建的文件后面匹配得到。`parsePipeline` 每次从头用一个 4 KiB 的全局缓冲区（`word_buf`）放展开好的词，命令（`Stage`）也在一个全局数组里，不占栈。
- `A ; B`：执行 A，再执行 B。`A & B`：A 在后台运行，马上执行 B。
- `A && B` 只有 A 成功（退出码 0）才执行 B，`A || B` 只有 A 失败才执行。跳过的管道不改 `$?`，所以 `false && x || y` 执行 y，`true || x && y` 也执行 y（和 sh 一样，从左到右，没有优先级）。

### 词法（`lex`）

从当前位置取下一个记号：跳过空格和 Tab；`#` 开头的是注释，直到行尾；然后是运算符，或者一个词。

| 运算符 | 意思 |
| --- | --- |
| `\|`、`\|\|` | 管道、或 |
| `&`、`&&` | 后台、且 |
| `;` | 顺序执行 |
| `<`、`>`、`>>` | 重定向 |

运算符不用空格隔开：`echo hi|wc`、`echo three>>/log`（`three` 是参数，`>>` 是重定向）、`spin&` 都可以。

一个词到空格、Tab 或者运算符的字符为止，中间可以有：

| 写法 | 结果 |
| --- | --- |
| `'...'` | 原样，什么都不展开，直到下一个 `'` |
| `"..."` | 展开 `$` 变量；`\` 只转义 `"`、`\`、`$`，别的 `\` 原样留着 |
| `\x` | 字符 `x` 本身（空格、运算符、引号、`$` 都可以这样写进词里） |
| `$...` | 变量（[变量](#变量)） |
| `*`、`?` | 不在引号里的话，这个词按文件名展开（[glob](#文件名匹配glob)） |

几段可以连在一起：`'it''s'` 是 `its`，`a"b c"d` 是 `ab cd`。引号没配对打印 `sh: unterminated quote`。

**变量展开之后不再按空格拆开**（bash 会拆，zsh 不拆）：`X='a b'; echo $X` 给 `echo` 的是一个参数 `a b`。不在引号里的变量展开成空的，这个词就不算（`echo $NOPE x` 只有一个参数 `x`）；`""` 是一个空的参数。

### 变量

| 写法 | 值 |
| --- | --- |
| `$?` | 上一个命令的退出码（[退出码](#退出码)） |
| `$$` | shell 自己的 pid |
| `$!` | 最后一个后台进程（或管道的组长）的 pid，没有是 0 |
| `$#` | 位置参数的个数（不算 `$0`） |
| `$0`..`$9` | 位置参数（[三种运行方式](#三种运行方式)），没有的是空的 |
| `$NAME`、`${NAME}` | shell 变量，没有的是空的。名字是字母、数字、`_`，不以数字开头；`${` 后面不是名字或者没有 `}` 打印 `sh: bad substitution (${NAME})` |
| 别的 `$`（比如行尾的 `$`、`$-`） | 原样留着 |

- 一个命令的所有词都是 `NAME=值` 时，设这些变量（`A=1 B=2`）；第一个词是 `NAME=值`、后面却不是的（`A=1 echo`，sh 里是给这个命令设环境变量）打印 `sh: echo: only NAME=VALUE words can follow an assignment`：没有环境变量，变量不传给程序。
- `set` 列出所有变量（`NAME=值`），`unset NAME...` 删掉。最多 32 个变量，名字最长 32 字节，值最长 256 字节。

### 文件名匹配（glob）

不在引号里的 `*`（任意多个字符，包括没有）、`?`（一个字符）让这个词按文件名展开：

- 只有路径的**最后一段**能有它们：`/bin/t_*` 可以，`/*/x` 不展开。最后一个 `/` 之前原样用作目录（没有就是当前目录），`readdir` 列出来，匹配的名字按名字排序，每个变成 `目录/名字` 一个参数。
- 以 `.` 开头的名字只有模式也以 `.` 开头才匹配。
- 一个都没匹配到：词原样留着（`echo /bin/zz*` 打印 `/bin/zz*`，和 sh 一样）。
- 匹配用回溯到上一个 `*` 的做法（`globMatch`），最坏 O(模式长 × 名字长)。
- 一个词里只要有不在引号里的 `*` 或 `?`，整个词都按模式匹配：`'*'x*` 里引号中的 `*` 也算通配符。

### 解析一个管道（`parsePipeline`）

```zig
const Stage = struct {
    args: [abi.max_args][]const u8,  // 程序名（或内置命令）和参数
    argc: usize,
    in: ?[]const u8,                  // < 文件
    out: ?[]const u8,                 // > 文件、>> 文件
    append: bool,                     // out 是 >> 给的
};
```

- 词加进当前命令的参数；`<`、`>`、`>>` 后面的那个词是文件名，不是参数；`|` 开始下一个命令。
- `|` 前面没有命令（`| wc`、`echo a | | wc`）、`|` 后面没有（`echo a |`）、只有重定向没有命令（`> f`）、`;` 前面什么都没有（`; ls`）、`&&` 后面什么都没有（`ls &&`）都打印 `sh: empty command`。
- 一个命令超过 32 个参数（`abi.max_args`）打印 `sh: too many arguments (at most 32)`；超过 8 个命令打印 `sh: too many programs in the pipeline (at most 8)`；`<`、`>` 后面没有文件名打印 `sh: missing file name after < or >`；展开之后超过 4 KiB 打印 `sh: line too long after expansion`。

## 运行一个管道

```zig
fn runPipeline(stages: []Stage, background: bool) void {
    // 去掉第一个命令开头的 time、run
    ...
    status = runStages(stages, background, explicit);
    if (timed) sys.print("real {d}.{d:0>2}s\n", ...);
}
```

- 第一个命令开头的 **`time`**：运行完打印 `real 0.03s`（`uptime` 的差）。
- 开头的 **`run`**：后面一定是程序，不当内置命令（`/bin` 里要是有个叫 `kill` 的程序，写 `run kill` 才能运行它）；找不到时打印 `no such program: NAME` 和程序列表（不写 `run` 时打印 `unknown command: NAME (try 'help')`）。`run` 单独一个时列出 `/bin` 里的程序。
- 只有一个命令、在前台、不是 `run`：全是 `NAME=值` 的话设变量；是内置命令的话在 shell 自己里运行（[内置命令](#内置命令)）。
- 别的情况（程序，或者在管道里、在后台的内置命令）`fork`：内置命令在子进程里运行完以它的退出码结束，程序 `exec`。先确认每个程序都有（`programExists`：和内核的 `exec` 一样，名字里没有 `/` 的看 `/bin/名字`，有的按路径看，要能打开、是文件），没有就报错、`$?` 是 127，不 `fork`。

### 前台和后台

```zig
const pid = sys.fork() catch |err| { forkFailed(err); return 1; };
if (pid == 0) {
    if (!background) sys.setfg(sys.getpid()) catch {};
    if (script_fd) |fd| sys.close(fd) catch {};
    if (stages.len == 1) {
        redirect(&stages[0], null) catch sys.exit(1);
        execStage(&stages[0], explicit);   // 内置命令：运行完 exit；程序：exec
    }
    sys.exit(runLeader(stages, explicit)); // 管道：这个子进程当“组长”
}
if (background) {
    sys.print("[proc] pid {d} ({s}) started in the background\n", .{ pid, what });
    last_bg = pid;
    return 0;
}
sys.setfg(pid) catch {};
const r = sys.wait(pid, false) catch null;
sys.setfg(null) catch {};
return exitCode(...);
```

- `exec` 失败（比如 ELF 不合法）时，子进程打印 `sh: cannot load NAME: BadElf`（或 `OutOfMemory`）并以 127 结束；这时它还是 shell 的副本，内核打印的名字是 `sh`。进程表满了打印 `sh: too many processes (at most 64)`（`fork` 返回 `TooManyProcesses`；64 是 `abi.max_procs`，其中 init 和 shell 占两个）。
- **前台**：`setfg(pid)` 告诉内核按 Ctrl-C 时杀掉它（和它的子孙），然后 `wait(pid)` 睡着等它结束、回收它，再 `setfg(null)`。子进程在 `exec` 之前也先 `setfg(自己的 pid)`：`fork` 之后先运行父进程还是子进程不一定，只靠父进程登记的话，子进程可能已经开始运行、等着输入了，父进程还没来得及 `setfg`，这时按的 Ctrl-C 没人管。QEMU 测试在 Debug 模式下碰到过一次：`t_read` 打印了 `reading`，测试马上按 Ctrl-C，结果没有任何反应。所以输出顺序是：程序的输出、`[proc] ... exited ...`，然后才是 `> `。
- **后台**（`... &`）：打印 `[proc] pid N (NAME) started in the background`（管道是 `(pipeline)`）后马上接着执行（`$!` 是它的 pid，`$?` 是 0）。它的输出和 shell 的输出会交错在一起；没有作业控制（不能切到前台），只能 `wait`、`kill` 它。后台进程和 shell 谁先运行取决于调度（多核时它们同时运行），所以程序的第一行输出可能出现在 `started in the background` 前面；紧接着 `ps`、`jobs` 的话，还可能看到它还没 `exec`，名字仍然是 `sh`。每次 `print` 是一次 `write`，内核整段输出，所以两边的输出只会按行交错，不会插进一行的中间。
- **回收后台进程**：每次打印提示符（脚本里是每一行）之前，`reapBackground` 用 `wait(null, nohang)` 把已经结束的子进程都回收掉。它们的结束信息内核已经打印过了；不回收的话会一直是 zombie，占着进程表的槽位。

### 退出码

`$?` 是上一个执行了的管道的退出码：

| 情况 | `$?` |
| --- | --- |
| 前台程序正常结束 | 它的退出码 |
| 前台程序被杀（Ctrl-C、`kill`） | 255（`wait` 给的状态是 `killed_status`，`exitCode` 换成 255） |
| 管道 | 最后一个程序的退出码（组长以它结束）；组长 `pipe`、`fork` 失败是 1 |
| 后台运行 | 0 |
| 内置命令 | 它返回的（`false` 是 1，用法不对是 1 或 2） |
| 找不到的程序 | 127 |
| `exec` 失败 | 127（子进程以 127 结束） |
| 重定向的文件打不开 | 1 |
| 语法错误 | 2 |

### 管道

`A | B | C`：A 的标准输出接到 B 的标准输入，B 的接到 C 的，最多 8 个命令（`max_stages`；进程表有 64 个槽位，init、shell、组长占三个）。和 xv6 的 `sh` 一样，shell 自己不建管道，而是 fork 一个子进程当**组长**（`runLeader`），由它来建：

```zig
for (stages, 0..) |*st, i| {
    if (!is_last) p = sys.pipe() ...;
    const pid = sys.fork() ...;
    if (pid == 0) {
        if (prev) |fd| { close(stdin); dup(fd); close(fd); }          // 标准输入换成上一个管道的读端
        if (!is_last) { close(stdout); dup(p[1]); close(p[0]); close(p[1]); }  // 标准输出换成这个管道的写端
        redirect(st, null) catch exit(1);
        execStage(st, explicit);
    }
    if (prev) |fd| close(fd);       // 组长自己不用的那一端都关掉
    if (!is_last) { close(p[1]); prev = p[0]; }
}
// 等所有程序结束，以最后一个程序的退出码结束
```

- **换标准输入输出靠 `close` 再 `dup`**：`dup` 返回编号最小的空闲 fd，刚关掉 0 号，`dup` 出来的就是 0 号（[syscalls.md](syscalls.md#closeduppipe)）。子进程 `exec` 之后打开的文件不变，新程序直接从 0 号读、往 1 号写，不知道自己在管道里。
- **用不着的一端都要关掉**，包括组长自己手里的：管道的写端只要还有一个开着，读的一方就读不到结尾。比如组长忘了关 `p[1]`，`echo hi | wc` 里 echo 结束了，wc 也永远等不到结尾。
- **为什么要组长**：Ctrl-C 只认一个前台进程（`setfg`），内核杀的是前台进程和它的子孙（[process.md](process.md#ctrl-c)）。所有程序都是组长的子进程，把组长设成前台进程，按一次 Ctrl-C 整条管道都结束了。组长是 shell `fork` 出来的，内核打印的名字是 `sh`：

  ```
  > run echo hello world | wc
  [proc] pid 60 (echo) exited with code 0
  1 2 12
  [proc] pid 61 (wc) exited with code 0
  [proc] pid 59 (sh) exited with code 0
  ```

  对 `run cat | wc` 按 Ctrl-C（cat 在等键盘，wc 在等 cat）：

  ```
  ^C
  [proc] pid 73 (sh) killed: interrupted by Ctrl-C
  [proc] pid 74 (cat) killed: interrupted by Ctrl-C
  [proc] pid 75 (wc) killed: interrupted by Ctrl-C
  ```

  组长被杀时 cat、wc 还没结束，它们被交给 init，由 init 回收。
- 内置命令也可以在管道里，在组长 `fork` 出来的子进程里运行：`pwd | wc` 打印 `1 1 2`。
- 前一个程序先结束：后一个程序读完管道里剩下的，读到结尾。后一个程序先结束：前一个程序再写就得到 `BrokenPipe`（`echo` 以 1 结束）。

### 重定向

`... > 文件` 把标准输出换成文件（没有就建，有就截成 0 字节），`... >> 文件` 也是，但不截断、每次写都写在文件末尾（`open_append`，[files.md](files.md#文件表)），`... < 文件` 把标准输入换成文件；在管道的哪一段都行（`echo a b c | cat >/p.txt`）。程序是在子进程里、`exec` 之前换（`redirect`）：

```zig
fn replaceFd(target: sys.Fd, path: []const u8, flags: sys.OpenFlags, saved: ?*[2]?sys.Fd) error{Failed}!void {
    const fd = sys.open(path, flags) catch |err| { print("sh: {s}: {s}\n", ...); return error.Failed; };
    if (saved) |s| s[target] = sys.dup(target) catch null;   // 内置命令：先存一份原来的
    sys.close(target) catch {};
    _ = sys.dup(fd) catch {};     // 编号最小的空闲 fd，就是刚关掉的 target
    sys.close(fd) catch {};
}
```

- `>` 用 `open(.{ .read = false, .write = true, .create = true, .truncate = true })`，`>>` 把 `.truncate` 换成 `.append = true`，`<` 用只读的 `open`。文件名跟着符号链接走，`> 悬空的链接` 建出它指向的文件（[fs.md](fs.md#符号链接)）。
- 管道里的一段同时有管道和重定向时，重定向在后面做，所以它优先（和 Unix 的 sh 一样）。
- 打不开（`cat < /nope`、`echo x > /bin`）时打印 `sh: /nope: NotFound`、`sh: /bin: IsDir`，以 1 结束，不运行程序。
- **内置命令在 shell 自己里运行时**（`pwd > f`）也能重定向：`redirect` 先把要换掉的 fd `dup` 一份存起来，运行完由 `restore` 换回去（从小到大 `close` 再 `dup`，`dup` 出来的就是刚关掉的那个）。
- 只认 `<`、`>`、`>>`，没有 `2>`、`2>&1`：程序的出错信息也是写到标准输出（`sys.print`）的。
- 例子：

  ```
  > echo hello file system > /hello.txt
  [proc] pid 4 (echo) exited with code 0
  > wc < /hello.txt
  1 3 18
  [proc] pid 5 (wc) exited with code 0
  ```

## 内置命令

| 命令 | 作用 | 输出示例 |
| --- | --- | --- |
| `help` | 列出命令和语法 | |
| `cd [DIR]` | 换 shell 的当前目录（`chdir`），之后启动的程序继承它；不给 `DIR` 时回到 `/`；`cd -` 回到上一个目录并打印它。出错时打印 `cd: DIR: NotFound`（或 `NotDir`、`SymlinkLoop`） | |
| `pwd` | 当前目录的绝对路径（`getcwd`）。经过符号链接 `cd` 进来的，是真实的路径（没有 bash 的“逻辑路径”） | `/bin` |
| `uptime` | 开机时长（`uptime` 系统调用） | `up 3.26s` |
| `mem` | 物理页的使用情况（`meminfo`，[page-allocator.md](page-allocator.md)） | `31492 of 31528 pages free (125968 KiB), 4 KiB each; 13 pages of programs cached`（空闲的页包括页缓存里没人映射着、随时可以丢掉的页） |
| `disk` | 磁盘的原始区域（文件系统之后的块）有多大（`blockcount`，[disk.md](disk.md#系统调用)）；没有磁盘时打印 `no disk` | `1024 blocks of 4 KiB (4 MiB)` |
| `ps` | 列出进程（`procinfo`）：pid、父进程、状态、用掉的 CPU 时间（毫秒）、名字 | 见下文 |
| `jobs` | 这个 shell 的还没结束的子进程（后台进程），从 `procinfo` 里按父进程挑出来 | `[19] running  spin` |
| `kill PID...` | 结束进程，可以给几个 | `[proc] pid 4 (spin) killed: kill()` |
| `wait [PID]` | 等后台进程 `PID` 结束并回收，`$?` 是它的退出码；不给时等所有子进程结束 | |
| `history` | 最近的 16 条命令 | `   3  echo hi` |
| `set` | 列出变量；`unset NAME...` 删掉变量 | `X=hello` |
| `true`、`false` | 以 0、1 结束 | |
| `exit [N]` | shell 以 `N`（不给时是 `$?`）结束；交互的 shell 结束之后 init 打印 `init: sh exited, restarting it`，再启动一个新的（历史、变量都没了） | |
| `shutdown` | 打印 `bye!`，通过 SBI 关机，QEMU 退出，退出码 0 | `bye!` |

说明：

- `uptime` 显示 `ms / 1000` 秒和 `ms % 1000 / 10` 百分之一秒（补零到两位），所以 `up 3.05s` 不会显示成 `3.5s`。内核给的是毫秒，只显示到百分之一秒。`time` 也是这样显示。
- `cd` 必须是 shell 自己的命令：子进程 `chdir` 改不了父进程的当前目录。所以内置命令只有在单独运行、前台时才在 shell 自己里运行；在管道里、后台的在子进程里运行，`cd`、`exit`、变量赋值这些就不起作用了（和 sh 一样）。
- `ps` 的输出（单核，一个后台的 `spin` 在死循环）：

  ```
    PID  PPID STATE    CPU_MS NAME
      1     0 sleeping      8 init
      2     1 running      10 sh
      3     2 running     494 spin
  ```

  `ps` 是 shell 执行的，所以 shell 自己总是 `running`；init 总在 `wait` 里睡着。单核时 shell 占着唯一的 hart，`spin` 只能是 `runnable`；多核时它在别的 hart 上跑，显示 `running`。`CPU_MS` 是进程用掉的 CPU 时间（毫秒，U 模式和内核里的都算：调度器切到它、它切回来时读 `time` 累加的，[process.md](process.md#schedyield)）。上面是 4 核时 `spin` 在后台转了约 0.5 秒。按槽位顺序列出，不一定按 pid 排序。结束了还没被回收的进程显示为 `zombie`。
- `kill PID`：没有参数、`PID` 不是数字时打印 `usage: kill PID...`，没有这个进程时打印 `kill: no such process: PID`，杀 init 打印 `kill: cannot kill pid 1: permission denied`；有一个失败 `$?` 就是 1。`kill` 系统调用只做标记（[process.md](process.md#kill只做标记)），所以 shell 接着 `wait(pid)`：是自己的子进程的话，等它真的结束、回收它，`killed: kill()` 那一行就在下一个提示符之前；不是自己的子进程时 `wait` 立刻返回 `NoChildren`。
- `kill` shell 自己（它的 pid）也可以：shell 结束，init 打印 `init: sh exited, restarting it` 并启动一个新的 shell。
- **列程序**（`run` 单独一个，`listPrograms`）：`readdir` 给的是名字的散列的顺序，shell 把名字收进全局的数组再排序。用的是插入排序：`std.mem.sort` 是块排序，栈上有一个 512 项的缓存（512 个切片，8 KiB），Debug 模式下把 shell 那时 16 KiB 的用户栈撑爆过（`store_page_fault`，`stval` 在保护页里，init 重启了 shell；现在用户栈最多 1 MiB）。glob、Tab 补全也用同一个数组和排序。
- 大的东西（行、历史、展开好的词、命令、变量、名字列表）都是全局变量，不放在用户栈上（以前用户栈只有 16 KiB；全局变量也是按需分配的，用到哪一页才占哪一页）。
- 文件操作是普通的用户程序：`ls [PATH...]`、`cat [FILE...]`、`mkdir DIR...`、`rm PATH...`、`mv OLD NEW`、`ln [-s] OLD NEW`、`cp`、`touch`、`scrub`（[user-programs.md](user-programs.md)）。
- shell 没有 `if`、`while`/`for`、算术和 `$(...)`。写脚本时用程序补上（[user-programs.md](user-programs.md#写脚本用的程序)）：条件用 `test`、`grep -q`、`expr` 的退出码配合 `&&`、`||`；循环用 `seq N | xargs -n 1 程序`（每个数运行一次，比如运行一个脚本 `sh 脚本`，数是 `$1`）；算术用 `expr`。

## 例子

```
> X=world; echo "hello, $X" 'and $X' a\ b
hello, world and $X a b
[proc] pid 3 (echo) exited with code 0
> false || echo failed $?
failed 1
[proc] pid 4 (echo) exited with code 0
> echo /bin/t_f*
/bin/t_fork /bin/t_fp /bin/t_fs /bin/t_fsmp
[proc] pid 9 (echo) exited with code 0
> cd /bin; pwd; cd -; pwd
/bin
/
/
> echo 'echo script $0 has $# args: $1 $2; cd /bin; pwd' > /s.sh
[proc] pid 3 (echo) exited with code 0
> sh /s.sh one "two three"
script /s.sh has 2 args: one two three
[proc] pid 5 (echo) exited with code 0
/bin
[proc] pid 4 (sh) exited with code 0
> time hello
Hello from U-mode! I am pid 18, the kernel has been up for 570 ms.
write() refused a kernel pointer: BadAddress
[proc] pid 18 (hello) exited with code 0
real 0.03s
> echo a &&
sh: empty command
```

（Debug 构建、单核，几次运行拼在一起，pid 不连续。）

## 添加内置命令

1. 在 `Builtin` 枚举里加一个名字（就是用户要输入的命令名；Tab 补全自动认得它）。
2. 在 `help` 的文本里加一行（按 14 列对齐）。
3. 在 `runBuiltin` 的 `switch` 里加分支，参数是 `args`（`args[0]` 是命令名），返回退出码。需要内核做的事，先加系统调用（[syscalls.md](syscalls.md#新增一个系统调用)）。
4. 更新本文和根目录 README 的命令表。
