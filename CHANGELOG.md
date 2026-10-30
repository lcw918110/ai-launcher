# 变更记录

版本号遵循「主版本.次版本.修订号」，1.0 之前每次成批改动升次版本号。安装包版本以 `src/Info.plist` 的
`CFBundleShortVersionString` 为准，构建脚本原样拷入 `.app`。

## 0.4.4 — 2026-10-30

续传的配套三件事：断了能接上（记住上次任务）、断了能复盘（日志落盘）、别把专线打满（限速）。

- **记住上次任务**：新增 `~/.config/ai-launcher/last-copy.json`，记录源/目标/递归/保留属性/续传/限速。
  - 启动时若源和目标都为空就自动回填，状态栏提示「已回填上次任务，再点「开始拷贝」即从断点继续」。
  - 续传要求「源/目标不变、再点一次」，之前重启 app 表单是空的，等于续不上——这才是续传真正卡住的地方。
  - 单独存文件而不是写回 `config.json`：config 是手写的，程序不该去改它的格式。只存路径与选项，密码仍然从不落盘。
- **传输日志落盘**：`~/Library/Logs/ai-launcher/<源名>-<哈希>.log`，同一对源/目标固定同名，续传的多次运行会追加到一起。
  - rsync 侧用 `--log-file`（客户端自己写，不经过管道，因此不干扰 ssh 的交互式密码输入）；
  - 脚本侧另记 `[时间] 开始 <源 → 目标>` / `[时间] 结束，退出码 N`；
  - 双远端直拷在源机执行，本机日志路径在源机不一定存在，故只记脚本层的时间与退出码；tar 流中转同理。
  - 状态栏会显示日志文件名。
- **限速**：互拷选项行加「限速 ___ MB/s」，留空不限。rsync 走 `--bwlimit`（换算成 KiB/s），scp 降级走 `-l`（Kbit/s = KiB/s × 8）；tar 流中转没有对应参数，界面说明里标注了。
  - 非法输入（字母、负数、多个小数点）直接报错，不静默当成「不限速」——否则用户以为限了其实没限。
- **实测**（Docker + sshd + rsync 3.4.3）：
  - 限速 2 MB/s 跑 6 秒后打断，`sent 12503969 bytes`，即 2.08 MB/s，与设定一致；
  - 中断现场仍是 `.rsync-partial/data.bin`，最终路径无残缺文件；
  - 日志 6 行包含两次运行（第一次 `rsync error: received SIGINT`，第二次成功），重跑 `sent 50459070 bytes` 只补剩余，md5 与源一致；
  - 脚本层日志实测：成功记 `退出码 0`，失败记 `退出码 23` 并把 23 透出给 Terminal。
- **测试 261 → 311 条**：限速解析（含 `1e3`/负数/多小数点拒绝）、日志参数位置与双远端不加本机日志、中转两段各带一次日志与限速、`safeFileComponent`、`copyLogPath` 稳定性、`CopyMemory` 往返与损坏回退、带日志脚本的 `zsh -n` 与含单引号摘要。

## 0.4.3 — 2026-10-30

直连互拷的断点续传改成和可续传中转同一套实现，修掉「中途失败会在目标路径留下残缺文件」的隐患。

- **直连续传改用 `--partial-dir`**：`buildCopyCommand` 的 push / pull / 双远端直拷三条路径，续传参数由
  `--partial --append-verify` 换成 `--partial --partial-dir=.rsync-partial`，与 `buildRelayResumeCommand` 统一。
  - 旧参数实测后果：200 MB 文件限速 2 MB/s、6 秒后中断，目标路径直接出现一个 11.6 MB 的 `big.bin`——
    文件名正确、大小不对，后续脚本或人一看「文件在」就会误判传完。
  - 新参数：半截文件落在目标侧 `.rsync-partial/` 里，最终路径不出现任何文件，重跑时 rsync 以它为基底做增量。
  - 另一个理由：`--append-verify` 假设目标文件是源文件的前缀，目标被改短时会先追加一段垃圾再靠校验发现，
    大文件等于白传一遍；`--partial-dir` 走的是滚动校验增量，只补真正缺的字节。
- **真实链路实测**（Docker + openssh + rsync 3.4.3，非本机模拟）：200 MB 随机文件限速 2 MB/s，6 秒打断 →
  `.rsync-partial/big.bin` 11.8 MB、最终路径为空；重跑 `Matched data 11,826,672` / `Literal data 197,888,528`，
  即只补了剩下的 197.9 MB；md5 与源一致；成功后 `.rsync-partial` 自动清空。
- **测试 249 → 261 条**：为推送、拉取、双远端直拷三条路径分别断言续传时带 `--partial-dir`、不带 `--append-verify`，
  以及不勾续传时不留任何 `--partial` 参数。

## 0.4.2 — 2026-10-30

测试补全 + 真实链路验证发现的两个中转 bug。

- **修续传式中转目标目录不存在就失败**：`rsync` 不会创建缺失的父目录，实测报 `mkdir "/tmp/dst2/data" failed: No such file or directory`。改为 `--rsync-path='mkdir -p <目标目录> && rsync'`，目标参数带尾斜杠。
- **统一两种中转的落点规则**（tar 流与续传式之前不一致）：
  - 目标末段与源名相同（`/data/report` → `/backup/report`）：结果就是 `/backup/report`
  - 末段不同名（`/data/report` → `/backup`）：目标当容器，结果 `/backup/report`
  - 两条路径都幂等，重复执行只同步，不会套娃成 `report/report`
