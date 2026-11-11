//! 进程和调度，照 xv6 的结构写：
//!
//! - 每个 hart 有自己的调度器 scheduler()，在这个 hart 的启动栈上永远循环，依次扫描进程表，
//!   遇到 runnable 的进程就切过去，等它切回来再接着往下扫。它只管调度，别的什么都不做。
//!   进程不绑定 hart：这次在哪个 hart 上让出 CPU，下次可能在另一个 hart 上接着运行。
//! - 进程要让出 CPU 时，先拿上自己的锁、改自己的状态，再调用 sched() 切回调度器：yield（时间片用完）、
//!   sleep（等某件事）、exit 都是这样。
//! - 等待用 sleep(chan, lock) / wakeup(chan)：chan 是任意一个地址，代表“在等什么”。sleep 系统调用睡在
//!   &timer.ticks 上，read 等键盘睡在 uart.rx_chan 上，wait 等子进程睡在自己的 Process 上。
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
//!   紧接着            堆：从最后一个段之后的页边界（heap_start）到 brk，sbrk 调整，可读写
//!   ...              没有页
//!   栈底下面一页      保护页，永远没有页：栈溢出时触发缺页异常，而不是悄悄写进堆里
//!   0x8000_0000 往下  用户栈，最多 1 MiB（vm.stack_max），可读写。最顶上放着 exec 传进来的命令行参数
//! 这些都是按需分页的（vm.fault）：exec 只记下各个段在程序文件里的位置，sbrk 只挪 brk，
//! 页在第一次被访问时才分配，段里的页那时才从程序文件读进来。
//!
//! 锁（照 xv6 的 proc.c，详见 docs/process.md 的“锁”一节）：
//! - 每个进程的 lock 保护它的 state、hart、chan、killed、xstatus、pid、ticks、name。调度器拿着它切到进程，
//!   进程拿着它切回调度器，所以“改状态 + 切换”在别的 hart 看来是一步完成的。
//! - wait_lock 保护所有进程的 parent，wait 拿着它睡在自己身上。加锁顺序：wait_lock 在前，进程锁在后；
//!   别的锁（管道、串口、ticks）也都在进程锁前面拿，进程锁之后只会再拿页分配器、文件表这种不再往下拿锁的。
//! - 其他字段（space、context、files、sleeplocks、cwd）只有进程自己会读写（没有线程），不用加锁；
//!   父进程 wait 回收 zombie 时它已经不再运行了。

const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
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
const kstat = @import("kstat.zig");
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
    /// 保护下面标着“lock”的字段。槽位一直在，锁也一直在：回收时不能连锁一起清掉（见 fill）
    lock: Spinlock = .init("proc", .proc),
    /// lock
    state: State = .unused,
    /// lock。state 为 running 时，它在哪个 hart 上运行（kill 要给那个 hart 发核间中断）
    hart: usize = 0,
    /// lock
    pid: usize = 0,
    /// lock（exec 会改，procinfo 要读）
    name: Name = .{},
    /// 这个进程的地址空间：根页表，各个段、堆从哪到哪（按需分页要用）
    space: vm.Space = undefined,
    /// wait_lock。父进程。init 没有父进程；父进程先结束时，子进程交给 init（见 finish）
    parent: ?*Process = null,
    /// 不在运行时，它的内核上下文保存在这里（见 switchContext）
    context: Context = undefined,
    /// lock。sleeping 时等的“通道”，wakeup 用同一个地址叫醒它
    chan: ?*const anyopaque = null,
    /// lock。被 kill 了的话是原因。进程回到 U 模式之前看到它就自己结束（见 checkKilled）
    killed: ?[]const u8 = null,
    /// lock。zombie 的结束状态，父进程 wait 时取走：正常退出时是退出码，被杀时是 abi.killed_status
    xstatus: u32 = 0,
    /// lock。在 U 模式运行期间来过的时钟中断数，大致就是用掉的 CPU 时间（单位 10 ms）
    ticks: u64 = 0,
    /// 打开的文件，下标就是 fd
    files: [abi.max_fds]?*file.File = @splat(null),
    /// 拿着每一级的睡眠锁各几把（sleeplock.zig，检查加锁顺序）。只有自己改；回到 U 模式时必须都是 0
    sleeplocks: sleeplock.Held = .{},
    /// 当前目录的 inode 号，相对路径从这里开始找。fork 继承，exec 不变；只有自己读写
    cwd: u64 = fs.root_ino,
};

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
        if (p.state == .unused) {
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
fn frameOf(p: *Process) *trap.TrapFrame {
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
    canary.check(stackOf(p), "pid {d} ({s})", .{ p.pid, p.name.slice() });
}

/// 从程序入口开始运行的 TrapFrame：a0 = argc，a1 = sp = 栈上 Arg 数组的地址（见 pushArgs），
/// 其他寄存器全为 0。
fn startFrame(frame: *trap.TrapFrame, image: Image) void {
    frame.* = .{
        .regs = @splat(0),
        .sepc = image.entry,
        // SPP = 0：sret 回到 U 模式；SPIE = 1：回到 U 模式后打开中断，时钟和键盘照常工作。
        // SIE 必须清掉：trapExit 一开始就写回 sstatus，SIE = 1 的话恢复寄存器的途中就可能被中断打断。
        // （内核代码都是关着中断运行的，读到的 SIE 本来就是 0，但不依赖这一点。）
        .sstatus = (riscv.read(.sstatus) & ~(riscv.sstatus_spp | riscv.sstatus_sie)) | riscv.sstatus_spie,
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
    const image = try loadImage(&space, .{ .bytes = init_image }, &.{"init"});
    const console = try file.openConsole();
    const p = try allocSlot();
    defer p.lock.release();
    var files: [abi.max_fds]?*file.File = @splat(null);
    files[abi.stdin] = console;
    files[abi.stdout] = file.dup(console);
    files[abi.stderr] = file.dup(console);
    startFrame(frameOf(p), image);
    fill(p, .{
        .state = .runnable,
        .pid = next_pid.fetchAdd(1, .monotonic),
        .name = .init("init"),
        .space = space,
        .context = firstContext(p),
        .files = files,
    });
    // 在放开锁之前设置：别的 hart 要先拿到这把锁才能运行 init，那时一定看得到 init_proc
    init_proc = p;
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
        .state = .runnable,
        .pid = pid,
        .name = parent.name,
        .space = space,
        .parent = parent,
        .context = firstContext(child),
        .files = files,
        .cwd = parent.cwd,
    });
    // 空闲的 hart 马上来运行子进程，不用等父进程让出 CPU
    ipi.wakeIdle(1);
    return pid;
}

