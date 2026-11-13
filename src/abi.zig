//! 系统调用约定，内核和用户程序共用这个文件（build.zig 把它作为 abi 模块交给用户程序）。
//!
//! 用户程序把调用号放进 a7、参数放进 a0..a5，执行 ecall 陷入内核；内核把返回值写回 a0，
//! 其他寄存器原样恢复。返回值按有符号数理解：>= 0 表示成功，-4095..-1 是错误码的相反数
//! （和 Linux 一样，错误码也沿用 Linux 的编号）。

const std = @import("std");

pub const Syscall = enum(usize) {
    /// exit(code: u8) 结束当前进程，不返回
    exit = 0,
    /// write(fd, ptr, len) 把用户内存里的 len 个字节写进文件 fd（串口或管道），返回写出的字节数
    write = 1,
    /// getpid() 返回当前进程号
    getpid = 2,
    /// uptime() 返回开机以来的毫秒数
    uptime = 3,
    /// yield() 让出 CPU，让别的就绪进程先运行，返回 0
    yield = 4,
    /// sleep(ms) 睡至少 ms 毫秒，期间不占 CPU，返回 0
    sleep = 5,
    /// read(fd, ptr, len) 从文件 fd（串口或管道）读最多 len 个字节到用户内存，返回读到的字节数。
    /// 一个字节都没有时阻塞；返回 0 表示读到了结尾（管道的写端都关了，或者在串口上按了 Ctrl-D）
    read = 6,
    /// fork() 复制当前进程。父进程得到子进程的 pid，子进程得到 0
    fork = 7,
    /// exec(path_ptr, path_len, argv_ptr, argc) 用文件系统里的程序 path 替换当前进程的地址空间，
    /// 从它的入口开始执行。path 里没有 '/' 时在 /bin 里找，有的话按路径找。argv_ptr 指向 argc 个 Arg（命令行参数，按惯例第一个是程序名），
    /// 内核把它们复制到新程序的栈顶。成功时不返回到原来的程序：新程序看到 a0 = argc、
    /// a1 = 栈上 Arg 数组的地址、sp 在这个数组下面，其他寄存器都是 0。打开的文件保持不变
    exec = 8,
    /// wait(pid, status_ptr, options) 等子进程结束并回收它，返回它的 pid。
    /// pid 为 wait_any 时等任意一个子进程；status_ptr 不为 0 时写入一个 u32 的结束状态（见 killed_status）；
    /// options 含 wait_nohang 时不阻塞，没有已结束的子进程就返回 0
    wait = 9,
    /// kill(pid) 结束进程 pid，返回 0。只做标记，进程回到 U 模式之前才结束
    kill = 10,
    /// getppid() 返回父进程的 pid（init 返回 0）
    getppid = 11,
    /// setfg(pid) 设置前台进程：按 Ctrl-C 时内核结束它。pid 为 0 表示没有前台进程
    setfg = 12,
    /// procinfo(ptr, n) 把最多 n 个进程的 ProcInfo 写进用户内存，返回进程总数
    procinfo = 13,
    /// meminfo(ptr) 把 MemInfo 写进用户内存，返回 0
    meminfo = 14,
    // 15 原来是 listprog（列出嵌在内核里的程序），程序搬进文件系统的 /bin 之后去掉了，用 readdir 列 /bin
    /// shutdown() 关机，不返回
    shutdown = 16,
    /// close(fd) 关闭文件 fd，返回 0
    close = 17,
    /// dup(fd) 让编号最小的空闲 fd 指向和 fd 同一个文件，返回新的 fd
    dup = 18,
    /// pipe(fds_ptr) 创建一个管道，把读端、写端的 fd（两个 u32）写进用户内存，返回 0
    pipe = 19,
    /// sbrk(increment) 把堆的末尾（program break）移动 increment 字节（按有符号数理解，可以为负），
    /// 返回原来的末尾。新增的内存清零；缩小时释放整页
    sbrk = 20,
    /// blockcount() 返回磁盘的原始区域（文件系统之后的块）有多少块（每块 block_size 字节），没有磁盘时返回 0
    blockcount = 21,
    /// readblock(blockno, ptr) 把原始区域的第 blockno 块读进用户内存 ptr（block_size 字节），返回 0。
    /// 经过缓冲区缓存。原始区域在文件系统之后，读写它碰不到文件系统
    readblock = 22,
    /// writeblock(blockno, ptr) 把用户内存 ptr 的 block_size 字节写到原始区域的第 blockno 块，写完才返回 0
    writeblock = 23,
    /// open(path_ptr, path_len, flags) 打开文件系统里的文件或目录，返回 fd。flags 见 open_*：
    /// 读写方式（open_read、open_write、open_rdwr）加上 open_create（没有就建一个空文件）、
    /// open_trunc（截成 0 字节）、open_append（每次写都写在末尾）。目录只能只读地打开（用 readdir 列出来）
    open = 24,
    /// mkdir(path_ptr, path_len) 建一个空目录，返回 0
    mkdir = 25,
    /// unlink(path_ptr, path_len) 删掉一个文件或者空目录，返回 0
    unlink = 26,
    /// chdir(path_ptr, path_len) 换当前目录（相对路径从它开始找），返回 0
    chdir = 27,
    /// fstat(fd, ptr) 把 fd 的 Stat 写进用户内存，返回 0
    fstat = 28,
    /// readdir(fd, ptr) 把目录 fd 的下一个目录项（Dirent）写进用户内存，返回 1；列完了返回 0
    readdir = 29,
    /// scrub(ptr) 检查整个文件系统：B 树的结构和每个节点的校验和、每个数据块的校验和（都重新从磁盘读）、
    /// 条目之间对不对得上（每个 inode 正好一个名字、都连得到根目录等）。都对就把 ScrubInfo 写进用户内存，
    /// 返回 0；不对返回 -EIO。只读不改；检查期间别的进程的文件操作都要等着
    scrub = 30,
    /// rename(old_ptr, old_len, new_ptr, new_len) 把文件或目录 old 改名成 new（可以换目录），一下子做完，返回 0。
    /// new 已经有了的话换掉它：文件换掉文件，目录换掉空目录。打开着它的 fd 照常能用
    rename = 31,
    /// lseek(fd, offset, whence) 挪文件 fd 的读写位置，返回新的位置。whence 见 seek_*，offset 按有符号数理解。
    /// 可以挪到文件末尾之后（再写的话中间是洞）。串口、管道是 -ESPIPE；目录只能 lseek(fd, 0, seek_set) 从头再列
    lseek = 32,
    /// link(old_ptr, old_len, new_ptr, new_len) 硬链接：给文件（或设备文件）old 再起一个名字 new，返回 0。
    /// 两个名字是同一个文件，删掉一个另一个照常。目录不行（-EPERM），new 已经有了是 -EEXIST
    link = 33,
    /// mknod(path_ptr, path_len, major) 建一个设备文件，返回 0。major 见 Major；不认识的也能建，打开时才是 -ENXIO
    mknod = 34,
    /// symlink(target_ptr, target_len, path_ptr, path_len) 建一个符号链接 path，内容是 target（不用存在），返回 0。
    /// 别的调用解析路径时遇到符号链接就换成 target 接着走（相对的 target 从链接所在的目录开始），最多 10 次，
    /// 再多是 -ELOOP。unlink、rename、link 对的是链接自己
    symlink = 35,
    /// readlink(path_ptr, path_len, buf_ptr, buf_len) 把符号链接 path 的目标写进 buf（不以 0 结尾，
    /// 放不下就截断），返回写了几个字节。path 不是符号链接是 -EINVAL
    readlink = 36,
    /// getcwd(buf_ptr, buf_len) 把当前目录的绝对路径写进 buf（不以 0 结尾），返回它的长度。放不下是 -ERANGE；
    /// 当前目录被删掉了是 -ENOENT
    getcwd = 37,
    /// lstat(path_ptr, path_len, ptr) 把 path 的 Stat 写进用户内存，返回 0。path 是符号链接的话是链接自己的
    /// （种类 symlink，长度是目标的长度），不跟着走
    lstat = 38,
    /// kstat(ptr) 把内核的计数器和栈的高水位（KStat）写进用户内存，返回 0
    kstat = 39,
    _,
};

