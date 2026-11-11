#!/usr/bin/env python3
"""在 QEMU 里测试内核：构建，启动，按提示符逐条输入命令，检查输出。

检查分成几个用例（--list 查看），每个用例写明它覆盖哪些源文件：
  python3 tools/qemu_test.py                  # 全部用例，safe 模式
  python3 tools/qemu_test.py --changed        # 只跑和未提交的改动有关的用例
  python3 tools/qemu_test.py shell fork       # 只跑指定的用例
  python3 tools/qemu_test.py --all-modes      # 四种优化模式都跑（改了汇编、中断、页表、进出 U 模式时用）
  python3 tools/qemu_test.py --smp 4          # 只用 4 个 hart 跑（可以给几个；默认 1 和 4 各跑一遍）

每种模式只构建一次（带上 user/tests/ 里的测试程序），所有用例共用一次启动。启动日志每次都检查；
结束时比较前后两次 mem 的空闲页数（不能漏页；两次都在新启动的 shell 里看，见 fresh_mem）、shutdown 后 QEMU 的退出码必须为 0、输出里不能有 KERNEL PANIC。
"""

import argparse
import functools
import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MODES = ["debug", "safe", "fast", "small"]
DEFAULT_SMP = [1, 4]  # 单核、多核各跑一遍；4 和 build.zig 里 zig build run 用的一样（config.json 的 run_smp，启动时检查）

BOOT_TIMEOUT = 60  # 秒：从启动 QEMU 到出现第一个提示符
COMMAND_TIMEOUT = 60  # 秒：每条命令从发出到出现下一个提示符
PROMPT = "\n> "  # 串口把 \n 输出成 \r\n，比较前统一换成 \n
SPIN_SECONDS = 0.5  # 让 spin 转多久再按 Ctrl-C
MIN_SPIN_TICKS = 10  # 这段时间里至少要有多少次时钟中断（100 Hz 下理论上约 50 次）
TIMEBASE_HZ = 10_000_000  # QEMU virt 的 time CSR 频率

# 下面这些在 Zig 里已经定义了，从 zig build 生成的 config.json 读（build.zig 的 Config），见 load_config
QEMU = None  # QEMU 的命令行（不含 -smp、-kernel、磁盘）
QEMU_DISK = None  # 接磁盘的参数，镜像的路径填进 {disk}
GUARD_PAGE = None  # 用户地址空间里栈下面那一页保护页（src/vm.zig 的 heap_limit..stack_limit）
USER_SPACE = None
MAX_PROCS = None  # src/abi.zig 的 max_procs，其中两个槽位是 init 和 sh
MAX_ARGS = None  # src/abi.zig 的 max_args
FS_BLOCKS = None  # 磁盘镜像的前 FS_BLOCKS 块是文件系统（mkfs 的参数）
RAW_BLOCKS = None  # 后 RAW_BLOCKS 块是原始区域
BLOCK_SIZE = None
# t_ipi 的两个延迟（中位数，微秒）的上限，多核时检查。没有核间中断时实测 kill ≥ 4000、wakeup ≥ 1100；
# 有了之后 kill 约 300～560（Debug 最慢，含打印 killed 那一行）、wakeup 约 200
IPI_KILL_MAX_US = 2000
IPI_WAKEUP_MAX_US = 1000
SPIN_STARTED = re.compile(r"pid (\d+) spinning in U-mode")


class Failure(Exception):
    pass


class Qemu:
    """启动 QEMU，后台线程持续读取串口输出；按提示符一条一条地发命令。"""

    def __init__(self, kernel, smp, disk):
        # 磁盘：virtio 块设备，现代（version 2）的 virtio-mmio 接口，和 build.zig 的 zig build run 一样，
        # 只是不加 snapshot=on：退出之后要检查写进磁盘镜像的内容
        drive = [a.replace("{disk}", disk) for a in QEMU_DISK]
        self.proc = subprocess.Popen(
            QEMU + ["-smp", str(smp), "-kernel", kernel] + drive,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.kernel = kernel
        self.smp = smp
        self.disk = disk
        self.after_shutdown = []  # [(Checks, 函数)]：QEMU 退出之后再做的检查（比如读磁盘镜像）
        self.raw = bytearray()
        self.cond = threading.Condition()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while True:
            chunk = self.proc.stdout.read1(4096)
            with self.cond:
                if not chunk:
                    self.cond.notify_all()
                    return
                self.raw += chunk
                self.cond.notify_all()

    def text(self):
        with self.cond:
            return self.raw.decode("utf-8", errors="replace").replace("\r\n", "\n")

    def wait_for(self, predicate, timeout, what):
        """等到 predicate(当前全部输出) 为真。QEMU 提前退出或者超时都算失败。"""
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                text = self.raw.decode("utf-8", errors="replace").replace("\r\n", "\n")
                if predicate(text):
                    return text
                if self.proc.poll() is not None and not self.reader.is_alive():
                    raise Failure(f"QEMU exited (code {self.proc.returncode}) while waiting for {what}")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise Failure(f"timed out after {timeout}s waiting for {what}")
                self.cond.wait(min(left, 0.5))

    def send(self, data):
        self.proc.stdin.write(data.encode())
        self.proc.stdin.flush()

    def command(self, line):
        """发一条命令，等下一个提示符，返回这条命令产生的输出。"""
        start = len(self.text())
        prompts = self.text().count(PROMPT)
        self.send(line + "\r")
        text = self.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, f"the prompt after '{line}'")
        return text[start:]

    def finish(self, timeout):
        """等 QEMU 自己退出，返回退出码；超时就杀掉并报错。"""
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            raise Failure(f"QEMU did not exit within {timeout}s after shutdown")

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()


class Checks:
    """收集一组检查的结果。"""

    def __init__(self):
        self.failures = []
        self.count = 0

    def expect(self, cond, message):
        self.count += 1
        if not cond:
            self.failures.append(message)

    def contains(self, output, pattern, what):
        m = re.search(pattern, output)
        self.expect(m is not None, f"{what}: expected /{pattern}/ in output:\n{indent(output)}")
        return m


def indent(text):
    lines = text.strip("\n").splitlines()[-15:]
    return "\n".join("      | " + line for line in lines)


def free_pages(output):
    m = re.search(r"(\d+) of (\d+) pages free", output)
    return (int(m.group(1)), int(m.group(2))) if m else None


def check_killed(c, out, name, exception, stval_range=None, stval=None, stval_mask=~0):
    m = c.contains(out, rf"\[proc\] pid \d+ \({name}\) killed: {exception} at 0x[0-9a-f]+, stval=0x([0-9a-f]+)", f"run {name}")
    if m:
        value = int(m.group(1), 16)
        if stval_range:
            lo, hi = stval_range
            c.expect(lo <= value < hi, f"run {name}: stval=0x{value:x} not in [0x{lo:x}, 0x{hi:x})")
        if stval is not None:
            c.expect(value & stval_mask == stval, f"run {name}: stval=0x{value:x}, expected 0x{stval:x}")


def exited(c, out, name, code):
    c.contains(out, rf"\[proc\] pid \d+ \({name}\) exited with code {code}\b", f"run {name}")


# ---- 用例 ----


def case_shell(q, c, mode):
    c.contains(q.command("help"), r"run NAME", "help")
    c.contains(q.command("uptime"), r"up \d+\.\d\ds\n", "uptime")
    c.contains(q.command("nope"), r"unknown command: nope", "unknown command")
    # /bin 里的程序按名字排序（测试程序 t_* 也在里面）
    c.contains(q.command("run"), r"programs: cat cp echo expr fault grep head hello init ln ls mkdir mv rm scrub seq sh sleep spin"
               r"( t_\w+)+ tail tee test ticker touch wc xargs\n", "run without a name")
    c.contains(q.command("run nope"), r"no such program: nope\nprograms: ", "run nope")
    # 不写 run，直接写程序名；管道、重定向照样能用。不是内置命令也不是程序的才是 unknown command
    out = q.command("hello")
    c.contains(out, r"Hello from U-mode!", "a program without run")
    exited(c, out, "hello", 0)
    c.contains(q.command("echo one two|wc"), r"\n1 2 8\n", "a pipeline without run")
    c.contains(q.command("nope|wc"), r"unknown command: nope \(try 'help'\)\n", "unknown program in a pipeline")
    shell_language(q, c)
    shell_editing(q, c)
    shell_scripts(q, c)
    shell_jobs(q, c)


