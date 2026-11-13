//! 进程和调度，照 xv6 的结构写：
//!
//! - 每个 hart 有自己的调度器 scheduler()，在这个 hart 的启动栈上永远循环，依次扫描进程表，
//!   遇到 runnable 的进程就切过去，等它切回来再接着往下扫。它只管调度，别的什么都不做。
//!   进程不绑定 hart：这次在哪个 hart 上让出 CPU，下次可能在另一个 hart 上接着运行。
//! - 进程要让出 CPU 时，先拿上自己的锁、改自己的状态，再调用 sched() 切回调度器：yield（时间片用完）、
//!   sleep（等某件事）、exit 都是这样。
//! - 等待用 WaitQueue：每个等待条件旁边放一个队列（管道的 readers/writers、timer.waiters、uart.rx_waiters、
//!   进程自己的 child_exit……），q.wait(lock) 睡下，q.wakeAll(lock) 叫醒排在里面的进程。
//! - 进程之间有父子关系：fork 复制当前进程，exec 换掉地址空间，exit 之后变成 zombie，等父进程 wait 回收。
//!   第一个进程 init（pid 1）由 kmain 创建，父进程先结束的孤儿交给它回收。
//! - kill 只做标记、叫醒在睡的进程；被杀的进程回到 U 模式之前自己结束（checkKilled）。
//!   正在别的 hart 上运行的，给那个 hart 发核间中断，让它马上进内核（ipi.zig）。
//! - 有进程变成 runnable（wakeup、kill、fork）时，给一个在 wfi 里空等的 hart 发核间中断，让它马上来运行。
//! - 每个进程有自己的 fd 表（files），指向全局文件表里的 File（file.zig）。fork 复制 fd 表，
//!   exec 保留，结束时全部关掉。
//!
//! 用户地址空间（都在 vm.user_base..vm.user_end 之内，vm.Space）：
//!   0x4000_0000 起    程序的各个段（user/linker.ld），按段设置 R/W/X，都带 U 位
//!   紧接着            堆：从最后一个段之后的页边界（堆的起点）到 brk，sbrk 调整，可读写
//!   ...              没有页
//!   栈底下面一页      保护页，永远没有页：栈溢出时触发缺页异常，而不是悄悄写进堆里
//!   0x8000_0000 往下  用户栈，最多 1 MiB（vm.stack_max），可读写。最顶上放着 exec 传进来的命令行参数
//! 这些都是按需分页的（vm.fault）：exec 只记下各个段在程序文件里的位置，sbrk 只挪 brk，
//! 页在第一次被访问时才分配，段里的页那时才从程序文件读进来。
//!
//! 锁（照 xv6 的 proc.c，详见 docs/process.md 的“锁”一节）：
//! - 每个进程的 lock 保护它的 state、hart、killed、xstatus、pid、cpu_time、name。调度器拿着它切到进程，
//!   进程拿着它切回调度器，所以“改状态 + 切换”在别的 hart 看来是一步完成的。
//! - wait_lock 保护所有进程的 parent，wait 拿着它睡在自己身上。加锁顺序：wait_lock 在前，进程锁在后；
//!   别的锁（管道、串口、timer.lock）也都在进程锁前面拿，进程锁之后只会再拿页分配器、文件表这种不再往下拿锁的。
//! - 其他字段（space、context、files、sleeplocks、cwd）只有进程自己会读写（没有线程），不用加锁；
//!   父进程 wait 回收 zombie 时它已经不再运行了。

const std = @import("std");
const builtin = @import("builtin");
const riscv = @import("riscv.zig");
const uart = @import("uart.zig");
const page = @import("page.zig");
const vm = @import("vm.zig");
const trap = @import("trap.zig");
const abi = @import("abi.zig");
const file = @import("file.zig");
const hart = @import("hart.zig");
const ipi = @import("ipi.zig");
const spinlock = @import("spinlock.zig");
const fs = @import("fs.zig");
const fsys = @import("fsys.zig");
const canary = @import("canary.zig");
const kstack = @import("kstack.zig");
const loader = @import("loader.zig");
const kstat = @import("kstat.zig");
const timer = @import("timer.zig");
const sleeplock = @import("sleeplock.zig");
const Spinlock = spinlock.Spinlock;

/// 内核里只嵌着 init（见 build.zig）：第一个进程要在挂载文件系统之前加载。别的程序都从文件系统的 /bin 加载（exec）。
const init_image = @embedFile("init");

/// 进程名：exec 的程序的文件名（路径的最后一段），最多 16 字节（和 abi.ProcInfo 一样），长了截断。
/// 存在进程自己的结构体里：fork 复制、exec 换掉，不指向别处。
pub const Name = struct {
    buf: [16]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(s: []const u8) Name {
        var n: Name = .{ .len = @intCast(@min(s.len, 16)) };
        @memcpy(n.buf[0..n.len], s[0..n.len]);
        return n;
    }

    pub fn slice(n: *const Name) []const u8 {
        return n.buf[0..n.len];
    }
};

pub const max_procs = abi.max_procs;

/// 进程的状态，和 procinfo 交给用户程序的是同一个类型。
pub const State = abi.ProcState;

pub const Process = struct {
    /// 保护 under_lock 里的字段。槽位一直在，锁也一直在：回收时不能连锁一起清掉（见 fill）
    lock: Spinlock = .init("proc", .proc),
    /// 归 lock 管的字段，只能经过 locked() 读写（它检查拿着 lock）
    under_lock: Guarded = .{},
    /// 归 wait_lock 管的字段，只能经过 family() 读写（它检查拿着 wait_lock）
    under_wait_lock: Family = .{},
    /// 这个进程的地址空间：根页表，各个段、堆从哪到哪（按需分页要用）
    space: vm.Space = undefined,
    /// 不在运行时，它的内核上下文保存在这里（见 switchContext）
    context: Context = undefined,
    /// 在某个 WaitQueue 里排着时的下一个进程，和 queued 一起由那个队列的锁（保护等待条件的锁）保护
    wait_next: ?*Process = null,
    /// 在不在某个 WaitQueue 里：wakeAll 把它摘下来时清掉；被 kill 叫醒的还排着，自己摘（见 WaitQueue.wait）
    queued: bool = false,
    /// 打开的文件，下标就是 fd
    files: [abi.max_fds]?*file.File = @splat(null),
    /// 拿着每一级的睡眠锁各几把（sleeplock.zig，检查加锁顺序）。只有自己改；回到 U 模式时必须都是 0
    sleeplocks: sleeplock.Held = .{},
    /// 当前目录的 inode 号，相对路径从这里开始找。fork 继承，exec 不变；只有自己读写
    cwd: u64 = fs.root_ino,

    /// 归进程锁管的字段。别的 hart 上的调度器、kill、wait、procinfo 都会读写它们
    pub const Guarded = struct {
        state: State = .unused,
        /// state 为 running 时，它在哪个 hart 上运行（kill 要给那个 hart 发核间中断）
        hart: usize = 0,
        pid: usize = 0,
        /// exec 会改，procinfo 要读
        name: Name = .{},
        /// 被 kill 了的话是原因。进程回到 U 模式之前看到它就自己结束（见 checkKilled）
        killed: ?[]const u8 = null,
        /// zombie 的结束状态，父进程 wait 时取走：正常退出时是退出码，被杀时是 abi.killed_status
        xstatus: u32 = 0,
        /// 用掉的 CPU 时间（time CSR 的单位）：调度器每次切到它、它切回来时累加中间的差值，U 模式和内核里的都算
        cpu_time: u64 = 0,
    };

    /// 归 wait_lock 管的字段：父子关系
    pub const Family = struct {
        /// 父进程。init 没有父进程；父进程先结束时，子进程交给 init（见 finish）
        parent: ?*Process = null,
        /// 在 wait 里等子进程结束的父进程排在这里，子进程的 finish、reparent 叫醒它
        child_exit: WaitQueue = .{},
    };

    /// 归进程锁管的字段。没拿着这个进程的锁就 panic：原来这是一条写在注释里的约定
    /// （“state、pid……只在拿着它的锁时读写”），漏了的话只有两个 hart 恰好同时碰它时才出错。
    pub fn locked(p: *Process) *Guarded {
        if (!p.lock.holding()) std.debug.panic("process fields used without holding the process lock (slot {d})", .{slotOf(p)});
        return &p.under_lock;
    }

    /// 归 wait_lock 管的字段（父子关系）。没拿着 wait_lock 就 panic。
    pub fn family(p: *Process) *Family {
        if (!wait_lock.holding()) std.debug.panic("parent/child_exit used without holding wait_lock (slot {d})", .{slotOf(p)});
        return &p.under_wait_lock;
    }

    /// 只给 panic 信息用：不拿锁读（就要停机了，锁可能在别人手里，读到半新半旧的也只是信息不准）。
    pub fn racyForPanic(p: *const Process) *const Guarded {
        return &p.under_lock;
    }

    /// 单元测试用：直接摆好、直接看，不拿锁（测试里只有一个线程）。内核代码不能用
    fn testFields(p: *Process) *Guarded {
        return &p.under_lock;
    }

    fn testFamily(p: *Process) *Family {
        return &p.under_wait_lock;
    }
};

