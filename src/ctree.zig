//! 写时复制的 B 树和事务，照 btrfs 简化（ctree.c、disk-io.c、transaction.c 的思路，没有 extent tree、快照）。
//! 节点格式在 btree.zig；块的读写走缓冲区缓存（bio.zig）。
//!
//! 磁盘布局：第 0、1 块是两个超级块槽位，其余的块是 B 树节点（以后还有文件数据）。
//!
//! - **写时复制**：已经提交的树（超级块指向的那棵）上的块从来不改。要改一个节点，先复制到一个新块上
//!   再改（cow），它的父节点也要改成指向新块，所以从根到叶子的整条路径都复制一遍。同一个事务里已经
//!   复制过的节点（generation 等于当前的事务号）直接改，不再复制。
//! - **提交**（commit）：新节点在每次操作结束时就写下去了（写到没被已提交的树用着的块上，什么时候掉电都不会
//!   破坏已提交的树），提交只写一个超级块，让它指向新的根。写超级块就是“一下子换成新的树”的那一刻：
//!   写完之前掉电，磁盘上还是旧的树；写完了就是新的树。不需要日志。
//! - **两个超级块槽位轮流写**：事务 g 写到第 g % 2 块。超级块写到一半掉电的话校验和不对，挂载时用另一块
//!   （上一个事务的），那棵树还完整：见下一条。
//! - **空闲空间**：磁盘上不记哪些块空闲，挂载时把树从根走一遍，用到的块记在内存的位图里（used）。
//!   一个块在事务 g 里不再被用了（被复制走了、节点被删了），如果它属于已提交的树，要等事务 g 的超级块
//!   写完才能再分配（pending）：不然下一次分配会改写已提交的树，这时掉电就坏了。在事务 g 里新分配、
//!   又在事务 g 里不用了的块，已提交的树没用它，马上就能再用。
//! - **校验**：每个节点带 crc32c、自己的块号、写它的事务号；父节点的指针里也记着子节点的事务号和层数。
//!   读盘时都对一遍，对不上就是 Corrupt（磁盘坏了、写错了地方、写丢了）。
//! - **出错时整个事务作废**（abort）：操作做到一半出错（比如读到坏块），根退回已提交的根，重新走一遍树
//!   算出空闲块。所以文件系统应该每个系统调用提交一次（以后），出错只丢这一次的改动。
//!   磁盘满不会做到一半才发现：每个操作开始前先按最坏情况预留块数（reserve）。
//!
//! 并发：修改（insert、update、delete、commit、abort 等）同一时刻只能有一个调用方在做，由调用方保证
//! （内核里是文件系统的写锁，fsys.zig）。读可以和修改、和别的读同时进行：读者用 beginRead 拿一个
//! 已提交的树的快照，用 lookupAt、nextAt 在它上面找。已提交的树的块从来不改，修改只碰别的块；
//! 只要提交之后释放的块等还在读旧树的读者都读完了才再分配（limbo），读者看到的就一直是完整的那棵树。

const std = @import("std");
const btree = @import("btree.zig");
const bio = @import("bio.zig");
const proc = @import("proc.zig");
const kstat = @import("kstat.zig");
const Spinlock = @import("spinlock.zig").Spinlock;
const Key = btree.Key;
const Node = btree.Node;
const Ptr = btree.Ptr;

pub const block_size = btree.block_size;
/// 磁盘格式的版本：B 树（btree.zig、这里）或者文件系统（fs.zig 的条目）的格式改了就换一个。
/// 0002：fs.Inode 多了链接数和设备号（硬链接、设备文件）；0003：inode 多了一种 symlink（符号链接）
pub const magic = "LBFS0005".*;
/// 最多管多大的磁盘：位图是静态的，65536 块（256 MiB）的位图是 8 KiB
pub const max_blocks = 65536;
/// 树最多几层。4 KiB 的节点一层最多 101 个指针，8 层远远用不完；单元测试里扇出只有 5，会长到 5、6 层
pub const max_levels = 8;
/// 第 0、1 块是超级块
const super_blocks = 2;

pub const Error = error{
    /// 校验和、块号、事务号、层数对不上，或者树的结构不对
    Corrupt,
    /// 磁盘满了
    NoSpace,
    /// 数据超过 btree.max_data
    TooBig,
    Exists,
    NotFound,
    /// 磁盘上没有能用的超级块
    NotFormatted,
    /// 磁盘比 max_blocks 大
    DiskTooLarge,
    /// 保存的快照已经有 max_snaps 个了
    TooManySnapshots,
    NoDevice,
    OutOfRange,
    /// 磁盘读写失败（bio.IoError）。提交到一半失败之后，这个卷不再接受修改，也是它（见 broken）
    IoError,
};

pub const Super = extern struct {
    /// crc32c，覆盖这一块从 csum 之后到末尾的所有字节
    csum: u32,
    _pad: u32 = 0,
    magic: [8]u8,
    generation: u64,
    blocks: u64,
    root: u64,
    root_generation: u64,
    root_level: u8,
    _pad2: [7]u8 = @splat(0),
    /// 保存下来的快照（Volume.snaps），generation 为 0 的槽位空着
    snaps: [max_snaps]SnapSlot = @splat(.{}),
};

/// 最多保存几个快照
pub const max_snaps = 4;

/// 超级块里的一个快照槽位：快照是哪个事务号的已提交的树，它的根。
pub const SnapSlot = extern struct {
    generation: u64 = 0,
    root: u64 = 0,
    root_generation: u64 = 0,
    root_level: u8 = 0,
    _pad: [7]u8 = @splat(0),
};

/// 保存下来的一个快照（snap）：某个事务提交之后的整棵树，删掉之前它的块都不释放、不改写，随时能在它上面读。
/// 和读者拿的 Snapshot 不一样：那个只在一次读的期间有效，不写进超级块。
pub const Snap = struct {
    generation: u64,
    root: Root,
};

pub const Root = struct {
    blockno: u64,
    generation: u64,
    level: u8,
};

/// 读者拿到的快照：一棵已提交的树的根，和提交它的事务号（endRead 用它判断这棵树是不是还是最新的）。
pub const Snapshot = struct {
    root: Root,
    generation: u64,
};

/// 树外的块（文件数据）：叶子里的某个条目指向它，记着它是哪个事务写的（释放时要用，见 Volume.free）。
pub const DataRef = struct {
    blockno: u64,
    generation: u64,
};

/// 每块一位。8 KiB 一个，比内核栈的一半还大：所有操作都通过指针做，不要按值传、按值遍历、
/// 也不要用 std.bit_set（它的 isSet、count 按值接收 self，调用一次就在栈上复制 8 KiB，开发时因此把内核栈撑爆过）。
const Bitmap = struct {
    masks: [max_blocks / 64]u64 = @splat(0),

    fn isSet(b: *const Bitmap, i: u64) bool {
        return b.masks[i / 64] >> @intCast(i % 64) & 1 != 0;
    }

    fn set(b: *Bitmap, i: u64) void {
        b.masks[i / 64] |= @as(u64, 1) << @intCast(i % 64);
    }

    fn unset(b: *Bitmap, i: u64) void {
        b.masks[i / 64] &= ~(@as(u64, 1) << @intCast(i % 64));
    }

    fn count(b: *const Bitmap) u64 {
        var n: u64 = 0;
        for (&b.masks) |*m| n += @popCount(m.*);
        return n;
    }

    fn clear(b: *Bitmap) void {
        @memset(&b.masks, 0);
    }
};