def shell_language(q, c):
    """引号、转义、变量、$?、; && ||、注释、glob、语法错误、内置命令的重定向和管道。"""
    c.contains(q.command("echo 'a  b' \"c  d\" e\\ f 'it''s'"), r"\na  b c  d e f its\n", "quotes and backslash")
    out = q.command("X=hello; echo \"$X world\" '$X' ${X}x $NOPE \"\\$X\"")
    c.contains(out, r"\nhello world \$X hellox \$X\n", "variables")
    c.contains(q.command("set"), r"\nX=hello\n", "set lists the variables")
    q.command("unset X")
    c.expect("X=hello" not in q.command("set"), "unset removes the variable")
    c.contains(q.command("false; echo $?"), r"\n1\n", "$? after false")
    c.contains(q.command("nope; echo $?"), r"unknown command: nope \(try 'help'\)\n127\n", "$? of an unknown command")
    c.contains(q.command("true && echo yes || echo no"), r"\nyes\n", "&&")
    out = q.command("false && echo no || echo yes")
    c.contains(out, r"\nyes\n", "|| after a skipped &&")
    c.expect("\nno\n" not in out, f"false && echo no ran echo:\n{indent(out)}")
    c.contains(q.command("echo a; echo b # echo c"), r"\na\n(.*\n)?b\n", "; and a comment")
    # 语法错误：整行都不执行
    for line, err in (("echo first; echo 'open", "unterminated quote"), ("echo first &&", "empty command"),
                      ("echo first | ; echo x", "empty command"), ("echo first > ", "missing file name after < or >"),
                      ("echo ${X", r"bad substitution \(\$\{NAME\}\)")):
        out = q.command(line)
        c.contains(out, rf"sh: {err}\n", line)
        c.expect("first\n" not in out.split("\n", 1)[1], f"'{line}': ran a command before the syntax error:\n{indent(out)}")
    c.contains(q.command("echo $?"), r"\n2\n", "$? after a syntax error")
    # 文件名匹配：只有最后一段；没匹配到的原样留着；引号里的不展开
    c.contains(q.command("echo /bin/t_f*"), r"\n/bin/t_fork /bin/t_fp /bin/t_fs /bin/t_fsmp\n", "glob *")
    c.contains(q.command("echo /bin/?c /bin/zz* '/bin/t_f*'"), r"\n/bin/wc /bin/zz\* /bin/t_f\*\n", "glob ?, no match, quoted")
    c.contains(q.command("cd /dev; echo *; cd /"), r"\nconsole null zero\n", "glob in the current directory")
    # cd、pwd、cd -
    c.contains(q.command("cd /dev; pwd; cd /bin; cd -; pwd"), r"\n/dev\n/dev\n/dev\n", "cd, pwd, cd -")
    q.command("cd")
    c.contains(q.command("pwd"), r"\n/\n", "cd without arguments")
    # 内置命令在管道里（在子进程里运行）、重定向之后标准输出换回来
    c.contains(q.command("pwd | wc"), r"\n1 1 2\n", "a builtin in a pipeline")
    q.command("pwd > /pwd.txt")
    c.contains(q.command("cat /pwd.txt; rm /pwd.txt"), r"\n/\n", "a builtin with > F")
    c.contains(q.command("uptime"), r"\nup \d+\.\d\ds\n", "stdout is back after a builtin with > F")


def shell_editing(q, c):
    """交互的行编辑：上下方向键翻历史、Ctrl-U、Tab 补全。"""
    q.command("echo history one")
    q.command("echo history two")
    c.contains(q.command("\x1b[A\x1b[A\x1b[B"), r"\nhistory two\n", "up, up, down recalls the last command")
    c.contains(q.command("\x1b[A\x1b[A"), r"\nhistory one\n", "up twice")
    c.contains(q.command("history"), r"\d+  echo history one\n +\d+  echo history two\n", "history")
    c.contains(q.command("garbage\x15echo cleared"), r"\ncleared\n", "Ctrl-U clears the line")
    # Tab：唯一的候选补全它，目录后面加 /；几个候选列出来，重新打印这一行
    out = q.command("hell\t")
    c.contains(out, r"Hello from U-mode!", "Tab completes a program name")
    out = q.command("ls /de\t")
    c.contains(out, r"ls /dev/\n", "Tab completes a directory")
    c.contains(out, r"\ndev +1 +1 console\n", "ls /dev/ after Tab")
    q.send("t_f\t")
    q.wait_for(lambda t: "\nt_fork  t_fp  t_fs  t_fsmp  \n> t_f" in t, COMMAND_TIMEOUT, "the list of completions")
    c.contains(q.command("\x15echo after the list"), r"\nafter the list\n", "a command after listing completions")


def shell_scripts(q, c):
    """sh 文件 参数、sh -c、从管道读命令；脚本里的 cd、exit 不影响交互的 shell。"""
    q.command("echo 'echo script $0: $# args, $1, $2 # comment' > /t.sh")
    q.command("echo 'cd /dev; pwd; exit 5' >> /t.sh")
    q.command("echo 'echo not reached' >> /t.sh")
    out = q.command("sh /t.sh one 'two three'; echo status $?")
    c.contains(out, r"\nscript /t\.sh: 2 args, one, two three\n", "sh FILE ARGS")
    c.contains(out, r"\n/dev\n", "cd in a script")
    c.contains(out, r"\nstatus 5\n", "exit in a script")
    c.expect("not reached" not in out, f"a script went on after exit:\n{indent(out)}")
    c.contains(q.command("pwd"), r"\n/\n", "a script's cd does not change the shell's directory")
    c.contains(q.command("sh -c 'echo $0 $1; false' x y; echo $?"), r"\nx y\n(.*\n)*1\n", "sh -c")
    c.contains(q.command("echo 'echo from a pipe' | sh"), r"\nfrom a pipe\n", "sh reading commands from a pipe")
    c.contains(q.command("sh < /t.sh"), r"\nscript sh: 0 args, ,\n", "sh < FILE")
    c.contains(q.command("sh /nope"), r"sh: /nope: NotFound\n", "sh a missing file")
    q.command("rm /t.sh")


def shell_jobs(q, c):
    """jobs、wait、$!、time、kill 几个进程；最后 exit：init 重新启动一个 shell。"""
    pid = start_background(q, c, "spin")
    if pid is not None:
        c.contains(q.command("jobs"), rf"\n\[{pid}\] \w+ +spin\n", "jobs")
        c.contains(q.command("echo $!"), rf"\n{pid}\n", "$!")
        c.contains(q.command("kill $!"), rf"pid {pid} \(spin\) killed: kill\(\)", "kill $!")
    c.expect("[" not in q.command("jobs").split("\n", 1)[1], "jobs after killing the background process")
    c.contains(q.command("hello & wait $!; echo waited $?"), r"Hello from U-mode!(.*\n)*waited 0\n", "wait PID")
    c.contains(q.command("time hello"), r"\nreal \d+\.\d\ds\n", "time")
    c.contains(q.command("kill 9999 1"), r"kill: no such process: 9999\nkill: cannot kill pid 1: permission denied\n",
               "kill several pids")
    out = q.command("exit 3")
    c.contains(out, r"\(sh\) exited with code 3\ninit: sh exited, restarting it\nType 'help' for commands\.\n", "exit")


def case_interrupts(q, c, mode):
    # spin 在 U 模式里死循环。这段时间里内核只能靠中断拿回 CPU，
    # 所以前后两次 uptime（精度是一个 tick，10 ms）的差说明时钟中断在 U 模式下照常发生；Ctrl-C 靠串口中断送进来
    before = uptime_ticks(q, c)
    run_and_interrupt(q, c, SPIN_SECONDS)
    after = uptime_ticks(q, c)
    if before is not None and after is not None:
        c.expect(after - before >= MIN_SPIN_TICKS,
                 f"uptime: only {after - before} timer interrupts while spin ran for {SPIN_SECONDS}s")
    # 在 shell 里按的 Ctrl-C 不应该影响之后运行的程序
    q.send("\x03")
    exited(c, q.command("run hello"), "hello", 0)


def run_and_interrupt(q, c, seconds):
    """在前台运行 spin，等它开始转，seconds 秒后按 Ctrl-C，检查它被结束。返回它的 pid。"""
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run spin\r")
    q.wait_for(lambda t: SPIN_STARTED.search(t[start:]), COMMAND_TIMEOUT, "spin to start")
    pid = int(SPIN_STARTED.search(q.text()[start:]).group(1))
    time.sleep(seconds)
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C")[start:]
    c.contains(out, rf"\^C\n\[proc\] pid {pid} \(spin\) killed: interrupted by Ctrl-C", "run spin + Ctrl-C")
    return pid


def uptime_ticks(q, c):
    """uptime 显示到 1/100 秒，正好是 tick 数。"""
    m = c.contains(q.command("uptime"), r"up (\d+)\.(\d\d)s", "uptime")
    return int(m.group(1)) * 100 + int(m.group(2)) if m else None


def case_user(q, c, mode):
    out = q.command("run hello")
    c.contains(out, r"Hello from U-mode! I am pid \d+, the kernel has been up for \d+ ms\.", "run hello")
    c.contains(out, r"write\(\) refused a kernel pointer: BadAddress", "run hello")
    exited(c, out, "hello", 0)
    check_killed(c, q.command("run fault"), "fault", "load_page_fault", stval=0x80200000)
    out = q.command("run t_panic")
    if mode in ("debug", "safe"):
        c.contains(out, r"panic: integer overflow", "run t_panic")
        exited(c, out, "t_panic", 255)
    else:  # 没有溢出检查：250 + 10 回绕成 4
        exited(c, out, "t_panic", 4)
    out = q.command("run t_time")
    m = c.contains(out, r"rdtime from U-mode = (\d+)", "run t_time")
    if m:
        c.expect(int(m.group(1)) > 0, "run t_time: time CSR read as 0")
    exited(c, out, "t_time", 0)


def start_background(q, c, name):
    """后台运行 name，返回 pid；是 spin 的话还要等它打印出第一行，免得这行混进下一条命令的输出。"""
    start = len(q.text())
    m = c.contains(q.command(f"run {name} &"), rf"\[proc\] pid (\d+) \({name}\) started in the background",
                   f"run {name} &")
    if not m:
        return None
    pid = int(m.group(1))
    if name == "spin":
        q.wait_for(lambda t: f"pid {pid} spinning" in t[start:], COMMAND_TIMEOUT, f"spin (pid {pid}) to start")
    return pid