/// 当前进程的 pid（getpid）。
pub fn currentPid() usize {
    const p = current().?;
    p.lock.acquire();
    defer p.lock.release();
    return p.locked().pid;
}

/// p 在进程表里的下标（panic 信息里用：不拿锁也能说出是哪个进程）。
fn slotOf(p: *const Process) usize {
    return (@intFromPtr(p) - @intFromPtr(&table)) / @sizeOf(Process);
}

/// 进程表。槽位 i 的进程用 kstack.process[i] 作内核栈。
pub var table: [max_procs]Process = @splat(.{});

/// 保护所有进程的 parent 字段（xv6 的 wait_lock）。见文件开头的加锁顺序。
var wait_lock: Spinlock = .init("wait", .wait);

/// 每个 hart 自己的状态（xv6 的 struct cpu），按 hart 编号下标。只有这个 hart 自己读写自己那一项。
const Cpu = struct {
    /// 正在这个 hart 上运行的进程，在调度器里时为 null
    proc: ?*Process = null,
    /// 调度器切到进程时保存的上下文，进程调用 sched() 时切回这里
    context: Context = undefined,
};
var cpus: [hart.max]Cpu = @splat(.{});

/// 当前 hart 上正在运行的进程，在调度器里时为 null。
/// 关着中断读：进程只在关着中断时切换，读到的值在开中断之前都不会变。
pub fn current() ?*Process {
    return cpus[hart.id()].proc;
}

var next_pid: std.atomic.Value(usize) = .init(1);

/// 第一个进程。孤儿交给它回收，它自己不能结束。userinit 设置之后不再改。
var init_proc: ?*Process = null;

/// 前台进程的 pid，0 表示没有。shell 用 setfg 系统调用设置，按 Ctrl-C 时内核杀掉它（可能在另一个 hart 上）。
var foreground: std.atomic.Value(usize) = .init(0);

/// 切换时保存的内核上下文。按 C 调用约定，跨函数调用需要保持不变的只有
/// ra、sp 和 s0..s11，其他寄存器调用方本来就不指望它们保持原值。
const Context = extern struct {
    ra: usize,
    sp: usize,
    s: [12]usize,
};

/// 找一个空槽位，拿着它的锁返回（对应 xv6 的 allocproc）。拿着锁，别的 hart 就看不到它半填好的样子。
/// 槽位空着，它的内核栈没人用，顺便重新写上金丝雀（只写最底下的，栈的其余部分留着上一个进程用过的痕迹，
/// 高水位量的是整个运行期间的最深值，见 kstack.deepest）。
fn allocSlot() error{TooManyProcesses}!*Process {
    for (&table) |*p| {
        p.lock.acquire();
        if (p.locked().state == .unused) {
            canary.set(stackOf(p));
            return p;
        }
        p.lock.release();
    }
    return error.TooManyProcesses;
}

/// 把 p 除了锁以外的字段都换成 new 的（填一个新进程、回收时清空）。调用方拿着 p.lock：
/// 直接 `p.* = .{...}` 会连锁一起覆盖，别的 hart 可能正在等这把锁。
fn fill(p: *Process, new: Process) void {
    inline for (comptime std.meta.fieldNames(Process)) |name| {
        if (comptime !std.mem.eql(u8, name, "lock")) @field(p, name) = @field(new, name);
    }
}

/// 进程从 U 模式陷入时的 TrapFrame，总在它的内核栈最顶端（trapEntry 从 sscratch = 栈顶开始压栈，
/// trapExit 回到 U 模式时也按这个位置设置 sscratch）。
pub fn frameOf(p: *Process) *trap.TrapFrame {
    const stack = stackOf(p);
    return @ptrCast(@alignCast(stack[stack.len - @sizeOf(trap.TrapFrame) ..]));
}

/// 进程 p 的内核栈（槽位 i 用 kstack.process[i]，24 KiB，静态分配：页分配器只能一页一页地给，给不出连续的几页）。
/// 栈下面是保护页（kstack.zig），最底下放着金丝雀（canary.zig），allocSlot 写上，sched、回到 U 模式之前检查。
fn stackOf(p: *Process) *[kstack.Process.stack_size]u8 {
    const slot = (@intFromPtr(p) - @intFromPtr(&table)) / @sizeOf(Process);
    return &kstack.process[slot].stack;
}

/// 当前进程的内核栈溢出了（金丝雀被改了）就 panic。切回调度器（sched）、回到 U 模式之前调用：
/// 这时栈已经退回去了，但溢出时踩坏的东西（相邻进程的 TrapFrame）还没被用到。
pub fn checkStack() void {
    const p = current().?;
    canary.check(stackOf(p), "pid {d} ({s})", .{ p.racyForPanic().pid, p.racyForPanic().name.slice() }); // 只给 panic 信息用
}

/// 从程序入口开始运行的 TrapFrame：a0 = argc，a1 = sp = 栈上 Arg 数组的地址（见 pushArgs），
/// 其他寄存器全为 0。
fn startFrame(frame: *trap.TrapFrame, image: loader.Image) void {
    frame.* = .{
        .regs = @splat(0),
        .sepc = image.entry,
        // SPP = 0：sret 回到 U 模式；SPIE = 1：回到 U 模式后打开中断，时钟和键盘照常工作。
        // SIE 必须清掉：trapExit 一开始就写回 sstatus，SIE = 1 的话恢复寄存器的途中就可能被中断打断。
        // （内核代码都是关着中断运行的，读到的 SIE 本来就是 0，但不依赖这一点。）
        .sstatus = blk: {
            var st = riscv.read(.sstatus);
            st.spp = .user;
            st.sie = false;
            st.spie = true;
            break :blk st;
        },
    };
    frame.regs[2] = image.sp;
    frame.regs[10] = image.argc;
    frame.regs[11] = image.sp;
}

