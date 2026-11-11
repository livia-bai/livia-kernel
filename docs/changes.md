# 修改记录

每次改了内核（`src/`、`user/`、`build.zig`、链接脚本），在最上面加几行：新增了什么功能，修了什么 bug。最新的在前面。

## 2026-11-11 内核的计数器（kstat）；panic 时打印调用栈；进程内核栈调到 24 KiB

- 新增：内核的计数器（`src/kstat.zig`）：系统调用、上下文切换、时钟中断、核间中断、`wakeup`（调用、真扫了进程表、叫醒的进程）、自旋锁要等的次数、三种缺页、TLB 全量刷新、缓冲区缓存的命中和没命中、磁盘的读写和 flush、文件系统的提交和作废。每个 hart 一份，名字是 `abi.Counters` 的字段名。系统调用 `kstat`（39）返回它们和栈的高水位，用户程序 `kstat` 打印出来。
- 新增：内核 panic 时打印调用栈（`backtrace: 0x... 0x...`）：内核编译时保留帧指针，`kstack.backtrace` 沿帧指针链往上走，帧指针不在内核栈里就停。`qemu_test.py` 看到 panic 时用 llvm-symbolizer 换成源码位置。
- 改动：进程内核栈 16 KiB → 24 KiB（Debug 模式下最深用到 14 KiB 多）。
- 新增：QEMU 测试用例 `kstat`。

## 2026-11-11 内核自己量栈用到过多深；测试脚本的常量从构建导出

- 新增：内核栈的高水位。启动时 `kstack.paintAll` 把所有的栈（进程内核栈、启动栈、陷阱栈）都写上金丝雀的图案，关机时 `kstack.deepest` 从栈底找第一个被改过的字，打印 `[stack] deepest use: process P of 16384, boot B of 32768, trap T of 16384 bytes`。`qemu_test.py` 要求每种栈至少留 2048 字节。实测 Debug 模式下进程内核栈最深 13912 字节，比文档里以前记的 11624 字节深。
- 新增：`zig build` 生成 `zig-out/config.json`（`build.zig` 的 `Config`）：QEMU 的命令行、`max_procs`、`max_args`、磁盘镜像的布局、用户地址空间和栈下面的保护页。`qemu_test.py` 读它，不再手抄这些数。`user_base`、`user_end`、`user_stack_max` 从 `vm.zig` 挪到 `abi.zig`。

## 2026-11-11 错误码按名字查表；read 不再为用不到的缓冲区分配页；wakeup 没人在等时不扫进程表

- 改动：系统调用把内核的错误换成错误码统一走 `syscall.errnos`（错误名 → 错误码的表）：`errno` 在编译期逐个查表，表里没有的错误编译不过，不再有 `else => EIO` 兜底。`fsys.errno` 去掉了，各个系统调用里手写的 `switch` 换成 `failWith(err)`。原始区域的块号超出范围在内核里改叫 `InvalidArgument`（错误码还是 `-EINVAL`）。
- 改动：`read` 先按文件的种类把长度截到这一次最多能读到的量（`file.readLimit`：串口 255 字节、管道 2048 字节、`/dev/null` 0），再检查、分配目标范围。读串口、管道时给一个很大的缓冲区，不再把整个缓冲区的页都提前分配好。
- 改动：`proc.wakeup` 先看按通道地址散列的睡眠者计数（`proc.sleepers`，32 格），是 0 就直接返回，不再每次扫 64 个槽位、拿 64 把进程锁。
- 改动：新增 `page.allocUninit`（不清零），写时复制和复制根页表用它，省掉一次马上就被覆盖的清零。

## 2026-11-11 提交前后 flush 磁盘；什么都没改的事务作废时不重走树

- 修复：设备有写缓存时，文件系统的掉电安全没有保证：写完的块不一定按顺序落盘，超级块可能先于它指向的节点落盘。virtio 驱动协商 `VIRTIO_BLK_F_FLUSH`，新增 flush 请求（`virtio_disk.flush`）；`bio.Device` 多了 `flush`，`bio.flush()` 等之前写的块都落盘；`ctree.Volume.commit`（和 `format`）在写超级块前后各 flush 一次。启动日志的磁盘那一行末尾多了 `, flush`（设备不支持时是 `, write-through`）。
- 改动：`Volume.abort` 在当前事务什么都没改过（`dirty` 为 false）时直接返回，不再重走整棵树重算空闲块。`mkdir` 已有的目录、`rm` 不存在的文件这类在查找阶段就失败的操作不再读遍所有节点。
- 新增：ctree 的单元测试多了写缓存模式的掉电测试：上次 flush 之后的写在掉电时随机落盘或丢掉、顺序打乱。

## 2026-10-31 按需分页；内核栈的保护页；写脚本用的程序