pub const ExecError = error{ NoSuchProgram, OutOfMemory, BadElf, IoError, NoDevice, NotDir, NameTooLong, SymlinkLoop, TextBusy };

/// 用文件系统里的程序 path 替换当前进程的地址空间（对应 xv6 的 exec），args 是命令行参数（在内核内存里，
/// 个数和总长度由调用方检查过）。path 里没有 '/' 时在 /bin 里找，有的话按路径找（相对路径从当前目录开始）。
/// 成功时 TrapFrame 已经改成从新程序的入口开始，系统调用返回后就进入新程序；
/// 失败时原来的地址空间和 TrapFrame 都不变，系统调用照常返回错误。pid、父进程、ticks、打开的文件、当前目录不变。
///
/// 只读 ELF 的文件头和程序头，记下各个段（vm.Space），段的内容等程序访问到时才读（按需分页）。
/// 所以新程序运行期间要一直能从这个文件读到同一个版本：先占住它（fsys.holdText，之后改它、删它的一方
/// 得到 TextBusy），再在一个新的快照上读文件头（占住之前那个快照里看到的可能已经被改掉了）。
/// 有人正在改这个文件时是 TextBusy。
pub fn exec(path: []const u8, args: []const []const u8) ExecError!void {
    const p = current().?;
    const ino = blk: {
        var r = fsys.reader() catch return error.NoDevice;
        defer r.end();
        break :blk try findProgram(&r.fs, p.cwd, path);
    };
    fsys.holdText(ino) catch return error.TextBusy;
    var space = vm.createUserSpace() catch |err| {
        fsys.releaseText(ino);
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
        break :blk try loadImage(&space, .{ .file = .{ .fs = &r.fs, .ino = ino, .size = st.size } }, args);
    };
    // 先切到新的地址空间，才能释放正在用的旧页表
    var old = p.space;
    p.space = space;
    vm.activate(space.root);
    vm.destroyUserSpace(&old);
    p.lock.acquire();
    p.name = .init(std.fs.path.basenamePosix(path));
    p.lock.release();
    startFrame(frameOf(p), image);
}

/// 加载好的程序：入口，栈指针（也是栈上 Arg 数组的地址），参数个数。
const Image = struct {
    entry: usize,
    sp: usize,
    argc: usize,
};

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

/// ELF 文件从哪来：嵌在内核里的字节（init、单元测试），或者文件系统里的一个文件（exec，在调用方的快照上读）。
/// 这里只用来读文件头和程序头；段的内容由 vm.Backing 按需读。
const Source = union(enum) {
    bytes: []const u8,
    file: struct { fs: *fs.Fs, ino: u64, size: u64 },

    fn size(src: Source) u64 {
        return switch (src) {
            .bytes => |b| b.len,
            .file => |f| f.size,
        };
    }

    /// 读 [off, off + dst.len)。偏移和长度来自 ELF 文件本身，可能是坏的：超出文件是 BadElf。
    fn read(src: Source, off: u64, dst: []u8) LoadError!void {
        if (off > src.size() or src.size() - off < dst.len) return error.BadElf;
        switch (src) {
            .bytes => |b| @memcpy(dst, b[off..][0..dst.len]),
            .file => |f| {
                const n = f.fs.read(f.ino, off, dst.len, fsys.KernelOut{ .buf = dst }) catch return error.IoError;
                if (n != dst.len) return error.IoError; // 文件在 stat 之后变短了：同一个快照，不应该发生
            },
        }
    }
};