/// 新进程第一次被调度时的内核上下文：switchContext 恢复它之后 ret 到 forkret，sp 正指向它的 TrapFrame。
fn firstContext(p: *Process) Context {
    return .{ .ra = @intFromPtr(&forkret), .sp = @intFromPtr(frameOf(p)), .s = @splat(0) };
}

pub const SpawnError = error{ TooManyProcesses, OutOfMemory, BadElf, IoError, TooManyFiles };

/// 创建第一个进程 init（对应 xv6 的 userinit）：加载嵌在内核里的 init 程序，命令行参数是 "init"，
/// 打开串口作为 0、1、2 号 fd，状态为 runnable。kmain 在启动调度器之前调用。
/// 这时别的 hart 已经在调度器里了，放开 init 的锁之后它可能立刻在别的 hart 上运行。
/// init 的页也是按需分页的，从内核里嵌着的字节读（vm.Backing.bytes）。
pub fn userinit() SpawnError!void {
    var space = try vm.createUserSpace();
    errdefer vm.destroyUserSpace(&space);
    space.backing = .{ .bytes = init_image };
    const image = try loader.loadImage(&space, .{ .bytes = init_image }, &.{"init"});
    const console = try file.openConsole();
    const p = try allocSlot();
    defer p.lock.release();
    var files: [abi.max_fds]?*file.File = @splat(null);
    files[abi.stdin] = console;
    files[abi.stdout] = file.dup(console);
    files[abi.stderr] = file.dup(console);
    startFrame(frameOf(p), image);
    fill(p, .{
        .under_lock = .{ .pid = next_pid.fetchAdd(1, .monotonic), .name = .init("init") },
        .space = space,
        .context = firstContext(p),
        .files = files,
    });
    // 在放开锁之前设置：别的 hart 要先拿到这把锁才能运行 init，那时一定看得到 init_proc
    init_proc = p;
    makeRunnable(p);
}

pub const ForkError = error{ TooManyProcesses, OutOfMemory };

/// 复制当前进程（对应 xv6 的 fork），返回子进程的 pid。子进程有一份内容相同的地址空间
/// （写时复制：先和父进程共用所有的页，谁先写哪一页，谁就复制一份，见 vm.cloneUserSpace），
/// TrapFrame 也是复制的，所以它被调度后从同一个 ecall 之后继续执行，只是 a0（fork 的返回值）是 0。
/// 打开的文件和父进程共用（引用数加 1）。
/// 由系统调用处理程序调用：这时 handleTrap 已经把父进程 TrapFrame 里的 sepc 加过 4 了。
///
/// 先复制地址空间（不拿锁：要分配页表），再拿着 wait_lock 和子进程的锁一次填好所有字段：
/// 子进程从别的 hart 看来要么还不存在，要么已经完整地 runnable 了。
pub fn fork() ForkError!usize {
    const parent = current().?;
    // 父进程的名字归它自己的锁管：先取出来。下面拿着子进程的锁时不能再拿它（两把都是进程锁，同一等级不能嵌套）
    const name = blk: {
        parent.lock.acquire();
        defer parent.lock.release();
        break :blk parent.locked().name;
    };
    var space = try vm.cloneUserSpace(&parent.space);
    errdefer vm.destroyUserSpace(&space);
    wait_lock.acquire();
    defer wait_lock.release();
    const child = try allocSlot();
    defer child.lock.release();
    const frame = frameOf(child);
    frame.* = frameOf(parent).*;
    frame.regs[10] = 0;
    var files: [abi.max_fds]?*file.File = undefined;
    for (&files, parent.files) |*c, f| c.* = if (f) |x| file.dup(x) else null;
    const pid = next_pid.fetchAdd(1, .monotonic);
    fill(child, .{
        .under_lock = .{ .pid = pid, .name = name },
        .under_wait_lock = .{ .parent = parent },
        .space = space,
        .context = firstContext(child),
        .files = files,
        .cwd = parent.cwd,
    });
    // 空闲的 hart 马上来运行子进程，不用等父进程让出 CPU
    makeRunnable(child);
    return pid;
}

pub const ExecError = error{ NoSuchProgram, OutOfMemory, BadElf, IoError, NoDevice, NotDir, NameTooLong, SymlinkLoop, TextBusy };

/// 用文件系统里的程序 path 替换当前进程的地址空间（对应 xv6 的 exec），args 是命令行参数（在内核内存里，
/// 个数和总长度由调用方检查过）。path 里没有 '/' 时在 /bin 里找，有的话按路径找（相对路径从当前目录开始）。
/// 成功时 TrapFrame 已经改成从新程序的入口开始，系统调用返回后就进入新程序；
/// 失败时原来的地址空间和 TrapFrame 都不变，系统调用照常返回错误。pid、父进程、CPU 时间、打开的文件、当前目录不变。
///
/// 只读 ELF 的文件头和程序头，记下各个段（vm.Space），段的内容等程序访问到时才读（按需分页）。
/// 所以新程序运行期间要一直能从这个文件读到同一个版本：先占住它（fsys.hold，之后改它的一方得到 TextBusy，
/// 删掉它只删名字），再在一个新的快照上读文件头（占住之前那个快照里看到的可能已经被改掉了）。
/// 有人正在改这个文件时是 TextBusy。
pub fn exec(path: []const u8, args: []const []const u8) ExecError!void {
    const p = current().?;
    const ino = blk: {
        var r = fsys.reader() catch return error.NoDevice;
        defer r.end();
        break :blk try findProgram(&r.fs, p.cwd, path);
    };
    fsys.hold(ino, .text) catch |err| return switch (err) {
        error.TextBusy => error.TextBusy,
        error.NotFound => error.NoSuchProgram, // 正在被删掉
    };
    var space = vm.createUserSpace() catch |err| {
        fsys.release(ino, .text);
        return err;
    };
    space.backing = .{ .file = ino }; // 占用交给地址空间，destroyUserSpace 时放开
    errdefer vm.destroyUserSpace(&space);
    const image = blk: {
        var r = fsys.reader() catch return error.NoDevice;
        defer r.end();
        const st = r.fs.stat(ino) catch |err| return switch (err) {
            error.NotFound => error.NoSuchProgram, // 找到之后、占住之前被删掉了
            else => error.IoError,
        };
        if (st.kind != .file) return error.BadElf;
        break :blk try loader.loadImage(&space, .{ .file = .{ .fs = &r.fs, .ino = ino, .size = st.size } }, args);
    };
    // 先切到新的地址空间，才能释放正在用的旧页表
    var old = p.space;
    p.space = space;
    vm.activate(space.root);
    vm.destroyUserSpace(&old);
    p.lock.acquire();
    p.locked().name = .init(std.fs.path.basenamePosix(path));
    p.lock.release();
    startFrame(frameOf(p), image);
}

/// 找到 exec 要运行的程序文件，返回它的 inode 号。root 是调用方的快照。
fn findProgram(root: *fs.Fs, cwd: u64, path: []const u8) ExecError!u64 {
    if (path.len == 0) return error.NoSuchProgram;
    var buf: [abi.max_path]u8 = undefined;
    const full = if (std.mem.indexOfScalar(u8, path, '/') != null)
        path
    else
        std.fmt.bufPrint(&buf, "/bin/{s}", .{path}) catch return error.NameTooLong;
    const ino = root.resolve(cwd, full) catch |err| return switch (err) {
        error.NotFound => error.NoSuchProgram,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.SymlinkLoop => error.SymlinkLoop,
        else => error.IoError,
    };
    const st = root.stat(ino) catch return error.IoError;
    if (st.kind != .file) return error.BadElf; // 目录不能运行
    return ino;
}