- 新增：按需分页。用户地址空间（`vm.Space`）记着程序的各个段、堆、栈从哪到哪，页表里只有访问过的页：`exec` 只读 ELF 的文件头和程序头，段里的页第一次被访问时才分配、从程序文件读进来（init 从内核里嵌着的字节读）；`.bss`、堆、栈的页用到才分配清零的页。U 模式的读、写、取指缺页都交给 `vm.fault`（写时复制也在这里）；内核替用户程序读写用户内存（`copyFromUser` 这些）时也按需分配。没内存时进程被结束（`out of memory (demand paging)`），读不出程序文件是 `cannot read the program file (demand paging)`。
- 新增：正在运行的程序文件不能改、不能删（新错误码 `ETXTBSY`，26）：`write`、截断、删掉最后一个名字、被 `rename` 换掉都是 `TextBusy`；正在被改的文件不能 `exec`。`exec` 占住程序文件（`fsys.holdText`），进程结束时放开。
- 改动：`sbrk` 变大时只挪 `brk`，不分配页；比空闲内存大的堆也能长成功，比整个物理内存还大才是 `ENOMEM`。`vm.growUser` 去掉了。
- 改动：用户栈从固定 16 KiB 改成按需长，最多 1 MiB（`0x7ff0_0000..0x8000_0000`），下面的保护页挪到 `0x7feff000`。`exec` 时入口地址不在可执行的段里是 `ENOEXEC`。
- 新增：内核栈的保护页（`src/kstack.zig`）。进程内核栈、启动栈下面各一页不映射，栈溢出时缺页、panic，报出是哪块栈（`kernel stack overflow: pid N (name) hit its guard page at ...`），不再悄悄踩坏相邻进程的 `TrapFrame`。每个 hart 新增一块 16 KiB 的陷阱栈：S 模式的陷阱（调度器开中断时的中断、内核的异常）都在它上面处理，`sscratch` 在内核里改成这个 hart 的陷阱栈顶（原来是 0），`TrapFrame` 的填充字段换成 `kernel_sscratch`。启动时自检一次（`[ok] stack overflow check: ...`）。
- 新增：写脚本用的用户程序 `test`、`expr`、`seq`、`sleep`、`head`、`tail`、`grep`、`cp`、`touch`、`tee`、`xargs`；`sys.zig` 新增按行读的 `LineReader`。`echo` 整行一次写出，不再和别的进程的输出交错在一行中间。
- 新增：回归测试 `t_demand`，QEMU 测试用例 `demand`、`tools`；`t_sbrk`、`t_cow` 按按需分配改了；单元测试加上按需分页、保护页。`qemu_test.py` 比较前后的空闲页数时，两次都在新启动的 shell 里看（按需分页之后一直运行的 shell 会越用越大）。

## 2026-10-31 符号链接；shell 的命令语言、行编辑和脚本

- 新增：符号链接。inode 种类 `symlink`，目标（最长 256 字节）内联在第 0 页的内容条目里。解析路径时遇到它就换成“目标 + 剩下的路径”接着走（相对的目标从链接所在的目录开始，不递归，最多 10 次，再多是新错误码 `ELOOP`）；`unlink`、`rename`、`link` 对的是链接自己；`open` 带 `O_CREATE` 穿过悬空的链接时建出目标。`check`/`scrub` 核对每个符号链接正好有一个内联的目标，统计里多了符号链接数。磁盘格式换成 `LBFS0003`。
- 新增：系统调用 `symlink`（35）、`readlink`（36）、`getcwd`（37，沿着 `parent` 往上找名字；新错误码 `ERANGE`）、`lstat`（38，不跟着最后一段的链接走）。`exec`、`chdir` 跟着链接走。
- 新增：`ln -s`；`ls` 用 `lstat`，显示 `link ... 名字 -> 目标`，指向目录的链接列出目录里的东西。
- 新增：shell 的命令语言：单引号、双引号、反斜杠；`;`、`&&`、`||`、`#` 注释；变量（`NAME=值`、`$NAME`、`${NAME}`、`set`、`unset`）和 `$?`、`$$`、`$!`、`$#`、`$0`..`$9`；`*`、`?` 匹配文件名；运算符不用空格隔开（`echo a>f`）。整行先检查语法，写错了一个命令都不执行。
- 新增：shell 的行编辑：上下方向键翻历史（16 条，`history`）、Ctrl-U、Tab 补全命令名和路径。
- 新增：shell 的内置命令 `pwd`、`cd -`、`jobs`、`wait [PID]`、`time`、`true`、`false`、`exit [N]`，`kill` 可以给几个 pid；内置命令可以重定向、放进管道。`sh 文件 参数`、`sh -c 命令`、标准输入不是串口时从标准输入读命令（脚本）。
- 改动：shell 的出错信息前缀从 `run:` 换成 `sh:`；管道里空的一段是 `sh: empty command`。
- 修复：`t_fs` 的 `removeTree` 用 `lstat`，不会跟着指向 `/` 的链接把整个文件系统删掉。`qemu_test.py` 的 `t_fork fill` 只等那一行的开头就检查整行，偶尔读到半行（Debug、4 核碰到过一次）。

## 2026-10-30 硬链接、设备文件；调大各种上限