pub const Volume = struct {
    blocks: u64 = 0,
    /// 磁盘上最新的超级块的事务号，和它指向的根。commit 拿着 snap_lock 改，读者拿着 snap_lock 读
    generation: u64 = 0,
    committed: Root = undefined,
    /// 当前事务的事务号（generation + 1）和当前的根
    transid: u64 = 0,
    root: Root = undefined,
    /// 当前事务开始以来改过东西没有（没改的话 commit 不写超级块，abort 不用重走树）。
    /// 分配、释放块（alloc、free）和换根的地方都要设它：改根之前总要先分配一个块，或者像 collapseRoot 那样自己设
    dirty: bool = false,
    /// 保存下来的快照（空槽位是 null）。当前事务里的样子；committed_snaps 是已提交的（作废事务时退回它）。
    /// 修改的一方读写；读者要在快照上读时，由调用方（fsys）拿着写锁取出根
    snaps: [max_snaps]?Snap = @splat(null),
    committed_snaps: [max_snaps]?Snap = @splat(null),
    /// 这个事务删了快照：提交之后重走一遍树，只有那个快照用着的块才空出来
    rescan_after_commit: bool = false,
    /// 提交到一半时读写失败了（写超级块、或者它之后的 flush）：不知道盘上的超级块指向旧树还是新树，
    /// 两棵树的块都不能再分配、改写，所以之后的修改（reserve、alloc、commit）都返回 IoError，直到重新挂载。
    /// 读者照常在已提交的树上读。作废事务时重走树失败了也这样（位图算到一半）
    broken: bool = false,
    /// 用着的块：当前的树、已提交的树、超级块。pending：已提交的树用着、当前的树不用了的块
    used: Bitmap = .{},
    pending: Bitmap = .{},
    /// 挂载、检查时走树用的临时位图
    seen: Bitmap = .{},
    free_count: u64 = 0,
    /// 提交时释放了、但可能还有读者在旧树上读的块（提交时 old_readers > 0 的话，pending 挪到这里）。
    /// 算作用着的（used 里有，不在 free_count 里），没有旧树的读者了才真正空出来（reclaim）
    limbo: Bitmap = .{},
    limbo_count: u64 = 0,
    /// 保护 generation、committed（修改的一方写、读者读）和下面两个读者计数
    snap_lock: Spinlock = .init("fs snapshot", .cond),
    /// 读着最新的已提交的树（generation）的读者个数，和读着更早的树的读者个数
    readers: usize = 0,
    old_readers: usize = 0,
    /// snap_lock。等旧树的读者读完的修改的一方（waitReaders）排在这里，最后一个旧树的读者 endRead 时叫醒
    readers_done: proc.WaitQueue = .{},
    /// 叶子里的条目指向的树外的块（文件系统的数据块）。挂载、检查走树时对每个条目调用它，
    /// 返回的块也算用着的（同一块被引用两次是 Corrupt）。由文件系统在挂载之前设好，没有就是 null
    data_refs: ?*const fn (key: Key, data: []const u8) ?DataRef = null,

    // ---- 格式化、挂载、提交 ----

    /// 在磁盘上建一个空的文件系统：一个空叶子当根，事务号 1 的超级块；另一个槽位清零（校验和不对，不会被用）。
    pub fn format(blocks: u64) Error!void {
        if (blocks > max_blocks) return error.DiskTooLarge;
        if (blocks < super_blocks + 1) return error.NoSpace;
        const root_block = super_blocks;
        const b = try bio.get(root_block);
        Node.of(b.data).init(0, root_block, 1);
        b.valid = true;
        defer bio.release(b);
        try writeNode(b);
        const empty = try bio.get(0);
        defer bio.release(empty);
        @memset(empty.data, 0);
        empty.valid = true;
        try bio.write(empty);
        try bio.flush(); // 根节点先落盘，见 commit
        try writeSuper(.{ .csum = 0, .magic = magic, .generation = 1, .blocks = blocks, .root = root_block, .root_generation = 1, .root_level = 0 });
        try bio.flush();
    }

    /// 读两个超级块，用校验和对、事务号大的那个；走一遍树，算出用着的块。
    pub fn mount(v: *Volume) Error!void {
        var best: ?Super = null;
        for (0..super_blocks) |slot| {
            const s = try readSuper(slot) orelse continue;
            if (best == null or s.generation > best.?.generation) best = s;
        }
        const s = best orelse return error.NotFormatted;
        if (s.blocks > max_blocks) return error.DiskTooLarge;
        if (s.blocks > bio.blockCount() or s.root_level >= max_levels) return error.Corrupt;
        // 逐个字段赋值：整个 Volume 有 32 KiB，`v.* = .{...}` 可能先在栈上造一个。挂载时还没有读者
        v.limbo.clear();
        v.limbo_count = 0;
        v.readers = 0;
        v.old_readers = 0;
        v.broken = false;
        v.blocks = s.blocks;
        v.generation = s.generation;
        v.committed = .{ .blockno = s.root, .generation = s.root_generation, .level = s.root_level };
        v.transid = s.generation + 1;
        v.root = v.committed;
        for (&v.snaps, s.snaps) |*x, slot| {
            x.* = if (slot.generation == 0) null else .{
                .generation = slot.generation,
                .root = .{ .blockno = slot.root, .generation = slot.root_generation, .level = slot.root_level },
            };
            if (slot.generation > s.generation or slot.root_level >= max_levels) return error.Corrupt;
        }
        v.committed_snaps = v.snaps;
        v.rescan_after_commit = false;
        try v.rescan();
    }

    /// 根据当前的根和保存的快照重新算用着的块（挂载、作废事务、删掉快照之后）。limbo 里的块可能还有读者在读，也算用着的。
    fn rescan(v: *Volume) Error!void {
        v.pending.clear();
        v.seen.clear();
        try v.walk(v.root, null, null, null, false);
        try v.walkSnaps();
        for (&v.used.masks, &v.seen.masks, &v.limbo.masks) |*u, *x, *l| u.* = x.* | l.*;
        for (0..super_blocks) |i| v.used.set(i);
        v.free_count = v.blocks - v.used.count();
        v.dirty = false;
    }

    /// 提交当前事务：新节点都已经写下去了，写一个超级块指向新的根。写完之后 pending 里的块才能再分配；
    /// 还有读者在读旧树的话，它们先进 limbo，等这些读者都读完。
    ///
    /// 设备可能有写缓存（bio.flush），超级块前后各 flush 一次：前一次保证超级块落盘时它指向的节点、数据块都已经在盘上；
    /// 后一次保证 pending 里的块（旧树的）再被分配、改写之前，指向新树的超级块已经在盘上。
    ///
    /// 读写失败时（bio.IoError）：第一次 flush 失败，超级块还没动，盘上还是已提交的树，作废这个事务就行。
    /// 写超级块或者第二次 flush 失败，就不知道盘上的超级块指向哪棵树了：写失败的那一块可能其实写下去了，
    /// 也可能没有。这时内存里还按旧树算（generation、committed 都不变，读者照常），但两棵树的块都不能再动：
    /// 旧树的块要是按“作废了”重新分配、改写，而盘上其实是新树，新树又在 pending 里……所以设上 broken，不再修改，
    /// 重新挂载时按盘上真有的超级块来。
    pub fn commit(v: *Volume) Error!void {
        if (v.broken) return error.IoError;
        if (!v.dirty) return;
        kstat.inc(.fs_commits);
        bio.flush() catch |err| {
            try v.abort();
            return err;
        };
        errdefer v.broken = true;
        var slots: [max_snaps]SnapSlot = @splat(.{});
        for (&slots, v.snaps) |*slot, x| if (x) |sn| {
            slot.* = .{ .generation = sn.generation, .root = sn.root.blockno, .root_generation = sn.root.generation, .root_level = sn.root.level };
        };
        try writeSuper(.{
            .csum = 0,
            .magic = magic,
            .generation = v.transid,
            .blocks = v.blocks,
            .root = v.root.blockno,
            .root_generation = v.root.generation,
            .root_level = v.root.level,
            .snaps = slots,
        });
        try bio.flush();
        v.snap_lock.acquire();
        v.generation = v.transid;
        v.committed = v.root;
        // 刚才还是最新的那棵树的读者，从现在起读的是旧树：它们可能正读着 pending 里的块
        v.old_readers += v.readers;
        v.readers = 0;
        const hold = v.old_readers > 0;
        v.snap_lock.release();
        const n = v.pending.count();
        if (hold) {
            for (&v.limbo.masks, &v.pending.masks) |*l, *p| l.* |= p.*;
            v.limbo_count += n;
        } else {
            v.free_count += n;
            for (&v.used.masks, &v.pending.masks) |*u, *p| u.* &= ~p.*;
        }
        v.pending.clear();
        v.transid += 1;
        v.dirty = false;
        v.committed_snaps = v.snaps;
        v.reclaim();
        if (v.rescan_after_commit) {
            v.rescan_after_commit = false;
            // 删掉的快照独占的块：只有重走一遍才知道是哪些。读盘失败的话位图不变，这些块留到下次挂载
            v.rescan() catch {};
        }
    }

    // ---- 快照：读者 ----

    /// 开始读：拿最新的已提交的树的快照。读完一定要 endRead。可以和修改同时进行（见文件开头）；
    /// 修改的一方可能在等旧树的读者读完（reserve、alloc），所以拿着快照时不能去等修改的一方拿着的东西。
    pub fn beginRead(v: *Volume) Snapshot {
        v.snap_lock.acquire();
        defer v.snap_lock.release();
        v.readers += 1;
        return .{ .root = v.committed, .generation = v.generation };
    }

    /// 读完了。是最后一个读旧树的读者的话，叫醒可能在等 limbo 的修改的一方。
    pub fn endRead(v: *Volume, s: Snapshot) void {
        v.snap_lock.acquire();
        defer v.snap_lock.release();
        if (s.generation == v.generation) {
            v.readers -= 1;
        } else {
            v.old_readers -= 1;
            if (v.old_readers == 0) v.readers_done.wakeAll(&v.snap_lock);
        }
    }

    /// 旧树的读者都读完了的话，limbo 里的块空出来。只有修改的一方调用（它改 used、free_count）。
    fn reclaim(v: *Volume) void {
        if (v.limbo_count == 0) return;
        v.snap_lock.acquire();
        // old_readers 只在 commit 里变大，commit 也是修改的一方做的，所以看到 0 之后它不会再变大
        const busy = v.old_readers > 0;
        v.snap_lock.release();
        if (busy) return;
        for (&v.used.masks, &v.limbo.masks) |*u, *l| u.* &= ~l.*;
        v.free_count += v.limbo_count;
        v.limbo.clear();
        v.limbo_count = 0;
    }

    /// 等旧树的读者都读完，再 reclaim（空闲块不够、limbo 里又有块时）。读者读完一次系统调用就放开快照，
    /// 不会等修改的一方，所以等得到。只有进程能调用；单元测试里没有并发的读者，不会走到 sleep。
    fn waitReaders(v: *Volume) void {
        v.snap_lock.acquire();
        while (v.old_readers > 0) v.readers_done.wait(&v.snap_lock);
        v.snap_lock.release();
        v.reclaim();
    }

    /// 作废当前事务：退回已提交的树。当前事务新写的节点都在已提交的树没用的块上，不用管它们。
    /// 什么都没改过（dirty 为 false：没分配、没释放过块，根也没变，和 commit 一样看它）就不用重走整棵树：
    /// 查找阶段就失败的操作（Exists、NotFound……）最常见，不该每次都读遍所有节点。
    /// 重走树时读盘失败的话，位图只算了一半，设上 broken（见 commit）。
    pub fn abort(v: *Volume) Error!void {
        if (!v.dirty) return kstat.inc(.fs_clean_aborts);
        kstat.inc(.fs_aborts);
        v.root = v.committed;
        v.snaps = v.committed_snaps;
        v.rescan_after_commit = false;
        errdefer v.broken = true;
        try v.rescan();
    }

    // ---- 块的分配和释放 ----

    /// 分配编号最小的空闲块（first fit）。刚放出来的块马上就会被重用：哪里提前放出了已提交的树的块，
    /// 掉电测试马上就能撞上（按顺序往后找的 next fit 要绕一圈才会重用，掩盖了这种错误）。
    /// 不等读者：调用方可能拿着已提交的树的缓冲区（cow），读者也可能正在等它。节点的分配靠事先 reserve。
    fn alloc(v: *Volume) Error!u64 {
        if (v.broken) return error.IoError;
        v.reclaim();
        for (&v.used.masks, 0..) |*m, i| {
            if (m.* == std.math.maxInt(u64)) continue;
            const b = i * 64 + @ctz(~m.*);
            if (b >= v.blocks) break;
            v.used.set(b);
            v.free_count -= 1;
            v.dirty = true;
            return b;
        }
        return error.NoSpace;
    }

    /// 块 blockno（由事务 generation 写的）不再被当前的树用了。
    fn free(v: *Volume, blockno: u64, generation: u64) void {
        std.debug.assert(v.used.isSet(blockno) and !v.pending.isSet(blockno));
        v.dirty = true;
        if (generation == v.transid) {
            // 这个事务里才分配的，已提交的树没用它
            v.used.unset(blockno);
            v.free_count += 1;
        } else if (generation <= v.newestSnap()) {
            // 保存快照的时候它就在已提交的树里（它一直在当前的树里，现在才被释放），快照还指着它：不释放。
            // 删掉快照时重走一遍树（rescan），没有别的快照用着的话才空出来
        } else {
            v.pending.set(blockno);
        }
    }

    /// 最新的快照的事务号，没有快照是 0。
    fn newestSnap(v: *const Volume) u64 {
        var g: u64 = 0;
        for (v.snaps) |x| if (x) |sn| {
            g = @max(g, sn.generation);
        };
        return g;
    }

    /// 把已提交的树保存成一个快照（这个事务里改之前的样子），返回它的事务号。最多 max_snaps 个（TooManySnapshots）；
    /// 已提交的树已经保存过了是 Exists。要在事务开头、改任何东西之前调用（之后释放块时才知道哪些要留给它）。
    pub fn createSnap(v: *Volume) Error!u64 {
        if (v.broken) return error.IoError;
        std.debug.assert(!v.dirty);
        for (v.snaps) |x| if (x) |sn| if (sn.generation == v.generation) return error.Exists;
        for (&v.snaps) |*x| if (x.* == null) {
            x.* = .{ .generation = v.generation, .root = v.committed };
            v.dirty = true;
            return v.generation;
        };
        return error.TooManySnapshots;
    }

    /// 删掉事务号为 generation 的快照（没有是 NotFound）。提交之后重走一遍树，它独占的块才空出来。
    pub fn deleteSnap(v: *Volume, generation: u64) Error!void {
        if (v.broken) return error.IoError;
        for (&v.snaps) |*x| if (x.*) |sn| if (sn.generation == generation) {
            x.* = null;
            v.dirty = true;
            v.rescan_after_commit = true;
            return;
        };
        return error.NotFound;
    }

    /// 事务号为 generation 的快照的根（读快照用，调用方保证这期间没人删它）。
    pub fn snapRoot(v: *const Volume, generation: u64) ?Root {
        for (v.snaps) |x| if (x) |sn| if (sn.generation == generation) return sn.root;
        return null;
    }

    /// 保证接下来的操作分配 n 个块不会失败。算上 limbo 才够的话，等旧树的读者读完。
    fn reserve(v: *Volume, n: u64) Error!void {
        if (v.broken) return error.IoError;
        v.reclaim();
        if (v.free_count >= n) return;
        if (v.free_count + v.limbo_count < n) return error.NoSpace;
        v.waitReaders();
    }

    /// 分配一个数据块（树外的块，比如文件的内容），返回块号，它属于当前事务（generation = transid）。
    /// 调用方把内容写下去，再在树里插一个指向它的条目（data_refs 要认得这个条目）。
    /// 没有空闲块、limbo 里有的话等旧树的读者读完，所以调用方不能拿着已提交的树的缓冲区。
    pub fn allocData(v: *Volume) Error!u64 {
        if (v.broken) return error.IoError;
        v.reclaim();
        if (v.free_count == 0 and v.limbo_count > 0) v.waitReaders();
        return v.alloc();
    }

    /// 数据块 blockno（事务 generation 写的）不再被引用了：和节点一样，属于已提交的树的要等提交之后才能再用。
    pub fn freeData(v: *Volume, blockno: u64, generation: u64) void {
        v.free(blockno, generation);
    }

    /// 当前树的高度（层数）。
    fn height(v: *const Volume) usize {
        return @as(usize, v.root.level) + 1;
    }

    // ---- 节点的读写 ----

    /// 读一个节点，拿着它的缓冲区返回。从磁盘读进来的验校验和；不管是不是缓存里的，都核对块号、事务号、层数。
    fn readNode(v: *Volume, blockno: u64, generation: u64, level: u8) Error!*bio.Buf {
        if (blockno < super_blocks or blockno >= v.blocks) return error.Corrupt;
        const b = try bio.get(blockno);
        const n = Node.of(b.data);
        const fresh = bio.load(b) catch |err| {
            bio.release(b);
            return err;
        };
        const h = n.header();
        if ((fresh and !n.csumOk()) or h.blockno != blockno or h.generation != generation or h.level != level or
            (level > 0 and h.nritems == 0) or (level > 0 and h.nritems > btree.max_ptrs))
        {
            b.valid = false; // 下次重新读盘
            bio.release(b);
            return error.Corrupt;
        }
        return b;
    }

    fn writeNode(b: *bio.Buf) bio.IoError!void {
        Node.of(b.data).setCsum();
        try bio.write(b);
    }

    /// 分配一个新的空节点，拿着它的缓冲区返回（还没写盘）。
    fn newNode(v: *Volume, level: u8) Error!*bio.Buf {
        const blockno = try v.alloc();
        const b = try bio.get(blockno);
        Node.of(b.data).init(level, blockno, v.transid);
        b.valid = true;
        return b;
    }

    /// 写时复制：b 不是这个事务写的，就复制到一个新块上（放开 b，返回新的缓冲区），旧块交给 free。
    /// 调用方负责把父节点（或者根）改成指向新块。
    fn cow(v: *Volume, b: *bio.Buf) Error!*bio.Buf {
        const h = Node.of(b.data).header();
        if (h.generation == v.transid) return b;
        errdefer bio.release(b);
        const blockno = try v.alloc();
        const nb = try bio.get(blockno);
        @memcpy(nb.data, b.data); // 不写成 nb.data.* = b.data.*：Debug 模式下会先复制到栈上的临时值
        nb.valid = true;
        const nh = Node.of(nb.data).header();
        nh.blockno = blockno;
        nh.generation = v.transid;
        v.free(h.blockno, h.generation);
        bio.release(b);
        return nb;
    }

    // ---- 查找 ----

    /// 从根 root 走到 key 所在的叶子，拿着叶子的缓冲区返回，一路只拿着一个缓冲区。
    /// 同时返回下一个叶子的下界：走过的各层里，右边还有兄弟的最深那一层的下一个键（没有就是 null）。
    fn findLeaf(v: *Volume, root: Root, key: Key) Error!struct { *bio.Buf, ?Key } {
        var r = root;
        var upper: ?Key = null;
        while (true) {
            const b = try v.readNode(r.blockno, r.generation, r.level);
            if (r.level == 0) return .{ b, upper };
            const n = Node.of(b.data);
            const slot = n.childFor(key);
            const ps = n.ptrs();
            if (slot + 1 < ps.len) upper = ps[slot + 1].key;
            r = .{ .blockno = ps[slot].blockno, .generation = ps[slot].generation, .level = r.level - 1 };
            bio.release(b);
        }
    }

    /// 在当前的树里找键正好是 key 的条目，把数据复制进 out（最多 out.len 字节），返回数据的长度；没有返回 null。
    pub fn lookup(v: *Volume, key: Key, out: ?[]u8) Error!?usize {
        return v.lookupAt(v.root, key, out);
    }

    /// 同 lookup，在根为 root 的树里找（读者用快照的根）。
    pub fn lookupAt(v: *Volume, root: Root, key: Key, out: ?[]u8) Error!?usize {
        const b, _ = try v.findLeaf(root, key);
        defer bio.release(b);
        const n = Node.of(b.data);
        const i, const found = n.leafSearch(key);
        if (!found) return null;
        const data = n.itemData(i);
        if (out) |o| @memcpy(o[0..@min(o.len, data.len)], data[0..@min(o.len, data.len)]);
        return data.len;
    }

    pub const Found = struct { key: Key, size: usize };

    /// 在当前的树里找第一个键 >= key 的条目（遍历用：下一次从 found.key.successor() 开始），数据复制进 out。
    pub fn next(v: *Volume, key: Key, out: ?[]u8) Error!?Found {
        return v.nextAt(v.root, key, out);
    }

    /// 同 next，在根为 root 的树里找（读者用快照的根）。
    pub fn nextAt(v: *Volume, root: Root, key: Key, out: ?[]u8) Error!?Found {
        var k = key;
        while (true) {
            const b, const upper = try v.findLeaf(root, k);
            defer bio.release(b);
            const n = Node.of(b.data);
            const i, _ = n.leafSearch(k);
            if (i < n.nritems()) {
                const data = n.itemData(i);
                if (out) |o| @memcpy(o[0..@min(o.len, data.len)], data[0..@min(o.len, data.len)]);
                return .{ .key = n.items()[i].key, .size = data.len };
            }
            // 这个叶子里没有更大的键了，去下一个叶子：它的键都 >= upper
            k = upper orelse return null;
        }
    }

    /// 树里最大的键，空树返回 null（文件系统挂载时用它算下一个 inode 号）。
    pub fn lastKey(v: *Volume) Error!?Key {
        var r = v.root;
        while (true) {
            const b = try v.readNode(r.blockno, r.generation, r.level);
            defer bio.release(b);
            const n = Node.of(b.data);
            if (r.level == 0) return if (n.nritems() == 0) null else n.key(n.nritems() - 1);
            const last = n.ptrs()[n.nritems() - 1];
            r = .{ .blockno = last.blockno, .generation = last.generation, .level = r.level - 1 };
        }
    }

    // ---- 修改 ----

    /// 从根到叶子写时复制的一条路径，拿着路径上的所有缓冲区。
    const Path = struct {
        bufs: [max_levels]?*bio.Buf = @splat(null),
        /// slots[l]：第 l 层的节点里，指向第 l - 1 层那个节点的指针的下标
        slots: [max_levels]usize = @splat(0),
        dirty: [max_levels]bool = @splat(false),
        /// 操作中新分配的节点（分裂出来的），结束时一起写
        extra: [max_levels + 1]?*bio.Buf = @splat(null),
        height: usize = 0,

        fn node(p: *Path, level: usize) Node {
            return Node.of(p.bufs[level].?.data);
        }

        fn addExtra(p: *Path, b: *bio.Buf) void {
            for (&p.extra) |*e| {
                if (e.* == null) {
                    e.* = b;
                    return;
                }
            }
            unreachable;
        }

        /// 写下改过的节点，放开所有缓冲区。有写失败的，其余的照样写完、放开，返回 IoError（调用方作废事务）。
        fn finish(p: *Path) bio.IoError!void {
            var result: bio.IoError!void = {};
            for (p.bufs[0..max_levels], p.dirty) |b, d| {
                if (b) |x| {
                    if (d) writeNode(x) catch |err| {
                        result = err;
                    };
                    bio.release(x);
                }
            }
            for (p.extra) |b| {
                if (b) |x| {
                    writeNode(x) catch |err| {
                        result = err;
                    };
                    bio.release(x);
                }
            }
            p.* = .{};
            return result;
        }

        /// 出错了：不写，放开所有缓冲区（调用方接着作废事务）。
        fn discard(p: *Path) void {
            for (p.bufs ++ p.extra) |b| if (b) |x| bio.release(x);
            p.* = .{};
        }
    };

    /// 从根走到 key 所在的叶子，路上的每个节点都写时复制（父节点改成指向复制出来的新块）。
    fn descend(v: *Volume, key: Key) Error!Path {
        var p: Path = .{ .height = v.height() };
        errdefer p.discard();
        var level: usize = v.root.level;
        const root = try v.readNode(v.root.blockno, v.root.generation, v.root.level);
        p.bufs[level] = try v.cow(root);
        if (p.bufs[level] != root) {
            p.dirty[level] = true;
            v.root = .{ .blockno = p.bufs[level].?.blockno, .generation = v.transid, .level = v.root.level };
        }
        while (level > 0) : (level -= 1) {
            const n = p.node(level);
            const slot = n.childFor(key);
            p.slots[level] = slot;
            const ptr = &n.ptrs()[slot];
            const child = try v.readNode(ptr.blockno, ptr.generation, @intCast(level - 1));
            p.bufs[level - 1] = try v.cow(child);
            if (p.bufs[level - 1] != child) {
                ptr.blockno = p.bufs[level - 1].?.blockno;
                ptr.generation = v.transid;
                p.dirty[level] = true;
                p.dirty[level - 1] = true;
            }
        }
        return p;
    }

    /// 插入一个新条目。键已经存在时返回 Exists，什么都不改。
    pub fn insert(v: *Volume, key: Key, data: []const u8) Error!void {
        if (data.len > btree.max_data) return error.TooBig;
        if (try v.lookup(key, null) != null) return error.Exists;
        // 最坏情况：路径上每一层复制一次、分裂一次，再长出一个新根
        try v.reserve(2 * v.height() + 1);
        var p = try v.descendOrAbort(key);
        v.insertInLeaf(&p, key, data) catch |err| {
            p.discard();
            try v.abort();
            return err;
        };
        try v.finishOrAbort(&p);
    }

    /// 写下路径上改过的节点（Path.finish），写失败的话作废事务。
    fn finishOrAbort(v: *Volume, p: *Path) Error!void {
        p.finish() catch |err| {
            try v.abort();
            return err;
        };
    }

    fn descendOrAbort(v: *Volume, key: Key) Error!Path {
        return v.descend(key) catch |err| {
            try v.abort();
            return err;
        };
    }

    fn insertInLeaf(v: *Volume, p: *Path, key: Key, data: []const u8) Error!void {
        const leaf = p.node(0);
        const i, const found = leaf.leafSearch(key);
        std.debug.assert(!found);
        p.dirty[0] = true;
        if (leaf.leafFree() >= Node.itemCost(data.len)) {
            leaf.leafInsert(i, key, data);
            return;
        }
        // 放不下：分出一个右兄弟，新条目放进该放的那一半（btree.max_data 保证放得下）
        const rb = try v.newNode(0);
        p.addExtra(rb);
        const right = Node.of(rb.data);
        leaf.splitLeaf(right);
        const m = leaf.nritems();
        if (i <= m) leaf.leafInsert(i, key, data) else right.leafInsert(i - m, key, data);
        try v.insertPtr(p, 1, .{ .key = right.key(0), .blockno = rb.blockno, .generation = v.transid });
    }

    /// 把指向新分裂出来的节点的指针插到第 level 层：插在路径上那个节点的下一个位置。满了就接着分裂，
    /// 一直到根；根也满了就长出一个新根，树高一层。
    fn insertPtr(v: *Volume, p: *Path, level: usize, ptr: Ptr) Error!void {
        if (level == p.height) {
            // 分裂的是根：新根有两个指针，旧根和它分出来的兄弟
            const rb = try v.newNode(@intCast(level));
            const old = p.bufs[level - 1].?;
            const n = Node.of(rb.data);
            n.ptrInsert(0, .{ .key = p.node(level - 1).key(0), .blockno = old.blockno, .generation = v.transid });
            n.ptrInsert(1, ptr);
            p.bufs[level] = rb;
            p.dirty[level] = true;
            p.height += 1;
            v.root = .{ .blockno = rb.blockno, .generation = v.transid, .level = @intCast(level) };
            return;
        }
        const n = p.node(level);
        const idx = p.slots[level] + 1;
        p.dirty[level] = true;
        if (n.nritems() < btree.max_ptrs) {
            n.ptrInsert(idx, ptr);
            return;
        }
        const rb = try v.newNode(@intCast(level));
        p.addExtra(rb);
        const right = Node.of(rb.data);
        n.splitPtrs(right);
        const m = n.nritems();
        if (idx <= m) n.ptrInsert(idx, ptr) else right.ptrInsert(idx - m, ptr);
        try v.insertPtr(p, level + 1, .{ .key = right.key(0), .blockno = rb.blockno, .generation = v.transid });
    }

    /// 删掉键为 key 的条目。没有时返回 NotFound，什么都不改。
    /// 叶子删空了就把它从父节点里摘掉（父节点空了接着往上）；根只剩一个子节点时让子节点当根，树矮一层。
    /// 不合并半空的节点（btrfs 会和兄弟合并、借条目），简单，代价是删得多了会有些半空的节点。
    pub fn delete(v: *Volume, key: Key) Error!void {
        if (try v.lookup(key, null) == null) return error.NotFound;
        try v.reserve(v.height());
        var p = try v.descendOrAbort(key);
        const leaf = p.node(0);
        const i, const found = leaf.leafSearch(key);
        std.debug.assert(found);
        leaf.leafRemove(i);
        p.dirty[0] = true;
        var level: usize = 0;
        while (level + 1 < p.height and p.node(level).nritems() == 0) : (level += 1) {
            const b = p.bufs[level].?;
            v.free(b.blockno, v.transid); // 路径上的节点都是这个事务复制出来的
            bio.release(b);
            p.bufs[level] = null;
            p.node(level + 1).ptrRemove(p.slots[level + 1]);
            p.dirty[level + 1] = true;
        }
        try v.finishOrAbort(&p);
        v.collapseRoot() catch |err| {
            try v.abort();
            return err;
        };
    }

    /// 根是只有一个指针的内部节点时，让它唯一的子节点当根。
    fn collapseRoot(v: *Volume) Error!void {
        while (v.root.level > 0) {
            const b = try v.readNode(v.root.blockno, v.root.generation, v.root.level);
            const n = Node.of(b.data);
            if (n.nritems() != 1) {
                bio.release(b);
                return;
            }
            const child = n.ptrs()[0];
            v.free(v.root.blockno, v.root.generation);
            bio.release(b);
            v.root = .{ .blockno = child.blockno, .generation = child.generation, .level = v.root.level - 1 };
            v.dirty = true;
        }
    }

    /// 把键为 key 的条目的数据换成 data。没有时返回 NotFound。长度不变时就地改，否则删了再插。
    pub fn update(v: *Volume, key: Key, data: []const u8) Error!void {
        if (data.len > btree.max_data) return error.TooBig;
        const size = try v.lookup(key, null) orelse return error.NotFound;
        if (size != data.len) {
            try v.reserve(v.height() + 2 * (v.height() + 1) + 1); // 删（可能矮一层前不变）+ 插
            try v.delete(key);
            return v.insert(key, data);
        }
        try v.reserve(v.height());
        var p = try v.descendOrAbort(key);
        const leaf = p.node(0);
        const i, const found = leaf.leafSearch(key);
        std.debug.assert(found);
        @memcpy(leaf.itemData(i), data);
        p.dirty[0] = true;
        try v.finishOrAbort(&p);
    }

    // ---- 走树、检查 ----

    pub const Stats = struct { nodes: usize = 0, items: usize = 0, height: usize = 0 };

    /// 从 r 往下走一遍：每个节点读一次（验校验和、块号、事务号、层数），记进 seen（同一块被引用两次是 Corrupt），
    /// 检查键的顺序和上下界（每个节点的键都在 [lo, hi) 里）。stats 不为 null 时顺便数节点和条目。
    /// shared 为 true 时走的是保存的快照：遇到已经走过的块（和当前的树、别的快照共用的）就不再往下走。
    fn walk(v: *Volume, r: Root, lo: ?Key, hi: ?Key, stats: ?*Stats, shared: bool) Error!void {
        if (r.blockno >= v.blocks) return error.Corrupt;
        if (v.seen.isSet(r.blockno)) return if (shared) {} else error.Corrupt;
        v.seen.set(r.blockno);
        const b = try v.readNode(r.blockno, r.generation, r.level);
        defer bio.release(b);
        const n = Node.of(b.data);
        if (n.header().generation > v.transid) return error.Corrupt;
        if (stats) |s| s.nodes += 1;
        if (r.level == 0) {
            const its = n.items();
            if (stats) |s| s.items += its.len;
            var end: usize = block_size;
            for (its, 0..) |it, i| {
                if (it.offset + it.size != end or it.size > btree.max_data) return error.Corrupt;
                if (v.data_refs) |refs| {
                    if (refs(it.key, n.itemData(i))) |d| {
                        if (d.blockno < super_blocks or d.blockno >= v.blocks or d.generation > v.transid) return error.Corrupt;
                        if (v.seen.isSet(d.blockno)) {
                            if (!shared) return error.Corrupt;
                        } else v.seen.set(d.blockno);
                    }
                }
                end = it.offset;
                if (i > 0 and !its[i - 1].key.lessThan(it.key)) return error.Corrupt;
                if (lo != null and it.key.lessThan(lo.?)) return error.Corrupt;
                if (hi != null and !it.key.lessThan(hi.?)) return error.Corrupt;
            }
            if (end < @sizeOf(btree.Header) + its.len * @sizeOf(btree.Item)) return error.Corrupt;
            return;
        }
        const ps = n.ptrs();
        for (ps, 0..) |ptr, i| {
            // ptrs[0].key 当作负无穷，可能已经过时（比后面的、甚至比父节点给的上界还大），不检查它
            if (i > 0) {
                if (i > 1 and !ps[i - 1].key.lessThan(ptr.key)) return error.Corrupt;
                if (lo != null and ptr.key.lessThan(lo.?)) return error.Corrupt;
                if (hi != null and !ptr.key.lessThan(hi.?)) return error.Corrupt;
            }
            const child_lo = if (i == 0) lo else ptr.key;
            const child_hi = if (i + 1 < ps.len) ps[i + 1].key else hi;
            try v.walk(.{ .blockno = ptr.blockno, .generation = ptr.generation, .level = r.level - 1 }, child_lo, child_hi, stats, shared);
        }
    }

    /// 把保存的快照的块也记进 seen（和当前的树共用的块不重复走）。
    fn walkSnaps(v: *Volume) Error!void {
        for (v.snaps) |x| if (x) |sn| try v.walk(sn.root, null, null, null, true);
    }

    /// 检查当前的树：结构、校验和，以及位图：用着的块正好是树的块、超级块、等着释放的块（pending、limbo）。
    pub fn check(v: *Volume) Error!Stats {
        var stats: Stats = .{ .height = v.height() };
        v.seen.clear();
        try v.walk(v.root, null, null, &stats, false);
        for (0..super_blocks) |i| v.seen.set(i);
        // 当前的树不能用着等释放的块：那些块属于已提交的树，提交之前不能分配出去
        for (&v.seen.masks, &v.pending.masks, &v.limbo.masks) |*x, *p, *l| if (x.* & (p.* | l.*) != 0 or p.* & l.* != 0) return error.Corrupt;
        // 快照的块也不能在 pending、limbo 里：快照之前就有的块不会被释放，快照之后释放的块快照没用
        try v.walkSnaps();
        for (&v.seen.masks, &v.pending.masks, &v.limbo.masks) |*x, *p, *l| if (x.* & (p.* | l.*) != 0) return error.Corrupt;
        for (&v.seen.masks, &v.pending.masks, &v.limbo.masks) |*x, *p, *l| x.* |= p.* | l.*;
        if (!std.mem.eql(u64, &v.seen.masks, &v.used.masks) or v.free_count != v.blocks - v.used.count() or
            v.limbo_count != v.limbo.count()) return error.Corrupt;
        return stats;
    }
};

