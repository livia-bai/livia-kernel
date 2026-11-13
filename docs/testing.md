# 测试与调试

内核的测试分两层：

- **单元测试**（`zig build test`）：在你的电脑上直接运行，测不碰硬件的纯逻辑，每次只要几毫秒。
- **QEMU 测试**（`tools/qemu_test.py`）：在 QEMU 里启动内核、输入命令、检查输出，测只有在真的 CPU 上才看得到的东西。

两层各管一半：陷阱的进出汇编、进入 U 模式、中断、硬件的权限检查，单元测试都测不到；反过来，设备树解析器遇到坏数据会怎样，在 QEMU 里很难构造。

## 单元测试（zig build test）

```sh
zig build test                 # 没有输出就是全部通过
zig build test --summary all   # 显示通过了几个
zig build test -Dtest-filter=掉电 --summary all   # 只跑名字里含“掉电”的测试
```

入口是 `src/tests.zig`，它引用了下面这些文件，各文件末尾的 `test` 块就是测试：

| 文件 | 测什么 |
| --- | --- |
| `src/dtb.zig` | 用测试里的 `TestFdt` 按 FDT 格式拼一份设备树，检查解析出的内存、时钟频率、保留区、hart 列表（`reg` 写在 `device_type` 前面的也算，被禁用的 cpu 节点和 `cpu-map` 不算）；截断、魔数不对、缺少时钟频率时返回错误 |
| `src/page.zig` | 引用数数组占掉开头的页；先分配低地址、分配时清零、跳过保留区、内存用完时报 `OutOfMemory`；共用的页最后一个引用放掉才回到空闲链表，再分配时引用数从 1 开始 |
| `src/vm.zig` | 能用大页时用大页（比较用掉的页表数）；`copyFromUser` 只读得到 U 模式可读的用户页，`copyToUser` 只写得进 U 模式可写的页，pin 检查整个范围（跨页、溢出、长度 0、只要开头能读的一段），pin 好之后的复制跨页读写；`cloneUserSpace` 写时复制：只建页表、可写页两边都变成 `cow`，谁先写谁复制、只剩一个人用时不复制，内核写（`copyToUser`、`pinDst`）也一样，三方共用依次释放不漏页，内存不够时不漏页、什么都不坏（`breakCow` 返回 `OutOfMemory`，`copyToUser` 返回 `BadAddress`）；`mapExcept` 跳过保护页；按需分页：段、堆、栈的页第一次访问时才分配，段的内容来自程序镜像、其余是 0，权限按区域（越权的访问不分配），段不能重叠、最多 8 个，读不出程序文件时是 `IoError`、什么都不留，`fork` 之后两边没访问过的页各自分配；`shrinkUser` 只释放分配过的页和空出来的页表，内存不够时缺页失败、什么都不留；释放用户空间后不漏页 |
| `src/kstack.zig` | 保护页按页对齐、排好序，栈底下面一页就是保护页；`guardOwner` 认得出是哪块栈的保护页，栈本身不算 |
| `src/loader.zig` | 加载真正的用户程序 `hello`（`build.zig` 把用户程序的 ELF 也交给了单元测试）：加载时一页都不分配，每个段的每一页都按需读得到，内容和 ELF 文件里的一样；拒绝截断、魔数不对、不是 RISC-V、程序头越界、入口不在可执行的段里、没有权限的段；命令行参数在栈顶的布局（16 字节对齐、指向正确的字节、没有参数时 `sp` 是栈顶）和堆的起点 |
| `src/proc.zig` | `wakeAll` 只叫醒排在这个队列里的进程、清空队列，空队列什么都不做；被 kill 叫醒的进程还排着，摘下来时状态不变；`kill` 只做标记、叫醒在睡的进程、只记第一次的原因、拒绝 init 和不存在的 pid；`wait` 只找自己的子进程、按 pid 挑，找到的 zombie 拿着锁返回；`reparent` 把子进程交给 init 并叫醒它；测完所有进程锁都放开了；`setfg` 检查 pid，Ctrl-C 找的是前台进程和它的子孙；`fill` 换掉除了锁以外的所有字段 |
| `src/abi.zig` | 系统调用返回值和错误码的互相转换 |
| `src/spinlock.zig` | 拿锁、放锁、`holding`、记录拿着几把锁 |
| `src/pipe.zig` | 管道不需要等待的路径：环形缓冲区回绕、有多少读多少、坏地址时数据不动、写端关了读到结尾、读端关了写返回 `BrokenPipe`、两端都关了释放 |
| `src/bio.zig` | 一块内存当磁盘（记下读写次数）：缓存命中不读盘、超出 `nbuf` 时换掉最久没用的块、`write` 写回磁盘、`get` 不读盘、拿着的缓冲区不会被换掉、块号超出范围、没有磁盘；`invalidate` 之后重新读盘，拿着的缓冲区不受影响 |
| `src/sleeplock.zig` | 拿、放、`holding`（主机上没有进程，只测不需要等待的路径） |
| `src/btree.zig` | 键的顺序和 `successor`；叶子的插入、删除和数据的挪动；叶子分裂后两边都空出至少四分之一；`childFor` 把 `ptrs[0].key` 当负无穷；内部节点的插入、删除、分裂；校验和 |
| `src/ctree.zig` | 写时复制 B 树（[btree.md](btree.md#单元测试)）：插入、查找、遍历、更新、删除，树长高又变矮；没提交的改动挂载后没了，`pending` 的块不被提前分配；磁盘满；坏块、写丢了、超级块坏了；随机操作每步都检查；在每一次写之后掉电（包括只写进一部分）共 681 次，重新挂载后都是某个已提交的状态；在每一次读、写、`flush` 时读写失败（共 832 次），事务作废或者卷不再修改，重新挂载后也都是某个已提交的状态；保存的快照：之后改、删都不影响它，重新挂载后还在，删掉之后块空出来；掉电测试里也存、删快照，掉电之后每个快照的内容都对 |
| `src/fs.zig` | 文件系统（[fs.md](fs.md#单元测试)）：目录和路径、各种错误，255 字节的名字找得到、列得出来、删得掉；`readdir`、散列相同的名字；内联、换成数据块、跨页、洞、写到一半出错整个作废、截断、删除后块都还回来；数据块的校验和；在每一次写盘之后掉电（共 138 次，操作里也有 `rename`），重新挂载后都是某一个操作做完的样子，再接着写也不坏；`check` 数对文件、目录、数据块，作废缓存之后发现磁盘上坏了的数据块和节点，发现 8 种条目之间对不上的情况；`rename` 的各种情况和错误；孤儿（删掉还有人用着的文件）：只删名字、按 inode 号读写、`reapOrphan`、挂载后 `reapOrphans`，以及“删掉的文件都还有人用着”的掉电测试 |
| `src/canary.zig` | 栈底的金丝雀：没写过的不算完好；写上之后完好，金丝雀之上随便改；金丝雀的第一个、中间、最后一个字节被改了都能发现 |
| `src/ipi.zig` | `wakeIdle` 每次用 `cmpxchg` 认领一个别的空闲 hart，不叫自己，没有空闲的就停下 |
| `src/file.zig` | `dup` 加引用、最后一个 `close` 才关掉管道；文件表满了 `openPipe` 失败且不漏 |

为什么页表能在主机上测：内核对物理内存做了恒等映射，页表里的地址就是能直接用的指针。测试拿一块按 4 KiB 对齐的数组交给页分配器当作“物理内存”，页表就建在这块数组里，代码不用改。只有 `vm.activate` 这类写 CSR 的函数不能在主机上调用，测试也不会用到它们：Zig 只编译被用到的函数，所以这些文件里的 RISC-V 内联汇编不影响在主机上编译。例外是被测的函数在不会走到的路径上调用了它们：管道的读写在等待时调用 `proc.sleep` → `proc.sched`（读 `sstatus`、切换上下文），测试只走不需要等待的路径，但 `sched` 照样要编译。所以 `sched` 开头在主机上直接 `@panic`（编译期判断，不是 RISC-V 时后面的汇编不会被编译），`Spinlock.acquire` 在主机上不检查 `sstatus`。

## QEMU 测试（tools/qemu_test.py）

```sh
python3 tools/qemu_test.py --changed      # 只跑和还没提交的改动有关的用例（平时用这个）
python3 tools/qemu_test.py                # 全部用例，safe 模式，单核和 4 核各一遍，约 20 秒
python3 tools/qemu_test.py shell fork     # 只跑指定的用例
python3 tools/qemu_test.py --all-modes    # debug、safe、fast、small 四种模式都跑
python3 tools/qemu_test.py --smp 8        # 只用 8 个 hart 跑（可以给几个：--smp 2 --smp 8）
python3 tools/qemu_test.py --jitter --repeat 5 --smp 4 --smp 8   # 拿锁、放锁时随机空转，每种组合跑 5 遍
python3 tools/qemu_test.py --list         # 列出用例和它们覆盖的文件
```

每种模式只构建一次（带上 `user/tests/` 里的测试程序），然后对每个 hart 数（默认 `-smp 1` 和 `-smp 4`）各启动一次 QEMU（每次接上一份新拷的磁盘镜像 `disk-smpN.img`，不加 `snapshot=on`，退出之后还要读它），等提示符出现再一条条输入命令、检查输出。不管跑哪些用例，都会检查启动日志（包括 `[ok] N harts running` 里的 N 等于 `-smp` 给的数、文件系统挂上了）；结束时还要求前后两次 `mem` 的空闲页数相同（不能漏页）、`shutdown` 后 QEMU 的退出码为 0、内核打印的每种内核栈用到过的最深处离栈底至少还有 2048 字节（`STACK_MARGIN`，[process.md](process.md#进程表)）、输出里没有 `KERNEL PANIC`（有的话，用 llvm-symbolizer 把 panic 打印的调用栈换成源码位置，附在失败信息里，[boot.md](boot.md#panic)）。QEMU 的命令行、进程表的大小这些常量从 `zig build` 生成的 `config.json` 读（[build.md](build.md#给测试脚本的配置)）。

两次 `mem` 都在**新启动的 shell** 里看（`fresh_mem`）：先 `kill $$` 让 shell 结束，init 重新启动一个，新 shell 的第一条命令就是 `mem`。按需分页之后进程的页用到才分配，一直在运行的 shell 执行的命令越多、用到的页越多（代码、栈），直接比较开头和结尾会差几页，分不出是漏页还是 shell 长大了；两个新 shell 走的是同一条路，用到的页一样多（init 重启 shell 的那段代码在第一次时就读进来了）。

单核、多核都要跑：多核时进程真的同时在跑，加锁的错误才会暴露出来；单核时所有进程只能轮流用一个 hart，“等别的进程让出 CPU”的路径（时间片轮转、调度器空转时的 `wfi`）才走得到。有的检查要按 hart 数写：`ps` 里死循环的后台进程，单核时是 `runnable`，多核时可能是 `running`；`ps` 可能正好看到 shell 刚 `fork` 出来、还没 `exec` 的子进程（名字还是 `sh`，父进程是 shell），所以认 shell 时看的是“父进程是 init 的那个 `sh`”。

| 用例 | 做什么 | 覆盖的文件 |
| --- | --- | --- |
| `shell` | `help`、`uptime`、不认识的命令、`run` 不带参数（`/bin` 里的程序按名字排序）和找不到的程序；不写 `run` 直接运行 `hello`、`echo one two\|wc`，管道里找不到的程序是 `unknown command`。命令语言：单引号、双引号、反斜杠；变量（`X=...`、`$X`、`${X}`、双引号里展开、单引号里不展开、没有的变量展开成空的、`set`、`unset`）；`$?`（`false` 之后是 1、不认识的命令是 127、语法错误是 2）；`&&`、`\|\|`（`false && echo no \|\| echo yes` 只打印 yes）、`;`、`#` 注释；5 种语法错误（引号没配对、`&&` 后面没有命令、`\|` 后面是 `;`、`>` 后面没有文件名、`${` 没有 `}`）都不执行这一行的任何命令；glob（`/bin/t_f*`、`/bin/?c`、匹配不到的原样留着、引号里的不展开、当前目录里的 `*`）；`cd`、`pwd`、`cd -`；内置命令在管道里（`pwd \| wc`）、带 `>` 重定向，之后标准输出换回来。行编辑：上、上、下翻历史，上两次，`history` 列出来，Ctrl-U 清掉一行；Tab 补全唯一的程序名、目录（后面加 `/`），几个候选时列出来、重新打印这一行。脚本：`sh 文件 参数`（`$0`、`$#`、`$1`、`$2`，带空格的参数，注释，`exit 5` 之后的行不执行，脚本里的 `cd` 不影响交互的 shell）、`sh -c`、`echo ... \| sh`、`sh < 文件`、没有的文件。`jobs` 列出后台的 `spin`、`$!`、`kill $!` 之后 `jobs` 是空的，`hello & wait $!`，`time hello`，`kill` 几个 pid，最后 `exit 3`：init 重新启动一个 shell | 只由核心文件触发 |
| `interrupts` | `spin` 在前台死循环 0.5 秒，`uptime` 至少走了 100 ms，Ctrl-C（串口中断）能结束它；在 shell 里按的 Ctrl-C 不会误杀下一个程序 | `src/timer.zig`、`src/sbi.zig`、`src/plic.zig`、`user/spin.zig` |
| `user` | `hello`（系统调用、拒绝内核指针）、`fault`（读内核内存被杀）、`t_panic`、`t_time` | `user/linker.ld` 和这几个程序 |
| `sched` | 两个后台 `spin` 死循环时，前台的 `hello`、`t_sleep` 照样跑完；0.5 秒里两个 `spin` 各自至少拿到 50 ms 的 CPU 时间（`ps` 的 `CPU_MS`），状态是 `runnable` 或 `running`；`ps` 里 init 是 pid 1、在睡，sh 是它的子进程、在运行；Ctrl-C 只结束前台进程，也能结束睡在 `sleep` 里的前台进程；后台的 `ticker` 在 `ps` 里是 `sleeping`；`kill` 正常的、不存在的、缺参数的 pid 和 init；后台运行 `t_fork fill` 开满进程表（它 fork 出 61 个睡着的子进程），再 `run` 报 `too many processes (at most 64)`，杀掉它之后子进程发现父进程没了、各自结束，`ps` 里没有剩下的 | `src/timer.zig`、`user/spin.zig`、`user/ticker.zig`、`user/hello.zig`、`user/tests/t_sleep.zig`、`user/tests/t_fork.zig` |
| `syscall` | `t_sys`：`write` 的各种边界情况、不存在的调用号 | `user/tests/t_sys.zig` |
| `fork` | `t_fork`（自己检查 97 项，见下文）；`t_read` 分几次读完一行，睡在 `read` 里时按 Ctrl-C 能结束它；杀掉 shell 后 init 重新启动一个 | `user/hello.zig`、`user/tests/t_fork.zig`、`user/tests/t_read.zig` |
| `protection` | `t_wx`、`t_stack`、`t_priv`、`t_fp`、`t_noperm`：硬件和加载器的各种保护 | `user/linker.ld`、对应的测试程序 |
| `args` | shell 按空格拆参数（多个空格算一个），`t_args` 看到的 argc、argv、退出码；`echo` 带参数、不带参数；超过 32 个参数时 shell 报错；`t_args check`（自己检查 11 项） | `user/echo.zig`、`user/tests/t_args.zig` |
| `pipe` | `t_pipe`（自己检查 31 项）；shell 的管道：`echo \| wc`、`echo \| cat \| cat \| wc`、`t_args \| wc` 的结果，8 个程序的管道照常，找不到的程序、空的一段、超过 8 个程序时报错；后台管道；对 `cat \| wc` 按 Ctrl-C 杀掉三个进程（组长、cat、wc），之后 `ps` 里没有剩下的；对 `cat \| wc` 输入 `abc` 再按 Ctrl-D，wc 打印 `0 1 3` | `src/pipe.zig`、`user/echo.zig`、`user/cat.zig`、`user/wc.zig`、`user/tests/t_pipe.zig`、`user/tests/t_args.zig` |
| `sbrk` | `t_sbrk`（自己检查 33 项），其中写满比空闲内存还大的堆的子进程被 `killed: out of memory (demand paging)` | `user/tests/t_sbrk.zig` |
| `demand` | `t_demand`（自己检查 19 项，见下文）：按需分页、运行中的程序文件不能改 | `src/fsys.zig`、`user/spin.zig`、`user/tests/t_demand.zig` |
| `snap` | 存一个快照之后改、删文件：`cat /.snap/ID/...` 还是原来的内容，`ls` 看得到删掉的文件、看不到新建的，删掉的大文件 `wc` 和 `/bin/hello` 一样；往快照里写是 `ReadOnly`，不存在的快照是 `NotFound`；后台的 `sleep` 的标准输入是快照里的文件时 `snap rm` 是 `Busy`，它结束之后能删；删掉之后 `scrub` 通过、空闲块变多 | `src/ctree.zig`、`src/fs.zig`、`src/fsys.zig`、`src/file.zig`、`user/snap.zig`、`user/scrub.zig` |
| `unlink` | `t_unlink`（自己检查 15 项，见下文）；关机之后再启动一次，后台运行 `t_unlink hold`（打开着一个删掉了的文件）时杀掉 QEMU，下一次启动的日志里有 `[ok] file system: removed 1 orphan inode`，`scrub` 通过 | `src/fs.zig`、`src/fsys.zig`、`src/file.zig`、`user/tests/t_unlink.zig` |
| `tools` | 写脚本用的程序（[user-programs.md](user-programs.md#写脚本用的程序)）：`seq`（正着、倒着、空的、步长 0）、`head`、`tail`（`-n 0`、比输入多、输入比一次 `read` 大）、`grep`（`-n -c -v -i -q`、`^ $ . *`、`\.`、打不开的文件退出码 2）、`expr`（优先级、括号、负数、`/ %`、比较和 `& \|`、退出码、除以 0、溢出、语法错误、不是数）、`test`（整数、字符串、文件、`! -a -o`、括号、没有参数、不是整数）、`xargs`（`-n`、默认 `echo`、退出码 123 和 127）、`sleep`；在 `/ttools` 下：`cp` 到文件、到同一个文件（报错、内容不变）、到目录、到不是目录的、复制目录，`touch`、`tee`、`tee -a`，几个文件的 `head`、`grep`；一个用 `seq \| xargs -n 1 sh 脚本` 循环、用 `expr`、`&&`、`\|\|` 判断奇偶的脚本；复制一份 `spin` 在后台运行，`cp` 覆盖它是 `TextBusy`，`rm` 它可以、它在 `ps` 里还在运行，杀掉之后又能 `cp` 覆盖；最后删干净 | 这些程序，和 `src/fsys.zig`、`user/echo.zig`、`user/cat.zig`、`user/wc.zig`、`user/ls.zig`、`user/rm.zig`、`user/spin.zig`、`user/hello.zig` |
| `cow` | `t_cow`（自己检查 15 项，见下文）；它打印的 `fork` 用掉的页数少于 16；最后一项里子进程被 `killed: out of memory (copy-on-write)` | `user/tests/t_cow.zig` |
| `disk` | `disk` 命令打印 `1024 blocks of 4 KiB (4 MiB)`（原始区域）；`t_disk`（自己检查 19 项，见下文）；QEMU 退出之后读这次启动用的磁盘镜像，原始区域的每一块都要是 `t_disk` 写进去的或者原来的内容；再启动一次，用 QEMU 的 `blkdebug` 让原始区域第 900 块的读写都失败：`t_disk eio 900` 读写它都得到 `IoError`（两遍），两边的块照常读得出来，内核打印出错的请求，不 panic | `src/sleeplock.zig`、`src/bio.zig`、`src/virtio_disk.zig`、`src/fsys.zig`、`src/mkfs.zig`、`user/tests/t_disk.zig` |
| `fs` | shell 里的文件操作：`ls /`（有 `bin`、`dev`，链接数 1）、`ls /bin`、`ls /dev`（三个设备文件和它们的设备号）、`echo > /dev/null` 什么都不输出、`cat /dev/null` 马上结束、`echo > /dev/console` 输出到串口、`echo ... > F` 再 `cat F`、`wc < F`、`echo \| cat >F`、`mkdir` 两层、`cd` 进去用相对路径写和列、`cd ..`、`rm` 非空目录报 `NotEmpty`、删干净之后 `ls /` 只剩 `bin` 和 `dev`；`ln` 之后 `ls` 显示链接数 2、从新名字追加、删掉原来的名字之后新名字的内容和长度都对，`ln` 目录报 `PermissionDenied`；`cd`、`cat`、`<`、`>`、`mkdir` 的出错信息；`>` 再两次 `>>` 之后文件里是三行；`mv` 改名之后旧名字没了、挪进目录换掉里面同名的文件、没有的文件和挪进自己下面的报错；`cat /bin/hello > /h` 复制一个程序再 `run /h`（进程名是 `h`），不是 ELF 的文件是 `BadElf`，`run /bin` 是找不到程序；符号链接：`ln -s` 相对的目标、`ls` 显示 `link ... -> 目标`、`cat` 跟着走、`ls` 指向目录的链接列出目录里的东西、`ls /` 里看得到链接、`cd` 穿过链接之后 `pwd` 是真实的路径、悬空的链接 `ls` 列得出来 `cat` 是 `NotFound`、`>` 穿过悬空的链接建出目标、自己指自己是 `SymlinkLoop`、`ln -s` 到已有的名字是 `Exists`、`rm` 链接之后目标还在；`t_fs`（自己检查 229 项，见下文）；`t_fsmp`（自己检查 11 项，读者和写者同时进行）。QEMU 正常关机之后在同一个镜像上**再启动两次**：第二次 `cat` 上一次写的文件还在（直接 `cat`，再通过一个符号链接 `cat`），然后后台运行 `t_fs churn`，0.2～1 秒（随机）之后直接杀掉 QEMU；第三次启动时文件系统要能挂上，`t_fs verify` 检查 churn 写的东西（实测留下几十到一百多条记录），`scrub` 通过，再用 `t_fs scrubfile` 建 `/scrub.dat`、关机；在镜像里按内容找到它第 1 页的数据块（必须正好一块）、改掉一个字节，**第四次启动**：`scrub` 报 `IoError`、退出码 1，`cat` 它报 `IoError`，`rm` 掉之后 `scrub` 又通过。第一次启动跑完 `t_fs` 之后也 `scrub` 一次。三次启动的串口日志在 `disk-smpN-boot2.log`、`-boot3.log`、`-boot4.log` | `src/btree.zig`、`src/ctree.zig`、`src/fs.zig`、`src/fsys.zig`、`src/mkfs.zig`、`src/sleeplock.zig`、`src/bio.zig`、`src/virtio_disk.zig`、`user/ls.zig`、`user/mkdir.zig`、`user/rm.zig`、`user/cat.zig`、`user/echo.zig`、`user/wc.zig`、`user/scrub.zig`、`user/mv.zig`、`user/ln.zig`、`user/tests/t_fs.zig`、`user/tests/t_fsmp.zig` |
| `ipi` | `t_ipi`：打印 kill、wakeup 两个延迟的中位数；多核时要求 kill < 2000 µs、wakeup < 1000 µs（没有核间中断时实测 kill ≥ 4000 µs、wakeup ≥ 1100 µs，有了之后约 300～560 µs 和 200 µs） | `src/sbi.zig`、`user/tests/t_ipi.zig` |
| `smp` | `t_smp`（自己检查 17 项，见下文）；至少 3 个 hart 时，两个后台 `spin` 0.5 秒里加起来拿到的 CPU 时间要多于 650 ms（一个 hart 最多给 500 ms，所以它们一定是同时在两个 hart 上跑的） | `src/timer.zig`、`src/plic.zig`、`src/pipe.zig`、`user/spin.zig`、`user/tests/t_smp.zig` |
| `kstat` | 最后跑：`kstat` 打印的计数器里系统调用、上下文切换、时钟中断、`wakeup`、两种缺页、TLB 刷新、缓冲区缓存没命中、读盘都大于 0，`processes_woken` 大于 0，三种栈的高水位都打印了 | `user/kstat.zig` |

`build.zig`、链接脚本、`src/` 下的 `main.zig`、`riscv.zig`、`trap.zig`、`vm.zig`、`page.zig`、`dtb.zig`、`uart.zig`、`proc.zig`、`syscall.zig`、`abi.zig`、`spinlock.zig`、`hart.zig`、`file.zig`，以及 `user/` 下的 `start.zig`、`sys.zig`、`init.zig`、`sh.zig` 是核心文件：所有用例都要经过 init、shell 和系统调用，改了它们就跑全部用例；没登记过的内核文件也一样。只改了文档时，`--changed` 什么都不跑。

优化模式默认只用 safe：既有安全检查（整数溢出、越界），也开了优化。改了内联汇编、MMIO、中断、页表、进出 U 模式的代码时，再加 `--all-modes`：release 模式下编译器会更激进地利用类型系统的承诺，漏写的 `volatile`、clobber，写错的 `noreturn`，往往只在 release 模式下出问题。

失败时会列出没通过的检查，以及串口日志的位置（`zig-out/qemu-test/<模式>/serial-smp<N>.log`）。例如多核支持刚写好时，4 核下 `sched` 用例失败过一次，是测试脚本的问题（上面说的还没 `exec` 的子进程）：

```
FAIL  safe   smp4   sched       61 checks
    - ps: expected one running sh, child of init: [(1, 0, 'sleeping', 0, 'init'), (2, 1, 'running', 3, 'sh'), (3, 2, 'running', 115, 'spin'), (4, 2, 'running', 114, 'spin'), (9, 2, 'running', 0, 'sh')]
    serial log: zig-out/qemu-test/safe/serial-smp4.log
```

多核下的竞争不一定每次都出现。改了加锁、调度、进程生命周期的代码之后，最好多跑几遍、多试几种 hart 数，再加上随机空转：`python3 tools/qemu_test.py --jitter --repeat 5 --mode debug --mode fast --smp 2 --smp 4 --smp 8`。

- `--repeat N`：每种模式、每个 hart 数都跑 N 遍。失败的那一遍的串口日志另存成 `serial-smpK-roundR.log`，不会被下一遍覆盖。
- `--jitter`：内核用 `zig build -Dlock-jitter=true` 构建（产物在 `zig-out/qemu-test/<模式>-jitter/`），启动时多打印一行 `[ok] lock jitter: ...`。`Spinlock.acquire` 拿锁之前、`release` 放锁之后，大约四次里有一次空转 0..1023 圈（伪随机数每个 hart 一份，种子来自 `time`，每次运行都不一样）。竞争类的错误常常要两个 hart 在几条指令的窗口里恰好交叉才出现，在每个加锁的地方随机停一停，交叉的方式就多得多。这时 `t_ipi` 的延迟上限不检查（空转会把延迟拉长）。
- 效果只验证过一次，算弱证据：在 `WaitQueue.wait` 里故意先放开条件的锁、再拿进程锁（会丢唤醒），`pipe smp disk` 三个用例 4 核跑 4 遍，不加 `--jitter` 4 遍里抓到 3 遍，加了 4 遍都抓到（都是 `disk` 用例卡住）。
- 它仍然只是让竞争更容易撞上，不能证明没有竞争；做不到可重放。

内核 panic 之后停机的行为（停机后不能忙等）没有自动测试：触发内核 panic 的 shell 命令随着 shell 搬到用户态一起去掉了。内核栈溢出也没法从用户程序触发，启动日志里的 `[ok] stack overflow check: ...`（`trap.probeGuard`，[trap.md](trap.md#内核栈溢出)）每次启动都模拟一次，`check_boot` 检查它和 `80 stack guard pages unmapped`。

## 回归测试程序

`user/tests/` 里的程序只在 `-Dtest-programs=true` 时编进内核（`qemu_test.py` 会自动加上），平时 `run` 列表里看不到它们。

| 程序 | 测什么 | 期望结果 |
| --- | --- | --- |
| `t_sys` | `write` 的部分越界、长度溢出、零长度、跨页；不存在的调用号 | 部分写返回已写字节数；零长度返回 0；未知调用号返回 -38；退出码 42 |
| `t_wx` | 往自己的代码段写 | `store_page_fault`，进程被杀 |
| `t_stack` | 无限递归 | 栈按需长到 1 MiB，撞到下面的保护页：`store_page_fault`，`stval` 在 `0x7feff000..0x7ff00000` |
| `t_priv` | U 模式执行 `csrr sstatus` | `illegal_instruction`，进程被杀 |
| `t_fp` | U 模式执行浮点指令 `fmv.d.x f1, a0`（手工编码） | `illegal_instruction`，`stval=0xf20500d3`（`sstatus.FS = Off`） |
| `t_panic` | 整数溢出 | Debug/safe：`panic: integer overflow`，退出码 255；fast/small 没有检查，回绕成 4 |
| `t_sleep` | `sleep(200)` 前后的 `uptime()`；`sleep(0)`、`yield()` | 睡了 200..1000 ms；之后打印 `yield ok`，退出码 0 |
| `t_time` | U 模式执行 `rdtime` | 正常返回（`scounteren` 允许，见 [user-programs.md](user-programs.md#写一个新程序)） |
| `t_noperm` | 数据段 `FLAGS(0)` 的 ELF（用 `user/tests/noperm.ld` 链接） | `sh: cannot load t_noperm: BadElf` |
| `t_fork` | `fork` 的返回值和地址空间复制；`wait` 的退出码、nohang、没有子进程、别人的子进程、坏的 options、写不进状态时不回收；`kill` 睡着的子进程、init、不存在的 pid；`setfg` 不存在的 pid；`exec` 不存在的程序和路径、空名字、257 字节的路径和加上 `/bin/` 超长的名字（`NameTooLong`）、坏 ELF、目录、路径中间是文件（`NotDir`）、坏指针，成功后 pid 不变；孤儿交给 init（孙进程的 `getppid()` 变成 1）；`fork` 到进程表满（`EAGAIN`，61 个子进程）再全部回收；`procinfo`、`meminfo`、`read` 的坏参数和边界，去掉了的 15 号调用（原来的 `listprog`）是 `ENOSYS` | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0 |
| `t_read` | 每次最多 `read` 3 个字节，读到回车为止 | 输入 `hello world` 回车：`got "hello world" in N reads`，N ≥ 4 |
| `t_args` | 不带 `check` 时打印 argc、每个参数、总字节数，退出码是 argc。`t_args check`：`argv` 在栈顶那一页、16 字节对齐；33 个参数、2050 字节的参数返回 `ArgsTooLong`；`argv` 指针、参数指针指向内核时 `EFAULT`；长度为 0 的参数不检查指针；正好 32 个参数、2048 字节；没有参数。要看子进程收到的参数时，把它的 stdout 接到管道上读回来比较 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0 |
| `t_pipe` | 基本读写、fd 编号最小；往读端写、从写端读是 `BadFd`；写端关了读到结尾；子进程写 5000 字节（比缓冲区大，要等）、父进程读完一字不差且读了至少 3 次；读的一方先睡下；读端关了写返回 `BrokenPipe`；写满之后读端才关，睡着的写者被叫醒、只写出一部分；睡在管道读、写里时被 kill；坏的 fd、坏指针；`dup` 到 fd 表满、`pipe` 在只剩一个空位时失败且不漏；`fork` 继承 fd、子进程关 stdout 不影响父进程 | 同上 |
| `t_disk` | `blockcount` 是 1024（原始区域）；每一块读一遍，和镜像一样（一路换掉缓存里的旧块）；块号超出磁盘、`maxInt`、读进代码页、从没有映射的地址和内核地址写都失败，失败的写不改磁盘；跨页的用户缓冲区；写 42 块（含第一块、最后一块）后马上读回、把缓存挤满之后再读回；6 个子进程同时各写 50 块再读回、同时读同一批块（比队列一次能放的请求多，有的要等描述符）；子进程读块到和父进程共用的页（写时复制）。同一次启动里再运行一遍也能通过 | `N checks, 0 failed`，退出码 0；QEMU 退出之后镜像里的内容由 `qemu_test.py` 检查 |
| `t_fs` | 文件系统的系统调用，所有东西建在 `/t_fs` 下、最后删干净：串口、管道的 `fstat`，`readdir` 串口是 `NotDir`；建文件、写、读回来、读到结尾；只写的 fd 不能读、只读的不能写；`O_CREATE` 不截断、`O_TRUNC` 截断；`dup`、`fork` 出来的 fd 共用读写位置，各自 `open` 的各有各的；40000 字节的文件分 3000 字节写、换几种大小读回来，一次写 40000 字节再一次读回来；路径、读写缓冲区、`fstat`、`readdir` 的结果指向内核是 `BadAddress`，读失败不挪位置，写到一半碰到没映射的地址整个写作废、文件不变；`mkdir` 重复、在文件下面、在不存在的目录下面、`..`；写方式打开目录、`O_CREATE` 一个目录是 `IsDir`，读目录是 `IsDir`，`readdir` 一个文件是 `NotDir`；256 字节的名字、257 字节的路径是 `NameTooLong`，255 字节的名字可以建；30 个文件的目录 `readdir` 每个名字正好一次；`chdir` 到文件、不存在的目录，相对路径，子进程 `chdir` 不影响父进程，带 `.`、`..` 的路径；删非空目录、`.`、`/`、不存在的；删掉打开着的文件之后读它是 `NotFound`；4 个进程同时往共用一个位置的 fd 追加 100 字节的记录、同时各写自己的文件，记录不交错不丢、各自的文件内容不错；`lseek` 的三种 whence、查当前位置、挪到末尾之后再写中间读出来是 0、负的位置和坏的 whence 是 `InvalidArgument`（位置不变）、挪到 `maxInt(i64)` 可以再往后不行、在那里写是 `FileTooBig`、`dup` 的 fd 共用位置、串口和管道是 `NotSeekable`、坏 fd、目录挪回 0 重新列出一样多的名字、挪到别处不行；`O_APPEND` 挪到开头再写也写在末尾、别的 fd 写长了接着追加、只读的 fd 带 append 也不能写、4 个进程各自 `open` 同一个文件追加 50 字节的记录，一条不丢不覆盖；`rename` 同目录改名、换目录、打开着的 fd 改名之后照常读写、当前目录的上一级被改名之后相对路径和 `..` 照常、换掉已有的文件、各种错误（没有的文件、挪进自己下面、文件换目录、目录换文件、换掉不空的目录、改成 `/`、内核指针、257 字节的路径）、目录换掉空目录；`link` 之后两个名字同一个 inode、链接数 2、从一个名字追加另一个名字读到，删掉一个名字另一个照常（打开着的 fd 也照常），链接到别的目录、相对路径，`rename` 到同一个文件的另一个名字什么都不变，错误（目录是 `PermissionDenied`、新名字已有、没有的文件、没有的目录、在文件下面、`..`、内核指针），删到最后一个名字就没了；设备文件：`/dev/null` 读是 0 字节、写全部收下，`fstat` 是 `device`、设备号 2、长度 0、链接数 1，`lseek` 是 `NotSeekable`，`readdir` 是 `NotDir`；`/dev/zero` 读 40100 字节全是 0，只读打开时不能写；写 `/dev/console` 输出到串口；`mknod` 建 null、重复的名字、链接设备文件、不认识的设备号能建不能打开（`NoSuchDevice`）、设备号 0 是 `InvalidArgument`、没有的目录；设备文件不能 `chdir`、不能当路径中间的目录、不能 `exec`（`BadElf`）；符号链接：相对的、指向目录的目标，`open` 跟着走、`lstat` 不跟（种类、长度、inode 号），`readlink` 读出目标、缓冲区小时截断、文件是 `InvalidArgument`、没有的是 `NotFound`、指向内核是 `BadAddress`，穿过指向目录的链接建文件、`chdir`（`.`、`..` 是目标和它的父目录），悬空的链接 `open` 是 `NotFound`、`lstat` 照常、`O_CREATE` 建出目标、`mkdir` 同名是 `Exists`，两个互指的链接 `open`、`O_CREATE`、`chdir`、`exec` 都是 `SymlinkLoop`，`exec` 穿过链接运行 `echo`，已有的名字、空的目标、257 字节的目标报错，256 字节的目标可以，`rename` 链接之后照常、硬链接到链接（链接数 2、目标的链接数不变）、`unlink` 链接不动目标，最后留下一个指向 `/` 的链接（`removeTree` 用 `lstat`，不能跟着它走进去）；`getcwd`：根目录是 `/`，穿过链接 `chdir` 之后是真实的路径，缓冲区太小是 `BufferTooSmall`，指向内核是 `BadAddress`，当前目录被删掉之后是 `NotFound`。`t_fs churn`：一直往 `/churn.dat` 末尾追加 300 字节的记录，反复删除、截断重写 `/churn/` 下的 3 个 5000 字节的文件，直到被杀。`t_fs verify`：`/churn.dat` 的长度是整数条记录、每条都对，`/churn/` 下的文件要么是 0 字节（刚建还没写）、要么内容完整。`t_fs scrubfile`：建 `/scrub.dat`，3 页，第 i 页是 `scrub test page i` 一行行重复，内容独一无二，`qemu_test.py` 能在镜像里按内容找到它 | `N checks, 0 failed`，退出码 0；`verify` 先打印 `churn: N records intact` |
| `t_ipi` | 核间中断的延迟，用 U 模式的 `rdtime` 计时，各测 15 次取中位数：杀掉一个在 U 模式里死循环的子进程（多核时在另一个 hart 上），从 `kill` 到 `wait` 返回；父进程写管道之后自己在 U 模式里忙 20 ms，睡在 `read` 里的子进程多久之后醒来 | `ipi latency (median of 15): kill N us, wakeup M us`，退出码 0 |
| `t_fsmp` | 文件系统的读者和写者同时进行（多核时在不同的 hart 上），东西建在 `/t_fsmp` 下、最后删干净：2 个写者各自把一个 3 页多的文件整个改写 30 次（每次一个 `write`，换一个版本号，内容由版本号和位置决定）；1 个进程在 `/t_fsmp/dir` 下反复建文件、写、改名、删、建删目录；3 个读者一直读到两个文件都是最后一个版本：每次一个 `read` 读出整个文件，必须正好是某一个完整的版本、版本号不倒退，每 8 轮列一次目录，每 16 轮 `fork` + `exec` 自己（`t_fsmp noop`）。最后两个文件都是第 30 版。写者写的整个过程中一直有读者在读，多核时它们在不同的 hart 上同时跑，读者读到一半时写者正好提交、再分配刚空出来的块：快照的旧树的块被提前重用的话（实测把 `ctree` 的 `limbo` 关掉），4 个 hart 时读者打开、读文件出错，`exec` 失败（试了 4 次都抓到）；单核时抓不到：读者只有等磁盘时才会在一次 `read` 的中间让出 CPU，碰不上。单核时读者每轮 `yield` 一下，不然写者每等完一次磁盘都要排到几个读者的时间片之后，写得太慢 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0 |
| `t_smp` | 6 个工作进程同时（多核时在不同的 hart 上）各做 30 次 `fork`/`exit`/`wait`、各往同一个管道写 30 × 64 字节（父进程读完，按字节数对账）、各做 30 次 `sbrk` 长 3 页再缩回去，最后各留下一个交给 init 的孤儿；然后杀掉 3 个在 U 模式死循环的子进程（多核时它们正在别的 hart 上跑），`wait` 拿到的都是被杀的状态 | 每项失败打印 `FAIL: ...`；最后 `N checks, 0 failed`，退出码 0；前后 `mem` 一样 |
| `t_cow` | 写时复制的 `fork`：带着 64 页堆的进程 `fork` 只多用了几页；父子进程各改各的（堆、全局变量，先写的、后写的都看不到对方的）；内核替子进程往共用的页里写（`read`、`pipe`、`meminfo`、`wait` 的输出参数）不改到父进程；父进程复制走之后子进程再写不再复制；最后父进程把内存全部用完，子进程让内核往共用的页里写得到 `EFAULT`，自己写被结束。按需分页之后 `sbrk` 不再占内存，用完内存的办法是长一个比空闲内存还大的堆、让内核读 `/dev/zero` 把它写满（写到没内存时返回 `EFAULT`，自己不会被结束），剩下的零星几页给管道；在那之前先把程序的每一页都读进来、栈的页都分配好，不然内存用完之后执行到还没读进来的代码，自己也会被结束 | `fork of a process with a 64-page heap used N pages`，N < 16；`killed: out of memory (copy-on-write)`；最后 `N checks, 0 failed`，退出码 0；前后 `mem` 一样 |
| `t_sbrk` | 堆一开始是空的；长 3 页多：返回原来的末尾、清零、按页算（最后一页的页尾能写，下一页缺页）；内核通过管道读写堆里的内存；`fork` 复制堆；缩到页中间：这一页还在，后面的页缺页；再长回来是清零的；缩到起点下面、`minInt`、长进栈、`maxInt`、比整个物理内存还大都失败，失败时不用页、`brk` 不变；按需分配：`sbrk(4 MiB)` 一页都不用，碰相隔很远的两页用 2～5 页，缩回去全部还回来；比空闲内存大的堆能长成功，子进程一页页写满时被结束，内核替自己写满它（读 `/dev/zero`）时返回 `EFAULT`；一个字节一个字节地长过页边界；全部还回去 | 同上；中间有几行 `killed: store_page_fault`，是故意去碰没有的页的子进程，还有一行 `killed: out of memory (demand paging)` |
| `t_demand` | 按需分页：程序里 256 KiB 的只读数组读 16 页正好多用 16 页、内容来自文件；128 KiB 的数据数组内容来自文件、可写，`fork` 之后父子各改各的（父进程碰过的、没碰过的页都是）；内核替程序访问还没读进来的页：`write` 管道、串口、文件的来源是没碰过的只读数据页，`read`、`fstat`、`readdir`、`wait` 的结果写进没碰过的数据页（有的是拿着锁复制的，靠先 pin 好）；子进程 `exec` 自己（`t_demand deep`）用掉 512 KiB 的栈（至少 128 页），回收后不漏页；正在运行的程序文件（复制一份 `spin` 运行起来）`write`、带 `O_TRUNC` 的 `open` 都是 `TextBusy`，改名、加硬链接再删掉一个可以，结束之后又都可以改 | `reading 16 untouched pages of the program used 16 pages`、`512 KiB of stack used N pages`；最后 `19 checks, 0 failed`，退出码 0 |
| `t_unlink` | 删掉还有人用着的文件：打开着删掉之后路径找不到、fd 照常读写、`fstat` 的链接数 0、`scrub` 数出一个孤儿、它的块还没还回来，关掉之后孤儿没了、块还回来；`fork` 之后子进程打开着，父进程关掉、删掉，子进程照常读、结束之后才删；删掉正在运行的一份自己的副本（`t_unlink lazy`），它之后才第一次读 32 KiB 的只读数据，内容对；`t_unlink hold` 见 `unlink` 用例 | `15 checks, 0 failed`，退出码 0 |

### 加一个回归测试

1. 新建 `user/tests/t_xxx.zig`（`const sys = @import("sys");`，`pub fn main() u8`），用打印的内容或者退出码表达结果。
2. 在 `build.zig` 的 `test_programs` 里加一项：`.{ .name = "t_xxx", .dir = "user/tests" }`。
3. 在 `tools/qemu_test.py` 的某个用例函数里加上 `q.command("run t_xxx")` 和对输出的检查，并把这个文件加进那个用例覆盖的文件列表。
4. 能在主机上测的逻辑，优先写成单元测试。

## 调试工具

### QEMU 的陷阱日志

`-d int` 让 QEMU 记录每一次陷阱（包括 M 模式的），`-D` 指定日志文件：

```sh
qemu-system-riscv64 ... -kernel zig-out/bin/kernel -d int -D qemu.log
zig build run -- -d int -D qemu.log      # 通过构建系统运行时，-- 之后的参数会传给 QEMU
```

每一行形如：

```
riscv_cpu_do_interrupt: hart:0, async:0, cause:000000000000000d, epc:0x0000000040011454, tval:0x0000000080200000, desc=load_page_fault
```

- `async:1` 是中断，`async:0` 是异常；`cause` 是编号，`epc`、`tval` 对应 `sepc`/`mepc`、`stval`/`mtval`。
- 日志里也有 OpenSBI 自己的陷阱：启动时一串 `illegal_instruction`（`epc` 在 `0x8000_xxxx`，是 OpenSBI 在探测 CSR），每次 SBI 调用一行 `supervisor_ecall`，以及 M 模式的定时器中断。
- 用户程序的系统调用是 `desc=user_ecall`，可以用 `grep -c user_ecall qemu.log` 数一个程序做了多少次系统调用。
- 内核在开分页、进 U 模式之类的地方“一声不响地卡住”时，日志的最后几行通常就是答案（比如同一个地址反复缺页）。

### GDB

需要 `gdb-multiarch`（Debian/Ubuntu 的包名同名，不在默认环境里）。QEMU 加 `-s -S`：`-s` 在 1234 端口开 GDB 服务，`-S` 让 CPU 停在第一条指令等待连接。下面用 `-smp 1`，简单些；多个 hart 时 GDB 把每个 hart 当成一个线程（`info threads`、`thread N`，推测和 QEMU 别的架构一样，没有实际用过）。

```sh
qemu-system-riscv64 -machine virt -smp 1 -m 128M -nographic -bios default -kernel zig-out/bin/kernel -s -S &
gdb-multiarch -q -ex 'set architecture riscv:rv64' -ex 'file zig-out/bin/kernel' -ex 'target remote :1234'
```

之后就是普通的 GDB。实际用过的命令：

```
(gdb) break vm.init                 # Zig 的函数名是“文件名.函数名”：main.kmain、vm.init、proc.scheduler、syscall.dispatch
(gdb) continue
(gdb) bt 3
#0  vm.init (memory=...) at src/vm.zig:73
#1  0x0000000080215ec2 in main.kmain (hartid=0, dtb_addr=2279604224) at src/main.zig:70
(gdb) print 'page.total_pages'      # 全局变量的名字里有点，要加单引号
$1 = 32020
(gdb) info registers scounteren     # CSR 也能读
(gdb) monitor info mem              # QEMU 监视器命令：当前 satp 下的所有映射（见 paging.md）
(gdb) x/2wx 0x87e00000              # 看内存（注意按小端显示）
(gdb) dump binary memory out.bin 0x87e00000 0x87e01516
(gdb) kill
```

- 只在 Debug 模式下有意义：release 模式的内核 ELF 不带符号表。
- 要和 shell 交互时，把喂输入的管道接在 QEMU 前面（`(sleep 2; printf 'run hello\r'; sleep 3) | qemu-system-riscv64 ... -s -S &`），GDB 断点设在想停的地方。
- 用户程序被 strip 过，没有符号；需要调试用户程序时可以临时去掉 `build.zig` 里的 `.strip = true`。
- 批处理模式（`-batch` 加一串 `-ex`）适合在脚本里取几个值，本仓库文档里的很多实测数字就是这样取得的。

### 查看 ELF

`llvm-readelf`、`llvm-objdump`、`llvm-nm`（或者 binutils 的 `riscv64-*-objdump` 等）：

```sh
llvm-readelf -S zig-out/bin/kernel          # 段的地址和大小：检查各段是否按页对齐、孤儿段落在哪里
llvm-readelf -l zig-out/bin/kernel          # 程序头：QEMU 按它加载
llvm-nm zig-out/bin/kernel | grep -E ' (__(text|rodata|data|bss|kernel)_|boot_stacks$)'   # 链接脚本里的符号和启动栈（Debug 模式）
llvm-objdump -d zig-out/bin/kernel | less   # 反汇编：确认内联汇编、编译器生成的代码
llvm-readelf -hl zig-out/user/hello       # 用户程序：入口地址、段布局
```

用户程序的入口地址是 0、或者没有 `LOAD` 段，说明 `_start` 没有被导出（见下表）。

### 设备树

```sh
qemu-system-riscv64 -machine virt,dumpdtb=virt.dtb -smp 4 -m 128M -nographic -bios default
dtc -I dtb -O dts virt.dtb
```

这是 QEMU 生成的原始版本。内核实际收到的版本（OpenSBI 改过）要用 GDB 从内存里导出来，见 [devicetree.md](devicetree.md#qemu-给的设备树长什么样)。

## 症状速查

都是这个项目里实际遇到过、或者按设计必然出现的情况：

| 症状 | 可能的原因 | 怎么查 |
| --- | --- | --- |
| `run` 一个程序就 `killed: instruction_page_fault at 0x0, stval=0x0` | 用户 ELF 的入口是 0：`_start` 没有导出（release 模式下尤其要注意） | `llvm-readelf -h` 看 `Entry point`；`_start` 必须在根文件 `user/start.zig` 里 |
| `KERNEL PANIC: page.free: 0x.. is already free` | 同一页释放了两次（引用数已经是 0）：多半是共用的页（写时复制）在某条路径上多放了一次引用，或者一页被两个地方当成自己的释放 | 对照 `page.share` 和 `page.free` 的调用，看是哪条路径（`destroyUserSpace`、`shrinkUser`、`breakCow`）多放了 |
| 进程结束后 `KERNEL PANIC: page.free: 0x.. was not handed out by the page allocator` | 切回调度器之后状态不对：典型的是调用 `switchContext` 之后的代码被优化掉了（单进程版本出过一次） | 只在 release 模式出现时，怀疑 `noreturn`、clobber、`volatile`；对照 `llvm-objdump -d` 看 `proc.scheduler` |
| 内核 `store_page_fault`，`stval` 在内核的代码或只读数据里 | 往只读段写了数据（W^X 生效了） | 用 `llvm-nm` 查 `stval` 落在哪个符号 |
| 内核 `load_page_fault`，`stval` 很小或是 0 | 空指针解引用 | `sepc` 对应的源码行：GDB 里 `info line *0x...` |
| 内核 `load/store_page_fault`，`stval` 在 `0x4000_0000..0x8000_0000` | 内核直接解引用了用户指针（`SUM` 是 0） | 改成 `vm.copyFromUser` / `vm.copyToUser` |
| 只有 OpenSBI 横幅，内核什么都没打印 | `_start` 不在 `0x8020_0000`，或者串口初始化之前就出错 | `llvm-readelf -S` 看 `.text` 起始；`-d int` 看第一个异常 |
| `cannot parse device tree at 0x...: <错误>` | 设备树格式不对，或者解析器有 bug | [devicetree.md](devicetree.md#错误) 的错误表；导出设备树用 `dtc` 看 |
| QEMU 卡住、`timeout` 返回 124 | 内核 panic 停机（看输出最后几行），或者死循环、陷阱风暴 | `-d int` 日志的最后几行 |
| `run` 完一个程序 `mem` 的数字变小了 | 有页没释放；或者有结束了的进程没人 `wait`（`ps` 里是 `zombie`） | 检查 `destroyUserSpace`、新加的分配路径；看 `ps` |
| `KERNEL PANIC: init exited` | init 结束了（被异常杀掉，或者 `main` 返回了） | 看 panic 前面打印的 `[proc] pid 1 (init) ...` |
| 有后台进程在转时 shell 卡住不动，或者空闲时 QEMU 占满一个 CPU 核 | 时钟预约了一个已经过去的时刻、处理完又预约它：比如时间片用完之后没有清掉 `slice_end`，调度器一开中断就又是一次时钟中断 | 看 `timer.onInterrupt`、`arm`；`kstat` 的 `timer_interrupts` 涨得飞快 |
| 内核 panic 停机后 QEMU 仍然占满一个 CPU 核 | `wfi` 被一直挂着的中断反复唤醒：停机前没有把 `sie` 清零 | 看 `kernelPanic` |
| 改了代码，运行结果却和改之前一样（或者出现早已修复的问题） | 这次构建失败了，手动运行的 QEMU 跑的是上一次的内核 | 看构建输出；手动运行时用 `zig build && qemu-system-riscv64 ...`，或者直接用 `qemu_test.py` |
| `KERNEL PANIC on hart N: kernel stack overflow: pid N (name)` 或 `... boot stack of hart N`，后面可能跟着 `hit its guard page at ...` | 内核栈（24 KiB）或启动栈（32 KiB）用到了最底下的金丝雀，或者越过栈底撞到了保护页：栈上放了大数组、按值传了大结构体，或者递归太深。Debug 模式下栈帧最大，最容易出现 | 看那个进程刚才在做哪个系统调用；`-Doptimize=debug` 下最容易复现。别的模式不出现不代表没问题 |
| `KERNEL PANIC on hart N: sched: 2 spinlocks held` | 拿着别的锁调用了 `sleep`/`yield`/`exit`（`sched` 只允许拿着进程自己的锁） | 看 panic 前在做什么；要拿着锁等待就用 `sleep(chan, lock)` |
| `KERNEL PANIC on hart N: acquire: lock X is already held by this hart` | 同一个 hart 重复拿同一把锁：比如拿着 `uart.lockOutput()` 又 `print`，或者 `wakeup` 时调用方拿着某个进程的锁 | 看 `X` 是哪把锁，对照 [process.md](process.md#锁) 的加锁顺序 |
| 多核时卡住不动，单核正常 | 推测是死锁：两个 hart 按相反的顺序拿两把锁（没有实际遇到过） | 对照 [process.md](process.md#锁) 的加锁顺序；GDB 看每个 hart 停在哪个 `acquire` 里 |
| 链接错误 `ld.lld: undefined symbol: a0`（或别的寄存器名） | 内联汇编里用 `"X"` 约束传了一个变量的地址（比如 `&boot_stacks`）：编译器先把地址算进一个寄存器，再把寄存器名代进 `la` 这类要符号的指令 | 把变量 `export` 出来，汇编里直接写符号名（[boot.md](boot.md#每个-hart-的启动栈)） |
| 编译错误 `unable to call function with calling convention 'naked'` | 直接调用了裸函数 | 在内联汇编里 `call`（[process.md](process.md#switchcontext)） |
| 编译错误 `unused argument in '...'` | `std.fmt.comptimePrint` 的参数结构体里有格式串用不到的字段 | 删掉多余字段，或者改用汇编操作数（如 `"i"` 约束） |
| 编译错误 `name shadows primitive 'u0'` | 变量名和原始类型重名：`u0`、`u1`、`i8` 这类“字母 u/i + 位宽”的名字都是整数类型 | 改名 |
| 编译错误 `file exists in modules 'sys' and 'program'` | 用户程序按路径 `@import("sys.zig")` | 改成 `@import("sys")` |
| 编译错误 `@ptrCast increases pointer alignment` | 指针转换后对齐要求变高 | 外面再套一层 `@alignCast(...)` |
| 构建输出里有 `error: warning(link): unexpected LLD stderr: ld.lld: warning: cannot find entry symbol _start`，构建树里对应的用户程序标着 `failure` | 原因同第一行。**注意**：实测这时 `zig build` 的退出码仍然是 0，内核照样生成，所以不能只看退出码，要看构建输出里有没有 `error:` | 同第一行 |