- **测试 195 → 249 条**：补齐此前没断言的 8 个 Core 函数（`dirLabel`、`sshConfigPath`、`fileModificationDate`、`remoteHostSepIndex`、`shortHash`、`relayStagingRoot`、`relayStagingDir` 边界、`hasRsync`、`debugLog`），并新增落点规则的回归断言。
- **顺带**：`relayStagingDir` 源为 `/` 时不再生成 `.-<哈希>` 的隐藏暂存目录。

## 0.4.1 — 2026-10-30

中转可断点续传（G-15）。

- **可续传中转**：新增 `buildRelayResumeCommand`。勾选「断点续传」且本机有 `rsync` 时，「经本机中转」改为两段式：源机 → 本机暂存 → 目标机；中断后再点一次同一任务即从断点继续。
- **稳定暂存目录**：`~/Library/Caches/ai-launcher/relay/<源文件名>-<源+目标哈希>`，同一对源/目标永远同名才能续传；成功后自动删除，失败保留。
- **续传实现**：`--partial --partial-dir=.rsync-partial`（以半截文件为基底做增量），不用 `--append-verify`，避免目标文件被改短时写坏。
- 未勾选「断点续传」或本机没有 `rsync` 时，仍走原来的 tar 流（不占本地磁盘、不可续传），状态栏会说明是哪种模式。
- 顺带修：直拷分支的 `ssh` 目标机名去掉 IPv6 方括号（之前 `user@[::1]` 会传给 ssh）。
- 测试 181 → **195 条**（新增可续传中转的 12 条：两段结构、`--partial-dir`、暂存目录稳定性、端口透传、非法输入）。

## 0.4.0 — 2026-10-30

待办清单（G-4 ~ G-13）批量落地。

- **窗口**：内容放进 `NSScrollView`，窗口可缩放；刷新改用 `setContentSize` 并夹回屏幕可见区，修掉「刷新后窗口被甩到左下角、内容顶出屏幕底部」。
- **免密联想**：`NSMenu.popUp` 换 `NSPopover` + `NSTableView`，不再抢占键盘；0.15 s 去抖，↑↓/回车/Tab/Esc 可操作；`~/.ssh/config` mtime 变化自动重载清单。
- **PATH 可配置**：新增配置项 `pathPrepend`（缺省 `~/.bun/bin`、`/opt/homebrew/bin`、`/usr/local/bin`），启动脚本不再硬编码。
- **互拷预设**：互拷区加「预设」下拉，数据源 `copy.hosts`，选中即填连接串 / 主机 / 用户名。
- **精确关窗**：启动脚本记录 `$(tty)`，拷贝成功后只关该 tty 所在 Terminal 窗口，匹配不到就不关。
- **本机中转**：「经本机中转」按钮 + `buildRelayCopyCommand`，用 `tar` 流经本机中转，不占本地磁盘、不依赖源机 `rsync`。
- **远端浏览导航**：对话框支持「进入下一层 / 选为路径 / 上一级 / 取消」，仍为后台执行不卡 UI。
- **IPv6**：支持 `[::1]:2222`、`user@[::1]:path`、裸 `::1` 填主机框。
- **改名收尾**：`AI启动器菜单栏` → `AI终端启动器`，bundle id 改 `local.ai-launcher.desktop`，旧 `.app` 由构建脚本移入废纸篓。
- **工程**：`buildCommandScript` 抽到 Core，测试用 `zsh -n` 校验生成脚本；断言 124 → 181 条；编译零警告；补 MIT LICENSE 与本文件。
- **脱敏**：测试与注释中的内网地址、真实用户名、演示密码统一换成 RFC 5737 文档地址与假值。

## 0.3.0 — 2026-10-29

- 拆层：`src/Core.swift`（纯逻辑，Foundation only）+ `src/main.swift`（AppKit UI）。
- 测试基建：`tests/main.swift` 124 条断言、`scripts/test.sh`、GitHub Actions CI；`--selftest` 降为 GUI 冒烟并支持 `--no-launch`。
- 修复 13 项审查问题：`IP:端口` 误解析为用户名；rsync/scp 不支持 `user@host:port:path`（自定义端口互拷从不可用变为可用，含双远端直拷）；`sshListDir` 管道死锁；浏览远端阻塞主线程；日志明文密码；刷新丢表单；缺省配置写死本机路径；死配置字段；`buildCopyCommand` 内藏子进程探测；scp 降级静默丢断点续传；`build.sh` 不更新 Info.plist 且 `pkill -f` 易误杀。
- 建立首次 git 提交，仓库公开于 GitHub，CI 通过。

## 0.2.0 — 2026-10-29

- 修「浏览远端弹不出目录」：`sshListDir` 把 `~` 包进单引号，远端 shell 不展开，`ls '~'` 必然失败；新增 `remotePathArg`（`~` 裸写、`~/x` 拼成 `~'/x'`）。
- 顺带修同函数「先 `waitUntilExit` 再读管道」在输出超过 64 KB 时的死锁。

## 0.1.0 — 2026-10-29

- 基线：目录 × CLI 一键启动、`.command` 启 Terminal（免 TCC 授权）、rsync/scp 互拷四向、连接串多格式解析、免密主机联想、远端 `ls` 选择。