pub const SbrkError = error{ OutOfMemory, InvalidArgument };

/// 把当前进程的堆末尾移动 increment 字节，返回原来的末尾（对应 xv6 的 growproc）。
/// 按需分配：变大时只挪 brk，新跨进来的页第一次被访问时才分配（清零、可读写，vm.fault）；
/// 变小时把整个落在新末尾之后、已经分配了的页释放掉。
/// 不能小于堆的起点（InvalidArgument），不能长进栈下面的保护页（OutOfMemory）。一次要的比整个物理内存还多的，
/// 肯定用不上，也是 OutOfMemory（和 Linux 默认的 overcommit 检查一个意思）；别的时候不看还有多少空闲的页，
/// 真用的时候没有内存了，访问它的进程被结束。失败时什么都不变。
pub fn sbrk(increment: isize) SbrkError!usize {
    const s = &current().?.space;
    const old = s.brk;
    const new = if (increment >= 0)
        std.math.add(usize, old, @intCast(increment)) catch return error.OutOfMemory
    else
        std.math.sub(usize, old, @abs(increment)) catch return error.InvalidArgument;
    if (new < s.heapStart()) return error.InvalidArgument;
    if (new > vm.heap_limit) return error.OutOfMemory;
    if (new > old and (new - s.heapStart()) / page.size > page.total_pages) return error.OutOfMemory;
    if (new < old) {
        vm.shrinkUser(s.root, old, new);
        vm.flushUserTlb(); // 释放的页可能还在 TLB 里
    }
    s.setBrk(new);
    return old;
}

/// 新进程（init 和 fork 出来的子进程）第一次被调度时从这里开始（对应 xv6 的 forkret），sp 指向它的 TrapFrame。
/// 调度器是拿着进程锁切过来的，先在 forkretC 里放开；和陷阱返回一样，进入 U 模式之前先检查是不是已经被杀了，
/// 然后经 trapExit 进入 U 模式。forkretC 是普通函数，只用 sp 以下的栈，不会碰到 TrapFrame。
fn forkret() callconv(.naked) noreturn {
    asm volatile (
        \\call %[forkretC]
        \\tail %[trapExit]
        :
        : [forkretC] "X" (&forkretC),
          [trapExit] "X" (&trap.trapExit),
    );
}

fn forkretC() callconv(.c) void {
    const p = current().?;
    p.lock.release();
    // 第一个进程第一次运行：挂载文件系统（要读盘、睡着等，kmain 做不了）。之后创建的进程都在这之后
    if (p == init_proc) fsys.init();
    checkStack();
    checkKilled();
    assertNoLocksHeld();
}

/// 回到 U 模式之前调用：这时不能拿着任何自旋锁，当前进程也不能拿着睡眠锁。
pub fn assertNoLocksHeld() void {
    spinlock.assertNoneHeld();
    const n = current().?.sleeplocks.total();
    if (n != 0) std.debug.panic("{d} sleeplock(s) still held", .{n});
}

/// 当前进程拿着几把睡眠锁，没有当前进程（单元测试、调度器）时是 0。vm 按需分页时用它判断能不能读盘。
pub fn sleeplocksHeld() u32 {
    const p = current() orelse return 0;
    return p.sleeplocks.total();
}

/// 当前进程拿着的睡眠锁（sleeplock.zig 拿、放时记下来，检查顺序）。单元测试里没有当前进程，是 null。
pub fn heldSleeplocks() ?*sleeplock.Held {
    const p = current() orelse return null;
    return &p.sleeplocks;
}

/// 调度器（对应 xv6 的 scheduler()）。每个 hart 初始化完之后调用，在这个 hart 的启动栈 boot_stack 上永远循环
/// （每一轮检查一次它最底下的金丝雀，main.zig 一开始就写好了；打断调度器的中断也用这块栈）：
/// 依次扫描进程表，遇到 runnable 的就切过去运行，等它调用 sched() 切回来，再接着往下扫。
/// 所以每个 runnable 的进程每一圈运行一次，自然就是轮转。几个 hart 的调度器同时扫同一张进程表，
/// 靠进程锁保证一个进程同一时刻只在一个 hart 上运行：拿着锁检查 runnable、改成 running，
/// 一直拿到进程切回来为止（锁在中间由进程那一边放开、再拿上，见 sched 的调用方）。
pub fn scheduler(boot_stack: []u8) noreturn {
    const c = &cpus[hart.id()];
    while (true) {
        // 进程和调度器都是关着中断运行的，中断只在这里打开一下：处理挂起的中断（它们可能叫醒进程），
        // 再关上。关着中断扫描、wfi：扫完发现没有可运行的进程、正要 wfi 时来了中断的话，
        // 中断保持挂起，wfi 立刻返回（wfi 只看 sie，不看 sstatus.SIE），不会白睡一觉。
        // 别的 hart 叫醒了进程的话，它会给登记为空闲的 hart 发核间中断，所以扫描之前先登记（见 ipi.setIdle）。
        riscv.enableInterrupts();
        riscv.disableInterrupts();
        hart.checkPanic();
        canary.check(boot_stack, "boot stack of hart {d}", .{hart.id()});
        trap.checkIdle();
        ipi.setIdle(true);
        var found = false;
        for (&table) |*p| {
            p.lock.acquire();
            defer p.lock.release();
            if (p.locked().state != .runnable) continue;
            ipi.setIdle(false);
            p.locked().state = .running;
            p.locked().hart = hart.id();
            c.proc = p;
            vm.activate(p.space.root);
            kstat.inc(.context_switches);
            timer.startSlice();
            const start = timer.now();
            switchContext(&c.context, &p.context);
            p.locked().cpu_time += timer.now() - start;
            timer.endSlice();
            // 进程让出了 CPU，切回来时又拿着它的锁。先切回内核页表再放开锁：它可能已经结束，
            // 父进程拿到它的锁才能回收它、释放它的页表，那时这个 hart 不能还在用这张页表
            vm.activate(vm.kernel_root);
            c.proc = null;
            found = true;
        }
        if (!found) {
            timer.stopSlice(); // 没有 sleeper 的话不预约时钟中断，wfi 一直睡到别的中断
            riscv.wfi();
        }
    }
}

/// 当前进程切回调度器（对应 xv6 的 sched()）。调用前要拿着自己的锁（不能拿着别的锁），
/// 并且已经把自己的状态改掉（不再是 running）。等调度器下次挑中这个进程时（可能在别的 hart 上），
/// switchContext 才返回，从这里接着往下执行，那时又拿着自己的锁。
fn sched() void {
    // 单元测试在主机上运行，不会走到这里（管道等的测试只走不需要等待的路径），但会被编译
    if (comptime !builtin.cpu.arch.isRISCV()) @panic("sched() in a unit test");
    const p = current().?;
    if (!p.lock.holding()) @panic("sched: not holding the process lock");
    // 拿着别的锁切走的话，别的进程再拿这把锁就会死锁
    if (spinlock.heldCount() != 1) std.debug.panic("sched: {d} spinlocks held", .{spinlock.heldCount()});
    std.debug.assert(p.locked().state != .running);
    std.debug.assert(!riscv.interruptsEnabled());
    checkStack();
    // 不能缓存 cpus[hart.id()]：切回来时可能已经在另一个 hart 上了
    switchContext(&p.context, &cpus[hart.id()].context);
}

/// 当前进程让出 CPU，别的 runnable 进程先运行，轮到它时返回。yield 系统调用用。
pub fn yield() void {
    const p = current().?;
    p.lock.acquire();
    p.locked().state = .runnable;
    sched();
    p.lock.release();
}

