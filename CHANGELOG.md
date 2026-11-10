# 变更记录

版本号遵循「主版本.次版本.修订号」，1.0 之前每次成批改动升次版本号。安装包版本以 `src/Info.plist` 的
`CFBundleShortVersionString` 为准，构建脚本原样拷入 `.app`。

## 0.4.8 — 2026-11-10

没有新功能，也没有用户可见的变化：把 1391 行的 `main.swift` 拆成 6 个文件，顺手把两个 action 升到 node24。

- **为什么拆**：`Core.swift` 早就是纯逻辑层，UI 却全挤在一个文件里。上次加「结果回收 + 工具菜单」时，改动分散在 6 个不相邻的位置，改完要靠肉眼确认没漏；再往上堆只会更难。
- **怎么拆**：`main.swift`（入口，只剩 `NSApplication` 启动与 `--selftest` 开关）、`AppShell.swift`（写临时 `.command`、`open` Terminal、旧文件清理、目录选择、`FlippedView`）、`AppDelegate.swift`（存储属性、生命周期、菜单、窗口构建、自测）、`CopyForm.swift`（表单构建、免密联想、远端浏览、表单快照）、`CopyRunner.swift`（参数校验、直连探测选路、启动、结果回收）、`SuggestionController.swift`（候选框）。
- **仍是同一个模块**：Swift 的 extension 不能加存储属性，所以 `AppDelegate` 的属性只能留在 `AppDelegate.swift`，互拷方法以两个 extension 的形式分出去；相应地 `buildCopySection`、`reloadSSHHostsIfNeeded` 从 `private` 放宽到 internal（`private` 在 Swift 里是文件级）。
- **没搬丢的证明**：把拆分前后所有非空行做多重集差，差异只有「原文件头注释被改写成各文件的头」和上面那两处 `private`，其余 1278 行一字不差。
- **构建脚本不再数文件**：`build.sh`、`package.sh`、CI 都改成 `swiftc -O src/*.swift`，以后加文件不用回来改三处。`test.sh` 仍只编 `Core.swift` + `tests/main.swift`，不牵扯 AppKit。
- **CI action 升级**：GitHub 已把 Node 20 标为弃用，`actions/checkout@v4 → @v7`、`softprops/action-gh-release@v2 → @v3`（后者 v3 的发布说明只有一句：runtime 从 Node 20 移到 24）。
- **验证**：断言仍是 362 条全绿；`build.sh` 编译安装 + ad-hoc 签名通过；GUI 冒烟（`--selftest --no-launch`）确认互拷控件、工具菜单、滚动布局、联想候选框都正常；`package.sh` 跑通 universal（arm64 + x86_64）DMG 与 zip。
- **文档**：`docs/03` 换成分文件后的分层表并说明「为什么跨文件方法不能 private」；`docs/05`/`README`/`docs/07` 的编译命令统一成 `src/*.swift`；`docs/06` 关闭 G-9。

## 0.4.7 — 2026-11-10

拷贝结果现在会自己回到窗口上，`~/Library` 里那两个目录也有菜单入口了。

- **状态栏不再永远停在「进行中…」**：拷贝跑在 Terminal 里（真 TTY 才能交互输密码），app 拿不到子进程的退出码。改为轮询日志新增内容：脚本层每次运行都会写「结束，退出码 N」，看到就回写「✅ 拷贝完成（退出码 0）」或「❌ 拷贝失败（退出码 N）· 菜单「工具 → 打开日志目录」看明细」。轮询期间只追加「已运行 12s」，不覆盖前面写的「走的哪条路」；超过 6 小时自动停。
- **必须记 offset**：日志按「源+目标」哈希复用，同一任务续传会追加多段。只读本次新增（`readNewText`），否则一点下去就会把上一次的退出码当成这一次的结果——这条有专门断言。
- **新增「工具」菜单**：打开日志目录、打开中转暂存目录、清除中转暂存…（先显示占用、说清后果再删）、打开配置文件。这四个目录都在 `~/Library` 和 `~/.config` 深处，让用户自己在 Finder 里翻等于没有。
- **冒烟入口**：`--selftest --selftest-copy` 会用 `last-copy.json` 里的路径真跑一次拷贝，14 秒后把状态栏内容写进调试日志，用来验「结果回收」这一跳（正常启动与普通 `--selftest` 都不会拷贝任何东西）。
- **测试 345 → 362 条**：`parseCopyLogOutcome`（无结束行 / 0 / 23 / 多段取最后 / rsync 明细不误判）、`readNewText`（从 0 读、带 offset 只读新增、offset 超长时退回、文件不存在不崩）、`humanSize`、`directorySizeBytes`。

## 0.4.6 — 2026-11-10

「经本机中转」这个按钮下线了：直连能不能走由程序自己测，测不通自动中转，用户只点一次「开始拷贝」。