- 新增：硬链接。系统调用 `link`（33），用户程序 `ln`。`fs.Inode` 多了链接数 `nlink`，`unlink`、`rename` 换掉文件时只减链接数，删到最后一个名字才删内容；目录不能链接（`EPERM`）。`fstat` 返回链接数，`ls` 多了一列链接数。
- 新增：设备文件。系统调用 `mknod`（34），inode 种类 `device` 和设备号 `major`（`abi.Major`：1 串口、2 null、3 zero）；打开它得到 `File` 的种类 `.device`，读写按设备号交给设备；不认识的设备号打开时是新错误码 `ENXIO`。`mkfs` 建 `/dev/console`、`/dev/null`、`/dev/zero`。
- 改动：磁盘格式换成 `LBFS0002`（`Inode` 用原来的填充字节放链接数和设备号），旧镜像挂不上，重新构建就行。`check`/`scrub` 核对每个 inode 正好有 `nlink` 个名字、只有目录核对 `parent`，统计里多了设备文件数。新错误码 `EMLINK`。
- 改动：进程表 16 → 64，每个进程的 fd 16 → 32，系统的文件表 32 → 128，缓冲区缓存 32 → 64 块，`exec` 的参数 16 个 / 1024 字节 → 32 个 / 2048 字节，shell 的一行 128 → 512 字节、管道最多 4 → 8 个程序。
- 新增：`t_fork fill`（在后台填满进程表，QEMU 测试用它代替 62 个后台 `spin`）；`t_fs` 测硬链接和设备文件；文件系统的单元测试、掉电测试加上硬链接。

## 2026-10-30 细粒度的锁

- 改动：页分配器每个 hart 一条空闲链表、一把锁（照 xv6 lock lab 的 kalloc），自己的空了从别的 hart 那里一次拿 32 页；每一页的引用数改成原子操作，不拿锁。`page.free_pages` 变量换成 `page.freePages()`。
- 改动：缓冲区缓存按块号分进 13 个桶，每个桶一把锁（照 xv6 lock lab 的 bcache）；LRU 改用时间戳，换块时拿 `evict_lock` 从所有桶里找最久没用的。原来的 `bio.lock` 去掉了。
- 改动：文件表没有整张表的锁了，每个 `File` 一把自旋锁保护引用数；读写位置 `off` 由每个 `File` 的睡眠锁 `pos_lock` 保护（原来靠文件系统的锁）。
- 改动：文件系统的读（`read`、`fstat`、`readdir`、`lseek`、`chdir`、只打开已有文件的 `open`、`exec` 加载程序）不再拿锁，在最近一次提交的 B 树的快照上读，和别的读、和修改同时进行；修改（`write`、`mkdir`、`unlink`、`rename`、建文件或截断的 `open`、`scrub`）拿 `fsys.write_lock`，之间仍然排队。原来的 `fsys.lock`、`fsys.get` 换成 `fsys.reader`、`fsys.writer`。
- 新增：`ctree` 的快照（`beginRead`、`endRead`、`lookupAt`、`nextAt`）。提交时还有读者在旧树上读的话，旧树释放的块先进 `limbo`，读者都读完才再分配；空闲块不够时修改的一方睡着等读者读完。
- 新增：回归测试 `t_fsmp`（读者和写者同时进行，读到的总是完整的某个版本）；`page`、`ctree` 的单元测试。

## 2026-10-30 lseek、O_APPEND、rename、shell 直接运行程序

- 新增：系统调用 `lseek`（32，`seek_set`/`seek_cur`/`seek_end`，可以挪到末尾之后；串口、管道是新错误码 `ESPIPE`；目录只能挪回 0 重新列）和 `open` 的 `open_append`（0x800：查文件长度和写在同一次拿锁里，几个进程各自打开同一个文件追加也不会互相覆盖）。
- 新增：系统调用 `rename`（31）：改名、换目录，新名字已经有了就换掉它（文件换文件、目录换空目录），一个事务做完，掉电也是原子的；inode 号不变，打开着的 fd、当前目录照常。目录不能挪进自己下面（`EINVAL`）。掉电测试的随机操作里加上了 `rename`。
- 新增：用户程序 `mv`（`mv 旧 新`、`mv 路径... 目录`）。
- 改动：shell 不写 `run` 也能运行程序（`hello`、`echo a | wc`、`spin &`），内置命令优先；新增 `>>` 追加重定向。

## 2026-10-30 scrub：检查整个文件系统

- 新增：系统调用 `scrub`（30）和用户程序 `scrub`：作废缓冲区缓存，再把整个文件系统核对一遍（B 树、每个数据块的校验和都重新从磁盘读），只读不改；都对就返回统计（`abi.ScrubInfo`），坏了返回 `-EIO`。
- 改动：`Fs.check` 除了 B 树，还核对条目之间的关系：每个条目都有 inode，目录项指向的 inode 存在、种类和 `parent` 对得上，内容条目在文件长度之内、内联的只在第 0 页，所有目录连得到根目录，每个 inode（除了根目录）正好一个名字；并且读一遍每个数据块核对校验和。返回文件数、目录数、数据块数。
- 新增：`bio.invalidate`，作废没人在用的缓冲区。
- 新增：`t_fs scrubfile`；QEMU 测试用例 `fs` 在镜像里改坏一个数据块，再启动一次，`scrub` 要发现它。

## 2026-10-30 内核栈底的金丝雀