/// 系统调用的参数在寄存器里是什么。abi.params 给每个系统调用写一串：内核的 dispatch 按它从 a0..a5 取参数、
/// 交给处理函数（syscall.zig），用户程序的 sys.call 按它把参数放进寄存器。两边的参数个数、顺序、种类都在编译期
/// 和这张表对一遍，写错了编译不过。
pub const Param = enum {
    /// 一个整数（一个寄存器）
    int,
    /// 一个 fd（一个寄存器）。内核收到的是它指向的打开的文件，fd 不对是 EBADF
    fd,
    /// 用户内存里的一段字节：地址、字节数（两个寄存器）
    bytes,
    /// 用户内存里的一个数组：地址、元素个数（两个寄存器）
    array,
    /// 用户内存里的一个地址，结果写在那里，大小由调用决定（一个寄存器）
    ptr,

    /// 占几个寄存器
    pub fn regs(p: Param) usize {
        return switch (p) {
            .bytes, .array => 2,
            else => 1,
        };
    }
};

/// 每个系统调用的参数（Syscall 的文档注释里有每个参数的意思）。
pub const params = .{
    .exit = .{.int},
    .write = .{ .fd, .bytes },
    .getpid = .{},
    .uptime = .{},
    .yield = .{},
    .sleep = .{.int},
    .read = .{ .fd, .bytes },
    .fork = .{},
    .exec = .{ .bytes, .array },
    .wait = .{ .int, .ptr, .int },
    .kill = .{.int},
    .getppid = .{},
    .setfg = .{.int},
    .procinfo = .{.array},
    .meminfo = .{.ptr},
    .shutdown = .{},
    .close = .{.fd},
    .dup = .{.fd},
    .pipe = .{.ptr},
    .sbrk = .{.int},
    .blockcount = .{},
    .readblock = .{ .int, .ptr },
    .writeblock = .{ .int, .ptr },
    .open = .{ .bytes, .int },
    .mkdir = .{.bytes},
    .unlink = .{.bytes},
    .chdir = .{.bytes},
    .fstat = .{ .fd, .ptr },
    .readdir = .{ .fd, .ptr },
    .scrub = .{.ptr},
    .rename = .{ .bytes, .bytes },
    .lseek = .{ .fd, .int, .int },
    .link = .{ .bytes, .bytes },
    .mknod = .{ .bytes, .int },
    .symlink = .{ .bytes, .bytes },
    .readlink = .{ .bytes, .bytes },
    .getcwd = .{.bytes},
    .lstat = .{ .bytes, .ptr },
    .kstat = .{.ptr},
};