/// 时钟中断打断了 U 模式的当前进程，它的时间片用完了：让出 CPU。由陷阱处理程序调用（关着中断）。
pub fn yieldTimeslice() void {
    const p = current().?;
    p.lock.acquire();
    p.locked().state = .runnable;
    sched();
    p.lock.release();
}

/// 等某件事的进程排成的队列（xv6 的 sleep/wakeup，“通道”从任意一个地址换成一个有类型的对象）。
/// 放在等待条件旁边：管道的 readers/writers、timer.waiters、uart.rx_waiters、睡眠锁的 waiters、进程的 child_exit……
/// 原来通道是 *const anyopaque，谁在等什么要靠搜同一个地址表达式来配对，写错一边就永远不醒；wakeup 每次都要扫
/// 整张进程表、拿 max_procs 把锁。现在 wakeAll 只看排在这个队列里的进程，没人在等时什么锁都不拿。
///
/// 队列由保护等待条件的那把锁（lock，等级 cond 或 wait）保护：wait 和 wakeAll 都要拿着它调用，两边都检查。
/// 不会丢唤醒：等的一方拿着 lock 检查条件、排进队列，拿上自己的进程锁之后才放开 lock；改条件的一方要拿 lock
/// 才能改、才能 wakeAll，所以它看到的队列里一定有这个进程，而它要拿进程锁才能改状态，等到拿上时进程已经切走了。
/// 醒来不代表条件已经满足（几个进程等同一个条件，先醒的拿走了；或者是被 kill 叫醒的），所以都在循环里等：
/// `while (!条件) q.wait(lock);`
pub const WaitQueue = struct {
    /// 排着的进程，用 Process.wait_next 串起来（后来的在前面：wakeAll 一次叫醒全部，顺序无所谓）
    first: ?*Process = null,

    /// 当前进程排进队列、睡下，直到被 wakeAll（或者 kill）叫醒。调用方拿着 lock 调用，返回时又拿着它。
    /// 先拿上自己的进程锁，再放开 lock，切走之后调度器才放开进程锁；醒来先放开进程锁，再拿上 lock（xv6 的写法）。
    pub fn wait(q: *WaitQueue, lock: *Spinlock) void {
        // 单元测试在主机上运行，不会走到这里（sched 会 panic）
        if (!lock.holding()) std.debug.panic("WaitQueue.wait: not holding {s}", .{lock.name});
        const p = current().?;
        std.debug.assert(!p.queued);
        p.wait_next = q.first;
        q.first = p;
        p.queued = true;
        p.lock.acquire();
        lock.release();
        p.locked().state = .sleeping;
        sched();
        p.lock.release();
        lock.acquire();
        // wakeAll 叫醒的已经被摘下来了；被 kill 叫醒（markKilled）的还排着，自己摘掉
        if (p.queued) q.remove(p);
    }

    /// 叫醒排在队列里的所有进程，队列清空。只改状态，不切换，中断处理程序里也能调用。调用方拿着 lock。
    /// 叫醒的每个都经过 makeRunnable：叫醒了几个，就给最多几个空闲的 hart 发核间中断，让它们马上来运行。
    /// 摘下来的进程可能已经不在睡了（被 kill 叫醒、还没拿上 lock 把自己摘掉），跳过。
    pub fn wakeAll(q: *WaitQueue, lock: *Spinlock) void {
        if (!lock.holding()) std.debug.panic("WaitQueue.wakeAll: not holding {s}", .{lock.name});
        kstat.inc(.wakeup_calls);
        var woken: usize = 0;
        while (q.first) |p| {
            // 当前进程在运行，不会排在任何队列里（被 kill 叫醒的，从 wait 返回之前就摘掉了自己）
            std.debug.assert(p != current());
            q.first = p.wait_next;
            p.wait_next = null;
            p.queued = false;
            p.lock.acquire();
            defer p.lock.release();
            if (p.locked().state == .sleeping) {
                makeRunnable(p);
                woken += 1;
            }
        }
        kstat.add(.processes_woken, woken);
    }

    /// 有没有进程排着。调用方拿着 lock。
    pub fn isEmpty(q: *const WaitQueue) bool {
        return q.first == null;
    }

    fn remove(q: *WaitQueue, p: *Process) void {
        var link = &q.first;
        while (link.*) |x| : (link = &x.wait_next) {
            if (x == p) {
                link.* = p.wait_next;
                p.wait_next = null;
                p.queued = false;
                return;
            }
        }
        unreachable; // queued 为 true 就一定排在这个队列里
    }
};

/// 把一个不在运行的进程（睡着的、刚建好的）改成 runnable，叫一个登记为空闲的 hart 马上来运行它（ipi.wakeIdle）。
/// 让别的进程变成 runnable 都经过这里（wakeup、markKilled、fork、userinit）：原来是一条约定，“改成 runnable 的地方
/// 要调用 ipi.wakeIdle”，漏了的话空闲的 hart 不会来：没有 sleeper 时它不预约时钟中断（timer.zig）。调用方拿着 p.lock。
/// 进程自己让出 CPU（yield）时不用：它在自己的 hart 上切回调度器，这个调度器接着扫描就会看到它。
fn makeRunnable(p: *Process) void {
    std.debug.assert(p.lock.holding() and p.locked().state != .running);
    p.locked().state = .runnable;
    ipi.wakeIdle(1);
}

/// 当前进程调用了 exit。由系统调用处理程序调用，不返回。
pub fn exit(code: u8) noreturn {
    const p = current().?;
    const id = identity(p);
    uart.print("[proc] pid {d} ({s}) exited with code {d}\n", .{ id.pid, id.name.slice(), code });
    finish(p, code);
}

/// 强行结束当前进程。由陷阱处理程序调用，不返回。
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn {
    const p = current().?;
    const id = identity(p);
    uart.print("[proc] pid {d} ({s}) killed: " ++ reason ++ "\n", .{ id.pid, id.name.slice() } ++ args);
    finish(p, abi.killed_status);
}

/// p 的 pid 和名字（拿着它的锁取一份，打印用）。
fn identity(p: *Process) struct { pid: usize, name: Name } {
    p.lock.acquire();
    defer p.lock.release();
    return .{ .pid = p.locked().pid, .name = p.locked().name };
}

/// p 的 pid（拿着它的锁读）。调用方不能拿着别的进程锁（同一等级不能嵌套）。
fn pidOf(p: *Process) usize {
    p.lock.acquire();
    defer p.lock.release();
    return p.locked().pid;
}

/// 当前进程是否被 kill 了。等待的循环里用它提前返回，回到陷阱处理程序后结束。
/// 单元测试里没有当前进程，返回 false。
pub fn isKilled() bool {
    const p = current() orelse return false;
    p.lock.acquire();
    defer p.lock.release();
    return p.locked().killed != null;
}

/// 当前进程被 kill 过的话就结束它，否则返回。陷阱处理程序回到 U 模式之前、新进程第一次进入 U 模式之前调用，
/// 所以被杀的进程不会再执行一条用户指令。
pub fn checkKilled() void {
    const p = current().?;
    p.lock.acquire();
    const reason = p.locked().killed;
    p.lock.release();
    if (reason) |r| killCurrent("{s}", .{r});
}