- 新增：`src/canary.zig`。每块进程内核栈和每个 hart 的启动栈最底下 256 字节写着固定的图案：进程的在分配槽位时写，启动栈在 `kmain`、`kmainSecondary` 一开始写。切回调度器、回到 U 模式之前检查当前进程的，调度器每一轮检查自己 hart 的启动栈，图案被改了就 panic（`kernel stack overflow: pid N (name)`、`kernel stack overflow: boot stack of hart N`）。以前内核栈溢出不会被发现，会悄悄改坏相邻进程的 `TrapFrame`。
- 改动：`proc.scheduler` 多了一个参数，是这个 hart 的启动栈。

## 2026-10-29 程序从文件系统加载

- 改动：`exec` 从文件系统加载程序：名字里没有 `/` 的在 `/bin` 里找，有的按路径找（相对路径从当前目录开始），加载期间拿着 `fsys.lock`，ELF 的内容直接读进新的用户页。内核里只嵌着 init（第一个进程要在挂载之前加载），内核镜像小了约 1.1 MiB。ELF 加载器改成通过 `Source`（嵌着的字节或者文件系统里的文件）读。
- 改动：`exec` 的路径最长 256 字节，新增错误 `ENAMETOOLONG`、`ENOTDIR`、`EIO`、`ENODEV`；目录不能运行（`ENOEXEC`）。进程名改成存在进程里的 16 字节（程序文件名），不再指向内核里的程序表。
- 去掉：`listprog` 系统调用（15 号，现在是 `ENOSYS`）。shell 的 `run` 用 `readdir` 列 `/bin`、按名字排序，用 `open`、`fstat` 检查程序在不在；可以运行别的路径上的程序（`run /h`）。

## 2026-10-29 文件系统接进内核：mkfs、系统调用、shell 的 cd 和重定向

- 新增：`src/mkfs.zig`，主机上生成磁盘镜像的程序（和内核共用 `fs.zig`、`ctree.zig`、`bio.zig`）。`build.zig` 构建时运行它：镜像改成 32 MiB（8192 块），前 7168 块是文件系统，用户程序装在 `/bin`；后 1024 块是原始区域，填原来的固定图案。
- 新增：`src/fsys.zig`，内核这一侧的文件系统：第一个进程在 `forkretC` 里挂载（启动日志多了 `[ok] file system: N of 7168 blocks free, generation G`，没有文件系统时打印警告照常启动），一把睡眠锁 `fsys.lock` 管整个文件系统，文件系统的错误换成错误码。
- 新增：系统调用 `open`（24，`O_CREATE`、`O_TRUNC`）、`mkdir`（25）、`unlink`（26）、`chdir`（27）、`fstat`（28）、`readdir`（29），错误码 `EIO`、`EEXIST`、`ENOTDIR`、`EISDIR`、`EFBIG`、`ENOSPC`、`ENAMETOOLONG`、`ENOTEMPTY`；`abi.Stat`、`abi.Dirent`、`abi.FileKind`。`read`、`write` 能读写文件（一次 `write` 一个事务，要么全写要么不写），`File` 多了 `.inode` 和读写位置；进程多了当前目录（`fork` 继承）。
- 改动：`blockcount`、`readblock`、`writeblock` 只能碰原始区域（块号从文件系统之后算），不会写坏文件系统。
- 新增：shell 的 `cd`、`run ... > 文件`、`run ... < 文件`（管道里的哪一段都行）；用户程序 `ls`、`mkdir`、`rm`，`cat` 能读文件。
- 修复：目录项的名字长度按 `u8` 和头的大小相加，名字长于 239 字节时溢出（Debug/safe 下 panic）。
- 修复：内核栈溢出。`ctree` 的位图用了 `std.bit_set`，它的 `isSet`、`count` 按值接收整个 8 KiB 的位图，加上 `x.* = y.*` 复制 4 KiB 的块，文件系统的调用在 Debug 模式下用到约 54 KiB 内核栈；改成自己的 `Bitmap` 和 `@memcpy` 之后最深不到 10 KiB。
- 新增：回归测试 `t_fs`（系统调用的边界情况、共用读写位置、坏指针、并发写），QEMU 测试用例 `fs`：shell 里的文件操作，关机后重新启动文件还在，边写边杀掉 QEMU 再启动，每个操作要么做完了要么没做。

## 2026-10-29 文件系统（还没接进内核）

- 新增：`src/fs.zig`，建在写时复制 B 树上的文件系统，照 btrfs 的条目设计简化：inode 条目（种类、长度、父目录）、按名字散列排序的目录项（散列相同的名字用序号分开）、每页一个的内容条目。不超过 512 字节的文件内联在条目里，更大的每页一个数据块（写时复制，条目里记着 crc32c，读盘时校验），没有条目的页是洞。创建、删除（目录要空）、路径解析（`.`、`..`）、`readdir`、读、写、截断成 0。每个操作一个事务（`Fs.run`：成功提交、出错作废）。
- 新增：`ctree` 给文件系统的接口：`data_refs`（挂载、检查时把条目指向的数据块算作用着的）、`allocData`/`freeData`、`lastKey`。
- 新增：`zig build test -Dtest-filter=...` 只跑名字里含某一段的单元测试。
- 新增：文件系统的单元测试，包括在每一次写盘之后掉电，重新挂载后都是某一个操作做完的样子。

## 2026-10-29 写时复制 B 树和事务