def ps_table(q, c):
    """运行 ps，返回 {pid: (状态, ticks, 名字)}，不含 init 和 sh（检查它们的父进程和状态）。"""
    out = q.command("ps")
    c.contains(out, r"PID +PPID STATE +TICKS NAME", "ps")
    rows = [(int(m.group(1)), int(m.group(2)), m.group(3), int(m.group(4)), m.group(5))
            for m in re.finditer(r"^ *(\d+) +(\d+) (\w+) +(\d+) (\w+)$", out, re.M)]
    init = [r for r in rows if r[4] == "init"]
    # shell 是 init 的子进程。别的叫 sh 的是它 fork 出来、还没 exec 的子进程（多核时 ps 可能正好看到），
    # 或者管道的组长，算作普通进程
    sh = [r for r in rows if r[4] == "sh" and r[1] == 1]
    c.expect([r[:3] for r in init] == [(1, 0, "sleeping")], f"ps: expected init as pid 1, sleeping: {rows}")
    c.expect(len(sh) == 1 and sh[0][2] == "running", f"ps: expected one running sh, child of init: {rows}")
    return {r[0]: (r[2], r[3], r[4]) for r in rows if r not in init + sh}


def wait_ps_empty(q, c, what):
    """等到 ps 里除了 init 和 sh 什么都没有、init 在睡。被杀的进程先打印 killed 那一行，之后才关文件、
    变成 zombie；父进程先结束了的话，它还要等 init 来回收。所以刚看到 killed 那一行时 ps 可能还看得到它
    （running），init 也可能正在回收它（running）。最多等 2 秒。"""
    for _ in range(20):
        attempt = Checks()
        if ps_table(q, attempt) == {} and not attempt.failures:
            return
        time.sleep(0.1)
    c.failures += [f"{what}: {f}" for f in attempt.failures]
    c.expect(False, f"{what}: processes still left after 2s")


def case_sched(q, c, mode):
    # 两个后台进程死循环，前台程序和 shell 照样能运行
    spinners = [start_background(q, c, "spin") for _ in range(2)]
    if None in spinners:
        return
    exited(c, q.command("run hello"), "hello", 0)
    out = q.command("run t_sleep")
    m = c.contains(out, r"slept (\d+) ms", "run t_sleep")
    if m:
        c.expect(200 <= int(m.group(1)) < 1000, f"run t_sleep: slept {m.group(1)} ms, expected 200..1000")
    c.contains(out, r"yield ok", "run t_sleep")
    exited(c, out, "t_sleep", 0)

    # 两个后台进程都分到了 CPU：0.5 秒里各自至少拿到几个 tick。单核时靠时间片轮转，状态是 runnable；
    # 多核时它们可能正在别的 hart 上运行
    before = ps_table(q, c)
    time.sleep(SPIN_SECONDS)
    after = ps_table(q, c)
    for pid in spinners:
        c.expect(after.get(pid, ("", 0, ""))[0] in ("runnable", "running"),
                 f"ps: spin (pid {pid}) not listed as runnable or running: {after}")
        got = after.get(pid, ("", 0, ""))[1] - before.get(pid, ("", 0, ""))[1]
        c.expect(got >= MIN_SPIN_TICKS // 2, f"ps: spin (pid {pid}) got only {got} ticks in {SPIN_SECONDS}s")

    # Ctrl-C 只结束前台进程，后台的还在
    fg = run_and_interrupt(q, c, 0.2)
    table = ps_table(q, c)
    c.expect(fg not in table and all(pid in table for pid in spinners), f"ps after Ctrl-C: {table}")

    # 在 sleep 里睡着的前台进程，Ctrl-C 也要能叫醒它、结束它
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run ticker\r")
    time.sleep(0.2)
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C on ticker")[start:]
    c.contains(out, r"\^C\n\[proc\] pid \d+ \(ticker\) killed: interrupted by Ctrl-C", "run ticker + Ctrl-C")
    c.expect("tick 1" not in out, f"run ticker + Ctrl-C: ticker kept running:\n{indent(out)}")

    # sleep 的进程不占 CPU。刚启动时它还是 runnable（紧接着的 ps 可能抢在它第一次运行之前），所以多看几次
    ticker = start_background(q, c, "ticker")
    for _ in range(10):
        table = ps_table(q, c)
        if table.get(ticker, ("",))[0] == "sleeping":
            break
        time.sleep(0.05)
    c.expect(table.get(ticker, ("",))[0] == "sleeping", f"ps: ticker (pid {ticker}) not sleeping: {table}")

    # kill
    for pid in spinners + [ticker]:
        c.contains(q.command(f"kill {pid}"), rf"\[proc\] pid {pid} \(\w+\) killed: kill\(\)", "kill")
    c.contains(q.command("kill 9999"), r"kill: no such process: 9999", "kill 9999")
    c.contains(q.command("kill 1"), r"kill: cannot kill pid 1: permission denied", "kill init")
    c.contains(q.command("kill"), r"usage: kill PID", "kill")
    c.expect(ps_table(q, c) == {}, "ps: processes left after killing all of them")

    # 进程表满了（init 和 sh 占着两个槽位）：t_fork fill 在后台 fork 到表满，子进程都睡着。
    # 杀掉它之后，子进程发现自己交给了 init，各自结束
    start = len(q.text())
    m = c.contains(q.command("run t_fork fill &"), r"\[proc\] pid (\d+) \(t_fork\) started in the background", "run t_fork fill &")
    # 等整行都到了再检查：串口的输出是一块一块到的，只等开头的话可能只读到半行
    q.wait_for(lambda t: re.search(r"t_fork: filled the process table with \d+ children\n", t[start:]), COMMAND_TIMEOUT,
               "t_fork fill")
    c.contains(q.text()[start:], rf"t_fork: filled the process table with {MAX_PROCS - 3} children\n", "t_fork fill")
    c.contains(q.command("run hello"), rf"sh: too many processes \(at most {MAX_PROCS}\)", "run with a full table")
    if m:
        q.command(f"kill {m.group(1)}")
    wait_ps_empty(q, c, "the children of t_fork fill")


def case_syscall(q, c, mode):
    out = q.command("run t_sys")
    for pattern in [
        r"abcd\npartial write -> 4\n",
        r"abcdhuge write -> 4\n",
        r"empty write -> 0\n",
        r"\.{4191}\ncross-page write -> 4192\n",
        r"syscall 999 -> -38\n",
    ]:
        c.contains(out, pattern, "run t_sys")
    exited(c, out, "t_sys", 42)


def case_protection(q, c, mode):
    check_killed(c, q.command("run t_wx"), "t_wx", "store_page_fault", stval_range=USER_SPACE)
    check_killed(c, q.command("run t_stack"), "t_stack", "store_page_fault", stval_range=GUARD_PAGE)
    # stval 是那条指令的编码：csrr rd, sstatus（= csrrs rd, sstatus, x0）。rd（第 7..11 位）随寄存器分配变化，不比较
    check_killed(c, q.command("run t_priv"), "t_priv", "illegal_instruction", stval=0x10002073, stval_mask=~(0x1F << 7))
    # sstatus.FS = Off，浮点指令是非法指令。stval 是 fmv.d.x f1, a0 的编码
    check_killed(c, q.command("run t_fp"), "t_fp", "illegal_instruction", stval=0xF20500D3)
    out = q.command("run t_noperm")
    c.contains(out, r"sh: cannot load t_noperm: BadElf", "run t_noperm")
    c.expect("should never run" not in out, "run t_noperm: the program ran")


def case_fork(q, c, mode):
    # t_fork 自己检查 fork、exec、wait、kill 等的边界情况，失败的项打印 FAIL
    out = q.command("run t_fork")
    c.contains(out, r"\d+ checks, 0 failed", "run t_fork")
    c.expect("FAIL" not in out, f"run t_fork:\n{indent(out)}")
    m = c.contains(out, r"child pid (\d+) execs hello", "run t_fork")
    if m:  # exec 之后 pid 不变
        c.contains(out, rf"Hello from U-mode! I am pid {m.group(1)},", "run t_fork: exec keeps the pid")
    c.contains(out, r"orphan's parent is pid 1\n", "run t_fork: orphans go to init")
    c.contains(out, rf"forked {MAX_PROCS - 3} children before the table was full", "run t_fork")
    exited(c, out, "t_fork", 0)

    # read：一行分几次读完；之后对睡在 read 里的进程按 Ctrl-C
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run t_read\r")
    q.wait_for(lambda t: "reading\n" in t[start:], COMMAND_TIMEOUT, "t_read to start")
    q.send("hello world\r")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after t_read")[start:]
    m = c.contains(out, r'got "hello world" in (\d+) reads', "run t_read")
    if m:
        c.expect(int(m.group(1)) >= 4, f"run t_read: a 12-byte line in {m.group(1)} reads of at most 3 bytes")
    exited(c, out, "t_read", 0)
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run t_read\r")
    q.wait_for(lambda t: "reading\n" in t[start:], COMMAND_TIMEOUT, "t_read to start")
    q.send("\x03")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-C on t_read")[start:]
    c.contains(out, r"\^C\n\[proc\] pid \d+ \(t_read\) killed: interrupted by Ctrl-C", "run t_read + Ctrl-C")

    # shell 被杀之后 init 重新启动一个
    out = q.command("ps")
    m = re.search(r"^ *(\d+) +1 running +\d+ sh$", out, re.M)
    c.expect(m is not None, f"ps: no running sh:\n{indent(out)}")
    if m:
        out = q.command(f"kill {m.group(1)}")
        c.contains(out, rf"\[proc\] pid {m.group(1)} \(sh\) killed: kill\(\)\ninit: sh exited, restarting it\n"
                   r"Type 'help' for commands\.", "kill sh")
        exited(c, q.command("run hello"), "hello", 0)


def check_counts(c, out, name):
    """t_args check、t_pipe、t_sbrk 这类自己检查边界情况的测试程序：失败的项打印 FAIL，最后打印通过的项数。"""
    c.contains(out, r"\d+ checks, 0 failed", f"run {name}")
    c.expect("FAIL" not in out, f"run {name}:\n{indent(out)}")
    exited(c, out, name, 0)


def case_args(q, c, mode):
    # shell 按空格拆参数，多个空格算一个；argv[0] 是程序名，退出码是 argc
    out = q.command("run t_args one  two   three")
    c.contains(out, r'argc=4\nargv\[0\]="t_args"\nargv\[1\]="one"\nargv\[2\]="two"\nargv\[3\]="three"\n'
                    r"total 17 bytes\n", "run t_args")
    exited(c, out, "t_args", 4)
    c.contains(q.command("run echo hello,   world"), r"\nhello, world\n", "run echo")
    c.contains(q.command("run echo"), r"echo\n\n\[proc\]", "run echo without arguments")
    c.contains(q.command("run t_args " + " ".join(["x"] * MAX_ARGS)), rf"sh: too many arguments \(at most {MAX_ARGS}\)",
               f"run t_args x*{MAX_ARGS}")
    check_counts(c, q.command("run t_args check"), "t_args")


def case_pipe(q, c, mode):
    check_counts(c, q.command("run t_pipe"), "t_pipe")
    # shell 的管道：前一个程序的输出接到后一个的输入，读到结尾才结束；“组长”是 fork 出来的 sh
    out = q.command("run echo hello world | wc")
    c.contains(out, r"\n1 2 12\n", "run echo | wc")
    exited(c, out, "echo", 0)
    exited(c, out, "wc", 0)
    exited(c, out, "sh", 0)
    c.contains(q.command("run echo a b c | cat | cat | wc"), r"\n1 3 6\n", "run echo | cat | cat | wc")
    c.contains(q.command("run t_args x y|wc"), r"\n5 7 62\n", "run t_args | wc")
    c.contains(q.command("run echo a | nope"), r"no such program: nope", "run echo | nope")
    c.contains(q.command("run echo a |"), r"sh: empty command\n", "run echo |")
    c.contains(q.command("run echo a b c | cat | cat | cat | cat | cat | cat | wc"), r"\n1 3 6\n", "run with 8 programs")
    c.contains(q.command("run " + " | ".join(["echo"] * 9)), r"sh: too many programs in the pipeline \(at most 8\)",
               "run with 9 programs")
    # 后台管道
    m = c.contains(q.command("run echo bg | wc &"), r"\[proc\] pid (\d+) \(pipeline\) started in the background",
                   "run echo | wc &")
    if m:
        q.wait_for(lambda t: re.search(rf"pid {m.group(1)} \(sh\) exited", t), COMMAND_TIMEOUT, "the background pipeline")
    # Ctrl-C 结束前台管道里的所有程序：cat 在等键盘，wc 在等 cat
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run cat | wc\r")
    time.sleep(0.3)
    q.send("\x03")
    # 三个进程被杀的顺序、和提示符谁先谁后取决于调度，都等到再检查
    killed = [rf"\[proc\] pid \d+ \({name}\) killed: interrupted by Ctrl-C" for name in ("cat", "wc", "sh")]
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts and all(re.search(k, t[start:]) for k in killed),
                     COMMAND_TIMEOUT, "Ctrl-C to kill cat | wc")[start:]
    c.expect(out.count("^C") == 1, f"run cat | wc + Ctrl-C:\n{indent(out)}")
    wait_ps_empty(q, c, "ps after Ctrl-C on a pipeline")
    # 在键盘上按 Ctrl-D：cat 读到结尾
    start = len(q.text())
    prompts = q.text().count(PROMPT)
    q.send("run cat | wc\r")
    time.sleep(0.3)
    q.send("abc\x04")
    out = q.wait_for(lambda t: t.count(PROMPT) > prompts, COMMAND_TIMEOUT, "the prompt after Ctrl-D on cat | wc")[start:]
    c.contains(out, r"\n0 1 3\n", "run cat | wc + Ctrl-D")