/// 把程序加载进一个新的地址空间 space（记下各个段、堆的起点，backing 由调用方设好），把命令行参数复制到栈顶。
/// 失败时由调用方释放 space。
fn loadImage(space: *vm.Space, src: Source, args: []const []const u8) LoadError!Image {
    const entry = try load(space, src);
    return .{ .entry = entry, .sp = try pushArgs(space, args), .argc = args.len };
}

/// 把命令行参数复制到用户栈的顶端，返回栈上 Arg 数组的地址，新程序的 sp 就从这里开始：
///
///   stack_top
///   参数的字节    各个参数依次往下放，不以 0 结尾
///   （对齐到 16）
///   Arg 数组      argc 个 { ptr, len }，ptr 指向上面的字节    <- 返回值（16 字节对齐，RISC-V 的 sp 要求）
///
/// 参数最多 abi.max_args 个、总共 abi.max_arg_bytes 字节，加起来远小于一页，栈的最顶上一页一定放得下。
/// 栈也是按需分配的：复制参数时分配最顶上那一页，没有内存就是 OutOfMemory（栈里只能有这一种失败）。
fn pushArgs(space: *vm.Space, args: []const []const u8) error{OutOfMemory}!usize {
    std.debug.assert(args.len <= abi.max_args);
    var argv: [abi.max_args]abi.Arg = undefined;
    var sp: usize = vm.stack_top;
    for (args, argv[0..args.len]) |a, *arg| {
        sp -= a.len;
        vm.copyToUser(space, sp, a) catch return error.OutOfMemory;
        arg.* = .{ .ptr = sp, .len = a.len };
    }
    std.debug.assert(vm.stack_top - sp <= abi.max_arg_bytes);
    sp = std.mem.alignBackward(usize, sp - args.len * @sizeOf(abi.Arg), 16);
    vm.copyToUser(space, sp, std.mem.sliceAsBytes(argv[0..args.len])) catch return error.OutOfMemory;
    return sp;
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
    if (new < s.heap_start) return error.InvalidArgument;
    if (new > vm.heap_limit) return error.OutOfMemory;
    if (new > old and (new - s.heap_start) / page.size > page.total_pages) return error.OutOfMemory;
    if (new < old) {
        vm.shrinkUser(s.root, old, new);
        riscv.sfenceVma(); // 释放的页可能还在 TLB 里
    }
    s.brk = new;
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
        ipi.setIdle(true);
        var found = false;
        for (&table) |*p| {
            p.lock.acquire();
            defer p.lock.release();
            if (p.state != .runnable) continue;
            ipi.setIdle(false);
            p.state = .running;
            p.hart = hart.id();
            c.proc = p;
            vm.activate(p.space.root);
            kstat.inc(.context_switches);
            switchContext(&c.context, &p.context);
            // 进程让出了 CPU，切回来时又拿着它的锁。先切回内核页表再放开锁：它可能已经结束，
            // 父进程拿到它的锁才能回收它、释放它的页表，那时这个 hart 不能还在用这张页表
            vm.activate(vm.kernel_root);
            c.proc = null;
            found = true;
        }
        if (!found) riscv.wfi();
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
    std.debug.assert(p.state != .running);
    std.debug.assert(riscv.read(.sstatus) & riscv.sstatus_sie == 0);
    checkStack();
    // 不能缓存 cpus[hart.id()]：切回来时可能已经在另一个 hart 上了
    switchContext(&p.context, &cpus[hart.id()].context);
}

/// 当前进程让出 CPU，别的 runnable 进程先运行，轮到它时返回。yield 系统调用用。
pub fn yield() void {
    const p = current().?;
    p.lock.acquire();
    p.state = .runnable;
    sched();
    p.lock.release();
}

/// 时钟中断打断了 U 模式的当前进程：记一个 tick，让出 CPU。由陷阱处理程序调用（关着中断）。
pub fn yieldTimeslice() void {
    const p = current().?;
    p.lock.acquire();
    p.ticks += 1;
    p.state = .runnable;
    sched();
    p.lock.release();
}