- **为什么去掉按钮**：直连的前提是「源机 → 目标机」免密（0.4.5 的跨机实测结论），这件事界面上完全看不出来。把判断交给用户，等于让他先失败一次、再回头点第二个按钮；而按钮又常驻在操作行，本机↔远端时点了只会弹一句「只用于服务器↔服务器」。
- **改成后台探测**：源和目标都是远端时，点「开始拷贝」先在后台跑 `buildDirectProbeCommand` —— 外层 `ssh` 到源机，源机上先 `command -v rsync` 再 `ssh` 目标机 `true`，两层都是 `BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1`。任一不成立即判直连不通。
- **自动选路**（`resolveDirectRoute`，纯函数）：直连通 → 直连；不通但本机两端都登得上 → 两段 rsync（`buildRelayResumeCommand`，勾了续传且本机有可用 rsync）或 tar 流（未勾续传 / 本机没 rsync）；本机也到不了其中一端 → 状态栏直接报「两端都不可达」，不再起 Terminal。
- **不在别人服务器上留指纹**：探测故意**不加** `StrictHostKeyChecking=accept-new`，首次连接遇未知主机键就判不通（改走中转，功能不损失）。
- **顺带修一个只在别人机器上复现的隐患**：`hasRsync()` 原来只判「命令存在」，而 macOS 15 起 `/usr/bin/rsync` 是 openrsync —— 本机实测 `rsync: unrecognized option '--info=progress2'`，也不支持 `--log-file`。新增 `RsyncFlavor`（`none` / `openRsync` / `full`），`buildCopyCommand` 与 `buildRelayResumeCommand` 按能力决定是否拼这两个参数（`--partial-dir` 一律保留，续传不能丢），状态栏会提示「系统自带 openrsync」。
- **UI**：删掉「经本机中转」按钮与 `startRelayCopy`；探测期间「开始拷贝」置灰防连点，状态栏显示「检测直连：源机 → 目标机 …」，出结果后写清本次走法。
- **测试 311 → 345 条**：`parseRsyncFlavor`（openrsync / GNU / 空 / 认不出的实现）、`buildDirectProbeCommand`（BatchMode、超时、内层引号转义、端口透传、不含路径、不写 StrictHostKeyChecking、源机 rsync 前置）、`buildLocalProbeCommand`（端口位置、IPv6 去括号、空主机）、`resolveDirectRoute` 四态、openrsync 下两个拼装函数是否漏参数。
- **配置写出不再转义斜杠**：`JSONSerialization` 默认把每个 `/` 写成 `\/`，而这个文件里几乎全是 macOS 路径，首次生成的 `config.json` 就是 `"\/Users\/me\/git\/a"`，手改时既难读又容易漏改。新增 `encodeJSON`（`.withoutEscapingSlashes`），`ensureConfigExists` 与 `encodeCopyMemory` 统一切过去。两种写法是等价 JSON，老文件解析不受影响，可自行把 `\/` 换成 `/`。
- **实测**：容器 sshd 三态验证 —— 源机有 rsync 且免密 → `rc=0`（0.29s 判直连）；卸掉 rsync → `rc=127`（判不通 → 中转）；目标不可达 → `rc=255`（5.0s 超时退出，不卡 UI）。

## 0.4.5 — 2026-10-31

修掉「从 GitHub 下载后提示已损坏」的分发问题，并补上完整的打包与安装链路。

- **根因**：arm64 上链接器自动打的 ad-hoc 签名声明了「bundle 应带 `_CodeSignature/CodeResources`」，而手工组装的 `.app` 没有这个文件，`codesign` 报 `code has no resources but signature indicates they must be present`，Gatekeeper 据此判定「已损坏，应移到废纸篓」，且无法绕过。
- **修法**：新增 `scripts/sign-app.sh`，每次构建后给 bundle 补签名并立即 `codesign --verify --deep --strict` 校验，失败即中止构建。
  - 有 `Developer ID Application` 证书（或 `DEVELOPER_ID` 环境变量）时真签名，带 `--options runtime --timestamp`，可继续公证；
  - 无证书时 ad-hoc（`--sign -`），把「已损坏」变成可放行的「无法验证开发者」；
  - `--require-dev-id` 让缺证书时直接失败，防止 CI 里悄悄降级。
- **打包** `scripts/package.sh`：universal 编译（`arm64` + `x86_64` 各自编译后 `lipo`），产出 DMG（含 Applications 软链、`首次打开说明.txt`、`安装到应用程序文件夹.command`）、zip 与 `SHA256SUMS.txt`，全部落在 `dist/`。
  - 每次从干净目录组装：残留的 `Applications` 是符号链接，`ln -s` 会跟随进入真实 `/Applications`（实测踩到，已在脚本里规避）。
  - 有 Developer ID 时给 DMG 也签名，便于 `notarytool` + `stapler`。
- **一键安装** `scripts/install-remote.sh`：`curl | zsh`，下载 DMG → 挂载 → 拷到 `/Applications` → 清 `com.apple.quarantine` → 校验签名 → 打开。`curl` 不经过 LaunchServices 本就不打标记，装出来的应用双击即开、零提示。
  - 支持 `AI_LAUNCHER_VERSION` / `AI_LAUNCHER_MIRROR` / `AI_LAUNCHER_DEST_DIR` / `AI_LAUNCHER_NO_OPEN`（内网镜像、批量部署）。
  - `/Applications` 不可写时自动退到 `~/Applications`。
- **自动发布** `.github/workflows/release.yml`：推 `v*` 标签先跑测试，再打包并上传 `ai-launcher-<版本>.dmg`、`ai-launcher-latest.dmg`、`ai-launcher-<版本>.zip`、`SHA256SUMS.txt`（ASCII 名便于 URL 引用）。`ci.yml` 改为只跑分支，避免 tag 重复执行。
- **实测**（macOS 26.6.2）：
  - 两包同样打上 quarantine，旧包 `codesign --verify` 报 `code has no resources…`、`spctl` 同样报错；新包 `codesign --verify` 通过、`spctl` 仅 `rejected`；
  - 清标记后二进制可直接执行（`--selftest` 退出码 0）；
  - `lipo -archs` 为 `x86_64 arm64`；
  - 一键安装三种路径实跑：latest 安装、指定版本安装、不存在版本报错退出 1，装完 `xattr -p` 确认无 quarantine、签名校验通过；
  - DMG 内 `.command` 在模拟 quarantine 场景下安装成功并清除标记。
- **文档**：新增 [docs/08-分发与安装.md](docs/08-分发与安装.md)（原理、三种分发方式、打包、签名升级路径、公证步骤、排障表）。

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