def case_sbrk(q, c, mode):
    # 按需分配：堆比空闲内存还大时，把它写满的子进程在内存用完时被结束
    out = q.command("run t_sbrk")
    c.contains(out, r"\[proc\] pid \d+ \(t_sbrk\) killed: out of memory \(demand paging\) at 0x[0-9a-f]+, stval=0x[0-9a-f]+\n",
               "run t_sbrk: touching more heap than there is memory")
    check_counts(c, out, "t_sbrk")


def case_cow(q, c, mode):
    # 写时复制的 fork：t_cow 自己检查内容、页数；最后一项把内存用完，子进程写共用的页时被结束
    out = q.command("run t_cow")
    m = c.contains(out, r"fork of a process with a 64-page heap used (\d+) pages\n", "run t_cow")
    if m:
        c.expect(int(m.group(1)) < 16, f"run t_cow: fork used {m.group(1)} pages")
    c.contains(out, r"\[proc\] pid \d+ \(t_cow\) killed: out of memory \(copy-on-write\) at 0x[0-9a-f]+, stval=0x[0-9a-f]+\n",
               "run t_cow: writing a shared page without memory")
    check_counts(c, out, "t_cow")


def case_demand(q, c, mode):
    # 按需分页：t_demand 自己检查程序的页用到才读进来、内核替它访问没读进来的页、栈按需长、
    # 正在运行的程序文件不能改不能删
    out = q.command("run t_demand")
    m = c.contains(out, r"reading 16 untouched pages of the program used (\d+) pages\n", "run t_demand")
    c.contains(out, r"\nthis line comes from a page that was never touched\n", "run t_demand: console write")
    c.contains(out, r"512 KiB of stack used \d+ pages\n", "run t_demand: deep stack")
    check_counts(c, out, "t_demand")


def no_proc_lines(out):
    """去掉内核打印的 [proc] 那几行（每个程序结束时一行），剩下的是程序自己的输出。"""
    return "\n".join(l for l in out.split("\n") if not l.startswith("[proc] "))