/// 按通道地址散列的睡眠者计数：睡在散列到第 i 格的通道上的进程有几个。wakeup 看到 0 就直接返回，
/// 不用扫整张进程表、拿 max_procs 把锁（放开睡眠锁、管道读写、磁盘中断、每个时钟 tick 都要 wakeup，
/// 绝大多数时候没人在等）。不同的通道散列到同一格只是多扫一次，不会漏。
///
/// 为什么不会丢唤醒：sleep 拿着条件锁 lock 时加 1，之后才放开 lock；改条件的一方要先拿 lock 才能改，
/// 改完（或者放开 lock 之后）才 wakeup。所以它读计数时，lock 的放开和拿上已经把这次加 1 排在了前面。
/// 计数只靠这个先后关系，不用来保护别的数据，monotonic 就够了。
var sleepers: [32]std.atomic.Value(u32) = @splat(.init(0));

fn sleepersOf(chan: *const anyopaque) *std.atomic.Value(u32) {
    // 通道多是结构体里的字段，低几位常常一样，先右移
    return &sleepers[(@intFromPtr(chan) >> 3) % sleepers.len];
}

/// 当前进程睡在 chan 上，直到别人调用 wakeup(chan)。
///
/// 醒来不代表等的条件已经满足（同一个 chan 上可能有好几个进程在等不同的东西，也可能被 kill 叫醒），
/// 所以调用方要在循环里检查条件：`while (!条件) sleep(chan, lock);`。
///
/// lock 是保护这个条件的锁，调用方拿着它检查条件、拿着它调用 sleep；sleep 先拿上自己的进程锁，
/// 再放开 lock，睡下、切走之后调度器才放开进程锁；醒来先放开进程锁，再重新拿上 lock（xv6 的写法）。
/// 改条件的一方要先拿 lock，wakeup 要拿进程锁，所以从“检查完条件”到“切走”之间它插不进来，
/// 不会丢掉 wakeup（lost wakeup），也不会在这个进程还没切走时就被另一个 hart 的调度器运行。
pub fn sleep(chan: *const anyopaque, lock: *Spinlock) void {
    const p = current().?;
    const count = sleepersOf(chan);
    _ = count.fetchAdd(1, .monotonic); // 在放开 lock 之前，见 sleepers
    p.lock.acquire();
    lock.release();
    p.chan = chan;
    p.state = .sleeping;
    sched();
    p.chan = null;
    p.lock.release();
    _ = count.fetchSub(1, .monotonic);
    lock.acquire();
}

/// 叫醒所有睡在 chan 上的进程。只改状态，不切换，中断处理程序里也能调用。
/// 没人睡在（散列到同一格的）通道上就直接返回（见 sleepers）。
/// 跳过当前进程：它在运行，不会在睡；调用方可能还拿着它的锁。
/// 叫醒了几个，就给最多几个空闲的 hart 发核间中断，让它们马上来运行。
/// 调用方要拿过保护条件的锁（sleep 的 lock）：拿着它调用，或者放开它之后调用。
pub fn wakeup(chan: *const anyopaque) void {
    kstat.inc(.wakeup_calls);
    if (sleepersOf(chan).load(.monotonic) == 0) return;
    kstat.inc(.wakeup_scans);
    const me = current();
    var woken: usize = 0;
    for (&table) |*p| {
        if (p == me) continue;
        p.lock.acquire();
        defer p.lock.release();
        if (p.state == .sleeping and p.chan == chan) {
            p.state = .runnable;
            woken += 1;
        }
    }
    kstat.add(.processes_woken, woken);
    ipi.wakeIdle(woken);
}

/// 当前进程调用了 exit。由系统调用处理程序调用，不返回。
pub fn exit(code: u8) noreturn {
    const p = current().?;
    uart.print("[proc] pid {d} ({s}) exited with code {d}\n", .{ p.pid, p.name.slice(), code });
    finish(p, code);
}

/// 强行结束当前进程。由陷阱处理程序调用，不返回。
pub fn killCurrent(comptime reason: []const u8, args: anytype) noreturn {
    const p = current().?;
    uart.print("[proc] pid {d} ({s}) killed: " ++ reason ++ "\n", .{ p.pid, p.name.slice() } ++ args);
    finish(p, abi.killed_status);
}

/// 当前进程是否被 kill 了。等待的循环里用它提前返回，回到陷阱处理程序后结束。
/// 单元测试里没有当前进程，返回 false。
pub fn isKilled() bool {
    const p = current() orelse return false;
    p.lock.acquire();
    defer p.lock.release();
    return p.killed != null;
}

/// 当前进程被 kill 过的话就结束它，否则返回。陷阱处理程序回到 U 模式之前、新进程第一次进入 U 模式之前调用，
/// 所以被杀的进程不会再执行一条用户指令。
pub fn checkKilled() void {
    const p = current().?;
    p.lock.acquire();
    const reason = p.killed;
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
    wakeup(p.parent.?);
    p.lock.acquire();
    p.xstatus = status;
    p.state = .zombie;
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
        if (c.parent == p) {
            c.parent = init;
            wakeup(init);
        }
    }
}