- 新增：`src/btree.zig`，B 树的节点格式（照 btrfs：键是 `(objectid, type, offset)`，叶子的条目在前、数据从块末尾往前放，内部节点的 `ptrs[0].key` 当作负无穷）和节点内的插入、删除、分裂；节点带 crc32c、自己的块号和事务号。
- 新增：`src/ctree.zig`，写时复制 B 树和事务：每次修改从根到叶子复制整条路径（同一个事务里不再复制），从下往上分裂，删空的节点摘掉、根只剩一个子节点时变矮；提交只写一个超级块（两个槽位轮流写）；空闲空间挂载时走树算出来（first fit 分配），已提交的树释放的块要等提交之后才能再用；操作前按最坏情况预留块，出错时作废整个事务；`check` 检查整棵树和位图。还没有接进内核。
- 新增：`bio.load`，返回这次是不是真的读了盘。
- 新增：单元测试，包括在每一次写之后掉电（完全没写、只写进 16 字节、只写进一半）共 681 次，重新挂载后都是某个已提交的状态。

## 2026-10-29 virtio 磁盘、睡眠锁、缓冲区缓存

- 新增：virtio 块设备驱动（`src/virtio_disk.zig`，照 xv6 的 `virtio_disk.c`）。现代（version 2）的 virtio-mmio 接口，启动时在 8 个槽位里找块设备，只协商 `VIRTIO_F_VERSION_1`；一个 16 项的队列，每个请求是三个描述符（请求头、4 KiB 数据、状态字节）；发出请求的进程睡着等，磁盘中断（PLIC 1 号源，发给所有 hart）叫醒它，描述符不够时也睡着等。启动日志多了 `[ok] virtio disk: 1024 blocks of 4 KiB (4 MiB), irq 1`，中断那一行末尾多了 `, disk`；没有磁盘或者只有旧版接口时打印警告，照常启动。`plic.init` 多了磁盘中断号的参数；`vm.init` 映射 virtio-mmio 区域。
- 新增：睡眠锁（`src/sleeplock.zig`，照 xv6 的 `sleeplock.c`）：等锁时睡下，拿着可以睡觉。自己重复拿会 panic；进程记着拿着几把（`Process.sleeplocks`），回到 U 模式之前检查是 0（`proc.assertNoLocksHeld`）。
- 新增：缓冲区缓存（`src/bio.zig`，照 xv6 的 `bio.c`）：32 个 4 KiB 的缓冲区，LRU，每块一把睡眠锁，`read`/`get`/`write`/`release`；磁盘通过 `Device` 交进来，单元测试用一块内存。缓冲区都在用时睡着等（xv6 是 panic）。
- 新增：系统调用 `blockcount`（21）、`readblock`（22）、`writeblock`（23），错误码 `ENODEV`；`abi.block_size`；shell 的 `disk` 命令。
- 新增：`build.zig` 生成 4 MiB 的磁盘镜像（固定图案）装到 `zig-out/disk.img`，`zig build run` 以 `snapshot=on` 接上它。
- 新增：回归测试 `t_disk`、QEMU 测试用例 `disk`（QEMU 退出后检查镜像文件的每一块），`qemu_test.py` 每次启动接一份新拷的磁盘；缓冲区缓存、睡眠锁的单元测试。

## 2026-10-29 核间中断

- 新增：核间中断（`src/ipi.zig`，经 SBI IPI 扩展的 `send_ipi`，新增 `sbi.sendIpi`；收到的是 S 模式软件中断，每个 hart 在 `ipi.initHart` 里打开 `sie.SSIE`）。调度器扫描前把自己登记为空闲；`wakeup`、`kill` 叫醒睡着的进程、`fork` 建好子进程时，给一个空闲的 hart 发核间中断，它马上来运行，不用等自己的下一个时钟中断。`kill`、Ctrl-C 杀的进程正在别的 hart 上运行时（新增进程字段 `hart`），给那个 hart 发核间中断，它马上进内核结束这个进程。多核时杀掉别的 hart 上的进程从 4～8 ms 降到约 0.3 ms，叫醒的进程开始运行从 1～7.6 ms 降到约 0.2 ms。
- 改动：启动日志改成 `[ok] interrupt sources enabled: timer at 100 Hz, keyboard via UART + PLIC, IPIs`。
- 新增：回归测试 `t_ipi`（用 `rdtime` 量两个延迟）、QEMU 测试用例 `ipi`；`wakeIdle` 的单元测试。

## 2026-10-29 写时复制的 fork

- 新增：`fork` 写时复制。`vm.cloneUserSpace` 只给子进程建页表，用户页和父进程共用；可写的页两边都改成只读、在页表项的 RSW 位上标 `cow`（`Pte.cow`）。谁先写哪一页，谁在 `store_page_fault` 里由新增的 `vm.breakCow` 复制一份，只剩自己在用时直接改回可写、不复制。内核往用户内存写（`copyToUser`、检查可写的 `checkUser`）遇到 `cow` 页也先复制。带着 64 页堆的进程 `fork` 一次，从多用 78 页降到多用 5 页；`fork` 之后马上 `exec` 的话一页都不复制。
- 新增：页分配器给每一页记引用数（数组放在管理范围开头，128 MiB 内存占 8 页）。新增 `page.share`、`page.isExclusive`；`page.free` 改成放掉一个引用，减到 0 才回到空闲链表；重复释放、共用一个空闲页现在会 panic。启动时的空闲页数相应少了 8 页左右。
- 新增：写 `cow` 页时内存不够，进程被结束（`killed: out of memory (copy-on-write) at ...`）；内核往 `cow` 页里写时内存不够，系统调用返回 `-EFAULT`（和 Linux 一样）。
- 新增：`riscv.sfenceVmaPage` 只刷一页的 TLB。
- 新增：回归测试 `t_cow`、QEMU 测试用例 `cow`（包括把内存用完之后写共用的页）；页分配器引用数、写时复制的单元测试。