// ---- 超级块 ----

fn superCsum(data: *const btree.Block) u32 {
    return std.hash.crc.@"CRC-32/ISCSI".hash(data[@sizeOf(u32)..]);
}

fn writeSuper(s: Super) Error!void {
    const b = try bio.get(s.generation % super_blocks);
    defer bio.release(b);
    @memset(b.data, 0);
    @memcpy(b.data[0..@sizeOf(Super)], std.mem.asBytes(&s));
    std.mem.writeInt(u32, b.data[0..4], superCsum(b.data), .little);
    b.valid = true;
    try bio.write(b);
}

/// 读第 slot 个超级块，校验和、魔数、槽位不对时返回 null。
fn readSuper(slot: usize) Error!?Super {
    const b = try bio.read(slot);
    defer bio.release(b);
    const s = std.mem.bytesToValue(Super, b.data[0..@sizeOf(Super)]);
    if (s.csum != superCsum(b.data) or !std.mem.eql(u8, &s.magic, &magic) or s.generation % super_blocks != slot) return null;
    return s;
}

// ---- 单元测试：一块内存当磁盘，可以在第 N 次写的时候“掉电” ----

var test_disk: [][block_size]u8 = &.{};
/// 还能成功写几次；用完之后的那一次写是掉电的那一刻（只写进开头的 test_torn 个字节），再往后的写都丢掉
var test_budget: ?usize = null;
var test_torn: usize = 0;
var test_crashed = false;
var test_writes: usize = 0;
var test_vol: Volume = .{};