/// 系统调用 name 的参数，按 Param。
pub fn paramsOf(comptime name: []const u8) []const Param {
    const list = @field(params, name);
    var out: [list.len]Param = undefined;
    for (list, &out) |p, *o| o.* = p;
    const final = out;
    return &final;
}

comptime {
    // 每个系统调用都有参数表，表里没有多余的名字，参数最多占 6 个寄存器（a0..a5）
    for (std.meta.fieldNames(Syscall)) |name| {
        if (!@hasField(@TypeOf(params), name)) @compileError("abi.params has no entry for Syscall." ++ name);
        var n = 0;
        for (paramsOf(name)) |p| n += p.regs();
        if (n > 6) @compileError("Syscall." ++ name ++ " takes more than 6 registers");
    }
    if (std.meta.fieldNames(@TypeOf(params)).len != std.meta.fieldNames(Syscall).len) @compileError("abi.params names a syscall that does not exist");
}

/// 设备号（设备文件的 major）。打开设备文件时内核按它找设备（file.zig）
pub const Major = enum(u16) {
    /// 串口，和 init 打开的 0、1、2 号 fd 一样
    console = 1,
    /// 读是结尾，写什么都丢掉
    null = 2,
    /// 读出来都是 0，写什么都丢掉
    zero = 3,
    _,
};