## 2026-10-29 多核；照 xv6 给进程加锁

- 新增：多核。OpenSBI 只把一个 hart 交给内核，`kmain` 做完全局的初始化后，从设备树 `/cpus` 里找出其他 hart（新增 `dtb.Info.harts`），用 SBI HSM 扩展的 `hart_start`（新增 `sbi.hartStart`）逐个启动，等每个报到了再启动下一个；它们从 `secondaryEntry` → `kmainSecondary` 做自己那份初始化（`trap.init`、`vm.initHart`、`plic.initHart`、`timer.initHart`），然后各自运行调度器。启动日志多了一行 `[ok] N harts running, booted on hart M`。最多用 8 个 hart（`hart.max`）。`zig build run` 默认 `-smp 4`。
- 新增：`src/hart.zig`。内核用 `tp` 存当前 hart 的编号（`hart.id()`）；`TrapFrame` 多了 `kernel_tp`（和补齐用的一项，共 288 字节），从 U 模式陷入时换回内核的 `tp`，回到 U 模式时再换成用户的。每个 hart 有自己的启动栈（`boot_stacks`，32 KiB，去掉了链接脚本里的 `__stack_top`）、`proc.cpus[i]`（当前进程、调度器上下文）、`spinlock` 的计数、定时器的预约时刻、PLIC 上下文。串口中断发给所有 hart。
- 新增：照 xv6 的进程锁。每个进程一把锁，保护状态等字段，调度器拿着它切到进程、进程拿着它切回；`wait_lock` 保护父子关系；`timer.lock`（tickslock）保护 `ticks`，只有启动 hart 给它加 1。`proc.sleep` 的锁参数不能再为空。`fork`、`userinit` 拿着新进程的锁一次填好所有字段（`fill`，不覆盖锁）；`wait` 整个移进 `proc.wait`；`next_pid`、`foreground` 改成原子变量；新增 `proc.current()`、`yieldTimeslice`、`setForeground`、`parentPid`、`info`。定下了加锁顺序。
- 新增：串口输出锁。每次 `print`、`write` 和一次 `write` 系统调用整段输出，不会和别的 hart 的输出交错。panic 的 hart 不拿锁，别的 hart 在输出、等锁、调度时看到有 hart 在 panic 就停下。panic 信息多了 hart 编号。
- 改动：进程表从 8 项增加到 16 项（`abi.max_procs`）。
- 新增：回归测试 `t_smp`（几个进程同时 fork/exit/wait、写同一个管道、sbrk、留下孤儿，杀掉在别的 hart 上死循环的进程），QEMU 测试用例 `smp`（还检查两个死循环的进程真的在并行）。`qemu_test.py` 默认单核和 4 核各跑一遍，新增 `--smp`。单元测试：设备树的 cpu 节点、Ctrl-C 找前台进程的子孙、`setfg`、`fill`、锁都放开了。

## 2026-10-29 命令行参数、文件描述符和管道、sbrk；为多核加锁

- 新增：命令行参数。`exec` 多了 `argv`、`argc` 两个参数（最多 16 个、共 1024 字节，超出返回 `-E2BIG`），内核把它们复制到新程序的栈顶，`_start` 从 `a0`、`a1` 拿到，用户程序用 `sys.argv`、`sys.arg(i)` 读。shell 的 `run NAME ARGS...` 按空格拆参数。
- 新增：文件描述符。每个进程有 16 项的 fd 表，指向全局文件表里的 `File`（串口或管道的一端，带引用计数）；init 打开串口作为 0、1、2 号 fd，`fork` 复制 fd 表，`exec` 保留，进程结束时全部关掉。`read`、`write` 的第一个参数改成 fd；新增系统调用 `close`、`dup`、`pipe`，错误码 `EBADF`、`EMFILE`、`ENFILE`、`EPIPE`。
- 新增：管道（`src/pipe.zig`，2048 字节的环形缓冲区，一页一个）。读空管道、写满管道时睡下等对方；写端都关了读到结尾，读端都关了写返回 `-EPIPE`。在串口上按 Ctrl-D 时 `read` 返回 0。
- 新增：shell 的管道 `run A | B | ...`（最多 4 个程序），照 xv6 由一个 fork 出来的“组长”建管道、启动各个程序。Ctrl-C 改成杀前台进程和它的所有子孙，所以一次结束整条管道。新增用户程序 `echo`、`cat`、`wc`。
- 新增：系统调用 `sbrk`。堆从程序最后一个段之后的页边界开始，按页映射，缩小时释放整页和空出来的页表；不能缩到起点下面、不能长进栈。新增 `vm.growUser`、`vm.shrinkUser`。
- 新增：自旋锁 `src/spinlock.zig`，加在页分配器、文件表、管道、串口输入缓冲区上；`proc.sleep` 改成 `sleep(chan, lock)`，在睡下之后放开锁、醒来再拿上。`sched` 和回到 U 模式之前检查没有拿着锁。
- 改动：`kmain` 不再打开 `sstatus.SIE`，内核代码从头到尾关着中断运行，只有调度器每一轮开头开一下（拿锁要求中断关着，`userinit` 里就要分配页）。启动日志改成 `[ok] interrupt sources enabled: ...`。`uart.takeCtrlC` 去掉了，`uart.onInterrupt` 直接返回有没有按过 Ctrl-C。
- 修复：shell `fork` 出前台程序后才 `setfg`，子进程先运行的话，程序刚开始运行时按的 Ctrl-C 会被忽略（QEMU 测试在 Debug 模式下碰到过）。现在子进程在 `exec` 之前自己先 `setfg`。
- 新增：回归测试 `t_args`、`t_pipe`、`t_sbrk`，QEMU 测试用例 `args`、`pipe`、`sbrk`；管道、文件表、自旋锁、命令行参数布局、`growUser`/`shrinkUser` 的单元测试。