/// 写缓存模式：模拟有写缓存的设备。写先进 test_cache，flush 时才按顺序落盘；掉电时上次 flush 之后的写
/// 每一个都可能落盘、也可能丢掉，落盘的顺序也是乱的（由 test_cache_seed 决定）。为 false 时写完就落盘、按顺序。
var test_cache_mode = false;
var test_cache_seed: u64 = 0;
var test_cache: std.ArrayListUnmanaged(struct { block: u64, data: [block_size]u8 }) = .empty;
var test_flushes: usize = 0;

/// 读写失败：第 test_fail_at 次设备操作（读、写、flush 都算，从 0 开始数，test_ops）返回 IoError，之后照常。
/// test_fail_wrote 为 true 时，失败的写和 flush 其实做完了（设备做完才报错），否则什么都没做。
var test_ops: usize = 0;
var test_fail_at: ?usize = null;
var test_fail_wrote = false;

/// 这一次设备操作要不要失败。
fn testFails() bool {
    defer test_ops += 1;
    if (test_fail_at != test_ops) return false;
    test_fail_at = null;
    return true;
}

fn testTransfer(block: u64, data: *[block_size]u8, write: bool) bio.IoError!void {
    if (testFails()) {
        if (write and test_fail_wrote) testWrite(block, data);
        return error.IoError;
    }
    if (write) return testWrite(block, data);
    // 设备的读能看到还在缓存里的写：从最新的往前找
    var i = test_cache.items.len;
    while (i > 0) {
        i -= 1;
        if (test_cache.items[i].block == block) {
            data.* = test_cache.items[i].data;
            return;
        }
    }
    data.* = test_disk[block];
}