/// open 的 flags（数值照 xv6）
pub const open_read: usize = 0x000;
pub const open_write: usize = 0x001;
pub const open_rdwr: usize = 0x002;
pub const open_create: usize = 0x200;
pub const open_trunc: usize = 0x400;
/// 每次 write 之前先把读写位置挪到文件末尾（同一个 write 里不会被别的进程插进来）
pub const open_append: usize = 0x800;

/// lseek 的 whence：从文件开头、当前位置、文件末尾算
pub const seek_set: usize = 0;
pub const seek_cur: usize = 1;
pub const seek_end: usize = 2;

/// 路径最长多少字节
pub const max_path = 256;
/// 名字（路径的一段）最长多少字节
pub const max_name = 255;

/// fd 指向的是什么（fstat、readdir）。文件、目录的数值和文件系统里的 fs.Kind 一样
pub const FileKind = enum(u8) {
    file = 1,
    dir = 2,
    /// init 打开的串口（不在文件系统里）。打开 /dev/console 得到的是 device
    console = 3,
    pipe = 4,
    /// 文件系统里的设备文件
    device = 5,
    /// 符号链接（lstat、readdir 才看得到：open 跟着它走）
    symlink = 6,
    _,
};

pub const Stat = extern struct {
    /// 文件系统里的 inode 号，串口和管道是 0
    ino: u64,
    /// 文件的字节数，符号链接的目标的长度；目录、设备、串口、管道是 0
    size: u64,
    kind: FileKind,
    _pad: u8 = 0,
    /// 设备文件的设备号（Major），别的是 0
    major: u16 = 0,
    /// 有几个名字（硬链接），目录是 1，串口、管道是 0
    nlink: u32 = 0,
};

pub const Dirent = extern struct {
    ino: u64,
    kind: FileKind,
    name_len: u8,
    _pad: [6]u8 = @splat(0),
    name: [max_name]u8,
};

/// 磁盘块的大小（缓冲区缓存、以后的文件系统都按这个大小读写），正好一页。
pub const block_size = 4096;

pub const Errno = enum(usize) {
    /// 没有权限（kill init）；给目录建硬链接（link）
    perm = 1,
    /// 没有这个程序（exec），没有这个文件或目录
    noent = 2,
    /// 没有这个进程（kill、setfg）
    srch = 3,
    /// 设备文件的设备号内核不认识（open）
    nxio = 6,
    /// 链接数到上限了（link）
    mlink = 31,
    /// 没有磁盘，或者磁盘上没有文件系统
    nodev = 19,
    /// 磁盘上的数据不对（校验和、结构）
    io = 5,
    /// 已经有这个名字了（mkdir、open_create 不会报这个）
    exist = 17,
    /// 路径中间的某一段不是目录；chdir、readdir 的不是目录
    notdir = 20,
    /// 读写目录、写方式打开目录
    isdir = 21,
    /// 文件太大
    fbig = 27,
    /// 磁盘满了
    nospc = 28,
    /// 名字或者路径太长
    nametoolong = 36,
    /// 删除的目录不是空的
    notempty = 39,
    /// 命令行参数太多或太长（exec）
    toobig = 7,
    /// 程序不是合法的 ELF（exec）
    noexec = 8,
    /// fd 不是打开的文件，或者文件不能这样用（往读端写、从写端读）
    badf = 9,
    /// 没有可以等的子进程（wait）
    child = 10,
    /// 进程表满了（fork）
    again = 11,
    /// 物理内存不够（fork、exec、pipe），或者堆不能再长了（sbrk）
    nomem = 12,
    /// 指针指向的内存不属于用户空间，或者没有映射
    fault = 14,
    /// 参数不对；块号超出原始区域（readblock、writeblock）；名字是 "."、".."；
    /// rename 把目录挪进它自己下面；lseek 挪到负的位置、whence 不对；readlink 的不是符号链接
    inval = 22,
    /// 系统的文件表满了（pipe、fork）
    nfile = 23,
    /// 进程的 fd 表满了（dup、pipe）
    mfile = 24,
    /// 解析路径时跟着走的符号链接太多（多半是有环）
    loop = 40,
    /// 给的缓冲区放不下（getcwd）
    range = 34,
    /// 管道的读端都关了，写进去没人读（write）
    pipe = 32,
    /// 不能 lseek 的文件（串口、管道）
    spipe = 29,
    /// 文件正在被运行，不能改、不能删（write、截断、unlink、rename 换掉它）；或者正在被改，不能运行（exec）
    txtbsy = 26,
    /// 没有这个系统调用
    nosys = 38,
    _,
};