## 2026-10-27 fork、exec、wait；init 和 shell 搬到用户态

- 新增：系统调用 `read`（阻塞读键盘，不回显）、`fork`、`exec`、`wait`、`kill`、`getppid`、`setfg`、`procinfo`、`meminfo`、`listprog`、`shutdown`，照 xv6 实现。进程有了父进程；`fork` 逐页复制地址空间（`vm.cloneUserSpace`）和 `TrapFrame`；`exec` 加载成功后才换掉旧的地址空间；`exit` 之后进程变成 zombie，由父进程 `wait` 取走结束状态（退出码，或者被杀时的 `0x100`）并回收，父进程先结束的子进程交给 init。新增 `vm.copyToUser`、`vm.checkUser`，写用户内存时要求页可写。
- 改动：内核启动时只创建第一个进程 init（`user/init.zig`，pid 1），它启动 shell 并回收孤儿，shell 结束了就重新启动一个；init 结束内核就 panic。shell 变成用户程序 `user/sh.zig`（pid 2），通过系统调用实现原来的命令，删掉了内核里的 `src/shell.zig` 和内核线程。`ps` 多了父进程一列；`uptime` 只显示秒；`kill` 的原因显示为 `kill()`。
- 删除：shell 的 `ebreak`、`crash` 命令和 QEMU 测试的 `panic` 用例（用户态触发不了内核异常）。
- 修复：用户程序的 `print` 每一段格式化输出都是一次 `write`，时钟中断落在两次 `write` 之间时，别的进程的输出会插进一行的中间（后台进程的第一行插进了 shell 的 `started in the background`）。现在 `print` 先攒进 256 字节的缓冲区，最后一次 `write` 写出。
- 新增：回归测试 `t_fork`（fork、exec、wait、kill 等的边界情况）、`t_read`，QEMU 测试用例 `fork`；`wait`、`reparent`、`copyToUser`、`checkUser`、`cloneUserSpace` 的单元测试。

## 2026-10-27 照 xv6 改写进程调度

- 改动：调度器 `proc.scheduler()` 从内核主循环里独立出来，照 xv6 的 `scheduler()`：在启动栈上永远循环，每一轮开一下中断再关上，依次扫描进程表、运行每个 `runnable` 的进程，一个都没有就 `wfi`。进程只通过 `proc.sched()` 切回调度器（`yield`、`sleep`、`exit`）。去掉了 `schedule`、`pickNext` 和 `last_slot`。
- 新增：`proc.sleep(chan)` / `proc.wakeup(chan)`。`sleep` 系统调用改成 xv6 的 `sys_sleep` 的写法：睡在 `&timer.ticks` 上，每个时钟中断叫醒一次，自己数够 tick 再返回；去掉了 `wake_tick`。
- 改动：shell 变成内核线程（pid 1，由新增的 `proc.spawnKernel` 创建），全程关着中断运行。没有输入时睡在 `uart.rx_chan` 上，串口中断叫醒它；`run` 前台程序时睡着等它结束。`ps` 里会列出它；它占一个槽位，所以同时最多 7 个用户进程，用户进程的 pid 从 2 开始。
- 改动：`kill` 照 xv6 只做标记（`killed`）并叫醒在睡的进程，被杀的进程在回到 U 模式之前（`handleTrap` 末尾、新进程第一次运行时经过的 `forkret`）由 `checkKilled` 结束自己。Ctrl-C 在串口中断里直接处理。shell 的 `kill` 命令等目标进程真的结束才回到提示符；`kill 1` 打印 `kill: pid 1 is a kernel thread`。
- 改动：只有时钟中断让 U 模式的进程让出 CPU，串口中断不再让出。状态改名为 xv6 的 `runnable`、`zombie`（原来的 `ready`、`exited`）。
- 新增：`wakeup`、`kill` 的单元测试；QEMU 测试 `sched` 用例加了对睡在 `sleep` 里的前台进程按 Ctrl-C、`kill` shell 自己。