def case_tools(q, c, mode):
    """写脚本用的程序：test、expr、seq、sleep、head、tail、grep、cp、touch、tee、xargs。"""
    def out_of(cmd):
        return no_proc_lines(q.command(cmd))

    for cmd, pattern in [
        ("seq 3", r"\n1\n2\n3\n> $"),
        ("seq 10 -3 1", r"\n10\n7\n4\n1\n> $"),
        ("seq 2 2", r"\n2\n> $"),
        ("seq 3 1", r"seq 3 1\n> $"),  # 一个都没有
        ("seq 1 0 3", r"seq: the step must not be 0\n"),
        ("seq 20 | head -n 3", r"\n1\n2\n3\n> $"),
        ("seq 20 | head | wc", r"\n10 10 21\n"),
        ("seq 5 | tail -n 2", r"\n4\n5\n> $"),
        ("seq 3 | tail -n 0", r"tail -n 0\n> $"),
        ("seq 3 | tail -n 9", r"\n1\n2\n3\n> $"),
        ("seq 3000 | tail -n 1", r"\n3000\n> $"),  # 输入比一次 read 大
        ("seq 12 | grep -n 1", r"\n1:1\n10:10\n11:11\n12:12\n> $"),
        ("seq 12 | grep -c '^1.$'", r"\n3\n> $"),
        ("seq 12 | grep -v 1", r"\n2\n3\n4\n5\n6\n7\n8\n9\n> $"),
        ("echo aab ab b | xargs -n 1 | grep '^a*b$'", r"\naab\nab\nb\n> $"),
        ("echo Hello | grep -i hello", r"\nHello\n> $"),
        ("echo a.c abc | grep -c 'a\\.c'", r"\n1\n> $"),
        ("echo xyz | grep 'x.*z$' && echo hit", r"\nxyz\nhit\n"),
        ("echo abc | grep -q d; echo $?", r"\n1\n> $"),
        ("grep x /nope; echo $?", r"grep: /nope: NotFound\n2\n"),
        ("expr 2 + 3 '*' 4", r"\n14\n> $"),
        ("expr '(' 2 + 3 ')' '*' 4 - -6", r"\n26\n> $"),
        ("expr 7 / 2; expr 7 % 2; expr -7 / 2", r"\n3\n1\n-3\n> $"),
        ("expr 3 '<' 5 '&' 2 = 2", r"\n1\n> $"),
        ("expr 0 '|' 5", r"\n5\n> $"),
        ("expr 1 - 1; echo $?", r"\n0\n1\n> $"),
        ("expr 7 / 0; echo $?", r"expr: division by zero\n2\n"),
        ("expr 9223372036854775807 + 1", r"expr: overflow\n"),
        ("expr 1 +", r"expr: syntax error\n"),
        ("expr x + 1", r"expr: not a number: 'x'\n"),
        ("test 3 -lt 10 && echo yes", r"\nyes\n"),
        ("test -5 -ge -4 || echo no", r"\nno\n"),
        ("test -d /bin -a ! -f /bin && echo dir", r"\ndir\n"),
        ("test abc = abd || echo differ", r"\ndiffer\n"),
        ("test ! = ! && echo eq", r"\neq\n"),
        ("test -z '' -a -n x && echo zn", r"\nzn\n"),
        ("test ( 1 -eq 2 -o 2 -eq 2 ) -a x && echo paren", r"\nparen\n"),
        ("test; echo $?", r"\n1\n> $"),
        ("test 1 -eq x; echo $?", r"test: not an integer: 'x'\n2\n"),
        ("test -e /nope || echo missing", r"\nmissing\n"),
        ("echo a b c d e | xargs -n 2", r"\na b\nc d\ne\n> $"),
        ("seq 3 | xargs", r"\n1 2 3\n> $"),
        ("seq 2 4 | xargs -n 1 echo hi", r"\nhi 2\nhi 3\nhi 4\n> $"),
        ("seq 3 | xargs -n 1 test 2 -eq; echo $?", r"\n123\n> $"),
        ("echo x | xargs nope; echo $?", r"xargs: nope: NoSuchProgram\n127\n"),
        ("sleep 0.05 && echo slept", r"\nslept\n"),
        ("sleep x", r"sleep: invalid time: 'x'\n"),
    ]:
        c.contains(out_of(cmd), pattern, cmd)

    # 文件：cp、touch、tee
    q.command("mkdir /ttools")
    for cmd, pattern in [
        ("echo hello > /ttools/a; cp /ttools/a /ttools/b; cat /ttools/b", r"\nhello\n> $"),
        ("cp /ttools/a /ttools/./a; cat /ttools/a", r"cp: /ttools/a and /ttools/./a are the same file\nhello\n"),
        ("mkdir /ttools/d; cp /ttools/a /ttools/b /ttools/d; ls /ttools/d", r"\nfile +1 +6 a\nfile +1 +6 b\n"),
        ("cp /ttools/a /ttools/b /ttools/nodir", r"cp: /ttools/nodir: not a directory\n"),
        ("cp /ttools/d /ttools/e", r"cp: /ttools/d: IsDir\n"),
        ("touch /ttools/c /ttools/a; test -f /ttools/c -a ! -s /ttools/c -a -s /ttools/a && echo touched", r"\ntouched\n"),
        ("seq 3 | tee /ttools/t | wc; cat /ttools/t", r"\n3 3 6\n1\n2\n3\n> $"),
        ("echo 4 | tee -a /ttools/t > /dev/null; tail -n 2 /ttools/t", r"\n3\n4\n> $"),
        ("head -n 1 /ttools/t /ttools/a", r"\n==> /ttools/t <==\n1\n\n==> /ttools/a <==\nhello\n> $"),
        ("grep -n l /ttools/a /ttools/t", r"\n/ttools/a:1:hello\n> $"),
    ]:
        c.contains(out_of(cmd), pattern, cmd)
    # 一个用这些程序的脚本：数到 3，每个数判断奇偶
    q.command("echo 'seq 3 | xargs -n 1 sh /ttools/odd.sh' > /ttools/count.sh")
    q.command("echo 'expr $1 % 2 > /dev/null && echo $1 odd || echo $1 even' > /ttools/odd.sh")
    c.contains(out_of("sh /ttools/count.sh"), r"\n1 odd\n2 even\n3 odd\n", "sh /ttools/count.sh")
    # 正在运行的程序不能被覆盖、删掉（按需分页要从它读页）；结束之后可以
    q.command("cp /bin/spin /ttools/s")
    m = c.contains(q.command("/ttools/s &"), r"\[proc\] pid (\d+) \(/ttools/s\) started in the background", "/ttools/s &")
    if m:
        q.wait_for(lambda t: re.search(rf"pid {m.group(1)} spinning", t), COMMAND_TIMEOUT, "/ttools/s to start")
        c.contains(out_of("cp /bin/hello /ttools/s"), r"cp: /ttools/s: TextBusy\n", "cp over a running program")
        c.contains(out_of("rm /ttools/s"), r"rm: /ttools/s: TextBusy\n", "rm a running program")
        q.command(f"kill {m.group(1)}")
        out = q.command("cp /bin/hello /ttools/s && /ttools/s")
        c.contains(out, r"Hello from U-mode!", "cp over a program after it exited")
    q.command("rm /ttools/d/a /ttools/d/b /ttools/d /ttools/a /ttools/b /ttools/c /ttools/t /ttools/s /ttools/count.sh /ttools/odd.sh /ttools")
    c.contains(q.command("ls /ttools"), r"ls: /ttools: NotFound", "cleanup /ttools")


def case_ipi(q, c, mode):
    # 核间中断：kill 别的 hart 上在跑的进程、叫醒进程给空闲的 hart 运行，都不用等时钟中断（10 ms 一次）。
    # 没有核间中断时多核下的中位数实测是 kill 4～8 ms、wakeup 1.1～7.6 ms；有了之后都在 0.6 ms 以内。
    # 单核时 wakeup 必然要等父进程的时间片用完，只检查能跑完
    out = q.command("run t_ipi")
    m = c.contains(out, r"ipi latency \(median of \d+\): kill (\d+) us, wakeup (\d+) us\n", "run t_ipi")
    if m and q.smp >= 2:
        kill, wakeup = int(m.group(1)), int(m.group(2))
        c.expect(kill < IPI_KILL_MAX_US, f"run t_ipi: killing a process on another hart took {kill} us")
        c.expect(wakeup < IPI_WAKEUP_MAX_US, f"run t_ipi: an idle hart took {wakeup} us to run a woken process")
    c.expect("FAIL" not in out, f"run t_ipi:\n{indent(out)}")
    exited(c, out, "t_ipi", 0)


# build.zig 生成的磁盘镜像：前 FS_BLOCKS 块是文件系统（mkfs 的参数），后 RAW_BLOCKS 块是原始区域，
# readblock/writeblock 只能读写原始区域，块号从它的开头算。原始区域的图案和 t_disk 改写的块见下面（几边的公式要一致）


def disk_original(b):
    """镜像里第 b 块的内容：第 i 个字节是 (b * 131 + i) % 251。按 251 循环，所以是一段固定序列的切片。"""
    start = b * 131 % 251
    return _period()[start:start + BLOCK_SIZE]


@functools.cache
def _period():
    return bytes(i % 251 for i in range(BLOCK_SIZE + 251))


def disk_expected(b):
    """t_disk 跑过之后第 b 块应该是什么。"""
    if b == 0 or b == RAW_BLOCKS - 1 or 100 <= b < 140:
        return bytes(255 - x for x in disk_original(b))
    if 200 <= b < 500:
        k = (b - 200) // 50
        return bytes((b * 7 + i * 3 + k * 29 + 1) & 0xFF for i in range(BLOCK_SIZE))
    return disk_original(b)


def check_disk_image(q, c):
    with open(q.disk, "rb") as f:
        image = f.read()
    c.expect(len(image) == (FS_BLOCKS + RAW_BLOCKS) * BLOCK_SIZE, f"disk image: {len(image)} bytes")
    raw = image[FS_BLOCKS * BLOCK_SIZE:]
    bad = [b for b in range(RAW_BLOCKS) if raw[b * BLOCK_SIZE:(b + 1) * BLOCK_SIZE] != disk_expected(b)]
    c.expect(not bad, f"disk image after shutdown: {len(bad)} blocks differ from what t_disk wrote, first {bad[:8]}")


def case_disk(q, c, mode):
    # t_disk 自己检查读、写、坏参数、并发和写时复制；QEMU 退出之后再读镜像文件，确认写的块真的到了磁盘上
    c.contains(q.command("disk"), r"1024 blocks of 4 KiB \(4 MiB\)\n", "disk")
    check_counts(c, q.command("run t_disk"), "t_disk")
    q.after_shutdown.append((c, lambda c: check_disk_image(q, c)))


def reboot(q, c, what, steps):
    """在同一个磁盘镜像上再启动一次（QEMU 已经退出），等提示符，确认文件系统挂上了，再调用 steps(新的 Qemu)。
    串口输出存到镜像旁边的 <镜像名>-<what>.log。"""
    r = Qemu(q.kernel, q.smp, q.disk)
    try:
        text = r.wait_for(lambda t: "Type 'help' for commands.\n> " in t or "KERNEL PANIC" in t, BOOT_TIMEOUT,
                          f"the first prompt ({what})")
        c.contains(text, rf"\[ok\] file system: \d+ of {FS_BLOCKS} blocks free", f"{what}: boot log")
        steps(r)
    except Failure as e:
        c.failures.append(f"{what}: {e}")
    finally:
        r.kill()
        with open(os.path.splitext(q.disk)[0] + f"-{what}.log", "w", encoding="utf-8") as f:
            f.write(r.text())
    c.expect("KERNEL PANIC" not in r.text(), f"{what}: KERNEL PANIC in the serial output")