fn testWrite(block: u64, data: *[block_size]u8) void {
    test_writes += 1;
    if (test_crashed) return;
    if (test_budget) |*left| {
        if (left.* == 0) {
            test_crashed = true;
            if (test_cache_mode) {
                testLoseCache();
            } else {
                @memcpy(test_disk[block][0..test_torn], data[0..test_torn]);
            }
            return;
        }
        left.* -= 1;
    }
    if (test_cache_mode) {
        test_cache.append(std.testing.allocator, .{ .block = block, .data = data.* }) catch @panic("out of memory");
    } else {
        test_disk[block] = data.*;
    }
}

fn testFlush() bio.IoError!void {
    if (testFails()) {
        if (test_fail_wrote) testFlushNow();
        return error.IoError;
    }
    testFlushNow();
}

fn testFlushNow() void {
    test_flushes += 1;
    if (test_crashed) return;
    for (test_cache.items) |*w| test_disk[w.block] = w.data;
    test_cache.clearRetainingCapacity();
}

/// 掉电时缓存里的写：随机挑一些、按随机的顺序落盘，其余的丢掉。
fn testLoseCache() void {
    var prng = std.Random.DefaultPrng.init(test_cache_seed);
    const rng = prng.random();
    rng.shuffle(@TypeOf(test_cache.items[0]), test_cache.items);
    for (test_cache.items) |*w| {
        if (rng.boolean()) test_disk[w.block] = w.data;
    }
    test_cache.clearRetainingCapacity();
}