/// 用户地址空间：[user_base, user_end)，Sv39 根页表的第 1 项（见 vm.zig）。程序从 user_base 开始链接（user/linker.ld），
/// 栈从 user_end 往下长，最多 user_stack_max 字节，再往下一页是保护页。
pub const user_base: usize = 0x4000_0000;
pub const user_end: usize = 0x8000_0000;
pub const user_stack_max: usize = 1 << 20;

/// 进程表的大小：最多同时有这么多个进程（包括 init、shell 和还没被回收的 zombie）。
pub const max_procs = 64;

/// 每个进程最多同时打开多少个文件（fd 的范围是 0..max_fds）。
pub const max_fds = 32;
/// 约定的三个 fd：init 把它们都指向串口，之后由 fork 继承下去。
pub const stdin = 0;
pub const stdout = 1;
pub const stderr = 2;

/// exec 最多传多少个命令行参数，参数加起来最多多少字节。
pub const max_args = 32;
pub const max_arg_bytes = 2048;

/// 一个命令行参数：用户地址空间里的一段字节（不以 0 结尾）。
pub const Arg = extern struct {
    ptr: usize,
    len: usize,

    pub fn of(s: []const u8) Arg {
        return .{ .ptr = @intFromPtr(s.ptr), .len = s.len };
    }

    /// 用户程序用：参数在自己的地址空间里，直接当成切片。
    pub fn slice(a: Arg) []const u8 {
        if (a.len == 0) return ""; // ptr 可能是 0，不能转成普通指针
        return @as([*]const u8, @ptrFromInt(a.ptr))[0..a.len];
    }
};

/// wait 的 pid 参数：等任意一个子进程。
pub const wait_any: usize = 0 -% @as(usize, 1);
/// wait 的 options：没有已结束的子进程时不阻塞，返回 0。
pub const wait_nohang: usize = 1;
/// wait 写回的结束状态：正常退出时是退出码（0..255），被杀时是 killed_status。
pub const killed_status: u32 = 0x100;

/// 进程的状态。内核的进程表直接用这个类型（proc.State），procinfo 原样交给用户程序。
pub const ProcState = enum(u8) {
    unused,
    /// 可以运行，等调度器挑到它
    runnable,
    /// 正在 CPU 上运行
    running,
    /// 排在某个 WaitQueue 里等某件事：sleep 系统调用、read 等键盘、wait 等子进程、等锁、等磁盘
    sleeping,
    /// 已经结束，等父进程 wait 回收
    zombie,
};

/// procinfo 返回的一个进程的信息。
pub const ProcInfo = extern struct {
    pid: u64,
    ppid: u64,
    /// 用掉的 CPU 时间（毫秒），U 模式和内核里的都算
    cpu_ms: u64,
    state: ProcState,
    /// name 里有效的字节数（名字超过 16 字节时截断）
    name_len: u8,
    name: [16]u8,
};

/// meminfo 返回的物理内存使用情况。
pub const MemInfo = extern struct {
    free_pages: u64,
    total_pages: u64,
    page_size: u64,
};