## 2026-10-26 多进程调度

- 新增：进程表，最多 8 个进程，每个有自己的地址空间、16 KiB 内核栈和保存的内核上下文。内核主循环兼作调度器，按时间片轮转：进程被时钟中断（每 10 ms）或串口中断打断时让出 CPU，主循环处理键盘输入后再挑下一个就绪的进程。
- 新增：shell 的 `run NAME &` 在后台运行程序；`run NAME` 仍然等程序结束，Ctrl-C 只结束这个前台进程。新命令 `ps`（列出进程、状态和用掉的 tick 数）和 `kill PID`。
- 新增：系统调用 `yield`（4）和 `sleep`（5）。`sleep` 的进程不被调度、不占 CPU。
- 新增：演示程序 `ticker`（每秒打印一行），回归测试 `t_sleep`，QEMU 测试用例 `sched`，`pickNext` 的单元测试。`spin` 改成打印自己的 pid。
- 写代码时注意到的坑：新进程初始 `TrapFrame` 的 `sstatus` 是从 shell（开着中断）读的，带着 `SIE = 1`；`trapExit` 一开始就写回 `sstatus`，恢复寄存器的途中就可能被中断。现在构造时清掉 `SIE`。

## 2026-10-26 单元测试；QEMU 测试按改动挑用例

- 新增：`zig build test` 在主机上运行单元测试，覆盖设备树解析、页分配器、页表和 `copyFromUser`、ELF 加载器、系统调用返回值的编码。为此 `dtb.parse` 拆出了只看字节的 `dtb.parseBlob`。
- 改动：`tools/qemu_test.py` 拆成几个有名字的用例，可以按名字挑，也可以用 `--changed` 按改过的文件挑；默认只跑 safe 模式，`--all-modes` 跑全部四种。
- 删掉了回归测试 `t_clock`、GitHub Actions CI 和文档链接检查脚本。

## 2026-10-26 浮点单元、时钟漂移、panic 忙等

- 修复：OpenSBI 交过来时浮点单元是开着的（`sstatus.FS` = Dirty）。用户程序可以执行浮点指令，浮点寄存器还会留给下一个进程。现在 `kmain` 一开始就把 `FS` 清成 Off。新增回归测试 `t_fp`。
- 修复：`uptime` 比实际时间慢 2%～3%。原因是下一次时钟中断按“处理中断的时刻 + 10 ms”预约，每次都把处理延迟丢掉了；改成按“上一次的预约时刻 + 10 ms”。
- 修复：内核 panic 后 QEMU 占满一个 CPU 核。时钟中断一直挂着，把 `wfi` 反复唤醒；现在停机前先把 `sie` 清零。
- 新增：QEMU 测试里加了 panic 用例。

## 2026-10-25 QEMU 自动测试

- 新增：`tools/qemu_test.py` 自动构建、启动 QEMU、输入命令并检查输出。
- 新增：`user/tests/` 里的回归测试程序（`-Dtest-programs=true` 时编进内核），覆盖 `write` 的边界情况、写代码段、栈溢出、特权指令、用户程序 panic、`rdtime`、没有权限的 ELF 段。
- 新增：用户程序的 ELF 另外安装到 `zig-out/user/`，方便用 `llvm-readelf` 查看。

## 2026-10-25 U 模式用户程序和系统调用

- 新增：用户程序独立编译成 ELF 嵌进内核，内核加载 ELF、建立用户地址空间（根页表第 1 项）、进入 U 模式运行。
- 新增：系统调用 `exit`、`write`、`getpid`、`uptime`；用户指针一律通过 `vm.copyFromUser` 查页表访问。
- 新增：用户程序出错或按 Ctrl-C 只结束进程，内核照常运行；shell 命令 `run`。
- 开发中修掉的 bug：
  - release 模式下用户程序的 `_start` 没有导出，ELF 是空的。`_start` 必须放在根文件 `user/start.zig` 里。
  - release 模式下进程结束后内核崩溃。原因是会返回的裸函数被声明成了 `noreturn`，调用之后的代码被编译器删掉了。
  - 部分越界的 `write` 整体失败。现在按页分块复制，返回已经写出的字节数。
  - （安全）R/W/X 全为 0 的 ELF 段会变成指向用户数据的“页表指针”，用户程序借此能映射任意物理内存。现在加载器拒绝这样的段。
  - Debug 模式下用户程序太大。打开 gc-sections、去掉 unwind 表之后小了很多。

## 2026-10-25 物理页分配器和 Sv39 分页

- 新增：以空闲链表实现的物理页分配器（4 KiB 一页）。
- 新增：Sv39 分页。内核恒等映射，按段设置权限：代码 R-X、只读数据 R--、其余 RW-；能用大页的地方用大页。shell 命令 `mem`。

## 2026-10-25 解析设备树

- 新增：从设备树读出内存范围、时钟频率和保留内存，不再写死。

## 2026-10-25 最小内核

- 新增：OpenSBI 引导，串口输出，陷阱处理（异常和中断），时钟中断，通过串口中断和 PLIC 接收键盘输入，一个小 shell（`help`、`uptime`、`ebreak`、`crash`、`shutdown`）。