/// 换一块全零的内存磁盘，格式化、挂载。
fn testSetup(blocks: usize) !void {
    if (test_disk.len != blocks) {
        std.testing.allocator.free(test_disk);
        test_disk = try std.testing.allocator.alloc([block_size]u8, blocks);
    }
    for (test_disk) |*b| @memset(b, 0);
    test_budget = null;
    test_torn = 0;
    test_crashed = false;
    test_writes = 0;
    test_flushes = 0;
    test_ops = 0;
    test_fail_at = null;
    test_cache.clearRetainingCapacity();
    testReboot();
    try Volume.format(blocks);
    try test_vol.mount();
}

/// “重启”：清空缓存（没写下去的东西都没了），恢复供电，重新挂载由调用方做。
fn testReboot() void {
    test_budget = null;
    test_crashed = false;
    test_cache.clearRetainingCapacity(); // 没落盘的写随着掉电没了（掉电那一刻 testLoseCache 已经处理过）
    bio.init(.{ .blocks = test_disk.len, .transfer = testTransfer, .flush = testFlush });
}

fn testFree() void {
    std.testing.allocator.free(test_disk);
    test_disk = &.{};
    test_cache.deinit(std.testing.allocator);
    test_cache = .empty;
    test_cache_mode = false;
    test_fail_at = null;
    test_fail_wrote = false;
}

/// 测试用的键和数据：编号 id 的键是 (id % 37, id % 3, id)，各种字段都会参与比较；
/// 数据由 id、版本号、长度决定，读回来能核对。
fn testKey(id: u32) Key {
    return .init(id % 37, @intCast(id % 3), id);
}

fn testData(id: u32, version: u32, size: usize, buf: []u8) []u8 {
    for (buf[0..size], 0..) |*c, i| c.* = @truncate(id *% 7 +% version *% 13 +% i);
    return buf[0..size];
}

const Entry = struct { version: u32, size: u32 };
/// 参照模型：编号 → 当前的版本和长度。
const Model = struct {
    map: std.AutoArrayHashMapUnmanaged(u32, Entry) = .empty,

    const gpa = std.testing.allocator;

    fn deinit(m: *Model) void {
        m.map.deinit(gpa);
    }
    fn get(m: *const Model, id: u32) ?Entry {
        return m.map.get(id);
    }
    fn put(m: *Model, id: u32, e: Entry) !void {
        try m.map.put(gpa, id, e);
    }
    fn remove(m: *Model, id: u32) void {
        _ = m.map.swapRemove(id);
    }
    fn count(m: *const Model) usize {
        return m.map.count();
    }
    fn clone(m: *const Model) !Model {
        return .{ .map = try m.map.clone(gpa) };
    }
};

/// 树的内容和 model 完全一样：逐个 next 遍历，键按顺序、数据对得上、个数相同。
fn expectContents(v: *Volume, model: *const Model) !void {
    return expectContentsAt(v, v.root, model);
}