/// 结束当前进程（对应 xv6 的 exit 的后半部分）：关掉打开的文件，子进程交给 init，自己变成 zombie，
/// 叫醒在 wait 里等的父进程，切回调度器，不再回来。地址空间和槽位由父进程 wait 时回收：
/// 这时进程还在用自己的内核栈和地址空间，不能自己释放。
/// 文件要在这里关：管道的写端关了，读的进程才能读到结尾，不能等到父进程来回收。
fn finish(p: *Process, status: u32) noreturn {
    const init = init_proc.?;
    if (p == init) std.debug.panic("init exited (status {d})", .{status});
    for (&p.files) |*f| {
        if (f.*) |x| file.close(x);
        f.* = null;
    }
    // 不会再缺页了：放开程序文件，它又能改、能删了（地址空间本身要等父进程回收时才释放）
    vm.releaseBacking(&p.space);
    wait_lock.acquire();
    reparent(p, init);
    // 父进程可能在 wait 里睡着。它要拿 wait_lock 才能检查子进程，所以先叫醒、后改状态也不会漏掉
    p.family().parent.?.family().child_exit.wakeAll(&wait_lock);
    p.lock.acquire();
    p.locked().xstatus = status;
    p.locked().state = .zombie;
    wait_lock.release();
    // 拿着自己的锁切走，调度器换回内核页表之后才放开：父进程要拿到这把锁才能回收它
    sched();
    unreachable; // 调度器不会再切回已经结束的进程
}

/// 把 p 的子进程都交给 init。交过去的可能已经是 zombie，所以叫醒 init 来回收。调用方拿着 wait_lock。
fn reparent(p: *Process, init: *Process) void {
    std.debug.assert(wait_lock.holding());
    for (&table) |*c| {
        // 空槽位的 parent 是 null（回收时清掉的），不会等于 p
        if (c.family().parent == p) {
            c.family().parent = init;
            init.family().child_exit.wakeAll(&wait_lock);
        }
    }
}

pub const WaitError = error{NoChildren};

/// 等一个子进程结束并回收它（对应 xv6 的 wait），返回它的 pid。pid 为 abi.wait_any 时等任意一个子进程，
/// 否则只等这一个。status 不为 null 时把结束状态写进去（用户内存，调用方 pin 好的：写不进去的地址在 pin 时就是
/// EFAULT，那时还没回收，子进程还在，可以再 wait 一次）。
/// 有子进程但都还没结束时，拿着 wait_lock 排在自己的 child_exit 里睡下，等子进程的 finish 叫醒；nohang 时不等，返回 null。
/// 被 kill 了也返回 null，回到陷阱处理程序后结束。
pub fn wait(pid: usize, nohang: bool, status: ?vm.PinnedDst) WaitError!?usize {
    const p = current().?;
    wait_lock.acquire();
    defer wait_lock.release();
    while (true) {
        if (try findZombieChild(p, pid)) |c| {
            defer c.lock.release();
            // 拿着锁写进用户内存，所以 status 是调用方 pin 好的
            if (status) |dst| dst.copyOut(0, std.mem.asBytes(&c.locked().xstatus));
            const child_pid = c.locked().pid;
            reap(c);
            return child_pid;
        }
        if (nohang or isKilled()) return null;
        p.family().child_exit.wait(&wait_lock);
    }
}

/// 在 p 的子进程（pid 为 abi.wait_any 时是全部，否则只看这一个）里找一个 zombie，拿着它的锁返回。
/// 有符合条件的子进程但都还没结束时返回 null，一个都没有时返回 NoChildren。调用方拿着 wait_lock，
/// 所以 parent 字段不会变；子进程的状态要拿它的锁才能看。
fn findZombieChild(p: *Process, pid: usize) WaitError!?*Process {
    std.debug.assert(wait_lock.holding());
    var have_kids = false;
    for (&table) |*c| {
        if (c.family().parent != p) continue;
        c.lock.acquire();
        if (pid == abi.wait_any or c.locked().pid == pid) {
            have_kids = true;
            if (c.locked().state == .zombie) return c;
        }
        c.lock.release();
    }
    return if (have_kids) null else error.NoChildren;
}

/// 回收 zombie：释放地址空间（所有用户页和页表），腾出槽位。内核栈是静态的，留给下一个用这个槽位的进程。
/// 调用方拿着 wait_lock（清 parent）和 c.lock。c 已经不在任何 hart 上运行了：它是拿着自己的锁切回调度器的，
/// 调度器换回内核页表之后才放开这把锁，所以这里拿得到锁时，它的页表和内核栈都没人在用了。
fn reap(c: *Process) void {
    std.debug.assert(c.locked().state == .zombie);
    for (c.files) |f| std.debug.assert(f == null); // finish 关掉了
    vm.destroyUserSpace(&c.space);
    fill(c, .{});
}

pub const KillError = error{ NoSuchProcess, PermissionDenied };

/// 杀掉进程 pid（对应 xv6 的 kill()）：只记下原因，在睡的叫醒，不当场结束它——
/// 它可能停在内核栈上的任何地方（sleep 里、yield 里），也可能正在另一个 hart 上运行，
/// 只有它自己知道怎么安全地收尾。它下一次回到 U 模式之前会在 checkKilled 里结束：
/// 正在另一个 hart 的 U 模式里运行的，markKilled 给那个 hart 发核间中断，它马上进内核。
/// 只改标志和状态，中断处理程序里也能调用。
/// init 不能杀：它结束内核就 panic。已经结束的进程（zombie）照常返回成功，什么也不变。
pub fn kill(pid: usize, reason: []const u8) KillError!void {
    const p = lockPid(pid) orelse return error.NoSuchProcess;
    defer p.lock.release();
    if (p == init_proc) return error.PermissionDenied;
    markKilled(p, reason);
}

/// 调用方拿着 p.lock。同一个进程被杀两次，保留第一次的原因。
fn markKilled(p: *Process, reason: []const u8) void {
    if (p.locked().killed == null) p.locked().killed = reason;
    switch (p.locked().state) {
        .sleeping => makeRunnable(p),
        // 正在别的 hart 上运行：打断它。在 U 模式里的话马上陷入内核，回到 U 模式之前结束；
        // 在内核里（中断关着）的话，中断挂着，它本来就会在回到 U 模式之前检查 killed，这个中断只是多余的一次。
        // 拿着 p.lock，p.locked().hart 不会变；它可能刚好在切走，那样别的进程会收到一个什么也不做的中断
        .running => if (p.locked().hart != hart.id()) ipi.send(p.locked().hart),
        else => {},
    }
}

/// 设置前台进程（setfg 系统调用），pid 为 0 表示没有。
pub fn setForeground(pid: usize) error{NoSuchProcess}!void {
    if (pid != 0) {
        const p = lockPid(pid) orelse return error.NoSuchProcess;
        p.lock.release();
    }
    foreground.store(pid, .monotonic);
}

/// 用户按了 Ctrl-C：杀掉前台进程和它的所有子孙进程（shell 运行管道时，各个阶段都是前台进程的子进程）。
/// 没有前台进程（或者它已经结束了）时什么也不做，所以在 shell 里随手按的 Ctrl-C 不会留到下一个程序。
/// 由串口的中断处理程序调用，和 xv6 的 consoleintr 处理控制字符一样。
/// 拿着 wait_lock 扫描：父子关系在这期间不会变，前台进程也不会被回收，一遍就能找全。
pub fn interruptForeground() void {
    wait_lock.acquire();
    defer wait_lock.release();
    const fg = lockPid(foreground.load(.monotonic)) orelse return;
    const alive = fg.locked().state != .zombie and fg != init_proc;
    fg.lock.release();
    if (!alive) return;
    uart.write("^C\n");
    for (&table) |*p| {
        // 空槽位的 parent 是 null，除非它就是 fg，否则不算 fg 的子孙
        if (!isDescendant(p, fg)) continue;
        p.lock.acquire();
        defer p.lock.release();
        if (p.locked().state != .unused) markKilled(p, "interrupted by Ctrl-C");
    }
}

