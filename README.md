# AI 终端启动器

macOS 本机 Dock 窗口应用：按「目录 × CLI」一键在 Terminal 启动（默认 `opencode` / `omp`），并附带本机↔服务器、服务器↔服务器的 rsync/scp 互拷。

源码与文档在本仓。安装产物是 `~/Applications/AI终端启动器.app`，运行时配置是 `~/.config/ai-launcher/config.json`，这两处都不进 Git。

## 要求

- macOS 13+
- Xcode Command Line Tools（`swiftc`）
- Terminal.app（用临时 `.command` 打开新窗口，不走辅助功能授权）
- 互拷建议本机已装 `rsync`（Homebrew 版）；macOS 自带的 `/usr/bin/rsync` 其实是 openrsync，没有单行进度与 rsync 明细日志（续传、限速不受影响），没有 rsync 则降级 `scp`——两种情况都会在状态栏提示
- 免密互拷依赖 `~/.ssh/config` 与已安装的公钥

## 编译安装

```bash
chmod +x scripts/build.sh
./scripts/build.sh
```

会把二进制写入 `~/Applications/AI终端启动器.app` 并打开。首次缺配置时，应用会按源码内置缺省写出 `~/.config/ai-launcher/config.json`。

从旧版本升级：改名前的 `AI启动器菜单栏.app` 会在构建成功后自动移入废纸篓；配置路径不变，无需迁移。

把 [config.example.json](config.example.json) 拷到该路径后按自己的目录与主机改，不要把真实配置提交进本仓。

## 装到别人的机器上

本仓没有 Apple 开发者证书，产物是 ad-hoc 签名。**直接双击下载的 `.app` 会被 Gatekeeper 拦**（旧版本还会报「已损坏」），按下面任一种方式装则没有任何提示：

```bash
# 方式一：命令行安装（推荐）
curl -fsSL https://raw.githubusercontent.com/lcw918110/ai-launcher/main/scripts/install-remote.sh | zsh

# 方式二：手动装 DMG 后清隔离标记
xattr -dr com.apple.quarantine "/Applications/AI终端启动器.app"
```

自己打包分发：

```bash
./scripts/package.sh        # → dist/AI终端启动器-<版本>.dmg / .zip / SHA256SUMS.txt
```

产物是 universal（arm64 + x86_64）。推 `v*` 标签时 GitHub Actions 会自动构建并挂到 Release。原理、签名升级到 Developer ID、公证步骤与排障见 [docs/08-分发与安装.md](docs/08-分发与安装.md)。

## 日常使用

1. 打开「AI终端启动器」，窗口里每个目录一行，点 CLI 名称即在该目录启动。项目多时窗口可滚动、可拉伸。
2. 「其他目录」可选任意文件夹再启动。
3. 改完 `config.json` 后点「刷新」即可，不必重编译（已填的互拷表单会保留）。
4. 窗口下方「互拷」：填源/目标路径（本地绝对路径或 `user@host:path`），粘贴连接串后点「解析」（结果补进一个路径框，凭据行只读展示）、从免密联想选主机、逐层浏览远端目录；选项只有保留属性 / 断点续传 / 限速（递归恒定），点「开始拷贝」在 Terminal 看进度。
5. 服务器↔服务器不用你选路：点「开始拷贝」后先自动探测直连（源机有 `rsync` 且**免密可达目标机**），通了走直连；不通自动改走本机中转——勾选「断点续传」走两段 rsync（源机→本机暂存→目标机，中断可续，占本地磁盘），未勾选走 tar 流（不占盘、不可续）。状态栏会写明本次走了哪条。
6. 「断点续传」默认勾选，直连（本机↔远端、远端↔远端）与中转都支持：中断后半截文件在目标侧 `.rsync-partial/`，最终路径不出现残缺文件，原样再执行一次即从断点补齐。
7. 上次的源/目标/选项会在启动时自动回填（关掉 app 再开也不用重填）；每次拷贝都写日志到 `~/Library/Logs/ai-launcher/`；大文件可在「限速」填 MB/s 避免打满专线。

细则见 [docs/04-使用说明.md](docs/04-使用说明.md)。文档总入口：[docs/README.md](docs/README.md)。

## 项目结构

| 路径 | 说明 |
|------|------|
| `src/Core.swift` | 纯逻辑层（仅 Foundation）：连接串解析、路径/主机拆分、互拷命令拼装、配置读写、`~/.ssh/config` 解析、Terminal 启动脚本生成 |
| `src/main.swift` | 入口：`NSApplication` 启动 + `--selftest` 开关 |
| `src/AppShell.swift` | 无状态 UI 辅助：临时 `.command` 脚本、`open` Terminal、目录选择 |
| `src/AppDelegate.swift` | 窗口、滚动视图、菜单（含「工具」）、生命周期 |
| `src/CopyForm.swift` / `src/CopyRunner.swift` | 互拷表单（含联想与远端浏览）/ 互拷执行（探测选路与结果回收） |
| `src/SuggestionController.swift` | 免密主机候选框 |
| `tests/main.swift` | Core 全量断言用例（纯命令行，无 GUI 副作用，条数见 [docs/05](docs/05-测试与验收.md)） |
| `scripts/build.sh` / `scripts/test.sh` | 编译安装 / 跑测试 |
| `scripts/check-docs.sh` | 校验文档与代码一致（版本号、断言数），CI 必跑 |
| `scripts/package.sh` / `scripts/sign-app.sh` | 打 DMG 与 zip（universal）/ 给 `.app` 签名（Developer ID 或 ad-hoc） |
| `scripts/install-remote.sh` | 给他人用的一键安装（下载 → 装 → 清 quarantine） |
| `.github/workflows/ci.yml` / `release.yml` | CI：编译 + 跑测试 / 推 tag 自动打包发布 |
| `LICENSE` / `CHANGELOG.md` | MIT 许可 / 版本改动记录（当前 0.5.2） |

## 测试

```bash
./scripts/test.sh
```

覆盖连接串全格式（含 `IP:端口` 回归）、命令拼装（含自定义端口 `-e "ssh -p N"`、tar 中转与可续传中转、限速换算、日志参数位置）、启动脚本（含 `zsh -n` 语法校验、按 tty 关窗、日志起止记录）、任务记忆读写、远端路径导航、IPv6、`pathPrepend`、填充决策、配置读写、免密主机解析等全套断言，失败返回非 0，可直接进 CI。

GUI 冒烟（可选；加 `--no-launch` 不会弹 Terminal）：

```bash
swiftc -O src/*.swift -o /tmp/ai-launcher-selftest
/tmp/ai-launcher-selftest --selftest --no-launch
```

约 6 秒后自动退出。日志写 `/tmp/ai-launcher-debug.log`。细则见 [docs/05-测试与验收.md](docs/05-测试与验收.md)。

## 不进本仓

| 路径 | 原因 |
|------|------|
| `~/Applications/AI终端启动器.app` | 本机安装产物 |
| `~/.config/ai-launcher/config.json` | 含本机目录与主机 |
| `~/.ssh/config` 与私钥 | 免密主机清单，不入库 |
| 编译出的二进制 | 由 `scripts/build.sh` 生成 |

## 许可

[MIT](LICENSE) © 2026 lcw918110