def scrub_ok(c, out, what):
    """scrub 通过了，返回它数出来的文件数。"""
    m = c.contains(out, r"scrub: ok: (\d+) files, \d+ dirs, 3 devices, \d+ symlinks, \d+ data blocks verified\n", what)
    exited(c, out, "scrub", 0)
    return int(m.group(1)) if m else None


def scrub_page(i):
    """t_fs scrubfile 写的 /scrub.dat 的第 i 页。"""
    line = f"scrub test page {i}\n".encode()
    return (line * (BLOCK_SIZE // len(line) + 1))[:BLOCK_SIZE]


def corrupt_scrub_file(q, c):
    """在镜像里找到 /scrub.dat 第 1 页的数据块，改掉一个字节。返回找到了没有。"""
    with open(q.disk, "r+b") as f:
        image = bytearray(f.read(FS_BLOCKS * BLOCK_SIZE))
        target = scrub_page(1)
        found = [b for b in range(FS_BLOCKS) if image[b * BLOCK_SIZE:(b + 1) * BLOCK_SIZE] == target]
        c.expect(len(found) == 1, f"/scrub.dat page 1: found in {len(found)} blocks of the disk image, expected 1")
        if len(found) != 1:
            return False
        f.seek(found[0] * BLOCK_SIZE + 100)
        f.write(bytes([image[found[0] * BLOCK_SIZE + 100] ^ 0x20]))
    return True


def check_fs_reboots(q, c):
    """QEMU 正常关机之后：第二次启动，上一次写的文件还在；然后边写边把 QEMU 杀掉（掉电），
    第三次启动，文件系统能挂上，t_fs verify 检查每个操作要么做完了、要么没做，scrub 通过。
    关机后在镜像里改坏一个数据块，第四次启动，scrub 发现它，读那个文件出错，删掉之后 scrub 又通过了。"""
    delay = random.uniform(0.2, 1.0)

    def second(r):
        c.contains(r.command("run cat /keep.txt"), r"\npersist across reboots\n", "reboot: cat /keep.txt")
        c.contains(r.command("cat /keep.lnk"), r"\npersist across reboots\n", "reboot: cat a symlink")
        r.send("run t_fs churn &\r")
        r.wait_for(lambda t: "churn: started" in t, COMMAND_TIMEOUT, "churn: started")
        time.sleep(delay)
        r.kill()  # 不关机，直接杀掉：磁盘停在写到一半的地方

    def third(r):
        out = r.command("run t_fs verify")
        m = c.contains(out, r"churn: (\d+) records intact\n", f"verify after killing QEMU {delay:.2f}s into churn")
        if m:
            c.expect(int(m.group(1)) > 0, f"verify: no records survived {delay:.2f}s of churn")
        check_counts(c, out, "t_fs")
        scrub_ok(c, r.command("run scrub"), "scrub after power loss")
        c.contains(r.command("run t_fs scrubfile"), r"scrubfile: written\n", "t_fs scrubfile")
        r.send("shutdown\r")
        c.expect(r.finish(COMMAND_TIMEOUT) == 0, "shutdown after verify")

    def fourth(r):
        out = r.command("run scrub")
        c.contains(out, r"scrub: the file system is damaged: IoError\n", "scrub after corrupting a data block")
        exited(c, out, "scrub", 1)
        c.contains(r.command("run cat /scrub.dat"), r"cat: /scrub.dat: IoError\n", "cat a corrupted file")
        exited(c, r.command("run rm /scrub.dat"), "rm", 0)  # 删除不读数据块
        scrub_ok(c, r.command("run scrub"), "scrub after removing the corrupted file")

    reboot(q, c, "boot2", second)
    reboot(q, c, "boot3", third)
    if corrupt_scrub_file(q, c):
        reboot(q, c, "boot4", fourth)


def case_fs(q, c, mode):
    # shell 里的文件操作：ls、重定向、cat、mkdir、cd、rm
    out = q.command("run ls /")
    c.contains(out, r"\ndir +1 +0 bin\n", "run ls /")
    c.contains(out, r"\ndir +1 +0 dev\n", "run ls /")
    c.contains(q.command("run ls /bin"), r"\nfile +1 +\d+ hello\n", "run ls /bin")
    # 设备文件：mkfs 建的 /dev，ls 显示设备号；重定向到 /dev/null 什么都不输出，写 /dev/console 输出到串口
    out = q.command("run ls /dev")
    for name, major in (("console", 1), ("null", 2), ("zero", 3)):
        c.contains(out, rf"\ndev +1 +{major} {name}\n", "run ls /dev")
    out = q.command("run echo into the void > /dev/null")
    c.expect("into the void" not in out.split("\n", 1)[1], f"echo > /dev/null printed something:\n{indent(out)}")
    exited(c, out, "echo", 0)
    c.contains(q.command("run cat /dev/null"), r"cat /dev/null\r?\n\[proc\] pid \d+ \(cat\) exited with code 0", "run cat /dev/null")
    c.contains(q.command("run echo via the console > /dev/console"), r"\nvia the console\n", "echo > /dev/console")
    q.command("run echo hello file system > /hello.txt")
    c.contains(q.command("run cat /hello.txt"), r"\nhello file system\n", "run cat /hello.txt")
    c.contains(q.command("run wc < /hello.txt"), r"\n1 3 18\n", "run wc < /hello.txt")
    c.contains(q.command("run ls /hello.txt"), r"\nfile +1 +18 /hello.txt\n", "run ls /hello.txt")
    # 硬链接：两个名字一个文件，链接数是 2；删掉原来的名字，新名字照常
    exited(c, q.command("run ln /hello.txt /hl"), "ln", 0)
    c.contains(q.command("run ls /hl"), r"\nfile +2 +18 /hl\n", "run ls /hl after ln")
    q.command("echo appended >> /hl")
    exited(c, q.command("rm /hello.txt"), "rm", 0)
    c.contains(q.command("cat /hl"), r"\nhello file system\nappended\n", "cat /hl after rm of the other name")
    c.contains(q.command("ls /hl"), r"\nfile +1 +27 /hl\n", "ls /hl after rm of the other name")
    exited(c, q.command("mv /hl /hello.txt"), "mv", 0)
    c.contains(q.command("ln /bin /b2"), r"ln: /bin -> /b2: PermissionDenied\n", "ln a directory")
    q.command("run echo a b c | cat >/p.txt")
    c.contains(q.command("run cat </p.txt"), r"\na b c\n", "run echo | cat > F")
    exited(c, q.command("run mkdir /d /d/e"), "mkdir", 0)
    q.command("cd /d/e")
    q.command("run echo deep > f")
    c.contains(q.command("run ls"), r"\nfile +1 +5 f\n", "run ls in /d/e")
    q.command("cd ..")
    c.contains(q.command("run ls"), r"\ndir +1 +0 e\n", "run ls in /d")
    c.contains(q.command("run rm /d"), r"rm: /d: NotEmpty\n", "run rm /d")
    exited(c, q.command("run rm e/f e"), "rm", 0)
    q.command("cd")
    exited(c, q.command("run rm /d /hello.txt /p.txt"), "rm", 0)
    out = q.command("run ls /")
    names = sorted(re.findall(r"^\w+ +\d+ +\d+ (\S+)$", out, re.M))
    c.expect(names == ["bin", "dev"], f"run ls / after rm: {names}")
    # 出错的情况
    c.contains(q.command("cd /nope"), r"cd: /nope: NotFound\n", "cd /nope")
    c.contains(q.command("cd /bin/hello"), r"cd: /bin/hello: NotDir\n", "cd /bin/hello")
    c.contains(q.command("run cat /nope"), r"cat: /nope: NotFound\n", "run cat /nope")
    c.contains(q.command("run cat < /nope"), r"sh: /nope: NotFound\n", "run cat < /nope")
    c.contains(q.command("run echo x > /bin"), r"sh: /bin: IsDir\n", "run echo x > /bin")
    c.contains(q.command("run echo x >"), r"sh: missing file name after < or >\n", "run echo x >")
    c.contains(q.command("run mkdir /bin"), r"mkdir: /bin: Exists\n", "run mkdir /bin")
    # >> 追加；mv 改名、挪进目录、换掉已有的文件
    q.command("echo one > /log")
    q.command("echo two >> /log")
    q.command("echo three >>/log")
    c.contains(q.command("cat /log"), r"\none\ntwo\nthree\n\[proc\]", "echo >> appends")
    exited(c, q.command("mv /log /log2"), "mv", 0)
    c.contains(q.command("cat /log2"), r"\none\ntwo\nthree\n", "cat after mv")
    c.contains(q.command("cat /log"), r"cat: /log: NotFound\n", "old name after mv")
    q.command("mkdir /m")
    q.command("echo x > /m/log2")
    exited(c, q.command("mv /log2 /m"), "mv", 0)  # 挪进目录，换掉里面同名的文件
    c.contains(q.command("cat /m/log2"), r"\none\ntwo\nthree\n", "mv into a directory replaces the file there")
    c.contains(q.command("mv /nope /x"), r"mv: /nope -> /x: NotFound\n", "mv a missing file")
    c.contains(q.command("mv /m /m/sub"), r"mv: /m -> /m/sub: InvalidArgument\n", "mv a directory into itself")
    exited(c, q.command("rm /m/log2 /m"), "rm", 0)
    fs_symlinks(q, c)
    # 程序从文件系统加载：复制一个程序、按路径运行它（进程名是文件名）；不是 ELF 的文件、目录不能运行
    q.command("run cat /bin/hello > /h")
    out = q.command("run /h")
    c.contains(out, r"Hello from U-mode!", "run /h (a copy of hello)")
    exited(c, out, "h", 0)
    q.command("run echo not an ELF > /bad")
    c.contains(q.command("run /bad"), r"sh: cannot load /bad: BadElf\n", "run /bad")
    c.contains(q.command("run /bin"), r"no such program: /bin\n", "run /bin")
    exited(c, q.command("run rm /h /bad"), "rm", 0)
    # 系统调用的边界情况、并发；之后整个文件系统检查一遍
    check_counts(c, q.command("run t_fs"), "t_fs")
    # 多核下同时读写：读者在快照上读，每次读到的都是某个完整的版本
    check_counts(c, q.command("run t_fsmp"), "t_fsmp")
    scrub_ok(c, q.command("run scrub"), "run scrub")
    # 关机之后：重新启动看文件还在，再测掉电
    q.command("run echo persist across reboots > /keep.txt")
    q.command("ln -s keep.txt /keep.lnk")
    q.after_shutdown.append((c, lambda c: check_fs_reboots(q, c)))


def fs_symlinks(q, c):
    """符号链接：ln -s、ls 显示目标、跟着走的 cat、cd、建文件；悬空的、有环的；rm 只删链接。"""
    q.command("mkdir /sd; echo via symlink > /sd/f")
    exited(c, q.command("ln -s sd/f /sl"), "ln", 0)  # 相对的目标从链接所在的目录（/）算起
    c.contains(q.command("ls /sl"), r"\nlink +1 +4 /sl -> sd/f\n", "ls a symlink")
    c.contains(q.command("cat /sl"), r"\nvia symlink\n", "cat through a symlink")
    q.command("ln -s /sd /sdl")
    c.contains(q.command("ls /sdl"), r"\nfile +1 +12 f\n", "ls a symlink to a directory lists the directory")
    c.contains(q.command("ls /"), r"\nlink +1 +3 sdl -> /sd\n", "ls shows symlinks in a directory")
    c.contains(q.command("cd /sdl; pwd; cat f; cd /"), r"\n/sd\nvia symlink\n", "cd through a symlink")
    q.command("ln -s /nowhere /dl")
    c.contains(q.command("ls /dl"), r"\nlink +1 +8 /dl -> /nowhere\n", "ls a dangling symlink")
    c.contains(q.command("cat /dl"), r"cat: /dl: NotFound\n", "cat a dangling symlink")
    q.command("echo made > /dl")
    c.contains(q.command("cat /nowhere"), r"\nmade\n", "> through a dangling symlink creates the target")
    q.command("ln -s lp /lp")
    c.contains(q.command("cat /lp"), r"cat: /lp: SymlinkLoop\n", "cat a symlink loop")
    c.contains(q.command("ln -s /x /sl"), r"ln: /x -> /sl: Exists\n", "ln -s onto an existing name")
    exited(c, q.command("rm /sl /sdl /dl /lp"), "rm", 0)
    c.contains(q.command("cat /sd/f /nowhere"), r"\nvia symlink\nmade\n", "rm a symlink keeps the target")
    exited(c, q.command("rm /sd/f /sd /nowhere"), "rm", 0)


def case_smp(q, c, mode):
    # 几个进程同时 fork/exit/wait、写同一个管道、sbrk、留下孤儿，再杀掉在别的 hart 上死循环的进程
    check_counts(c, q.command("run t_smp"), "t_smp")
    if q.smp < 3:
        return
    # 真的在并行：两个死循环的后台进程在不同的 hart 上同时运行，0.5 秒里加起来拿到的 tick
    # 比一个 hart 能给的（100 Hz × 0.5 秒 = 50 个）多得多。单核时两个加起来最多 50 个
    spinners = [start_background(q, c, "spin") for _ in range(2)]
    if None in spinners:
        return
    before = ps_table(q, c)
    time.sleep(SPIN_SECONDS)
    after = ps_table(q, c)
    got = sum(after.get(pid, ("", 0, ""))[1] - before.get(pid, ("", 0, ""))[1] for pid in spinners)
    one_hart = int(SPIN_SECONDS * 100)
    c.expect(got >= one_hart * 1.3, f"ps: two spinners got {got} ticks in {SPIN_SECONDS}s on {q.smp} harts, "
             f"expected well over {one_hart}")
    for pid in spinners:
        q.command(f"kill {pid}")
    c.expect(ps_table(q, c) == {}, "ps: processes left after killing all of them")


# 每个用例覆盖的文件。改了 CORE 里的文件（或者没列出的内核文件）就跑全部用例。
CORE = ["build.zig", "linker.ld", "src/main.zig", "src/riscv.zig", "src/trap.zig", "src/vm.zig", "src/page.zig",
        "src/dtb.zig", "src/uart.zig", "src/proc.zig", "src/syscall.zig", "src/abi.zig", "src/spinlock.zig", "src/hart.zig", "src/ipi.zig",
        "src/canary.zig", "src/kstack.zig",
        "src/file.zig", "user/start.zig", "user/sys.zig", "user/init.zig", "user/sh.zig", "tools/qemu_test.py"]
NOT_KERNEL = ["src/tests.zig"]  # 只在单元测试里用
CASES = {
    # 名字: (函数, 覆盖的文件)
    "shell": (case_shell, []),
    "interrupts": (case_interrupts, ["src/timer.zig", "src/sbi.zig", "src/plic.zig", "user/spin.zig"]),
    "user": (case_user, ["user/linker.ld", "user/hello.zig", "user/fault.zig", "user/tests/t_panic.zig",
                         "user/tests/t_time.zig"]),
    "sched": (case_sched, ["src/timer.zig", "user/spin.zig", "user/ticker.zig", "user/hello.zig", "user/tests/t_fork.zig",
                           "user/tests/t_sleep.zig"]),
    "syscall": (case_syscall, ["user/tests/t_sys.zig"]),
    "fork": (case_fork, ["user/hello.zig", "user/tests/t_fork.zig", "user/tests/t_read.zig"]),
    "protection": (case_protection, ["user/linker.ld", "user/tests/t_wx.zig", "user/tests/t_stack.zig",
                                     "user/tests/t_priv.zig", "user/tests/t_fp.zig", "user/tests/t_noperm.zig",
                                     "user/tests/noperm.ld"]),
    "args": (case_args, ["user/echo.zig", "user/tests/t_args.zig"]),
    "pipe": (case_pipe, ["src/pipe.zig", "user/echo.zig", "user/cat.zig", "user/wc.zig", "user/tests/t_pipe.zig",
                         "user/tests/t_args.zig"]),
    "sbrk": (case_sbrk, ["user/tests/t_sbrk.zig"]),
    "cow": (case_cow, ["user/tests/t_cow.zig"]),
    "demand": (case_demand, ["src/fsys.zig", "user/spin.zig", "user/tests/t_demand.zig"]),
    "tools": (case_tools, ["src/fsys.zig", "user/test.zig", "user/expr.zig", "user/seq.zig", "user/sleep.zig", "user/head.zig",
                           "user/tail.zig", "user/grep.zig", "user/cp.zig", "user/touch.zig", "user/tee.zig", "user/xargs.zig",
                           "user/echo.zig", "user/cat.zig", "user/wc.zig", "user/ls.zig", "user/rm.zig", "user/spin.zig",
                           "user/hello.zig"]),
    "ipi": (case_ipi, ["src/sbi.zig", "user/tests/t_ipi.zig"]),
    "disk": (case_disk, ["src/sleeplock.zig", "src/bio.zig", "src/virtio_disk.zig", "src/fsys.zig", "src/mkfs.zig",
                         "user/tests/t_disk.zig"]),
    "fs": (case_fs, ["src/sleeplock.zig", "src/bio.zig", "src/virtio_disk.zig", "src/btree.zig", "src/ctree.zig",
                     "src/fs.zig", "src/fsys.zig", "src/mkfs.zig", "user/ls.zig", "user/mkdir.zig", "user/rm.zig",
                     "user/cat.zig", "user/echo.zig", "user/wc.zig", "user/scrub.zig", "user/mv.zig", "user/ln.zig", "user/tests/t_fs.zig",
                     "user/tests/t_fsmp.zig"]),
    "smp": (case_smp, ["src/timer.zig", "src/plic.zig", "src/pipe.zig", "user/spin.zig", "user/tests/t_smp.zig"]),
}


def changed_files():
    """工作区里相对 HEAD 改过的文件，加上还没被 git 跟踪的新文件。"""
    out = []
    for cmd in (["git", "diff", "--name-only", "HEAD"], ["git", "ls-files", "--others", "--exclude-standard"]):
        out += subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, text=True, check=True).stdout.split()
    return sorted(set(out))


def cases_for(files):
    """按改动的文件挑出要跑的用例。返回 (用例名的集合, 每个文件选中了什么的说明)。"""
    selected, notes = set(), []
    for f in files:
        kernel = f.startswith(("src/", "user/")) or f in CORE
        hits = [name for name, (_, covers) in CASES.items() if f in covers]
        if f in NOT_KERNEL or not kernel:
            continue
        if f.startswith("user/tests/") and not os.path.exists(os.path.join(ROOT, f)):
            continue  # 删掉的测试程序
        if f in CORE or not hits:
            selected |= set(CASES)
            notes.append(f"{f} -> all")
        else:
            selected |= set(hits)
            notes.append(f"{f} -> {', '.join(hits)}")
    return selected, notes


def build(mode, prefix):
    cmd = ["zig", "build", f"-Doptimize={mode}", "-p", prefix, "-Dtest-programs=true"]
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # 链接器的警告会以 "error: warning(link)" 打印出来，但 zig build 仍然返回 0，所以输出必须为空
    if r.returncode != 0 or r.stdout.strip():
        raise Failure(f"`{' '.join(cmd)}` failed (exit {r.returncode}) or printed output:\n{indent(r.stdout)}")
    load_config(os.path.join(prefix, "config.json"))


def load_config(path):
    """读 zig build 生成的 config.json（build.zig 的 Config），设好上面那些常量。"""
    global QEMU, QEMU_DISK, GUARD_PAGE, USER_SPACE, MAX_PROCS, MAX_ARGS, FS_BLOCKS, RAW_BLOCKS, BLOCK_SIZE
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    QEMU = cfg["qemu"]
    QEMU_DISK = cfg["qemu_disk"] + [cfg["qemu_drive"] + "{disk}"] + cfg["qemu_disk_device"]
    GUARD_PAGE = tuple(cfg["user_stack_guard"])
    USER_SPACE = tuple(cfg["user_space"])
    MAX_PROCS = cfg["max_procs"]
    MAX_ARGS = cfg["max_args"]
    FS_BLOCKS = cfg["fs_blocks"]
    RAW_BLOCKS = cfg["raw_blocks"]
    BLOCK_SIZE = cfg["block_size"]
    if cfg["run_smp"] not in DEFAULT_SMP:
        raise Failure(f"zig build run uses {cfg['run_smp']} harts, but DEFAULT_SMP is {DEFAULT_SMP}")


def check_boot(q, c, smp):
    text = q.wait_for(lambda t: "Type 'help' for commands.\n> " in t or "KERNEL PANIC" in t, BOOT_TIMEOUT, "the first prompt")
    for pattern in [
        r"Hello from a Zig kernel on RISC-V!",
        r"\[ok\] trap vector installed",
        r"\[trap\] breakpoint at 0x[0-9a-f]+, skipping it",
        rf"\[ok\] device tree: \d+ MiB RAM at 0x80000000, timebase {TIMEBASE_HZ} Hz",
        r"\[ok\] page allocator: \d+ free pages",
        r"\[ok\] Sv39 paging enabled: .*, 80 stack guard pages unmapped\n",
        r"\[ok\] stack overflow check: hitting a guard page traps onto the trap stack\n",
        rf"\[ok\] virtio disk: {FS_BLOCKS + RAW_BLOCKS} blocks of 4 KiB \({(FS_BLOCKS + RAW_BLOCKS) * BLOCK_SIZE >> 20} MiB\), irq 1, flush\n",
        rf"\[ok\] file system: \d+ of {FS_BLOCKS} blocks free, generation \d+\n",
        r"\[ok\] interrupt sources enabled: timer at 100 Hz, keyboard via UART \+ PLIC, IPIs, disk\n",
        rf"\[ok\] {smp} harts? running, booted on hart \d+\n",
    ]:
        c.contains(text, pattern, "boot log")


# 内核栈至少要留这么多字节没用到过（shutdown 时内核打印每种栈用到过的最深处，kstack.deepest）。
# 最底下 256 字节是金丝雀，碰到就 panic；再留一些，栈用得越来越深时在这里先发现，而不是等到真的溢出
STACK_MARGIN = 2048
STACK_USE = re.compile(r"\[stack\] deepest use: process (\d+) of (\d+), boot (\d+) of (\d+), trap (\d+) of (\d+) bytes\n")


def check_stack_use(c, text):
    m = STACK_USE.search(text)
    c.expect(m is not None, "shutdown: no '[stack] deepest use' line")
    if m is None:
        return
    for i, name in enumerate(["process", "boot", "trap"]):
        used, size = int(m.group(2 * i + 1)), int(m.group(2 * i + 2))
        c.expect(size - used >= STACK_MARGIN, f"{name} stack: {used} of {size} bytes used, less than {STACK_MARGIN} left")


def fresh_mem(q, c):
    """在一个新的 shell 里看空闲页数，用来比较前后有没有漏页。
    按需分页：进程的页用到才分配，一直在运行的 shell 执行过的命令越多、用到的页越多，前后直接比较不出漏页。
    所以每次都先让 shell 自己结束，init 重新启动一个（init 自己的这段代码第一次就分配好了），新的 shell 第一条命令就是 mem，
    两次走的是同一条路，用到的页一样多。"""
    out = q.command("kill $$")
    c.contains(out, r"init: sh exited, restarting it\n", "kill $$ before mem")
    return free_pages(q.command("mem"))


def run_session(kernel, disk, log_path, names, mode, smp):
    """启动一次 QEMU，依次运行 names 里的用例。返回 [(名字, Checks)]，第一项是启动和收尾的检查。"""
    session = Checks()
    results = [("boot", session)]
    current = session  # 出错时，错误记在正在跑的那一项上
    q = Qemu(kernel, smp, disk)
    try:
        check_boot(q, session, smp)
        before = fresh_mem(q, session)
        for name in names:
            current = Checks()
            results.append((name, current))
            CASES[name][0](q, current, mode)
        current = session  # 收尾的检查也记在 boot 上
        after = fresh_mem(q, session)
        session.expect(before is not None and before == after, f"mem: free pages changed from {before} to {after} (leak?)")
        q.send("shutdown\r")
        code = q.finish(COMMAND_TIMEOUT)
        session.expect(code == 0, f"shutdown: QEMU exit code {code}, expected 0")
        check_stack_use(session, q.text())
        for c, check in q.after_shutdown:
            check(c)
    except Failure as e:
        current.failures.append(str(e))  # 之后的用例没有运行
    finally:
        q.kill()
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(q.text())
    if "KERNEL PANIC" in q.text():
        session.failures.append("KERNEL PANIC in the serial output")
    return results


def run_mode(mode, names, smps):
    """构建一次，每个 hart 数各启动一次 QEMU。返回 [(hart 数, 名字, Checks, 构建错误, 串口日志)]。"""
    prefix = os.path.join(ROOT, "zig-out", "qemu-test", mode)
    try:
        build(mode, prefix)
    except Failure as e:
        return [(None, "build", Checks(), str(e), None)]
    kernel = os.path.join(prefix, "bin", "kernel")
    results = []
    for smp in smps:
        log = os.path.join(prefix, f"serial-smp{smp}.log")
        # 每次启动用一份新的磁盘镜像（测试会改写它）
        disk = os.path.join(prefix, f"disk-smp{smp}.img")
        shutil.copyfile(os.path.join(prefix, "disk.img"), disk)
        results += [(smp, n, c, None, log) for n, c in run_session(kernel, disk, log, names, mode, smp)]
    return results


def main():
    parser = argparse.ArgumentParser(description="Run the kernel in QEMU and check the results.")
    parser.add_argument("cases", nargs="*", help=f"cases to run (default: all): {', '.join(CASES)}")
    parser.add_argument("--changed", action="store_true", help="only run the cases covering files changed since HEAD")
    parser.add_argument("--mode", action="append", choices=MODES, help="optimize mode (repeatable; default: safe)")
    parser.add_argument("--all-modes", action="store_true", help="test all four optimize modes")
    parser.add_argument("--smp", action="append", type=int,
                        help=f"number of harts given to QEMU (repeatable; default: {' and '.join(map(str, DEFAULT_SMP))})")
    parser.add_argument("--list", action="store_true", help="list the cases and the files they cover")
    args = parser.parse_args()

    if args.list:
        print(f"{'(all)':<11} {' '.join(CORE)}")
        for name, (_, covers) in CASES.items():
            print(f"{name:<11} {' '.join(covers) or '(only the files above)'}")
        return 0
    unknown = [n for n in args.cases if n not in CASES]
    if unknown:
        parser.error(f"unknown case(s): {', '.join(unknown)}; choose from {', '.join(CASES)}")
    if args.changed:
        selected, notes = cases_for(changed_files())
        for note in notes:
            print(f"changed: {note}")
        if not selected:
            print("no kernel-related changes, nothing to test")
            return 0
    else:
        selected = set(args.cases) or set(CASES)
    names = [n for n in CASES if n in selected]
    modes = MODES if args.all_modes else (args.mode or ["safe"])
    smps = args.smp or DEFAULT_SMP

    failed = False
    for mode in modes:
        started = time.monotonic()
        results = run_mode(mode, names, smps)
        for smp, name, c, error, log in results:
            if error:
                c.failures.append(error)
            status = "PASS" if not c.failures else "FAIL"
            harts = f"smp{smp}" if smp else ""
            print(f"{status}  {mode:<5}  {harts:<5}  {name:<10}  {c.count} checks")
            for f in c.failures:
                print(f"    - {f}")
            if c.failures:
                failed = True
                if log:
                    print(f"    serial log: {os.path.relpath(log, ROOT)}")
        print(f"      {mode:<5}  {time.monotonic() - started:.1f}s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
