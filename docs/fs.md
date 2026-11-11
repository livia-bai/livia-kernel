# 文件系统

涉及文件：`src/fs.zig`（文件系统本身）、`src/fsys.zig`（接进内核）、`src/mkfs.zig`（主机上生成磁盘镜像）；调用方：`src/syscall.zig`、`src/file.zig`；建在写时复制 B 树上（`src/ctree.zig`、`src/btree.zig`，[btree.md](btree.md)），数据块的读写走缓冲区缓存（[disk.md](disk.md#缓冲区缓存biozig)）

文件系统的所有东西——inode、目录、文件内容——都是写时复制 B 树里的条目，照 btrfs 的条目设计简化。`fs.zig` 只有文件系统本身的逻辑：不加锁、不知道进程、不直接碰用户内存（读写通过调用方给的 `out`、`in`）。内核、主机上的 `mkfs`、单元测试都用它。

## 条目

键是 `(objectid, type, offset)`，`objectid` 都是 inode 号，所以一个文件的所有条目在树里挨在一起：

| 键 | 数据 | 说明 |
| --- | --- | --- |
| `(ino, 1, 0)` | `Inode { kind, major, nlink, size, parent }`（24 字节） | 种类（文件、目录、设备、符号链接）、设备号、链接数、长度、所在的目录 |
| `(目录 ino, 2, 散列 << 32 \| 序号)` | `DirHeader { ino, kind, name_len }` + 名字 | 目录项。散列是名字的 crc32c |
| `(ino, 3, 页号 × 4096)` | `ExtentHeader { kind, csum }` + 内容或 `{ blockno, generation }` | 文件第几页的内容：内联，或者指向一个数据块；符号链接的目标（总是内联在第 0 页） |

- 根目录的 inode 号是 1。新 inode 号是树里最大的 `objectid` + 1：挂载时用 `Volume.lastKey()` 算出来，之后递增，不重用。
- `Inode.nlink` 是有几个目录项指着它（[硬链接](#硬链接和设备文件)）：文件、设备文件可以有几个名字，目录总是 1。没有 Unix 那种“打开着的文件也算一个引用”，见[目录](#目录)里的删除。
- `Inode.parent` 是所在的目录，只对目录有意义（`..` 和 `check` 用它）；文件可能有几个名字，它的 `parent` 只是建它（或者最后一次 `rename` 挪进去）的那个目录。
- 所有结构体都是 `extern struct`，内核和主机上看到的布局一样。格式改了要换 `ctree.magic`：加链接数、设备号时从 `LBFS0001` 换成了 `LBFS0002`（新字段放在原来 `Inode` 的填充字节里，大小还是 24 字节，但旧镜像里那里是 0，链接数 0 会被 `check` 当成坏的）；加符号链接时换成了 `LBFS0003`（多了一种 inode，旧的内核读到它会当成坏的）。

## 目录

**目录项按名字的散列排序**：键的 `offset` 是 `散列 << 32 | 序号`。查一个名字时从 `(dir, 2, 散列 << 32)` 开始往后看所有散列相同的目录项（`Volume.next`），逐个比名字。插入时序号用这些目录项里最大的序号 + 1，所以散列相同的名字也分得开（单元测试用了一对事先找好的 crc32c 相同的名字 `n1371838`、`n2000402`）。btrfs 的 `DIR_ITEM` 也是按名字的散列做键，散列冲突时把几个名字放进同一个条目。

**目录里不存 "." 和 ".."**：路径里遇到 `.` 就是自己，遇到 `..` 用 `Inode.parent`（根目录的 `parent` 是它自己）。

**`readdir(dir, cookie, name)`** 返回键 `>= (dir, 2, cookie)` 的第一个目录项和下一次用的 `cookie`（这一项的 `offset + 1`），从 0 开始，没有了返回 null。顺序就是散列的顺序。cookie 是键，不是下标，所以列目录的过程中别的名字被删了、加了，也不会重复或者跳过还在的名字。

**路径**（`resolve`）：以 `/` 开头的从根目录找，否则从调用方给的当前目录找；多个 `/` 当一个；中间的每一段都必须是目录（`NotDir`）。名字最长 255 字节（`NameTooLong`）；创建、删除时最后一段不能是空的、`.`、`..`（`InvalidName`）。遇到符号链接就换成它的目标接着走（[符号链接](#符号链接)）。

**删除**（`unlink`）：目录必须是空的（`NotEmpty`）。删掉目录项；指向的 inode 还有别的名字（`nlink > 1`）的话只把链接数减 1，否则删掉这个 inode 号的所有条目（inode 和文件内容，指向的数据块一起释放）。inode 删掉之后，还打开着它的文件、以它为当前目录的进程再用它，会得到 `NotFound`：没有 Unix 那种“最后一个打开的人关掉才真正删除”。

## 硬链接和设备文件

**硬链接**（`link(cwd, old, new)`，和 xv6 的 `link` 一样）：在 `new` 的目录里插一个目录项，指向 `old` 的 inode，`nlink` 加 1，一个事务做完。两个名字是同一个 inode：内容、长度都只有一份，从哪个名字改，另一个名字都看得到；删掉一个名字（`unlink`、`rename` 换掉它），另一个照常，删到最后一个才删内容。

- 目录不能链接（`IsDirLink`，系统调用返回 `-EPERM`）：目录要有唯一的 `parent`，`..` 才有意义，`check` 才能确认所有目录都连得到根目录、没有环。
- `new` 已经有了是 `Exists`；`new` 的最后一段和创建一样检查（不能是 `.`、`..`）。链接数是 `u32`，到上限是 `TooManyLinks`（`-EMLINK`）。
- `rename` 到同一个 inode 的另一个名字（`rename a b`，`a`、`b` 是同一个文件的两个硬链接）什么都不做，和 Unix 一样。
- 目录项里记着 inode 的种类，所以 `readdir` 不用读 inode 就知道是不是目录。

**设备文件**（`mknod(cwd, path, major)`，xv6 的 `mknod`）：种类是 `device` 的 inode，`major` 是设备号（`abi.Major`：1 串口、2 null、3 zero），长度 0，没有内容条目。文件系统只管它的名字和设备号，打开它之后的读写由内核按设备号交给设备（[files.md](files.md#设备文件)），不经过文件系统。不认识的设备号也能建（和 Unix 一样），打开时才报错。设备文件可以链接、改名、删除；不能 `chdir` 进去、不能当程序运行（`BadElf`）。`fs.read`、`fs.write` 碰到设备文件是 `IsDir`（内核不会这样调用）。

`mkfs` 建 `/dev`，里面是 `console`、`null`、`zero` 三个设备文件（xv6 只有 `console`，由 init 在启动时 `mknod`）。

## 符号链接

**符号链接**（`symlink(cwd, target, path)`）：种类是 `symlink` 的 inode，内容是 `target` 这个字符串，原样存下，用到时才解析，所以目标可以还不存在（悬空的链接），也可以以后被删掉、换掉。目标存在第 0 页的内容条目里，总是内联（btrfs 也把符号链接的目标存成 inline extent），inode 的长度就是目标的长度。目标最长 `max_symlink` = 256 字节（和路径一样长），空的是 `NotFound`（和 Linux 一样）。`readlink(ino, out)` 读出目标，不是符号链接是 `NotSymlink`（系统调用返回 `-EINVAL`）。

**解析路径**（`walk`，`resolve` 和 `resolveNoFollow` 都用它）一段一段地走，遇到符号链接就把“目标 + 还没走的部分”拼成新的路径接着走：

```
/c/f，/c -> /tob，/tob -> a/b
  走到 /c：是链接，剩下的 "/f" 接在目标后面 → "/tob/f"，目标是绝对路径，从根目录重新开始
  走到 /tob：是链接 → "a/b/f"，目标是相对路径，从链接所在的目录（/）开始
  a、b、f 都不是链接，结果是 /a/b/f
```

- 相对的目标从**链接所在的目录**开始，不是从调用方的当前目录（和 Unix 一样）。
- 跟着走最多 `max_follows` = 10 次（xv6 的 symlink 实验建议的数），再多是 `SymlinkLoop`（`-ELOOP`）：自己指自己、两个互指，或者太长的链。
- 拼出来的路径放在 `walk` 栈上的一个 256 字节的缓冲区里：先把还没走的部分挪到后面（它可能本来就在这个缓冲区里，用 `@memmove`），再把目标读到前面。不递归，栈上只多这一个缓冲区；拼出来超过 256 字节是 `NameTooLong`。
- 链接后面的 `..` 是目标的父目录（按 `Inode.parent`），不是链接所在的目录：`/tob/..` 是 `/a`。shell 的 `cd` 也是这样，没有 bash 那种按字符串处理的“逻辑路径”。
- **最后一段**跟不跟着走看调用方：`resolve` 跟着走（`open`、`chdir`、`exec`、`link` 的新名字所在的目录），`resolveNoFollow` 不跟（`lstat`、`readlink`、`link` 的旧名字）。路径后面只有 `/` 的（`link/`）也算最后一段。中间的链接总是跟着走，包括 `resolveParent` 找父目录的时候，所以在链接后面建东西（`/tob/g`）建在目标目录里。
- **对链接自己的操作**：`unlink`、`rename` 只看父目录里的目录项，不解析最后一段，删的、改名的是链接自己，目标不动；指向目录的链接像文件一样删，不管目录空不空。`link` 不跟着旧名字走（和 Linux 的 `link` 一样），硬链接到的是链接自己，所以符号链接也有链接数。
- **建文件**（`createFollow`，`open` 带 `O_CREATE` 并且路径不存在时）：最后一段是指向不存在的东西的链接的话，建的是它指向的那个文件（`echo x > 悬空的链接` 建出目标），也跟着走最多 10 次；中间缺的目录不建（`NotFound`）。`mkdir`、`mknod`、`symlink` 遇到同名的链接都是 `Exists`。
- 读写、截断、`chdir`、`exec` 都先 `resolve`，拿到的不会是链接；`fs.read`、`fs.write` 碰到链接是 `IsDir`（内核不会这样调用）。

## 当前目录的路径（`getcwd`）

`dirPath(ino, out)` 从目录 `ino` 沿着 `parent` 往上走到根目录，在每一层的父目录里用 `readdir` 找指向它的目录项（目录只有一个名字，`nameOf`），把名字从后往前填进 `out`。走的是真实的目录，所以经过符号链接 `cd` 进来的目录，得到的是它真正的位置；目录改了名、挪了地方，结果跟着变。`out` 放不下是 `NameTooLong`（系统调用返回 `-ERANGE`）；磁盘上的 `parent` 有环的话，路径越拼越长，也停在这里。目录被删掉了是 `NotFound`。

找名字要把父目录列一遍，一层是 O(目录项数)：xv6 没有 `getcwd`，Linux 的 dentry 缓存里直接有名字和父目录。这里只有 shell 的 `pwd`、`cd -` 用它，够快了。

## 文件内容

文件按 4 KiB 一页存，一页一个条目：

- **内联**：整个文件不超过 `inline_max`（512）字节时，内容直接放在第 0 页的条目里，不占数据块（btrfs 的 inline extent）。内联条目的数据长度就是文件长度。写的时候整个条目读出来、改、写回去（`writeInline`）。
- **数据块**：文件长到 512 字节以上时，先把内联的内容搬进一个数据块（`unInline`），之后每页一个数据块。条目里记着块号、写它的事务号和内容的 crc32c。
- **洞**：没有条目的页读出来是 0，不占块。往文件末尾之后很远的地方写，中间就是洞。
- **长度之外的字节总是 0**：新分配的页先清零（不是整页覆盖的话），内联转数据块时剩下的部分清零。所以文件变长时不用专门去清零。

**写**（`write`）：对每一页，分配一个**新**数据块；不是整页覆盖的话先把旧内容复制过来（没有旧的就清零）；再从 `in` 取新内容；算校验和、写下去；条目改成指向新块，旧块交给 `Volume.freeData`。数据块和树的节点一样写时复制：已提交的树指向的数据块从来不改，属于已提交的树的旧块要等提交之后才能再分配（[btree.md](btree.md#事务和提交)）。最后改 inode 的长度。

**读**（`read`）：对每一页查条目：洞给 0，内联的从条目里取，数据块的读出来交给 `out`。数据块从磁盘读进来时（`bio.load` 返回 true）核对条目里记的 crc32c，对不上是 `Corrupt`：btrfs 也对数据做校验和，只是存在单独的一棵树里。

**截断**（`truncate`）：现在只能截成 0（`open` 时的 `O_TRUNC`），删掉所有内容条目、释放数据块，长度设成 0。之后再写又从内联开始。

**挂载时**，`ctree` 走树算用着的块，也要算上数据块：`fs.mount` 先把 `Volume.data_refs` 设成 `dataRefs`，它对指向数据块的内容条目返回那个块，`walk` 把它记成用着的（同一块被引用两次是 `Corrupt`）。挂载只读树的节点，不读数据块。

**读写的对象**：`read(ino, off, len, out)` 把内容交给 `out.put(在这次读里的位置, 字节)`，`write(ino, off, len, in)` 从 `in.get(在这次写里的位置, 目标)` 取内容。内核里它们是用户内存（`vm.copyToUser`、`copyFromUser`，可能返回 `BadAddress`），单元测试里是一个切片。数据块的内容从缓冲区直接复制到用户内存，不经过内核栈上的临时缓冲区（内联的内容不超过 512 字节，经过栈上的一个小缓冲区）。

## 事务：每个操作提交一次

```zig
pub fn run(fs: *Fs, comptime op: anytype, args: anytype) Error!...
```

调用方用 `fs.run(Fs.write, .{ ino, off, len, in })` 这样的方式做每一个操作：操作成功就 `Volume.commit()`，出错就 `Volume.abort()`。一个操作（比如创建文件 = 插入 inode + 插入目录项，或者写 10 页）在 ctree 里是好几次修改，中间任何一步出错（磁盘满、读到坏块、用户内存不对），之前做了的一起作废。所以**每个操作要么全做了、要么什么都没做**，掉电也一样：掉电时最后一个操作要么提交了，要么没有。

代价是每个操作都写一次超级块。以后可以把几个操作攒在一个事务里（xv6 的日志也是攒着一起提交）。

## 接进内核（`fsys.zig`）

```zig
var vol: ctree.Volume = .{};   // 唯一的一个卷
var root: fs.Fs = undefined;   // 挂载好的文件系统（修改的一方用）
pub var mounted = false;
var write_lock: Sleeplock = .init("fs write");
pub var raw_base: u64 = 0;     // 原始区域：文件系统之后的块
pub var raw_count: u64 = 0;

pub const Reader = struct { fs: Fs, snap: ctree.Snapshot, pub fn end(r: *Reader) void };
pub fn init() void                         // 挂载
pub fn reader() error{NoDevice}!Reader     // 读：拿一个已提交的树的快照
pub fn writer() error{NoDevice}!*Fs        // 改：拿着 write_lock 返回文件系统
pub fn unlock() void                       // 放开 write_lock

// 正在运行的程序文件（按需分页从它读页），见下面
pub fn holdText(ino: u64) error{TextBusy}!void
pub fn dupText(ino: u64) void
pub fn releaseText(ino: u64) void
pub fn beginModify(ino: u64) error{TextBusy}!void    // 拿着 write_lock，改 ino 之前
pub fn endModify() void
pub fn beginRemove(w: *Fs, cwd: u64, path: []const u8) error{TextBusy}!bool
pub fn readText(ino: u64, off: u64, dst: []u8) error{IoError}!void
```

**挂载**：第一个进程（init）第一次回到 U 模式之前，在 `forkretC` 里调用 `fsys.init()`（xv6 的 `forkret` 里调用 `fsinit` 也是这个原因）：挂载要读盘，读盘要睡着等中断，只有进程能做，`kmain` 不行。之后创建的进程都在这之后运行。成功时打印

```
[ok] file system: 6840 of 7168 blocks free, generation 27
```

磁盘上没有文件系统时打印 `[warn] no file system on the disk: NotFormatted`（接一块全 0 的 4 MiB 镜像实测；超级块坏了是别的错误名），照常启动：文件系统的系统调用返回 `-ENODEV`（`ls /` 打印 `ls: /: NoDevice`），整个磁盘都是原始区域。

**读者不拿锁，在快照上读；修改的一方拿写锁，一个一个来。** 写时复制的 B 树天然有快照：已提交的树的块从来不改，修改只写别的块，最后写超级块“一下子换成新的树”。所以读的一方只要记下最近一次提交的根，就能在那棵树上读，不管修改的一方同时在做什么（[btree.md](btree.md#快照读者)）。

- **读**：`read`、`fstat`、`lstat`、`readdir`、`readlink`、`getcwd`、`lseek`、`chdir`、只打开已有文件的 `open`、`exec` 加载程序、按需分页从程序文件读页（`readText`）。`fsys.reader()` 拿一个快照（`ctree.Volume.beginRead`），返回一个只读的 `Fs`（`view` 设成快照的根，所有查找都在那棵树上做），读完 `r.end()`。几个读者之间、读者和修改的一方之间都不用等（只在同一个缓冲区的睡眠锁上短暂地排队）。读者看到的是开始读时最近一次提交的样子：修改的一方做到一半的东西看不到；一次 `read` 读出的整个内容一定来自同一个版本，不会半新半旧（`t_fsmp` 测这个）。
- **改**：`write`、`mkdir`、`unlink`、`rename`、`link`、`symlink`、`mknod`、建文件或者截断的 `open`、`scrub`。`fsys.writer()` 拿 `write_lock`（睡眠锁），在当前事务的树上做，`fs.run` 提交或作废，`fsys.unlock()`。B 树同一时刻只能有一个事务（一个事务是从根到叶子的整条写时复制路径，改的都是同一个根），所以修改之间还是排队；但它们不再挡着读。xv6 的 inode 各有一把睡眠锁，改不同的文件可以并行；这里要做到这一点得像 btrfs 那样让几个操作加入同一个正在进行的事务、给树的每个节点加锁，复杂得多。
- **旧树的块不能马上重用**：读者可能还在读旧的那棵树，而提交之后旧树不用的块（`pending`）本来马上就能再分配、被改写。所以有旧树的读者时，这些块先进 `limbo`，旧树的读者都读完了才空出来；修改的一方在空闲块不够时睡着等它们读完（[btree.md](btree.md#快照读者)）。
- **加锁顺序**：`File.pos_lock` → `write_lock` → 缓冲区的睡眠锁 → `virtio_disk.lock`。`write_lock` 是睡眠锁：拿着它要读写磁盘（睡着等），拿它之前不能拿着自旋锁，回到 U 模式之前放开。**拿着快照时不能去等 `pos_lock`、`write_lock`**：修改的一方可能拿着它们在等旧树的读者读完。系统调用都是先拿 `pos_lock`，再拿快照或写锁。
- `File.off`（几个 fd 共用的读写位置）由 `File.pos_lock` 保护（[files.md](files.md#文件表)）：读写的整个过程拿着它，共用一个 `File` 的进程并发 `write` 不会写到同一个位置上。
- `mounted`、`root` 只在 `init` 里写一次（那时还没有别的进程），之后只读，读者不拿锁读它们。`root.next_ino` 只有修改的一方用，由 `write_lock` 保护；读者的 `Fs` 里它是 0，不用。
- 原始区域只由 `readblock`、`writeblock` 读写，不拿文件系统的锁：它和文件系统用的块不重叠。

**打开的文件**：`file.File` 多了一种 `.inode`，记着 inode 号 `ino` 和读写位置 `off`（[files.md](files.md)）。`read`、`write` 系统调用对它调用 `fs.read`、`fs.run(Fs.write, ...)`，`out`、`in` 是 `UserOut`、`UserIn`（用户地址空间和指针，经 `vm.copyToUser`、`copyFromUser`，[syscalls.md](syscalls.md#访问用户内存)），成功了才挪 `off`。

**每个进程有当前目录**：`Process.cwd`（inode 号，从根目录开始），`fork` 继承，`exec` 不变，只有自己读写（`chdir`）。相对路径从它开始找。

**系统调用**（[syscalls.md](syscalls.md#调用列表)）：

| 调用 | 做什么 |
| --- | --- |
| `open(path, flags)` | `resolve`（跟着符号链接走）；没有并且带 `O_CREATE` 时 `createFollow`；是目录并且要写是 `EISDIR`；带 `O_TRUNC` 并且可写时 `truncate`；`O_APPEND` 记在 `File` 里。设备文件打开成设备（[files.md](files.md#设备文件)），内核不认识的设备号是 `ENXIO`。返回 fd。带 `O_CREATE`、或者可写并带 `O_TRUNC` 的拿写锁，别的在快照上找 |
| `mkdir(path)`、`unlink(path)` | `create(.dir)`、`unlink` |
| `chdir(path)` | `resolve`，不是目录是 `ENOTDIR` |
| `fstat(fd)` | inode 号、长度、种类、链接数、设备号；串口和管道也能查（种类是 `console`、`pipe`，链接数 0） |
| `readdir(fd)` | 目录的下一项：`File.off` 就是 `fs.readdir` 的 cookie，结果写进用户内存成功了才往后挪 |
| `read`、`write` | 从 `off` 开始读写（读在快照上，写拿写锁）；读写目录是 `EISDIR`。`open_append` 打开的，写之前先把 `off` 挪到文件末尾（同一次拿锁里） |
| `rename(old, new)` | `rename`（[改名](#改名rename)） |
| `link(old, new)` | `link`（[硬链接](#硬链接和设备文件)）；目录是 `EPERM` |
| `symlink(target, path)` | `symlink`（[符号链接](#符号链接)），拿写锁 |
| `readlink(path)`、`lstat(path)` | `resolveNoFollow` 之后 `readlink`、`stat`，在快照上读 |
| `getcwd` | `dirPath(当前目录)`（[当前目录的路径](#当前目录的路径getcwd)），在快照上读 |
| `mknod(path, major)` | `mknod`；`major` 是 0 或者超过 `u16` 是 `EINVAL` |
| `lseek(fd, offset, whence)` | 改 `File.off`，`seek_end` 要先 `stat`（[files.md](files.md#文件表)） |
| `scrub` | 先作废缓存，再 `check` 整个文件系统（[检查](#检查整个文件系统checkscrub)） |
| `exec` | 在 `/bin`（或给的路径）里找程序，占住它（`holdText`），在一个新的快照上读 ELF 的文件头和程序头；段的内容等缺页时再读（`readText`，[process.md](process.md#按需分页)） |

路径先复制进内核栈上的缓冲区（最长 `abi.max_path` = 256 字节，长了是 `ENAMETOOLONG`）。错误码：`SymlinkLoop` → `ELOOP`，`NotSymlink` → `EINVAL`，`NotFound` → `ENOENT`，`Exists` → `EEXIST`，`NotDir` → `ENOTDIR`，`IsDir` → `EISDIR`，`NotEmpty` → `ENOTEMPTY`，`NameTooLong` → `ENAMETOOLONG`，`InvalidName` → `EINVAL`，`NoSpace` → `ENOSPC`，`FileTooBig` → `EFBIG`，`BadAddress` → `EFAULT`，`Corrupt` 等磁盘上的东西不对 → `EIO`。

**内核栈**：系统调用在 16 KiB 的进程内核栈上运行，B 树的操作走得很深。开发时内核栈被撑爆过一次（Debug 模式用到 54 KiB）：`std.bit_set` 的 `isSet`、`count` 按值接收整个位图，每调用一次在栈上复制 8 KiB；`x.* = y.*` 复制 4 KiB 的块也会先放在栈上。改成自己写的 `Bitmap`（方法接收指针）和 `@memcpy` 之后，实测跑完全部 QEMU 测试（包括 `t_fs`、掉电后重新启动、从文件系统 `exec`），最深 Debug 11624 字节、safe 7800 字节、small 7384 字节（加了符号链接、`getcwd` 之后重新量的，测法见 [process.md](process.md#进程表)）。路径解析（`walk`）跟着符号链接走时不递归，只在栈上多放一个 256 字节的缓冲区。

## 正在运行的程序文件

按需分页（[process.md](process.md#按需分页)）：进程运行期间才从它的程序文件里读页，每次缺页拿一个新的快照、按 inode 号读那一页（`readText`）。所以程序文件在有地址空间用着它的时候不能变，不然之后读进来的页和 `exec` 时读的文件头、和之前读进来的页就不是同一个版本了。和 Linux 一样，改它的一方得到 `TextBusy`（`-ETXTBSY`）：

| 操作 | 什么时候是 `TextBusy` |
| --- | --- |
| `write` | 写的是正在运行的程序文件（`file.inodeWrite`） |
| 带 `O_TRUNC` 的 `open` | 截断的是正在运行的程序文件（`syscall.openPath`） |
| `unlink` | 删的是正在运行的程序文件的**最后一个**名字（`nlink == 1`，删了内容就没了） |
| `rename` | 新名字已经有了、是正在运行的程序文件的最后一个名字（会被换掉）；两个名字是同一个 inode 时 `rename` 什么都不做，不算 |
| `exec` | 程序文件正在被改（上面某个操作做到一半） |

改名（`rename` 的旧名字）、加硬链接、删掉别的名字都不动内容，照常可以。Linux 允许删掉正在运行的程序（inode 留到最后一个用它的进程结束）；这里的文件系统没有“没有名字、但还有人用着”的 inode，删掉最后一个名字就删掉了内容，所以干脆不让删。

**记账**（`fsys.zig` 末尾）：

```zig
var text_lock: Spinlock = .init("fs text");                   // 叶子锁
var texts: [2 * abi.max_procs]struct { ino: u64 = 0, refs: u32 = 0 } = @splat(.{});
var modifying: u64 = 0;                                       // 修改的一方正在改的 inode
```

- **占住**：`exec` 找到程序文件之后 `holdText(ino)`，引用数加 1（`modifying == ino` 的话是 `TextBusy`）；占用交给新的地址空间（`vm.Space.backing = .{ .file = ino }`）。`fork` 复制地址空间时 `dupText`；进程结束（`proc.finish`）、`exec` 换掉旧的地址空间、地址空间被释放时 `releaseText`（`vm.releaseBacking`，只放一次）。表按 inode 记，每个地址空间最多占一份，表的大小是地址空间最多能有的个数（每个进程一个，加上 `exec` 新建、还没换上的），不会满。
- **修改**：上面那几个操作拿着 `write_lock`，在改之前 `beginModify(ino)`：有人占着就是 `TextBusy`；没有就记下 `modifying = ino`，事务提交或者作废之后 `endModify`。`unlink`、`rename` 先用 `beginRemove` 找到要删掉的 inode（用写的一方的 `Fs` 找：拿着 `write_lock`，没有做到一半的事务，它就是已提交的样子），是文件、并且是最后一个名字才检查。名字不存在之类的错误留给接下来的操作自己报。修改都拿着 `write_lock`，所以同一时刻最多一个 `modifying`。
- **为什么 `exec` 占住之后要重新拿快照**：`exec` 先在一个快照上按路径找到 inode，再占住它。找的那个快照可能已经旧了：别人可能在两者之间改完、提交了这个文件。两边都拿着 `text_lock` 查、改：占住之前开始的修改，要么还没 `endModify`（`holdText` 看到 `modifying == ino`，`exec` 失败），要么已经提交了；占住之后开始的修改都会失败。所以占住之后新拿的快照里的文件，就是之后每次缺页读到的版本。
- 加锁顺序：`text_lock` 是叶子锁。`proc.finish` 什么锁都没拿时放开；`beginModify` 拿着 `write_lock`（睡眠锁）拿它。

`t_demand` 和 QEMU 测试用例 `tools`（`cp` 覆盖、`rm` 一个正在运行的 `spin` 的副本）检查了这张表（[testing.md](testing.md#回归测试程序)）。

## 改名（`rename`）

`rename(cwd, old, new)` 把 `old` 改名成 `new`，可以换目录。它只改目录项，inode 号不变：打开着它的 fd、以它（或者它下面的目录）为当前目录的进程都照常能用，这一点和 `unlink` 不一样。

1. `resolveParent` 两个路径，在旧目录里找到旧名字的目录项 `e`（没有是 `NotFound`），在新目录里 `scan` 新名字。
2. 新名字已经有了（`t`）：是同一个 inode（`rename a a`，或者 `a` 和 `//a/`）就什么都不做；目录换文件是 `NotDir`，文件换目录是 `IsDir`。
3. `e` 是目录的话，从新目录沿着 `parent` 往上走到根目录，路上遇到 `e` 自己就是 `InvalidName`（`-EINVAL`）：挪进自己下面会让这一串和根目录断开、成了环。
4. 换掉 `t`：和 `unlink` 一样连内容一起删掉（共用的 `remove`），目录不空是 `NotEmpty`。新的目录项就用 `t` 原来的键（名字一样，散列也一样）；没有 `t` 时用 `scan` 给的序号。
5. 删掉旧的目录项，插入新的；换了目录的话，inode 的 `parent` 改成新目录（`..` 和 `check` 都靠它）。

整个 `rename` 由调用方放在一个事务里（`fs.run(Fs.rename, ...)`），所以**换掉已有的文件是原子的**：掉电之后要么还是旧的文件，要么已经是新的，不会两个都没有、也不会两个名字指着同一个 inode。出错的话（比如第 4 步发现目录不空）前面做了的一起作废。掉电测试里也有随机的 `rename`（[单元测试](#单元测试)）。

## 检查整个文件系统（`check`、`scrub`）

`Fs.check` 把整个文件系统核对一遍，只读不改，哪里不对就是 `Corrupt`。单元测试几乎每一步之后都调用它（包括掉电测试的每一次重新挂载），`mkfs` 写完镜像调用一次，运行中由 `scrub` 系统调用调用（用户程序 `scrub`，[user-programs.md](user-programs.md#scrub)）。核对的东西：

- **B 树**：`Volume.check`，每个节点的校验和、块号、事务号、层数，键的顺序和上下界，空闲空间的位图正好是没被树（和等着释放的）用着的块（[btree.md](btree.md#检查check)）。
- **每个数据块**：按内容条目读一遍（`readData`），核对条目里记的 crc32c。
- **条目之间**：按键的顺序扫一遍所有条目（同一个 inode 的条目挨在一起，inode 条目在最前面），一边扫一边核对：
  - 每个条目前面都有它的 inode 条目，inode 号小于 `next_ino`；inode 的种类是文件、目录、设备或符号链接；链接数不是 0，目录的是 1；只有设备的 `major` 不是 0，设备的长度是 0。
  - 符号链接的长度是 1..256，正好有一个内容条目：内联在第 0 页，长度就是 inode 的长度（目标）；没有目标、目标在数据块里都不对。
  - 目录项只出现在目录里：名字合法（`checkName`）、长度和头里的 `name_len` 一样、键里的散列就是名字的散列；指向的 inode 存在、种类和目录项里记的一样；指向目录的话那个目录的 `parent` 就是这个目录；不能指向根目录。
  - 内容条目只出现在文件和符号链接里（目录、设备都没有），偏移是 4096 的倍数、在文件长度之内；内联的只能是第 0 页、长度正好是文件长度（不超过 512），后面不能再有别的内容条目。
  - 根目录是目录、`parent` 是自己；别的目录沿着 `parent` 往上走得到根目录（走的步数超过 inode 号的个数就是有环，比如两个目录互为 `parent`、和根目录断开了）。
  - 除了根目录，每个 inode 正好有 `nlink` 个目录项指着它。不用记下每个 inode 号：目录项指向的 inode 号算一份“指纹”，inode 条目的 inode 号按 `nlink` 次算一份——个数、和、每个号搅乱（splitmix64）之后的和，都是回绕的加法，和顺序无关，乘上次数就是算了那么多次——三样都一样才算对上。一个 inode 多一个名字、另一个少一个，这三样同时对上的概率可以忽略。

返回文件数、目录数、设备文件数、符号链接数、核对过的数据块数，以及 B 树的节点数、条目数、层数。

**缓存**：校验和只在从磁盘读进来的时候核对（`bio.load` 返回 true 时），缓存里的块不再算。`scrub` 要核对的是磁盘上的内容，所以先 `bio.invalidate()`，把没人在用的缓冲区都作废（[disk.md](disk.md#写和放开)），之后读到的每一块都是刚从磁盘读的。

**`scrub` 系统调用**（30 号）：拿着写锁做完，期间别的修改都在等，没有做到一半的事务，当前的树就是已提交的树（每个修改在放开锁之前都写完了）。读者照常在快照上读，它们只会把块读进缓存，不改东西。都对的话把 `abi.ScrubInfo`（上面这些数，加上空闲块数、总块数、事务号）写进用户内存；`Corrupt` 返回 `-EIO`。实测（Debug 构建、带测试程序的镜像，`fs` 用例跑完 `t_fs`、`t_fsmp` 之后）：

```
> run scrub
scrub: ok: 35 files, 3 dirs, 3 devices, 0 symlinks, 987 data blocks verified
scrub: tree of 30 nodes, 1068 items, height 2; 6149 of 7168 blocks free, generation 1114
[proc] pid 494 (scrub) exited with code 0
```

QEMU 测试里在镜像上改坏 `/scrub.dat` 一个数据块的一个字节，再启动：

```
> run scrub
scrub: the file system is damaged: IoError
[proc] pid 3 (scrub) exited with code 1
```

`cat` 这个文件先输出没坏的第 0 页，读到第 1 页时报 `cat: /scrub.dat: IoError`；`rm` 它不读数据块，能删掉，删掉之后 `scrub` 又通过了。

只能发现问题，不能修：坏了的数据块没有副本可以换（btrfs 的 scrub 用镜像副本修复）。

## 生成磁盘镜像（`mkfs.zig`）

```
mkfs <输出文件> <总块数> <文件系统的块数> <文件>...
```

主机上的程序，`build.zig` 构建时运行它（xv6 的 `mkfs/mkfs.c`）：用 `fs.zig`、`ctree.zig`、`bio.zig` 这几个和内核同一份的文件，磁盘是内存里的一块数组（`bio` 的 `Device`）。`Fs.format` 格式化前 7168 块，建 `/bin`，把选中的每个用户程序的 ELF 装成 `/bin/<名字>`，建 `/dev` 和里面的 `console`、`null`、`zero`，跑一遍 `check`，再给后面 1024 块的原始区域填上固定图案（[disk.md](disk.md#qemu-的磁盘)），写出镜像文件。`mkfs.zig` 是一个单独的主机程序的根，和内核、单元测试是不同的编译，所以可以和它们共用 `src/` 下的文件（一个文件在一次编译里只能属于一个模块）。

## 单元测试

都在主机上，用内存当磁盘：

- 目录：创建、`resolve`（`.`、`..`、多余的 `/`、相对路径）；`Exists`、`NotFound`、`NotDir`、`InvalidName`、`NameTooLong`、`IsDir`；最长的名字（255 字节）找得到、列得出来、删得掉；删除非空目录是 `NotEmpty`；删了之后找不到，inode 号不重用。
- `readdir` 列出 62 个名字一个不少、不重复；散列相同的两个名字都找得到，删掉一个另一个还在。
- 文件内容：内联的读写、中间补 0；正好 512 字节还是内联，再长一个字节换成数据块、内容不变；跨页的写；洞读出来是 0、不占块；读到末尾之后返回 0；写到一半“用户内存”出错，整个写作废、文件不变；`FileTooBig`；截断之后再写又是内联；删除文件之后空闲块数和创建之前一样。
- 数据块的校验和：在磁盘上改一个字节，读这一页是 `Corrupt`，别的页照常；重新挂载之后内容还在。
- `check`：数对文件、目录（含根目录）、数据块（有洞的文件只算有块的页）；在磁盘上改一个数据块、改根节点，缓存里还是好的时 `check` 照样通过，`bio.invalidate` 之后就是 `Corrupt`，改回来又通过。条目之间对不上的 16 种坏法（没有名字的 inode、指向不存在的 inode 的目录项、目录的 `parent` 不对、没有 inode 的条目、内容条目超出文件长度、名字比链接数多、名字比链接数少、目录有两个名字、链接数是 0、设备文件有内容、普通文件带设备号、两个目录成环、文件里有目录项、符号链接没有目标、符号链接的长度和目标对不上、符号链接的目标在数据块里）在当前事务里直接改 B 树做出来，每一种都是 `Corrupt`，`abort` 之后又通过。验证过它能抓住错误：去掉“每个 inode 正好一个名字”那一项，没有名字的 inode 就查不出来了；去掉“符号链接要有目标”那一项，测试报 `not detected: symlink_no_target`。
- 硬链接、设备文件：链接到别的目录，两个名字同一个 inode、链接数 2、改了内容两边一样、不复制数据块；目录不能链接、新名字已经有了、旧名字没有、新目录没有、`..`；`rename` 到同一个 inode 的另一个名字什么都不做；删掉一个名字另一个照常；`rename` 换掉有两个名字的文件只少一个名字；删到最后一个名字，数据块都还回来；`mknod` 的设备文件长度 0、设备号对、可以链接和删除；链接数重新挂载之后还在。每一步之后 `check`。
- 符号链接：绝对的、相对的目标（相对于链接所在的目录）；`resolveNoFollow` 停在链接上；中间一段是指向目录的链接、链接后面的 `..`、链接的链、在链接后面建文件；悬空的链接解析是 `NotFound`，`createFollow` 建出目标（目标的目录没有是 `NotFound`）；自己指自己、两个互指是 `SymlinkLoop`，正好跟 10 次可以、11 次不行；空的、超长的目标，正好 256 字节的目标，拼出来超长的路径；`rename`、`link`、`unlink` 对链接自己，目标不动；重新挂载之后还在。每一步之后 `check`。
- `dirPath`：根目录、深处的目录、同一个目录里有别的名字、文件是 `NotDir`、经过符号链接到的目录是它真正的路径、改名之后跟着变、缓冲区正好放得下和差一个字节、删掉了的目录。
- `rename`：同一个目录里改名、换目录（`..` 跟着变）、目录连着下面的东西一起挪；换掉已有的文件（它的块都还回来）、换掉空目录，不空的不行；没有的名字、新目录不存在、目录换文件、文件换目录、挪进自己下面、`/`、`..`、穿过文件的路径、太长的名字都报错，并且事务号不变（什么都没写）；改成自己什么都不做；改成 255 字节的名字。每一步之后 `check`。验证过它能抓住错误：换目录时不改 `parent`，测试失败。
- **掉电**：一串 25 个随机操作（创建、删除、截断、改名成另一个名字（有的话换掉它）、建硬链接、在随机位置写最多 3 页；不含符号链接：建链接和建文件一样是插入 inode 和目录项，只多一个内联的条目），每个操作提交一次，完整跑一遍写盘 124 次；对每一个 N，在第 N 次写之后掉电，重新挂载，要求：挂载成功、`check` 通过、所有名字的内容正好是某一个操作做完之后的样子、不早于最后一个做完了的操作，指着同一个文件的名字是同一个 inode、链接数就是名字的个数。参照模型记的是“名字 → 文件”，几个名字可以指着同一个文件。然后接着创建、写一个新文件，再核对一遍旧文件：挂载时漏算了哪个块（当成了空闲块），这里就会被改写。

  验证过它能抓住错误：`link` 不加链接数，掉电测试失败（随机种子是挑过的：原来的种子 25 步里一次链接都没做成，测不到它）；改数据页时直接在旧块上改（不写时复制），掉电测试失败；挂载时不把数据块算作用着的（`dataRefs` 总返回 null），掉电测试失败（这一种是在加了“挂载之后接着写”之后才抓到的）。

## QEMU 里的测试

`tools/qemu_test.py` 的 `fs` 用例（[testing.md](testing.md)）：shell 里的 `ls`、`cat`、`mkdir`、`rm`、`mv`、`ln`、`ln -s`、`cd`、`<`、`>`、`>>`，`/dev` 下的设备文件，符号链接（相对的、指向目录的、悬空的、有环的）；回归测试 `t_fs` 测系统调用的边界情况和并发，`t_fsmp` 测读者和修改的一方同时进行（读到的总是完整的某个版本）；关机之后在同一个镜像上再启动，上一次写的文件和符号链接还在；然后边写边把 QEMU 杀掉（掉电），再启动一次，`t_fs verify` 检查每个操作要么做完了、要么没做，`scrub` 通过；最后在镜像里改坏一个数据块，第四次启动，`scrub` 发现它（见上面的[检查](#检查整个文件系统checkscrub)）。

这个用例在开发时抓到过一个 bug：目录项的头里名字长度是 `u8`，`@sizeOf(DirHeader) + head.name_len` 按 `u8` 算，名字长于 239 字节时溢出（Debug、safe 模式下 panic；fast、small 模式下不检查溢出，是未定义行为）。单元测试原来只建了 255 字节的名字，没有再找它、列它，碰不到这段代码，现在补上了。

## 限制和以后可以做的

- 只能截成 0；没有权限、时间戳。
- 一页一个数据块，没有 btrfs 那种连续多块的 extent；也没有压缩。
- 每个操作一个事务，每次都写超级块。
- 删除打开着的文件之后，打开它的人再读写会出错（`ENOENT`）。正在运行的程序文件干脆不能删（`ETXTBSY`），见[正在运行的程序文件](#正在运行的程序文件)。
- 修改之间排队：改不同文件的进程也要一个一个来（读不排队）。