pub const WaitError = error{NoChildren};

/// 等一个子进程结束并回收它（对应 xv6 的 wait），返回它的 pid。pid 为 abi.wait_any 时等任意一个子进程，
/// 否则只等这一个。status 不为 null 时把结束状态写进去（用户内存，调用方 pin 好的：写不进去的地址在 pin 时就是
/// EFAULT，那时还没回收，子进程还在，可以再 wait 一次）。
/// 有子进程但都还没结束时，拿着 wait_lock 睡在自己身上，等子进程的 finish 叫醒；nohang 时不等，返回 null。
/// 被 kill 了也返回 null，回到陷阱处理程序后结束。
pub fn wait(pid: usize, nohang: bool, status: ?vm.PinnedDst) WaitError!?usize {
    const p = current().?;
    wait_lock.acquire();
    defer wait_lock.release();
    while (true) {
        if (try findZombieChild(p, pid)) |c| {
            defer c.lock.release();
            // 拿着锁写进用户内存，所以 status 是调用方 pin 好的
            if (status) |dst| dst.copyOut(0, std.mem.asBytes(&c.xstatus));
            const child_pid = c.pid;
            reap(c);
            return child_pid;
        }
        if (nohang or isKilled()) return null;
        sleep(p, &wait_lock);
    }
}

/// 在 p 的子进程（pid 为 abi.wait_any 时是全部，否则只看这一个）里找一个 zombie，拿着它的锁返回。
/// 有符合条件的子进程但都还没结束时返回 null，一个都没有时返回 NoChildren。调用方拿着 wait_lock，
/// 所以 parent 字段不会变；子进程的状态要拿它的锁才能看。
fn findZombieChild(p: *Process, pid: usize) WaitError!?*Process {
    std.debug.assert(wait_lock.holding());
    var have_kids = false;
    for (&table) |*c| {
        if (c.parent != p) continue;
        c.lock.acquire();
        if (pid == abi.wait_any or c.pid == pid) {
            have_kids = true;
            if (c.state == .zombie) return c;
        }
        c.lock.release();
    }
    return if (have_kids) null else error.NoChildren;
}