/// p 是不是 ancestor 自己或者它的子孙。调用方拿着 wait_lock。
fn isDescendant(p: *Process, ancestor: *Process) bool {
    var q: ?*Process = p;
    while (q) |x| : (q = x.family().parent) {
        if (x == ancestor) return true;
    }
    return false;
}

/// 找到进程 pid，拿着它的锁返回。pid 为 0 或者没有这个进程时返回 null。
fn lockPid(pid: usize) ?*Process {
    if (pid == 0) return null;
    for (&table) |*p| {
        p.lock.acquire();
        if (p.locked().state != .unused and p.locked().pid == pid) return p;
        p.lock.release();
    }
    return null;
}

/// 当前进程的父进程的 pid，init 返回 0（getppid 系统调用）。
pub fn parentPid() usize {
    wait_lock.acquire();
    defer wait_lock.release();
    // 拿着 wait_lock，父进程不会被回收，它的 pid 不会变；pid 归它的锁管，拿着读
    return if (current().?.family().parent) |q| pidOf(q) else 0;
}

/// 进程表第 i 个槽位的进程信息（procinfo 系统调用），空槽位返回 null。
pub fn info(i: usize) ?abi.ProcInfo {
    wait_lock.acquire();
    defer wait_lock.release();
    const p = &table[i];
    // 父进程的 pid 归父进程的锁管：先拿它读（拿着 wait_lock，父子关系不会变），放开之后再拿 p 的锁。
    // 两把都是进程锁，同一等级不能嵌套
    const ppid = if (p.family().parent) |q| pidOf(q) else 0;
    p.lock.acquire();
    defer p.lock.release();
    if (p.locked().state == .unused) return null;
    return .{
        .pid = p.locked().pid,
        .ppid = ppid,
        .cpu_ms = timer.toMs(p.locked().cpu_time),
        .state = p.locked().state,
        .name_len = p.locked().name.len,
        .name = p.locked().name.buf,
    };
}

/// 把当前的内核上下文保存到 from，再恢复 to 里保存的上下文：恢复出来的 ra、sp 是别处
/// 调用 switchContext 时留下的，所以执行从那次调用之后继续。对这里的调用者来说，
/// 要等到别人切回 from 时，这个函数才“返回”。
///
/// 实际的切换在裸函数 switchNaked 里。Zig 不允许直接调用裸函数，这里在内联汇编里
/// call 它：对编译器来说这只是一段会破坏若干寄存器的汇编，它不会对裸函数做任何假设。
/// （如果转成函数指针来调，签名就必须写对：这个调用是会返回的，声明成 noreturn 的话，
/// 编译器会把调用之后的代码全部删掉，release 模式下就出过这个问题。）
/// 按 C 调用约定，调用者保存的寄存器在调用前后可能变化，所以都声明为被破坏；
/// ra、sp、s0..s11 由 switchNaked 保存和恢复，保持不变。
fn switchContext(from: *Context, to: *const Context) void {
    asm volatile (
        \\mv a0, %[from]
        \\mv a1, %[to]
        \\call %[switchNaked]
        :
        : [from] "r" (from),
          [to] "r" (to),
          [switchNaked] "X" (&switchNaked),
        : .{
          .ra = true,
          .t0 = true,
          .t1 = true,
          .t2 = true,
          .t3 = true,
          .t4 = true,
          .t5 = true,
          .t6 = true,
          .a0 = true,
          .a1 = true,
          .a2 = true,
          .a3 = true,
          .a4 = true,
          .a5 = true,
          .a6 = true,
          .a7 = true,
          .memory = true,
        });
}

/// a0 = from，a1 = to。最后的 ret 跳到恢复出来的 ra，不会走到函数体结尾，所以是 noreturn；
/// 只从 switchContext 的内联汇编里调用。
fn switchNaked() callconv(.naked) noreturn {
    asm volatile (contextAsm("sd", "a0") ++ contextAsm("ld", "a1") ++ "ret\n");
}

/// 在编译期生成保存/恢复 Context 里 14 个寄存器的指令，base 是存放 Context 地址的寄存器。
fn contextAsm(comptime op: []const u8, comptime base: []const u8) []const u8 {
    const regs = [_][]const u8{ "ra", "sp", "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11" };
    comptime std.debug.assert(regs.len * @sizeOf(usize) == @sizeOf(Context));
    var s: []const u8 = "";
    for (regs, 0..) |reg, i| {
        s = s ++ std.fmt.comptimePrint("{s} {s}, {d}({s})\n", .{ op, reg, i * @sizeOf(usize), base });
    }
    return s;
}

/// 测试用：表里直接摆好的 sleeping 进程没走 WaitQueue.wait，替它排进队列。
fn testEnqueue(q: *WaitQueue, p: *Process) void {
    std.debug.assert(p.testFields().state == .sleeping and !p.queued);
    p.wait_next = q.first;
    q.first = p;
    p.queued = true;
}

/// 测试用：清空进程表和全局状态。
fn testReset() void {
    table = @splat(.{});
    cpus = @splat(.{});
    init_proc = null;
    foreground.store(0, .monotonic);
}

test "wakeAll 只叫醒排在这个队列里的进程，清空队列；kill 只做标记，叫醒在睡的进程，不能杀 init" {
    const expectEqual = std.testing.expectEqual;
    testReset();
    defer testReset();
    var lock: Spinlock = .init("test cond", .cond);
    var a: WaitQueue = .{};
    var b: WaitQueue = .{};
    table[0] = .{ .under_lock = .{ .state = .sleeping, .pid = 1 } };
    table[1] = .{ .under_lock = .{ .state = .sleeping, .pid = 2 } };
    table[2] = .{ .under_lock = .{ .state = .sleeping, .pid = 3 } };
    table[3] = .{ .under_lock = .{ .state = .runnable, .pid = 4 } };
    table[4] = .{ .under_lock = .{ .state = .zombie, .pid = 5 } };
    init_proc = &table[0];
    testEnqueue(&a, &table[0]);
    testEnqueue(&a, &table[1]);
    testEnqueue(&b, &table[2]);

    lock.acquire();
    a.wakeAll(&lock);
    a.wakeAll(&lock); // 空队列：什么都不做
    lock.release();
    try expectEqual(.runnable, table[0].testFields().state);
    try expectEqual(.runnable, table[1].testFields().state);
    try expectEqual(.sleeping, table[2].testFields().state);
    try std.testing.expect(a.isEmpty() and !b.isEmpty());
    try std.testing.expect(!table[0].queued and !table[1].queued and table[2].queued);

    // kill 叫醒在睡的进程，只记第一次的原因；runnable 的进程状态不变，等它自己结束
    try kill(3, "first");
    try kill(3, "second");
    try expectEqual(.runnable, table[2].testFields().state);
    // 被 kill 叫醒的还排在 b 里（醒来的进程自己摘掉，见 WaitQueue.wait）；这时 wakeAll 把它摘下来，状态不变
    try std.testing.expect(table[2].queued);
    lock.acquire();
    b.remove(&table[2]);
    lock.release();
    try std.testing.expect(b.isEmpty() and !table[2].queued and table[2].wait_next == null);
    try std.testing.expectEqualStrings("first", table[2].testFields().killed.?);
    try kill(4, "x");
    try expectEqual(.runnable, table[3].testFields().state);
    try kill(5, "x"); // zombie：成功，状态不变
    try expectEqual(.zombie, table[4].testFields().state);
    try std.testing.expectError(error.PermissionDenied, kill(1, "x"));
    try expectEqual(null, table[0].testFields().killed);
    try std.testing.expectError(error.NoSuchProcess, kill(99, "x"));
    try std.testing.expectError(error.NoSuchProcess, kill(0, "x"));
    for (&table) |*p| try std.testing.expect(!p.lock.holding()); // 都放开了
}