/// 同 expectContents，看根为 root 的树（快照）。
fn expectContentsAt(v: *Volume, root: Root, model: *const Model) !void {
    var buf: [btree.max_data]u8 = undefined;
    var want: [btree.max_data]u8 = undefined;
    var count: usize = 0;
    var k: ?Key = Key.min;
    var prev: ?Key = null;
    while (k) |key| {
        const f = try v.nextAt(root, key, &buf) orelse break;
        if (prev) |p| try std.testing.expect(p.lessThan(f.key));
        prev = f.key;
        const id: u32 = @intCast(f.key.offset);
        try std.testing.expect(f.key.eql(testKey(id)));
        const e = model.get(id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(e.size, f.size);
        try std.testing.expectEqualSlices(u8, testData(id, e.version, e.size, &want), buf[0..f.size]);
        count += 1;
        k = f.key.successor();
    }
    try std.testing.expectEqual(model.count(), count);
}

/// 对树和 model 做同一个随机操作：没有这个键就插入，有的话一半概率删掉、一半概率换成新的数据。
fn randomOp(v: *Volume, model: *Model, rng: std.Random, key_space: u32) !void {
    var buf: [btree.max_data]u8 = undefined;
    const id = rng.uintLessThan(u32, key_space);
    const size = rng.uintAtMost(u32, btree.max_data);
    if (model.get(id)) |e| {
        if (rng.boolean()) {
            try v.delete(testKey(id));
            model.remove(id);
        } else {
            // 一半的更新保持长度不变（就地改），一半换个长度（删了再插）
            const new_size = if (rng.boolean()) e.size else size;
            try v.update(testKey(id), testData(id, e.version + 1, new_size, &buf));
            try model.put(id, .{ .version = e.version + 1, .size = new_size });
        }
    } else {
        try v.insert(testKey(id), testData(id, 0, size, &buf));
        try model.put(id, .{ .version = 0, .size = size });
    }
}

test "插入、查找、遍历、更新、删除：树长高又变矮，提交、重新挂载后内容不变" {
    try testSetup(2048);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    var buf: [btree.max_data]u8 = undefined;

    try std.testing.expectEqual(null, try v.lookup(testKey(1), null));
    try std.testing.expectEqual(null, try v.next(Key.min, null));
    // 打乱顺序插入 400 个大小不一的条目
    var ids: [400]u32 = undefined;
    for (&ids, 0..) |*id, i| id.* = @intCast(i);
    rng.shuffle(u32, &ids);
    for (ids) |id| {
        const size = rng.uintAtMost(usize, btree.max_data);
        try v.insert(testKey(id), testData(id, 0, size, &buf));
        try model.put(id, .{ .version = 0, .size = @intCast(size) });
    }
    const grown = try v.check();
    try std.testing.expect(grown.height >= 4); // 测试里内部节点只有 5 个指针
    try std.testing.expectEqual(400, grown.items);
    try expectContents(v, &model);
    try std.testing.expectError(error.Exists, v.insert(testKey(3), "x"));
    try std.testing.expectError(error.TooBig, v.insert(testKey(999), &(@as([btree.max_data + 1]u8, undefined))));
    try std.testing.expectError(error.NotFound, v.update(testKey(999), "x"));
    try std.testing.expectError(error.NotFound, v.delete(testKey(999)));
    // lookup 只复制 out 放得下的部分
    const e = model.get(5).?;
    var small: [3]u8 = undefined;
    try std.testing.expectEqual(e.size, (try v.lookup(testKey(5), &small)).?);

    // 随机改一阵，提交，“重启”之后内容一样
    for (0..300) |_| try randomOp(v, &model, rng, 500);
    _ = try v.check();
    try v.commit();
    _ = try v.check();
    testReboot();
    try v.mount();
    _ = try v.check();
    try expectContents(v, &model);

    // 全部删掉：树缩回一个空叶子，除了超级块和它，所有块都空出来了
    for (model.map.keys()) |id| try v.delete(testKey(id));
    model.map.clearRetainingCapacity();
    const empty = try v.check();
    try std.testing.expectEqual(1, empty.height);
    try std.testing.expectEqual(0, empty.items);
    try v.commit();
    try std.testing.expectEqual(v.blocks - 3, v.free_count);
    try expectContents(v, &model);
}

test "没提交的改动重新挂载后就没了；等着释放的块提交之前不会被分配出去" {
    try testSetup(512);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(2);
    const rng = prng.random();
    for (0..100) |_| try randomOp(v, &model, rng, 200);
    try v.commit();
    const gen = v.generation;
    // 改很多东西：已提交的树的块不断进 pending，check 每次都核对当前的树没有用到它们
    var scratch = try model.clone();
    defer scratch.deinit();
    for (0..200) |i| {
        try randomOp(v, &scratch, rng, 200);
        if (i % 20 == 0) _ = try v.check();
    }
    try std.testing.expect(v.pending.count() > 0);
    testReboot();
    try v.mount();
    try std.testing.expectEqual(gen, v.generation);
    try expectContents(v, &model);
    // 没改东西的提交不写超级块
    const writes = test_writes;
    try v.commit();
    try std.testing.expectEqual(writes, test_writes);
}

test "快照：提交之后读者还看得到旧树；旧树的块进 limbo，读者读完才再分配" {
    try testSetup(512);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    for (0..100) |_| try randomOp(v, &model, rng, 200);
    try v.commit();

    // 拿着快照的时候提交很多次：快照的内容一直不变，旧树释放的块都进 limbo、不会被分配出去
    const snap = v.beginRead();
    var scratch = try model.clone();
    defer scratch.deinit();
    for (0..200) |i| {
        try randomOp(v, &scratch, rng, 200);
        if (i % 10 == 9) {
            try v.commit();
            _ = try v.check(); // limbo 里的块不在当前的树里，used 也算上了它们
            try expectContentsAt(v, snap.root, &model);
        }
    }
    try std.testing.expect(v.limbo_count > 0);
    try std.testing.expectEqual(1, v.old_readers);
    // 提交之后才开始读的读者读最新的树；它读完不会影响 limbo
    const fresh = v.beginRead();
    try expectContentsAt(v, fresh.root, &scratch);
    v.endRead(fresh);
    try std.testing.expect(v.limbo_count > 0);

    // 读完了：下一次分配之前 limbo 空出来
    v.endRead(snap);
    const free_before = v.free_count;
    const limbo = v.limbo_count;
    try randomOp(v, &scratch, rng, 200);
    try v.commit();
    try std.testing.expectEqual(0, v.limbo_count);
    try std.testing.expect(v.free_count + 20 > free_before + limbo); // 一次操作最多再用掉十几块
    _ = try v.check();
    try expectContents(v, &scratch);

    // 没有快照时提交释放的块直接空出来，不进 limbo；同一个事务号里开始又结束的读者也不留下什么
    const s2 = v.beginRead();
    v.endRead(s2);
    for (0..20) |_| try randomOp(v, &scratch, rng, 200);
    try v.commit();
    try std.testing.expectEqual(0, v.limbo_count);
    try std.testing.expectEqual(0, v.readers + v.old_readers);

    // 作废事务（abort 重新走树算用着的块）时 limbo 里的块也还算用着的
    const s3 = v.beginRead();
    var after = try scratch.clone();
    defer after.deinit();
    for (0..20) |_| try randomOp(v, &after, rng, 200);
    try v.commit();
    try std.testing.expect(v.limbo_count > 0);
    try randomOp(v, &after, rng, 200);
    try v.abort();
    _ = try v.check();
    try expectContentsAt(v, s3.root, &scratch);
    v.endRead(s3);

    testReboot();
    try v.mount();
    try std.testing.expectEqual(0, v.limbo_count);
    _ = try v.check();
}

test "磁盘满：放不下时返回 NoSpace、什么都不改；删掉一些、提交之后又能放" {
    try testSetup(40);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var buf: [btree.max_data]u8 = undefined;
    var id: u32 = 0;
    while (true) : (id += 1) {
        v.insert(testKey(id), testData(id, 0, btree.max_data, &buf)) catch |err| {
            try std.testing.expectEqual(error.NoSpace, err);
            break;
        };
        try model.put(id, .{ .version = 0, .size = btree.max_data });
        if (id % 4 == 0) try v.commit();
    }
    _ = try v.check();
    try expectContents(v, &model);
    try v.commit();
    testReboot();
    try v.mount();
    try expectContents(v, &model);
    // 删一半，提交之后释放的块能用了
    for (0..id / 2) |i| {
        try v.delete(testKey(@intCast(i)));
        model.remove(@intCast(i));
    }
    try v.commit();
    try v.insert(testKey(id), testData(id, 0, btree.max_data, &buf));
    try model.put(id, .{ .version = 0, .size = btree.max_data });
    _ = try v.check();
    try expectContents(v, &model);
}

test "坏块、写丢了、写错了地方都能发现；最新的超级块坏了就用上一个" {
    try testSetup(256);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    for (0..60) |_| try randomOp(v, &model, rng, 100);
    try v.commit();
    const old_gen = v.generation;
    const old_root = v.root.blockno;

    // 1. 根节点上翻一位
    test_disk[old_root][100] ^= 0x10;
    testReboot();
    try std.testing.expectError(error.Corrupt, v.mount());
    test_disk[old_root][100] ^= 0x10;
    testReboot();
    try v.mount();

    // 2. 写丢了：再提交一次，然后把新的根块换回它以前的内容（像是新内容根本没写到盘上）
    const before = test_disk[old_root];
    var after_model = try model.clone();
    defer after_model.deinit();
    for (0..10) |_| try randomOp(v, &after_model, rng, 100);
    try v.commit();
    const new_root = v.root.blockno;
    const saved = test_disk[new_root];
    test_disk[new_root] = before; // 内容是旧的根：块号、事务号都对不上
    testReboot();
    try std.testing.expectError(error.Corrupt, v.mount());
    test_disk[new_root] = saved;

    // 3. 最新的超级块坏了：退回上一个事务，那棵树还完整（提交之后没有再写过别的块）
    test_disk[v.generation % 2][50] ^= 1;
    testReboot();
    try v.mount();
    try std.testing.expectEqual(old_gen, v.generation);
    _ = try v.check();
    try expectContents(v, &model);

    // 4. 两个超级块都坏了
    test_disk[0][50] ^= 1;
    test_disk[1][60] ^= 1;
    testReboot();
    try std.testing.expectError(error.NotFormatted, v.mount());
}

test "随机插入、更新、删除，每一步之后检查整棵树" {
    try testSetup(1024);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(4);
    const rng = prng.random();
    for (0..1500) |i| {
        try randomOp(v, &model, rng, 150);
        _ = try v.check();
        if (i % 50 == 49) try v.commit();
    }
    try expectContents(v, &model);
}

/// 掉电测试的一次运行：格式化，按固定的随机序列做 txns 个事务（每个 ops 个操作），每次提交后记下
/// 这个事务号对应的内容。budget 不为 null 时，在第 budget 次写之后掉电（那一次只写进开头的 torn 个字节）。
/// 磁盘只有 64 块：分配器很快就绕回来重用释放了的块，提前重用了已提交的树的块的话，这里一定会撞上。
/// 磁盘满了（NoSpace）的操作什么都不改，参照模型也跳过它。
/// 返回最后一个确实写完了的事务号（它的 commit 返回时还没掉电）。
const CrashRun = struct {
    snapshots: std.ArrayListUnmanaged(Model) = .empty,
    completed: u64 = 0,

    const txns = 20;
    const ops = 6;

    fn deinit(r: *CrashRun) void {
        for (r.snapshots.items) |*m| m.deinit();
        r.snapshots.deinit(std.testing.allocator);
    }

    fn snapshot(r: *CrashRun, gen: u64, m: *const Model) !void {
        try std.testing.expectEqual(gen, r.snapshots.items.len + 1); // 事务号从 1 开始，一个一个来
        try r.snapshots.append(std.testing.allocator, try m.clone());
    }

    fn run(r: *CrashRun, budget: ?usize, torn: usize) !void {
        try testSetup(64);
        const v = &test_vol;
        var model: Model = .{};
        defer model.deinit();
        try r.snapshot(v.generation, &model);
        r.completed = v.generation;
        test_budget = budget;
        test_torn = torn;
        var prng = std.Random.DefaultPrng.init(5);
        const rng = prng.random();
        for (0..txns) |t| {
            // 时不时在事务开头保存一个快照、删掉最早的快照
            if (t % 6 == 2) _ = v.createSnap() catch |err| switch (err) {
                error.TooManySnapshots, error.Exists => {},
                else => return err,
            };
            if (t % 6 == 5) if (oldestSnap(v)) |g| try v.deleteSnap(g);
            for (0..ops) |_| {
                randomOp(v, &model, rng, 40) catch |err| {
                    if (test_crashed) return; // 掉电之后读到的东西是乱的，出什么错都不奇怪
                    if (err != error.NoSpace) return err;
                };
                if (test_crashed) return;
            }
            // 提交之前就记下：在写超级块的那一刻掉电，这个事务可能算提交了、也可能没有
            //（只写进一半的超级块：前一半就是整个 Super，后面都是 0，和旧的一样，其实是写完整了）
            try r.snapshot(v.transid, &model);
            v.commit() catch |err| {
                if (test_crashed) return;
                return err;
            };
            if (test_crashed) return;
            r.completed = v.generation;
        }
    }
};

fn oldestSnap(v: *const Volume) ?u64 {
    var g: ?u64 = null;
    for (v.snaps) |x| if (x) |sn| {
        g = if (g) |o| @min(o, sn.generation) else sn.generation;
    };
    return g;
}

/// 保存的快照的内容都是它那个事务号提交之后的样子。
fn expectSnaps(v: *Volume, models: []const Model) !void {
    for (v.snaps) |x| if (x) |sn| try expectContentsAt(v, sn.root, &models[sn.generation - 1]);
}

fn crashAt(budget: usize, torn: usize) !void {
    var r: CrashRun = .{};
    defer r.deinit();
    try r.run(budget, torn);
    // 重新上电、挂载：必须成功，树完好，内容正好是某一次提交之后的样子，而且不早于最后一次写完的提交
    testReboot();
    const v = &test_vol;
    v.mount() catch |err| {
        std.debug.print("budget {d} torn {d}: mount failed: {s}\n", .{ budget, torn, @errorName(err) });
        return err;
    };
    _ = try v.check();
    try std.testing.expect(v.generation >= r.completed and v.generation <= r.snapshots.items.len);
    try expectContents(v, &r.snapshots.items[v.generation - 1]);
    try expectSnaps(v, r.snapshots.items);
    // 挂载之后还能接着用
    var prng = std.Random.DefaultPrng.init(budget);
    var model = try r.snapshots.items[v.generation - 1].clone();
    defer model.deinit();
    for (0..5) |_| randomOp(v, &model, prng.random(), 40) catch |err| if (err != error.NoSpace) return err;
    try v.commit();
    _ = try v.check();
}

test "掉电（设备有写缓存）：上次 flush 之后的写可能丢、可能乱序，重新挂载后都是某个已提交的状态" {
    defer testFree();
    test_cache_mode = true;
    var full: CrashRun = .{};
    defer full.deinit();
    try full.run(null, 0);
    const total = test_writes;
    try std.testing.expect(test_flushes > 2); // 每次提交前后各一次
    for (0..total + 1) |budget| {
        for (0..4) |seed| {
            test_cache_seed = budget * 4 + seed;
            crashAt(budget, 0) catch |err| {
                std.debug.print("cached crash after {d} of {d} writes, seed {d}\n", .{ budget, total, test_cache_seed });
                return err;
            };
        }
    }
}

test "掉电：在每一次写之后掉电（包括只写了一半），重新挂载后都是某个已提交的状态" {
    defer testFree();
    // 先完整跑一遍，数一共写几次
    var full: CrashRun = .{};
    defer full.deinit();
    try full.run(null, 0);
    const total = test_writes;
    try std.testing.expect(total > 100);
    for (0..total + 1) |budget| {
        // 那一次写：完全没写进去、写进前 16 字节（超级块的字段写了一半）、写进前一半（节点写了一半）
        for ([_]usize{ 0, 16, block_size / 2 }) |torn| crashAt(budget, torn) catch |err| {
            std.debug.print("crash after {d} of {d} writes, torn at {d} bytes\n", .{ budget, total, torn });
            return err;
        };
    }
}

/// 在第 fail_at 次设备操作时读写失败，跑 CrashRun 那样的随机事务：失败的事务作废（内存里退回上一次提交），
/// 接着跑下去；提交到一半失败的，卷不再修改（broken）。最后核对内存里和重新挂载之后的内容。
/// 返回跑完这些事务用了几次设备操作（之后的核对不再注入失败），卷有没有因此不再修改。
fn ioErrorAt(fail_at: usize, wrote: bool) !struct { ops: usize, broken: bool } {
    try testSetup(64);
    const v = &test_vol;
    var snapshots: CrashRun = .{}; // 借它记每个事务号对应的内容
    defer snapshots.deinit();
    var model: Model = .{};
    defer model.deinit();
    try snapshots.snapshot(v.generation, &model);
    test_fail_at = fail_at;
    test_fail_wrote = wrote;
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    for (0..CrashRun.txns) |_| {
        bio.invalidate(); // 不然大部分读都被缓存挡住了，测不到读失败
        const ok = txn: {
            for (0..CrashRun.ops) |_| randomOp(v, &model, rng, 40) catch |err| switch (err) {
                error.NoSpace => {},
                error.IoError => break :txn false, // 操作自己作废了事务
                else => return err,
            };
            // 提交之前就记下：写超级块失败的话，盘上可能是它、也可能还是上一个
            if (snapshots.snapshots.items.len < v.transid) try snapshots.snapshot(v.transid, &model);
            v.commit() catch |err| switch (err) {
                error.IoError => break :txn false,
                else => return err,
            };
            break :txn true;
        };
        if (!ok) {
            // Fs.run 也是这样：出错就作废（已经作废过的话什么都不做）
            v.abort() catch |err| if (err != error.IoError) return err;
            model.deinit();
            model = try snapshots.snapshots.items[v.generation - 1].clone();
            // 提交到一半失败的，盘上可能已经是下一个事务号的内容，留着它
            if (v.broken) break;
            // 没提交的事务号会被下一个事务重用
            while (snapshots.snapshots.items.len > v.generation) {
                var m = snapshots.snapshots.pop().?;
                m.deinit();
            }
        }
    }
    const ops_used = test_ops;
    const broken = v.broken;
    test_fail_at = null;
    const gen = v.generation;
    const committed = &snapshots.snapshots.items[gen - 1];
    if (v.broken) {
        // 不再修改，读者照常读已提交的树
        try std.testing.expectError(error.IoError, v.commit());
        try std.testing.expectError(error.IoError, randomOp(v, &model, rng, 40));
        try expectContentsAt(v, v.committed, committed);
    } else {
        _ = try v.check();
        try expectContents(v, committed);
    }
    // 重新挂载：盘上的是最后一次提交的；提交到一半失败的话，也可能是那一次（写失败的超级块可能其实写下去了）
    testReboot();
    try v.mount();
    _ = try v.check();
    try std.testing.expect(v.generation == gen or (v.generation == gen + 1 and v.generation <= snapshots.snapshots.items.len));
    try expectContents(v, &snapshots.snapshots.items[v.generation - 1]);
    // 挂载之后还能接着用
    model.deinit();
    model = try snapshots.snapshots.items[v.generation - 1].clone();
    for (0..5) |_| randomOp(v, &model, rng, 40) catch |err| if (err != error.NoSpace) return err;
    try v.commit();
    _ = try v.check();
    try expectContents(v, &model);
    return .{ .ops = ops_used, .broken = broken };
}

test "读写失败：在每一次读、写、flush 时失败，事务作废或者卷不再修改，重新挂载后都是某个已提交的状态" {
    defer testFree();
    const total = (try ioErrorAt(std.math.maxInt(usize), false)).ops; // 不失败，数一共几次设备操作
    try std.testing.expect(total > 200);
    var broken: usize = 0;
    for (0..total) |n| {
        for ([_]bool{ false, true }) |wrote| {
            const r = ioErrorAt(n, wrote) catch |err| {
                std.debug.print("I/O error at operation {d} of {d} (wrote: {})\n", .{ n, total, wrote });
                return err;
            };
            if (r.broken) broken += 1;
        }
    }
    try std.testing.expect(broken > 0); // 有些落在了提交的中间
}

test "保存的快照：之后改、删都不影响它，它的块不释放、不改写；删掉之后块空出来；重新挂载后还在" {
    try testSetup(512);
    defer testFree();
    const v = &test_vol;
    var model: Model = .{};
    defer model.deinit();
    var prng = std.Random.DefaultPrng.init(3);
    const rng = prng.random();
    for (0..60) |_| try randomOp(v, &model, rng, 50);
    try v.commit();
    const free_before = v.free_count;
    var saved = try model.clone();
    defer saved.deinit();
    const g = try v.createSnap();
    try std.testing.expectEqual(v.generation, g);
    try v.commit();
    // 改很多、删很多：快照里还是原来的样子，check 认得共用的块
    for (0..200) |_| {
        try randomOp(v, &model, rng, 50);
        if (rng.uintLessThan(u8, 8) == 0) try v.commit();
    }
    try v.commit();
    _ = try v.check();
    try expectContents(v, &model);
    try expectContentsAt(v, v.snapRoot(g).?, &saved);
    try std.testing.expect(v.free_count < free_before);
    // 重新挂载：快照还在
    testReboot();
    try v.mount();
    _ = try v.check();
    try expectContentsAt(v, v.snapRoot(g).?, &saved);
    // 存满了是 TooManySnapshots；作废的事务里删掉的快照还在
    for (1..max_snaps) |_| {
        try randomOp(v, &model, rng, 50);
        try v.commit();
        _ = try v.createSnap();
        try v.commit();
    }
    try std.testing.expectError(error.TooManySnapshots, v.createSnap());
    try v.deleteSnap(g);
    try v.abort();
    try std.testing.expect(v.snapRoot(g) != null);
    try std.testing.expectError(error.NotFound, v.deleteSnap(12345));
    try v.abort();
    // 都删掉：提交之后重走一遍树，块都空出来；当前的树不变
    for (v.snaps) |x| if (x) |sn| try v.deleteSnap(sn.generation);
    try v.commit();
    _ = try v.check();
    try expectContents(v, &model);
    for (0..400) |_| randomOp(v, &model, rng, 50) catch |err| if (err != error.NoSpace) return err;
    try v.commit();
    _ = try v.check();
    try expectContents(v, &model);
}