/// 回收 zombie：释放地址空间（所有用户页和页表），腾出槽位。内核栈是静态的，留给下一个用这个槽位的进程。
/// 调用方拿着 wait_lock（清 parent）和 c.lock。c 已经不在任何 hart 上运行了：它是拿着自己的锁切回调度器的，
/// 调度器换回内核页表之后才放开这把锁，所以这里拿得到锁时，它的页表和内核栈都没人在用了。
fn reap(c: *Process) void {
    std.debug.assert(c.state == .zombie);
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
    if (p.killed == null) p.killed = reason;
    switch (p.state) {
        .sleeping => {
            p.state = .runnable;
            ipi.wakeIdle(1);
        },
        // 正在别的 hart 上运行：打断它。在 U 模式里的话马上陷入内核，回到 U 模式之前结束；
        // 在内核里（中断关着）的话，中断挂着，它本来就会在回到 U 模式之前检查 killed，这个中断只是多余的一次。
        // 拿着 p.lock，p.hart 不会变；它可能刚好在切走，那样别的进程会收到一个什么也不做的中断
        .running => if (p.hart != hart.id()) ipi.send(p.hart),
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
    const alive = fg.state != .zombie and fg != init_proc;
    fg.lock.release();
    if (!alive) return;
    uart.write("^C\n");
    for (&table) |*p| {
        // 空槽位的 parent 是 null，除非它就是 fg，否则不算 fg 的子孙
        if (!isDescendant(p, fg)) continue;
        p.lock.acquire();
        defer p.lock.release();
        if (p.state != .unused) markKilled(p, "interrupted by Ctrl-C");
    }
}

/// p 是不是 ancestor 自己或者它的子孙。调用方拿着 wait_lock。
fn isDescendant(p: *Process, ancestor: *Process) bool {
    var q: ?*Process = p;
    while (q) |x| : (q = x.parent) {
        if (x == ancestor) return true;
    }
    return false;
}

/// 找到进程 pid，拿着它的锁返回。pid 为 0 或者没有这个进程时返回 null。
fn lockPid(pid: usize) ?*Process {
    if (pid == 0) return null;
    for (&table) |*p| {
        p.lock.acquire();
        if (p.state != .unused and p.pid == pid) return p;
        p.lock.release();
    }
    return null;
}

/// 当前进程的父进程的 pid，init 返回 0（getppid 系统调用）。
pub fn parentPid() usize {
    wait_lock.acquire();
    defer wait_lock.release();
    // 拿着 wait_lock，父进程不会被回收，它的 pid 不会变
    return if (current().?.parent) |q| q.pid else 0;
}

/// 进程表第 i 个槽位的进程信息（procinfo 系统调用），空槽位返回 null。
pub fn info(i: usize) ?abi.ProcInfo {
    wait_lock.acquire();
    defer wait_lock.release();
    const p = &table[i];
    p.lock.acquire();
    defer p.lock.release();
    if (p.state == .unused) return null;
    return .{
        .pid = p.pid,
        .ppid = if (p.parent) |q| q.pid else 0,
        .ticks = p.ticks,
        .state = p.state,
        .name_len = p.name.len,
        .name = p.name.buf,
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

const LoadError = error{ BadElf, OutOfMemory, IoError };

/// 读 ELF 文件的各个 PT_LOAD 段，记进地址空间 space（vm.Space.addSegment），设好堆的起点（最后一个段之后的页边界：
/// 段的最后一页属于段，堆从下一页开始，权限不会和段混在一起），返回入口地址。
/// 不分配页、不读段的内容：都等程序访问到时按需做（vm.fault）。栈也一样，只有 pushArgs 写参数的最顶上一页。
/// 文件头和程序头每次读一个到栈上（几十字节）。
fn load(space: *vm.Space, src: Source) LoadError!usize {
    const Ehdr = elf.Elf64.Ehdr;
    const Phdr = elf.Elf64.Phdr;
    var ehdr_bytes: [@sizeOf(Ehdr)]u8 = undefined;
    try src.read(0, &ehdr_bytes); // 比文件头还短是 BadElf
    const ehdr = std.mem.bytesToValue(Ehdr, &ehdr_bytes);
    if (!std.mem.eql(u8, &ehdr.ident.magic, elf.MAGIC) or ehdr.ident.class != .@"64" or
        ehdr.ident.data != .@"2LSB" or ehdr.type != .EXEC or ehdr.machine != .RISCV or
        ehdr.phentsize != @sizeOf(Phdr))
    {
        return error.BadElf;
    }

    var brk: usize = vm.user_base;
    for (0..ehdr.phnum) |i| {
        const offset = std.math.add(usize, ehdr.phoff, i * @sizeOf(Phdr)) catch return error.BadElf;
        var phdr_bytes: [@sizeOf(Phdr)]u8 = undefined;
        try src.read(offset, &phdr_bytes);
        const phdr = std.mem.bytesToValue(Phdr, &phdr_bytes);
        if (phdr.type != .LOAD or phdr.memsz == 0) continue;
        try loadSegment(space, src, phdr);
        brk = @max(brk, std.mem.alignForward(usize, phdr.vaddr + phdr.memsz, page.size));
    }
    // 入口要在一个可执行的段里：不然第一条指令就缺页，与其让它运行起来再被结束，不如 exec 时就拒绝
    const entry_ok = for (space.segments[0..space.nsegments]) |seg| {
        if (ehdr.entry >= seg.start and ehdr.entry < seg.end and seg.perm.x) break true;
    } else false;
    if (!entry_ok) return error.BadElf;
    space.heap_start = brk;
    space.brk = brk;
    return ehdr.entry;
}

fn loadSegment(space: *vm.Space, src: Source, phdr: elf.Elf64.Phdr) LoadError!void {
    // 段要从页边界开始（user/linker.ld 保证），整段落在用户区里、在堆能长到的最高处（栈下面的保护页）之下，
    // 文件内容不能超出镜像。段必须可读：R/W/X 全为 0 的页表项会被 CPU 当成指向下一级页表的指针，
    // 而只写不读的组合在 RISC-V 里是保留的。
    const end = std.math.add(usize, phdr.vaddr, phdr.memsz) catch return error.BadElf;
    if (phdr.vaddr % page.size != 0 or phdr.vaddr < vm.user_base or end > vm.heap_limit or
        phdr.filesz > phdr.memsz or phdr.offset > src.size() or src.size() - phdr.offset < phdr.filesz or
        !phdr.flags.R)
    {
        return error.BadElf;
    }
    space.addSegment(.{
        .start = phdr.vaddr,
        .end = std.mem.alignForward(usize, end, page.size),
        .perm = .{ .r = phdr.flags.R, .w = phdr.flags.W, .x = phdr.flags.X },
        .file_off = phdr.offset,
        .file_size = phdr.filesz,
    }) catch return error.BadElf; // 两个段重叠了，或者段太多
}

/// 测试用的“物理内存”，用法见 vm.zig 里的测试。
var test_memory: [256 * page.size]u8 align(page.size) = undefined;

/// 把 image 加载进一个新的地址空间，把每一页都碰一遍，检查完之后释放，确认没有漏页。返回入口。
fn testLoad(image: []const u8) !usize {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    const before = page.freePages();
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = image };
    defer {
        vm.destroyUserSpace(&space);
        std.testing.expectEqual(before, page.freePages()) catch @panic("leaked pages");
    }
    const entry = try load(&space, .{ .bytes = image });
    // 加载时一页都没分配（只有根页表）
    try std.testing.expectEqual(before - 1, page.freePages());
    // 入口可读，段里的每一页都读得到，栈的两端可读，栈下面的保护页、堆（还是空的）读不到
    var buf: [2]u8 = undefined;
    try std.testing.expect(entry >= vm.user_base and entry < vm.heap_limit);
    vm.copyFromUser(&space, &buf, entry) catch return error.BadElf;
    for (space.segments[0..space.nsegments]) |seg| {
        var va = seg.start;
        while (va < seg.end) : (va += page.size) vm.copyFromUser(&space, &buf, va) catch return error.BadElf;
    }
    vm.copyFromUser(&space, &buf, vm.stack_limit) catch return error.BadElf;
    vm.copyFromUser(&space, &buf, vm.stack_top - 2) catch return error.BadElf;
    try std.testing.expectError(error.BadAddress, vm.copyFromUser(&space, &buf, vm.stack_limit - 2));
    try std.testing.expectError(error.BadAddress, vm.copyFromUser(&space, &buf, space.heap_start));
    return entry;
}

test "加载真正的用户程序 hello：按需分页读到的段和 ELF 文件里的一样" {
    const image = @embedFile("hello");
    _ = try testLoad(image);
    // 段的第一个字节就是文件里 p_offset 处的字节
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = image };
    defer vm.destroyUserSpace(&space);
    _ = try load(&space, .{ .bytes = image });
    try std.testing.expect(space.nsegments >= 2);
    for (space.segments[0..space.nsegments]) |seg| {
        if (seg.file_size == 0) continue;
        var b: [1]u8 = undefined;
        try vm.copyFromUser(&space, &b, seg.start);
        try std.testing.expectEqual(image[seg.file_off], b[0]);
    }
}

test "命令行参数复制到栈顶，Arg 数组 16 字节对齐，指向栈上的字节" {
    const base = @intFromPtr(&test_memory);
    page.init(base, base + test_memory.len, &.{});
    vm.kernel_root = @ptrCast(try page.alloc());
    const hello: Source = .{ .bytes = @embedFile("hello") };
    var space = try vm.createUserSpace();
    space.backing = .{ .bytes = hello.bytes };
    defer vm.destroyUserSpace(&space);
    const image = try loadImage(&space, hello, &.{ "hello", "", "world!" });
    try std.testing.expectEqual(3, image.argc);
    try std.testing.expectEqual(0, image.sp % 16);
    try std.testing.expect(image.sp < vm.stack_top and vm.stack_top - image.sp <= 64);

    var argv: [3]abi.Arg = undefined;
    try vm.copyFromUser(&space, std.mem.sliceAsBytes(&argv), image.sp);
    const expected = [_][]const u8{ "hello", "", "world!" };
    for (argv, expected) |a, e| {
        var buf: [16]u8 = undefined;
        try std.testing.expect(a.ptr > image.sp and a.ptr + a.len <= vm.stack_top);
        try vm.copyFromUser(&space, buf[0..a.len], a.ptr);
        try std.testing.expectEqualStrings(e, buf[0..a.len]);
    }

    // 没有参数：sp 就是栈顶
    var empty_space = try vm.createUserSpace();
    empty_space.backing = .{ .bytes = hello.bytes };
    defer vm.destroyUserSpace(&empty_space);
    const empty = try loadImage(&empty_space, hello, &.{});
    try std.testing.expectEqual(vm.stack_top, empty.sp);
    // 堆从最后一个段之后的页边界开始，一开始是空的
    try std.testing.expect(space.heap_start % page.size == 0 and space.heap_start > vm.user_base and space.heap_start <= vm.heap_limit);
    try std.testing.expectEqual(space.heap_start, space.brk);
}

test "ELF 加载器拒绝坏文件" {
    const good = @embedFile("hello");
    const image = try std.testing.allocator.dupe(u8, good);
    defer std.testing.allocator.free(image);

    try std.testing.expectError(error.BadElf, testLoad(good[0..32])); // 比文件头还短
    image[0] = 0; // 魔数不对
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u16, image[18..20], @backingInt(elf.EM.X86_64), .little); // 不是 RISC-V
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u64, image[32..40], image.len - 8, .little); // 程序头表超出文件
    try std.testing.expectError(error.BadElf, testLoad(image));
    @memcpy(image, good);
    std.mem.writeInt(u64, image[24..32], 0x3000_0000, .little); // 入口不在任何段里
    try std.testing.expectError(error.BadElf, testLoad(image));
    // 数据段 R/W/X 全为 0（用 user/tests/noperm.ld 链接的）
    try std.testing.expectError(error.BadElf, testLoad(@embedFile("t_noperm")));
}