test "setfg 检查 pid；Ctrl-C 找的是前台进程和它的子孙，没有前台进程时什么也不做" {
    const expectEqual = std.testing.expectEqual;
    testReset();
    defer testReset();
    const init = &table[0];
    init.* = .{ .under_lock = .{ .state = .sleeping, .pid = 1 } };
    table[1] = .{ .under_lock = .{ .state = .sleeping, .pid = 2 }, .under_wait_lock = .{ .parent = init } }; // sh
    table[2] = .{ .under_lock = .{ .state = .sleeping, .pid = 3 }, .under_wait_lock = .{ .parent = &table[1] } }; // 前台的管道组长
    table[3] = .{ .under_lock = .{ .state = .runnable, .pid = 4 }, .under_wait_lock = .{ .parent = &table[2] } };
    table[4] = .{ .under_lock = .{ .state = .sleeping, .pid = 5 }, .under_wait_lock = .{ .parent = &table[3] } }; // 孙进程
    table[5] = .{ .under_lock = .{ .state = .runnable, .pid = 6 }, .under_wait_lock = .{ .parent = &table[1] } }; // 后台进程
    init_proc = init;

    interruptForeground(); // 没有前台进程
    for (table[0..6]) |*p| try expectEqual(null, p.testFields().killed);

    try setForeground(3);
    try std.testing.expectError(error.NoSuchProcess, setForeground(99));
    try expectEqual(3, foreground.load(.monotonic));
    // interruptForeground 会打印 ^C，单元测试里没有串口，只测找子孙的部分
    wait_lock.acquire();
    defer wait_lock.release();
    for (table[0..6], [_]bool{ false, false, true, true, true, false }) |*p, expected| {
        try expectEqual(expected, isDescendant(p, &table[2]));
    }
    try expectEqual(false, isDescendant(&table[6], &table[2])); // 空槽位
}

test "wait 只找自己的子进程，按 pid 挑；子进程结束时交给 init" {
    const expectEqual = std.testing.expectEqual;
    testReset();
    defer testReset();
    const init = &table[0];
    const sh = &table[1];
    init.* = .{ .under_lock = .{ .state = .sleeping, .pid = 1 } };
    testEnqueue(&init.testFamily().child_exit, init); // 在 wait 里睡着
    sh.* = .{ .under_lock = .{ .state = .running, .pid = 2 }, .under_wait_lock = .{ .parent = init } };
    table[2] = .{ .under_lock = .{ .state = .runnable, .pid = 3 }, .under_wait_lock = .{ .parent = sh } };
    table[3] = .{ .under_lock = .{ .state = .zombie, .pid = 4 }, .under_wait_lock = .{ .parent = sh } };
    table[4] = .{ .under_lock = .{ .state = .zombie, .pid = 5 }, .under_wait_lock = .{ .parent = init } }; // 不是 sh 的子进程
    init_proc = init;

    wait_lock.acquire();
    defer wait_lock.release();
    // 找到的 zombie 是拿着锁返回的
    const z = (try findZombieChild(sh, abi.wait_any)).?;
    try expectEqual(&table[3], z);
    try std.testing.expect(z.lock.holding());
    z.lock.release();
    const z4 = (try findZombieChild(sh, 4)).?;
    try expectEqual(&table[3], z4);
    z4.lock.release();
    try expectEqual(null, try findZombieChild(sh, 3)); // 还在运行
    try std.testing.expectError(error.NoChildren, findZombieChild(sh, 5)); // 别人的子进程
    try std.testing.expectError(error.NoChildren, findZombieChild(sh, 99));
    try std.testing.expectError(error.NoChildren, findZombieChild(&table[2], abi.wait_any)); // 没有子进程

    // sh 结束时，它的子进程（包括已经结束的）都交给 init，init 被叫醒
    reparent(sh, init);
    try expectEqual(init, table[2].testFamily().parent.?);
    try expectEqual(init, table[3].testFamily().parent.?);
    try expectEqual(.runnable, init.testFields().state);
    try std.testing.expect(init.testFamily().child_exit.isEmpty());
    try std.testing.expectError(error.NoChildren, findZombieChild(sh, abi.wait_any));
    const z5 = (try findZombieChild(init, abi.wait_any)).?;
    try expectEqual(&table[3], z5);
    z5.lock.release();
    for (&table) |*p| try std.testing.expect(!p.lock.holding());
}

test "fill 换掉除了锁以外的所有字段" {
    var p: Process = .{ .under_lock = .{ .state = .zombie, .pid = 7, .name = .init("x"), .cpu_time = 3 }, .sleeplocks = .{ .counts = .{ 0, 1, 2 } } };
    p.lock.acquire();
    fill(&p, .{});
    try std.testing.expect(p.lock.holding());
    try std.testing.expectEqual(.unused, p.testFields().state);
    try std.testing.expectEqual(0, p.testFields().pid + p.testFields().cpu_time + p.sleeplocks.total());
    p.lock.release();
}

test "归锁管的字段只经过 locked()、family() 读写（扫描源码）" {
    // locked()、family() 在运行时检查拿着锁；这里检查没有人绕过它们直接碰 under_lock、under_wait_lock。
    // 允许的写法：字段的声明、整个新值的字面量（fill、测试里摆好进程表）、注释，和下面数过个数的几个访问函数。
    // 新加一个直接取地址的访问函数、或者在别的文件里碰它们，这个测试就失败
    const sources = .{
        .{ "proc.zig", @embedFile("proc.zig") },
        .{ "trap.zig", @embedFile("trap.zig") },
        .{ "syscall.zig", @embedFile("syscall.zig") },
        .{ "file.zig", @embedFile("file.zig") },
        .{ "fsys.zig", @embedFile("fsys.zig") },
        .{ "vm.zig", @embedFile("vm.zig") },
        .{ "ipi.zig", @embedFile("ipi.zig") },
        .{ "sleeplock.zig", @embedFile("sleeplock.zig") },
        .{ "kstack.zig", @embedFile("kstack.zig") },
    };
    var accessors: usize = 0;
    inline for (sources) |src| {
        var lines = std.mem.splitScalar(u8, src[1], '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " ");
            if (std.mem.indexOf(u8, line, "under_lock") == null and std.mem.indexOf(u8, line, "under_wait_lock") == null) continue;
            if (std.mem.startsWith(u8, line, "//") or std.mem.indexOfScalar(u8, line, '"') != null) continue; // 注释、这个测试自己
            const ok = std.mem.startsWith(u8, line, "under_lock: Guarded") or std.mem.startsWith(u8, line, "under_wait_lock: Family") or
                std.mem.indexOf(u8, line, ".under_lock = .{") != null or std.mem.indexOf(u8, line, ".under_wait_lock = .{") != null;
            if (std.mem.eql(u8, line, "return &p.under_lock;") or std.mem.eql(u8, line, "return &p.under_wait_lock;")) {
                accessors += 1;
            } else if (!ok) {
                std.debug.print("{s}: touches a lock-guarded field directly: {s}\n", .{ src[0], line });
                return error.TestUnexpectedResult;
            }
        }
    }
    // locked、racyForPanic、testFields；family、testFamily
    try std.testing.expectEqual(5, accessors);
}