/// scrub 返回的统计。
pub const ScrubInfo = extern struct {
    files: u64,
    dirs: u64,
    devices: u64,
    symlinks: u64,
    /// 读过、校验和对得上的数据块（不算内联在树里的小文件）
    data_blocks: u64,
    /// B 树的节点数、条目数、层数
    nodes: u64,
    items: u64,
    height: u64,
    free_blocks: u64,
    /// 文件系统的总块数
    blocks: u64,
    /// 最后提交的事务号
    generation: u64,
    /// 孤儿：名字都删掉了、还有人用着（打开着、正在运行）的 inode
    orphans: u64,
};

/// kstat 返回的内核计数器：开机以来的累计值，所有 hart 加起来（内核里每个 hart 一份，见 kstat.zig）。
/// 内核按字段名计数，所以加一个计数器就是在这里加一个字段，再在要数的地方 kstat.inc(.名字)。
pub const Counters = extern struct {
    /// 系统调用
    syscalls: u64 = 0,
    /// 调度器切到一个进程
    context_switches: u64 = 0,
    /// 时钟中断（所有 hart 的）
    timer_interrupts: u64 = 0,
    /// 发出的核间中断
    ipis_sent: u64 = 0,
    /// WaitQueue.wakeAll 被调用的次数（大多数时候队列是空的，什么锁都不拿）；叫醒的进程数
    wakeup_calls: u64 = 0,
    processes_woken: u64 = 0,
    /// 拿自旋锁时锁已经被别的 hart 拿着、要等的次数
    lock_contended: u64 = 0,
    /// 缺页（U 模式的和内核替用户访问的）：分配清零的页、从程序文件读进来的页、写时复制
    faults_zero: u64 = 0,
    faults_file: u64 = 0,
    faults_cow: u64 = 0,
    /// 整个 TLB 的刷新（sfence.vma zero, zero，只在启动时每个 hart 一次）
    tlb_full_flushes: u64 = 0,
    /// 只作废用户映射的刷新（sfence.vma zero, t0，ASID 0 的非全局项）：切换地址空间、fork、sbrk 缩小
    tlb_user_flushes: u64 = 0,
    /// 缓冲区缓存：要的块已经在缓存里，或者要读盘
    bio_hits: u64 = 0,
    bio_misses: u64 = 0,
    /// 磁盘请求
    disk_reads: u64 = 0,
    disk_writes: u64 = 0,
    disk_flushes: u64 = 0,
    /// 文件系统的事务：提交（写了超级块）、作废（真改过东西，要重走整棵树）、作废时什么都没改过
    fs_commits: u64 = 0,
    fs_aborts: u64 = 0,
    fs_clean_aborts: u64 = 0,
};

/// kstat 返回的东西。
pub const KStat = extern struct {
    counters: Counters,
    /// 各种内核栈用到过的最深处（字节，所有 hart、所有进程槽位里最大的）和它们的大小
    stack_process: u64,
    stack_process_size: u64,
    stack_boot: u64,
    stack_boot_size: u64,
    stack_trap: u64,
    stack_trap_size: u64,
};

/// 每个错误码在 Zig 里叫什么：用户程序拿到的错误就是这些（user/sys.zig 按这张表把错误码换成错误），
/// 内核里同名的错误直接换成这个错误码（syscall.zig 的 errno：名字不在这里的才要另外说明换成哪个）。
/// 一个错误码只有一个名字，所以 exec 找不到程序和 open 找不到文件都是 NotFound。
const error_names = .{
    .perm = error.PermissionDenied,
    .noent = error.NotFound,
    .srch = error.NoSuchProcess,
    .io = error.IoError,
    .nxio = error.NoSuchDevice,
    .toobig = error.ArgsTooLong,
    .noexec = error.BadElf,
    .badf = error.BadFd,
    .child = error.NoChildren,
    .again = error.TooManyProcesses,
    .nomem = error.OutOfMemory,
    .fault = error.BadAddress,
    .exist = error.Exists,
    .nodev = error.NoDevice,
    .notdir = error.NotDir,
    .isdir = error.IsDir,
    .inval = error.InvalidArgument,
    .nfile = error.TooManyFiles,
    .mfile = error.TooManyOpenFiles,
    .txtbsy = error.TextBusy,
    .fbig = error.FileTooBig,
    .nospc = error.NoSpace,
    .spipe = error.NotSeekable,
    .mlink = error.TooManyLinks,
    .pipe = error.BrokenPipe,
    .range = error.BufferTooSmall,
    .nametoolong = error.NameTooLong,
    .nosys = error.NoSuchSyscall,
    .notempty = error.NotEmpty,
    .loop = error.SymlinkLoop,
};