/// 测试用：表里直接摆好的 sleeping 进程没走 sleep，替它们记上睡眠者计数。
fn testSleepers(procs: []const Process) void {
    for (procs) |*p| if (p.state == .sleeping) {
        _ = sleepersOf(p.chan.?).fetchAdd(1, .monotonic);
    };
}

/// 测试用：清空进程表和全局状态。
fn testReset() void {
    sleepers = @splat(.init(0));
    table = @splat(.{});
    cpus = @splat(.{});
    init_proc = null;
    foreground.store(0, .monotonic);
}

test "wakeup 只叫醒睡在同一个通道上的进程；kill 只做标记，叫醒在睡的进程，不能杀 init" {
    const expectEqual = std.testing.expectEqual;
    testReset();
    defer testReset();
    var a: u64 = 0;
    var b: u64 = 0;
    table[0] = .{ .state = .sleeping, .pid = 1, .chan = &a };
    table[1] = .{ .state = .sleeping, .pid = 2, .chan = &a };
    table[2] = .{ .state = .sleeping, .pid = 3, .chan = &b };
    table[3] = .{ .state = .runnable, .pid = 4 };
    table[4] = .{ .state = .zombie, .pid = 5 };
    init_proc = &table[0];
    testSleepers(&table);

    wakeup(&a);
    try expectEqual(.runnable, table[0].state);
    try expectEqual(.runnable, table[1].state);
    try expectEqual(.sleeping, table[2].state);

    // kill 叫醒在睡的进程，只记第一次的原因；runnable 的进程状态不变，等它自己结束
    try kill(3, "first");
    try kill(3, "second");
    try expectEqual(.runnable, table[2].state);
    try std.testing.expectEqualStrings("first", table[2].killed.?);
    try kill(4, "x");
    try expectEqual(.runnable, table[3].state);
    try kill(5, "x"); // zombie：成功，状态不变
    try expectEqual(.zombie, table[4].state);
    try std.testing.expectError(error.PermissionDenied, kill(1, "x"));
    try expectEqual(null, table[0].killed);
    try std.testing.expectError(error.NoSuchProcess, kill(99, "x"));
    try std.testing.expectError(error.NoSuchProcess, kill(0, "x"));
    for (&table) |*p| try std.testing.expect(!p.lock.holding()); // 都放开了
}