/// 所有错误码对应的错误。
pub const Error = blk: {
    var set = error{};
    for (std.meta.fieldNames(@TypeOf(error_names))) |name| set = set || @TypeOf(@field(error_names, name));
    break :blk set;
};

comptime {
    // error_names 正好列出了每一个错误码，名字也不重复：两个方向都是一一对应的
    const codes = std.meta.fieldNames(Errno);
    const names = std.meta.fieldNames(@TypeOf(error_names));
    if (codes.len != names.len) @compileError("abi.error_names must name every Errno");
    for (codes) |c| {
        if (!@hasField(@TypeOf(error_names), c)) @compileError("abi.error_names has no name for Errno." ++ c);
    }
    if (@typeInfo(Error).error_set.error_names.?.len != codes.len) @compileError("abi.error_names gives two errnos the same name");
}

/// 错误码换成错误。不认识的错误码（比用户程序新的内核）是 null。
pub fn errorOf(e: Errno) ?Error {
    inline for (comptime std.meta.fieldNames(Errno)) |name| {
        if (e == @field(Errno, name)) return @field(error_names, name);
    }
    return null;
}

/// 错误换成错误码。在编译期按名字查，所以 err 的错误集是 Error 的子集就行。
pub fn errnoFor(err: anytype) Errno {
    switch (err) {
        inline else => |e| return comptime errnoNamed(@errorName(e)) orelse
            @compileError("abi.error_names has no errno for error." ++ @errorName(e)),
    }
}

/// 名字叫 name 的错误对应的错误码，没有就是 null（syscall.zig 用它决定内核里的错误要不要另外说明换成哪个）。
pub fn errnoNamed(comptime name: []const u8) ?Errno {
    @setEvalBranchQuota(10_000);
    for (std.meta.fieldNames(Errno)) |code| {
        if (std.mem.eql(u8, @errorName(@field(error_names, code)), name)) return @field(Errno, code);
    }
    return null;
}

const max_errno = 4095;

/// 把错误码编码成返回值。
pub fn fail(e: Errno) usize {
    return 0 -% @backingInt(e);
}

/// 返回值表示错误时取出错误码，否则返回 null。
pub fn errnoOf(ret: usize) ?Errno {
    if (ret < 0 -% @as(usize, max_errno)) return null;
    return @fromBackingInt(0 -% ret);
}

test "错误码和错误一一对应，两个方向换回来都是自己" {
    inline for (comptime std.meta.fieldNames(Errno)) |name| {
        const e = @field(Errno, name);
        try std.testing.expectEqual(e, errnoFor(errorOf(e).?));
    }
    try std.testing.expectEqual(Errno.noent, errnoFor(error.NotFound));
    try std.testing.expectEqual(@as(?Error, null), errorOf(@fromBackingInt(4000)));
}

test "错误码编码成返回值，再取回来" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(?Errno, .fault), errnoOf(fail(.fault)));
    try expectEqual(@as(?Errno, .nosys), errnoOf(0 -% @as(usize, 38)));
    // 普通返回值不是错误；-4096 超出了错误码的范围，也当成普通返回值
    try expectEqual(@as(?Errno, null), errnoOf(42));
    try expectEqual(@as(?Errno, null), errnoOf(0 -% @as(usize, 4096)));
}