test "setfg 检查 pid；Ctrl-C 找的是前台进程和它的子孙，没有前台进程时什么也不做" {
    const expectEqual = std.testing.expectEqual;
    testReset();
    defer testReset();
    const init = &table[0];
    init.* = .{ .state = .sleeping, .pid = 1 };
    table[1] = .{ .state = .sleeping, .pid = 2, .parent = init }; // sh
    table[2] = .{ .state = .sleeping, .pid = 3, .parent = &table[1] }; // 前台的管道组长
    table[3] = .{ .state = .runnable, .pid = 4, .parent = &table[2] };
    table[4] = .{ .state = .sleeping, .pid = 5, .parent = &table[3] }; // 孙进程
    table[5] = .{ .state = .runnable, .pid = 6, .parent = &table[1] }; // 后台进程
    init_proc = init;

    interruptForeground(); // 没有前台进程
    for (table[0..6]) |p| try expectEqual(null, p.killed);

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
    init.* = .{ .state = .sleeping, .pid = 1 };
    init.chan = init; // 在 wait 里睡着
    testSleepers(&table);
    sh.* = .{ .state = .running, .pid = 2, .parent = init };
    table[2] = .{ .state = .runnable, .pid = 3, .parent = sh };
    table[3] = .{ .state = .zombie, .pid = 4, .parent = sh };
    table[4] = .{ .state = .zombie, .pid = 5, .parent = init }; // 不是 sh 的子进程
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
    try expectEqual(init, table[2].parent.?);
    try expectEqual(init, table[3].parent.?);
    try expectEqual(.runnable, init.state);
    try std.testing.expectError(error.NoChildren, findZombieChild(sh, abi.wait_any));
    const z5 = (try findZombieChild(init, abi.wait_any)).?;
    try expectEqual(&table[3], z5);
    z5.lock.release();
    for (&table) |*p| try std.testing.expect(!p.lock.holding());
}

test "fill 换掉除了锁以外的所有字段" {
    var p: Process = .{ .state = .zombie, .pid = 7, .name = .init("x"), .ticks = 3, .sleeplocks = .{ .counts = .{ 0, 1, 2 } } };
    p.lock.acquire();
    fill(&p, .{});
    try std.testing.expect(p.lock.holding());
    try std.testing.expectEqual(.unused, p.state);
    try std.testing.expectEqual(0, p.pid + p.ticks + p.sleeplocks.total());
    p.lock.release();
}
