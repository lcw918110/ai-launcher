// Core 逻辑层全量测试（无 GUI 副作用，可进 CI）
// 运行：./scripts/test.sh  或
//   swiftc -O src/Core.swift tests/main.swift -o /tmp/ai-launcher-core-tests && /tmp/ai-launcher-core-tests
import Foundation

// —— 测试骨架 ——
var passCount = 0
var failures: [String] = []

func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want {
        passCount += 1
        print("PASS \(label)")
    } else {
        failures.append(label)
        print("FAIL \(label)\n      got  = \(got)\n      want = \(want)")
    }
}

func expectTrue(_ cond: Bool, _ label: String, _ detail: String = "") {
    if cond {
        passCount += 1
        print("PASS \(label)")
    } else {
        failures.append(label)
        print("FAIL \(label) \(detail)")
    }
}

// ============================================================
// 1. looksLikeHost
// ============================================================
expectTrue(looksLikeHost("192.168.1.5"), "looksLikeHost: 纯 IPv4")
expectTrue(looksLikeHost("example.com"), "looksLikeHost: 域名")
expectTrue(!looksLikeHost("user@host"), "looksLikeHost: 含 @ 不是主机")
expectTrue(!looksLikeHost("host:2222"), "looksLikeHost: 含 : 不是主机")
expectTrue(!looksLikeHost(""), "looksLikeHost: 空串")
expectTrue(!looksLikeHost("hostname"), "looksLikeHost: 无点主机名按非主机处理")

// ============================================================
// 2. splitHostPort
// ============================================================
expectEqual(splitHostPort("host").host, "host", "splitHostPort: 无端口 host")
expectTrue(splitHostPort("host").port.isEmpty, "splitHostPort: 无端口 port 为空")
expectEqual(splitHostPort("host:2222").host, "host", "splitHostPort: 带端口 host")
expectEqual(splitHostPort("host:2222").port, "2222", "splitHostPort: 带端口 port")
expectEqual(splitHostPort("192.168.1.5").host, "192.168.1.5", "splitHostPort: 纯 IP")
expectTrue(splitHostPort("192.168.1.5").port.isEmpty, "splitHostPort: 纯 IP 无端口")
expectEqual(splitHostPort("user@host:2222").host, "user@host", "splitHostPort: user@host:port host")
expectEqual(splitHostPort("user@host:2222").port, "2222", "splitHostPort: user@host:port port")

// ============================================================
// 3. parseConnection（全格式 + 回归）
// ============================================================
func pc(_ s: String) -> ConnectionInfo { parseConnection(s) }

var r = pc("user@host")
expectEqual(r.user, "user", "parse user@host: user")
expectEqual(r.host, "host", "parse user@host: host")

r = pc("user:password@host")
expectEqual(r.user, "user", "parse user:pass@host: user")
expectEqual(r.password, "password", "parse user:pass@host: pass")
expectEqual(r.host, "host", "parse user:pass@host: host")

r = pc("ssh://user@host")
expectEqual(r.user, "user", "parse ssh://user@host: user")
expectEqual(r.host, "host", "parse ssh://user@host: host")

r = pc("ssh://user:password@host")
expectEqual(r.user, "user", "parse ssh://user:pass@host: user")
expectEqual(r.password, "password", "parse ssh://user:pass@host: pass")

r = pc("host")
expectEqual(r.host, "host", "parse 纯主机名")
expectTrue(r.user.isEmpty, "parse 纯主机名: 无用户")

r = pc("user@host:2222")
expectEqual(r.host, "host", "parse user@host:port: host")
expectEqual(r.port, "2222", "parse user@host:port: port")

r = pc("192.0.2.101")
expectEqual(r.host, "192.0.2.101", "parse 纯 IP")

// 回归（曾把端口解析成用户名的 bug）
r = pc("192.168.1.5:2222")
expectEqual(r.host, "192.168.1.5", "parse IP:端口: host")
expectEqual(r.port, "2222", "parse IP:端口: port")
expectTrue(r.user.isEmpty, "parse IP:端口: 用户名应为空")

r = pc("host:2222")
expectEqual(r.host, "host", "parse host:端口: host")
expectEqual(r.port, "2222", "parse host:端口: port")
expectTrue(r.user.isEmpty, "parse host:端口: 用户名应为空")

// 主机在前格式（Excel 复制常见）
r = pc("192.0.2.102\tuser/S3cret@pass!")
expectEqual(r.host, "192.0.2.102", "parse tab 分隔: host")
expectEqual(r.user, "user", "parse tab 分隔: user")
expectEqual(r.password, "S3cret@pass!", "parse tab 分隔: pass")

r = pc("192.0.2.102 user/S3cret@pass!")
expectEqual(r.user, "user", "parse 空格分隔: user")
expectEqual(r.password, "S3cret@pass!", "parse 空格分隔: pass")

r = pc("192.0.2.102:user:S3cret@pass!")
expectEqual(r.host, "192.0.2.102", "parse 冒号分隔: host")
expectEqual(r.user, "user", "parse 冒号分隔: user")
expectEqual(r.password, "S3cret@pass!", "parse 冒号分隔: pass")

r = pc("192.0.2.102|user|S3cret@pass!")
expectEqual(r.user, "user", "parse 竖线分隔: user")
expectEqual(r.password, "S3cret@pass!", "parse 竖线分隔: pass")

r = pc("192.0.2.102,user/S3cret@pass!")
expectEqual(r.user, "user", "parse 逗号分隔: user")
expectEqual(r.password, "S3cret@pass!", "parse 逗号分隔: pass")

r = pc("192.0.2.102 user")
expectEqual(r.user, "user", "parse 仅主机+用户")
expectTrue(r.password.isEmpty, "parse 仅主机+用户: 无密码")

r = pc("example.com")
expectEqual(r.host, "example.com", "parse 纯域名")

// 密码含 @：按最后一个 @ 拆分
r = pc("user:P@ss@host")
expectEqual(r.user, "user", "parse 密码含@: user")
expectEqual(r.password, "P@ss", "parse 密码含@: pass")
expectEqual(r.host, "host", "parse 密码含@: host")

r = pc("ssh://user:pa@ss@host/")
expectEqual(r.user, "user", "parse ssh://密码含@: user")
expectEqual(r.password, "pa@ss", "parse ssh://密码含@: pass")
expectEqual(r.host, "host", "parse ssh://密码含@: host")

r = pc("")
expectTrue(r.host.isEmpty && r.user.isEmpty, "parse 空串返回全空")

// ============================================================
// 4. buildHostSpec
// ============================================================
expectEqual(buildHostSpec(ConnectionInfo(user: "user", password: "", host: "192.168.1.5", port: "")),
            "user@192.168.1.5", "buildHostSpec: 无端口")
expectEqual(buildHostSpec(ConnectionInfo(user: "user", password: "", host: "192.168.1.5", port: "2222")),
            "user@192.168.1.5:2222", "buildHostSpec: 带端口")
expectEqual(buildHostSpec(ConnectionInfo(user: "", password: "", host: "h", port: "")),
            "h", "buildHostSpec: 无用户")

// ============================================================
// 5. shellQuote / remotePathArg / maskSecret
// ============================================================
expectEqual(shellQuote("a b"), "'a b'", "shellQuote: 空格")
expectEqual(shellQuote("a'b"), "'a'\\''b'", "shellQuote: 单引号")

// 回归（~ 被引号包住导致远端 ls 找不到目录的 bug）
expectEqual(remotePathArg("~"), "~", "remotePathArg: ~ 必须裸写")
expectEqual(remotePathArg("~/data"), "~'/data'", "remotePathArg: ~/data 波浪号裸写+引号拼接")
expectEqual(remotePathArg("/home/user"), "'/home/user'", "remotePathArg: 绝对路径")
expectEqual(remotePathArg("my dir"), "'my dir'", "remotePathArg: 含空格")
expectEqual(remotePathArg(""), "''", "remotePathArg: 空串")

expectEqual(maskSecret(""), "", "maskSecret: 空串原样")
expectEqual(maskSecret("secret"), "***", "maskSecret: 非空脱敏")

// ============================================================
// 6. isRemotePath / splitRemotePath / splitRemoteSpec
// ============================================================
expectTrue(!isRemotePath("/Users/me/data"), "isRemotePath: 本地绝对路径")
expectTrue(isRemotePath("user@host:/home/data"), "isRemotePath: user@host:path")
expectTrue(isRemotePath("host:path"), "isRemotePath: host:path")
expectTrue(!isRemotePath("plain"), "isRemotePath: 相对路径无冒号")
expectTrue(!isRemotePath("a/b:c"), "isRemotePath: 冒号前含斜杠视为本地")

let srp = splitRemotePath("user@host:/p")
expectEqual(srp?.host, "user@host", "splitRemotePath: host")
expectEqual(srp?.path, "/p", "splitRemotePath: path")
expectTrue(splitRemotePath("nocolon") == nil, "splitRemotePath: 无冒号返回 nil")

// 「解析」把 host 前缀补进路径框：空 / 本地路径 / 已是远端（幂等）
expectEqual(applyHostToPath("", hostSpec: "jykj@192.0.2.9"), "jykj@192.0.2.9:",
            "applyHostToPath: 空路径只留 host 前缀与冒号")
expectEqual(applyHostToPath("/Users/me/data", hostSpec: "jykj@192.0.2.9"), "jykj@192.0.2.9:/Users/me/data",
            "applyHostToPath: 本地绝对路径加前缀")
expectEqual(applyHostToPath("~/logs/", hostSpec: "jykj@192.0.2.9"), "jykj@192.0.2.9:~/logs/",
            "applyHostToPath: 相对/家目录路径加前缀")
expectEqual(applyHostToPath("old@h:/data", hostSpec: "jykj@192.0.2.9:2200"), "jykj@192.0.2.9:2200:/data",
            "applyHostToPath: 远端路径只换 host、保留原路径")
expectEqual(applyHostToPath("jykj@192.0.2.9:2200:/data", hostSpec: "jykj@192.0.2.9:2200"),
            "jykj@192.0.2.9:2200:/data", "applyHostToPath: 重复解析结果不变（幂等）")

let srs = splitRemoteSpec("user@192.168.1.5:2222:/data")
expectEqual(srs?.host, "user@192.168.1.5", "splitRemoteSpec: host（含端口时拆出）")
expectEqual(srs?.port, "2222", "splitRemoteSpec: port")
expectEqual(srs?.path, "/data", "splitRemoteSpec: path")
let srs2 = splitRemoteSpec("user@host:/p")
expectEqual(srs2?.host, "user@host", "splitRemoteSpec: 无端口 host")
expectTrue(srs2?.port.isEmpty ?? false, "splitRemoteSpec: 无端口 port 为空")
expectEqual(srs2?.path, "/p", "splitRemoteSpec: 无端口 path")
expectTrue(splitRemoteSpec("plain") == nil, "splitRemoteSpec: 无冒号返回 nil")

// ============================================================
// 7. deriveDirection
// ============================================================
expectEqual(deriveDirection(src: "/Users/me/data", dst: "user@h:/home/data"), "push", "deriveDirection: 本机→远端")
expectEqual(deriveDirection(src: "user@h:/home/data", dst: "/Users/me/data"), "pull", "deriveDirection: 远端→本机")
expectEqual(deriveDirection(src: "user@h:/a", dst: "u@h2:/b"), "direct", "deriveDirection: 双远端直拷")
expectEqual(deriveDirection(src: "/a", dst: "/b"), "local", "deriveDirection: 双本机")

// ============================================================
// 8. buildCopyCommand（命令拼装 + 自定义端口 + scp 降级）
// ============================================================
let cfg = CopyConfig(defaultFlags: [])
func cmd(_ source: String, _ target: String,
         recursive: Bool = true, preserveAttrs: Bool = true, resume: Bool = true,
         rsync: Bool = true) -> String {
    buildCopyCommand(cfg: cfg, params: CopyParams(
        source: source, target: target,
        recursive: recursive, preserveAttrs: preserveAttrs, resume: resume),
        rsyncAvailable: rsync)
}

expectEqual(cmd("/Users/me/data", "user@192.0.2.101:/home/user/data"),
            "rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 '/Users/me/data' 'user@192.0.2.101:/home/user/data'",
            "buildCopyCommand: push 全选项")

expectEqual(cmd("/Users/me/data", "user@192.168.1.5:2222:/data"),
            "rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 -e 'ssh -p 2222' '/Users/me/data' 'user@192.168.1.5:/data'",
            "buildCopyCommand: push 自定义端口走 -e ssh -p（回归）")

expectEqual(cmd("user@192.168.1.5:2222:/data/x", "/Users/me/data", rsync: false),
            "scp -r -p -P 2222 'user@192.168.1.5:/data/x' '/Users/me/data'",
            "buildCopyCommand: pull 无 rsync 降级 scp -P（回归）")

expectEqual(cmd("user@192.0.2.101:/home/data", "/Users/me/data"),
            "rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 'user@192.0.2.101:/home/data' '/Users/me/data'",
            "buildCopyCommand: pull 默认端口")

// 直拷：ssh 到源机执行 rsync，源机端口走 ssh -p，目标机端口走内层 -e "ssh -p"
expectEqual(cmd("user@192.168.1.5:2222:/data/a", "user@192.168.1.6:2200:/data/b"),
            "ssh -t -p 2222 'user@192.168.1.5' 'rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 -e '\\''ssh -p 2200'\\'' '\\''/data/a'\\'' '\\''user@192.168.1.6:/data/b'\\'''",
            "buildCopyCommand: 双远端直拷+双端口")

expectEqual(cmd("user@h1:/a", "user@h2:/b"),
            "ssh -t 'user@h1' 'rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 '\\''/a'\\'' '\\''user@h2:/b'\\'''",
            "buildCopyCommand: 双远端直拷默认端口")

expectEqual(cmd("/Users/me/a", "/Users/me/b", recursive: true, preserveAttrs: false, resume: false),
            "rsync -r --info=progress2 '/Users/me/a' '/Users/me/b'",
            "buildCopyCommand: 本地拷贝最小选项")

expectEqual(cmd("/Users/me/my data", "user@h:/tmp/x y", recursive: false, preserveAttrs: false, resume: false),
            "rsync --info=progress2 '/Users/me/my data' 'user@h:/tmp/x y'",
            "buildCopyCommand: 路径含空格正确加引号")

// 注：isRemotePath 为真时 splitRemoteSpec 必然可解析，故「解析失败返回空」不可达；
// 这里改为覆盖「双远端但缺路径」的边界：host: 后为空路径仍应产出合法直拷命令
expectEqual(cmd("user@h1:/a", "user@h2:"),
            "ssh -t 'user@h1' 'rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 '\\''/a'\\'' '\\''user@h2:'\\'''",
            "buildCopyCommand: 双远端空路径仍可拼命令")

// 续传语义：三条路径（push / pull / 双远端直拷）都必须用 --partial-dir，且不得出现 --append-verify
for (label, c) in [
    ("push", cmd("/Users/me/data", "user@h:/data")),
    ("pull", cmd("user@h:/data", "/Users/me/data")),
    ("双远端", cmd("user@h1:/a", "user@h2:/b")),
] {
    expectTrue(c.contains("--partial-dir=.rsync-partial"), "续传@\(label): 半截文件落 .rsync-partial，不污染最终路径")
    expectTrue(c.contains("--partial "), "续传@\(label): 带 --partial 才会保留中断现场")
    expectTrue(!c.contains("--append-verify"), "续传@\(label): 禁用 append-verify（目标被改短会写坏）")
}
// 不勾续传时不能残留任何续传相关的 partial 参数（否则中断会留下隐藏目录）
for (label, c) in [
    ("push", cmd("/Users/me/data", "user@h:/data", resume: false)),
    ("pull", cmd("user@h:/data", "/Users/me/data", resume: false)),
    ("双远端", cmd("user@h1:/a", "user@h2:/b", resume: false)),
] {
    expectTrue(!c.contains("--partial"), "不续传@\(label): 无 --partial")
}

// ============================================================
// 9. buildFillPlan（填充决策六场景，覆盖串框 bug 回归）
// ============================================================
let spec = "user@192.0.2.102"
var p = buildFillPlan(trigger: .target, spec: spec,
                      sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.targetValue, "\(spec):", "fillPlan 场景1: 目标框触发-都空 → 填目标框")
expectEqual(p.hostValue, "192.0.2.102", "fillPlan 场景1: 联动填主机")
expectEqual(p.userValue, "user", "fillPlan 场景1: 联动填用户")
expectTrue(p.sourceValue == nil && p.connValue == nil, "fillPlan 场景1: 不串到其他框")

p = buildFillPlan(trigger: .source, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.sourceValue, "\(spec):", "fillPlan 场景2: 源框触发-都空 → 填源框")

p = buildFillPlan(trigger: .conn, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.connValue, spec, "fillPlan 场景3: 连接串框触发 → 填连接串框")

p = buildFillPlan(trigger: .host, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.hostValue, "192.0.2.102", "fillPlan 场景4: IP框触发 → 填主机框")
expectEqual(p.userValue, "user", "fillPlan 场景4: 联动填用户框")
expectTrue(p.sourceValue == nil && p.targetValue == nil, "fillPlan 场景4: 不动路径框")

p = buildFillPlan(trigger: .none, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.sourceValue, "\(spec):", "fillPlan 场景5: 无触发-源空 → 兜底填源")

p = buildFillPlan(trigger: .target, spec: spec,
                  sourceEmpty: false, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.targetValue, "\(spec):", "fillPlan 场景6: 目标框触发-源已填 → 仍填目标框不串源")

// ============================================================
// 10. 配置读写（合法 / 损坏 JSON / 废弃键兼容 / 缺省去本机化）
// ============================================================
let tmpDir = NSTemporaryDirectory() + "ai-launcher-tests-\(UUID().uuidString)"
try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

// 合法配置
let goodPath = tmpDir + "/good.json"
let goodJSON = """
{
  "dirs": ["/a", "/b"],
  "tools": [{"name": "t1", "cmd": "c1"}],
  "copy": {
    "hosts": [{"name": "h1", "spec": "u@1.2.3.4"}],
    "defaultFlags": ["--dry-run"],
    "defaultDirection": "push",
    "auth": "key"
  }
}
"""
try? goodJSON.write(toFile: goodPath, atomically: true, encoding: .utf8)
let lc = loadConfig(path: goodPath)
expectEqual(lc.dirs, ["/a", "/b"], "loadConfig: dirs")
expectEqual(lc.tools.first?.cmd, "c1", "loadConfig: tools")
let cc = loadCopyConfig(path: goodPath)
// copy.hosts 已删除（主机清单以 ~/.ssh/config 为唯一来源）：旧配置里留着这个键也不该影响读取
expectEqual(cc.defaultFlags, ["--dry-run"], "loadCopyConfig: defaultFlags")

// 损坏 JSON → 回退缺省
let badPath = tmpDir + "/bad.json"
try? "{not json".write(toFile: badPath, atomically: true, encoding: .utf8)
let lcBad = loadConfig(path: badPath)
expectEqual(lcBad.dirs, ["/path/to/project-a", "/path/to/project-b"], "loadConfig: 损坏 JSON 回退缺省占位目录")
expectEqual(lcBad.tools.first?.cmd, "opencode", "loadConfig: 损坏 JSON 回退缺省工具")

// 缺省配置去本机化回归：不得再包含任何个人路径/内网主机
let defaultRaw = try? JSONSerialization.data(withJSONObject: defaultConfigJSON(), options: [.sortedKeys])
let defaultStr = String(data: defaultRaw ?? Data(), encoding: .utf8) ?? ""
expectTrue(!defaultStr.contains("/Users/"), "defaultConfigJSON: 不含本机用户目录")
expectTrue(!defaultStr.contains("192.168."), "defaultConfigJSON: 不含内网主机")
expectTrue(!defaultStr.contains("defaultDirection") && !defaultStr.contains("\"auth\""),
           "defaultConfigJSON: 不再输出废弃键")

// ensureConfigExists：缺失时写缺省、已存在时不覆盖
let ensurePath = tmpDir + "/sub/ensure.json"
ensureConfigExists(path: ensurePath)
expectTrue(FileManager.default.fileExists(atPath: ensurePath), "ensureConfigExists: 缺失时写出")
try? "{\"dirs\":[\"/custom\"]}".write(toFile: ensurePath, atomically: true, encoding: .utf8)
ensureConfigExists(path: ensurePath)
let lcKeep = loadConfig(path: ensurePath)
expectEqual(lcKeep.dirs, ["/custom"], "ensureConfigExists: 已存在不覆盖")

// ============================================================
// 11. loadSSHKnownHosts（通配符跳过 / HostName / User）
// ============================================================
let sshPath = tmpDir + "/ssh_config"
let sshConf = """
Host *
  User nobody

Host 192.0.2.101
  User user

# 注释行
Host myserver
  HostName example.com
  User admin
"""
try? sshConf.write(toFile: sshPath, atomically: true, encoding: .utf8)
let hosts = loadSSHKnownHosts(path: sshPath)
expectEqual(hosts.count, 2, "loadSSHKnownHosts: 跳过通配符 Host *")
expectEqual(hosts[0].spec, "user@192.0.2.101", "loadSSHKnownHosts: 无 HostName 用 Host 别名")
expectEqual(hosts[1].spec, "admin@example.com", "loadSSHKnownHosts: HostName 覆盖别名")
expectTrue(loadSSHKnownHosts(path: tmpDir + "/not-exist").isEmpty, "loadSSHKnownHosts: 文件不存在返回空")

// ============================================================
// 12. sshListDir 优雅失败（不可达主机）
// ============================================================
let sl = sshListDir(hostSpec: "nonexistent-host.invalid", path: "~")
expectTrue(!sl.ok, "sshListDir: 不可达主机返回失败")
expectTrue(!sl.error.isEmpty, "sshListDir: 失败时带回错误信息")

// ============================================================
// 13. IPv6（方括号写法）
// ============================================================
expectEqual(splitHostPort("[::1]").host, "[::1]", "IPv6: 方括号主机")
expectTrue(splitHostPort("[::1]").port.isEmpty, "IPv6: 方括号无端口")
expectEqual(splitHostPort("[::1]:2222").host, "[::1]", "IPv6: 方括号+端口 host")
expectEqual(splitHostPort("[::1]:2222").port, "2222", "IPv6: 方括号+端口 port")
expectEqual(splitHostPort("user@[::1]:2222").host, "user@[::1]", "IPv6: user@方括号+端口 host")
expectEqual(splitHostPort("user@[::1]:2222").port, "2222", "IPv6: user@方括号+端口 port")
// 裸 IPv6 不能把最后一段当端口
expectEqual(splitHostPort("::1").host, "::1", "IPv6: 裸地址不拆端口")
expectTrue(splitHostPort("::1").port.isEmpty, "IPv6: 裸地址无端口")
expectEqual(splitHostPort("fe80::1%en0").host, "fe80::1%en0", "IPv6: 链路本地地址")

expectEqual(stripBrackets("[::1]"), "::1", "stripBrackets: 纯主机")
expectEqual(stripBrackets("user@[::1]"), "user@::1", "stripBrackets: 带用户")
expectEqual(stripBrackets("host"), "host", "stripBrackets: 非 IPv6 原样")

expectTrue(isRemotePath("user@[::1]:/data"), "IPv6: isRemotePath 识别方括号风格远端路径")
let srp6 = splitRemotePath("user@[::1]:/data")
expectEqual(srp6?.host, "user@[::1]", "IPv6: splitRemotePath host")
expectEqual(srp6?.path, "/data", "IPv6: splitRemotePath path")
let srs6 = splitRemoteSpec("[::1]:2222:/data")
expectEqual(srs6?.port, "2222", "IPv6: splitRemoteSpec port")
expectEqual(srs6?.path, "/data", "IPv6: splitRemoteSpec path")

r = pc("user@[::1]:2222")
expectEqual(r.host, "[::1]", "IPv6: parseConnection host")
expectEqual(r.port, "2222", "IPv6: parseConnection port")

// ============================================================
// 14. PATH 前缀（可配置，不再硬编码）
// ============================================================
expectEqual(buildPathExport(["~/.bun/bin", "/opt/homebrew/bin"]),
            "export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:$PATH\"", "buildPathExport: ~ 展开为 $HOME")
expectEqual(buildPathExport([]), "", "buildPathExport: 空数组不输出")
expectEqual(buildPathExport(["  ", ""]), "", "buildPathExport: 空白项被忽略")
expectEqual(buildPathExport(["/usr/local/bin"]), "export PATH=\"/usr/local/bin:$PATH\"", "buildPathExport: 绝对路径")

// 缺少 pathPrepend 键 → 缺省值
expectEqual(loadPathPrepend(path: goodPath), defaultPathPrepend, "loadPathPrepend: 缺键用缺省值")
let emptyPathConfig = tmpDir + "/empty-path.json"
try? "{\"pathPrepend\": []}".write(toFile: emptyPathConfig, atomically: true, encoding: .utf8)
expectTrue(loadPathPrepend(path: emptyPathConfig).isEmpty, "loadPathPrepend: 显式空数组表示不注入")
let customPathConfig = tmpDir + "/custom-path.json"
try? "{\"pathPrepend\": [\"/opt/x/bin\", \"/opt/y/bin\"]}".write(toFile: customPathConfig, atomically: true, encoding: .utf8)
expectEqual(loadPathPrepend(path: customPathConfig), ["/opt/x/bin", "/opt/y/bin"], "loadPathPrepend: 读取自定义值")

// ============================================================
// 15. 远端路径导航（浏览远端：进入下一层 / 上一级）
// ============================================================
expectEqual(remoteJoin(base: "~", name: "data"), "~/data", "remoteJoin: ~ + data")
expectEqual(remoteJoin(base: "~/data", name: "sub"), "~/data/sub", "remoteJoin: ~/data + sub")
expectEqual(remoteJoin(base: "/", name: "var"), "/var", "remoteJoin: / + var")
expectEqual(remoteJoin(base: "/data/", name: "x"), "/data/x", "remoteJoin: 尾部斜杠不重复")
expectEqual(remoteJoin(base: "/data", name: "/abs"), "/abs", "remoteJoin: 子项是绝对路径")
expectEqual(remoteJoin(base: "~/data", name: ".."), "~", "remoteJoin: .. 走上一级")

expectEqual(remoteParent("~"), "~", "remoteParent: ~ 的上一层仍是 ~")
expectEqual(remoteParent("~/data"), "~", "remoteParent: ~/data → ~")
expectEqual(remoteParent("~/data/sub"), "~/data", "remoteParent: ~/data/sub → ~/data")
expectEqual(remoteParent("/"), "/", "remoteParent: / 的上一层仍是 /")
expectEqual(remoteParent("/data"), "/", "remoteParent: /data → /")
expectEqual(remoteParent("/data/sub/"), "/data", "remoteParent: 尾部斜杠")
expectEqual(remoteParent(""), "~", "remoteParent: 空串回 ~")

expectEqual(splitDirAndName("/data/a").dir, "/data", "splitDirAndName: 目录")
expectEqual(splitDirAndName("/data/a").name, "a", "splitDirAndName: 名称")
expectEqual(splitDirAndName("/").name, ".", "splitDirAndName: 根路径用 .")
expectEqual(splitDirAndName("rel").dir, ".", "splitDirAndName: 相对路径")

// ============================================================
// 16. buildRelayCopyCommand（直拷失败的一键中转）
// ============================================================
expectEqual(buildRelayCopyCommand(params: CopyParams(
                source: "user@192.168.1.5:/data/a", target: "user@192.168.1.6:/data/b",
                recursive: true, preserveAttrs: true, resume: true)),
            "ssh 'user@192.168.1.5' 'tar -cf - -C '\\''/data'\\'' '\\''a'\\''' | ssh 'user@192.168.1.6' 'mkdir -p '\\''/data/b'\\'' && tar -xf - -C '\\''/data/b'\\'''",
            "buildRelayCopyCommand: 双远端默认端口（不同名时目标当容器，落 /data/b/a）")

expectEqual(buildRelayCopyCommand(params: CopyParams(
                source: "user@192.168.1.5:2222:/data/a", target: "user@192.168.1.6:2200:/data/b",
                recursive: true, preserveAttrs: true, resume: true)),
            "ssh -p 2222 'user@192.168.1.5' 'tar -cf - -C '\\''/data'\\'' '\\''a'\\''' | ssh -p 2200 'user@192.168.1.6' 'mkdir -p '\\''/data/b'\\'' && tar -xf - -C '\\''/data/b'\\'''",
            "buildRelayCopyCommand: 双端口")

expectEqual(buildRelayCopyCommand(params: CopyParams(
                source: "/local/a", target: "user@h:/data/b",
                recursive: true, preserveAttrs: true, resume: true)),
            "", "buildRelayCopyCommand: 非双远端返回空")

// 回归（真机验证时发现）：目标必须解到「父目录」，否则结果是 <目标>/<源名> 多嵌一层
let tarCmd = buildRelayCopyCommand(params: CopyParams(
        source: "user@h1:/srv/report", target: "user@h2:/backup/report",
        recursive: true, preserveAttrs: true, resume: true))
expectTrue(tarCmd.contains("mkdir -p '\\''/backup'\\''"), "relayTar: mkdir 建的是目标父目录")
expectTrue(!tarCmd.contains("/backup/report'"), "relayTar: 不再拿完整目标路径当解包目录（否则多一层）")
// 单文件源同样落到目标父目录，不受影响
let tarFileCmd = buildRelayCopyCommand(params: CopyParams(
        source: "user@h1:/srv/big.iso", target: "user@h2:/backup/big.iso",
        recursive: true, preserveAttrs: true, resume: true))
expectTrue(tarFileCmd.contains("tar -cf - -C '\\''/srv'\\'' '\\''big.iso'\\''"), "relayTar: 单文件打包父目录 + 文件名")
expectTrue(tarFileCmd.contains("mkdir -p '\\''/backup'\\'' && tar -xf - -C '\\''/backup'\\''"),
           "relayTar: 单文件解到目标父目录")

// 目标末段与源名不同：目标当容器目录（否则会丢掉末段，/backup/2026 变成 /backup/report）
let tarContainerCmd = buildRelayCopyCommand(params: CopyParams(
        source: "user@h1:/srv/report", target: "user@h2:/backup/2026",
        recursive: true, preserveAttrs: true, resume: true))
expectTrue(tarContainerCmd.contains("mkdir -p '\\''/backup/2026'\\''"),
           "relayTar: 不同名时目标当容器（落 /backup/2026/report）")

// ============================================================
// 16b. 可续传中转（两段 rsync + 稳定暂存目录）
// ============================================================
let relayRoot = "/tmp/relay-root"
let relayParams = CopyParams(source: "user@192.168.1.5:/data/big.iso",
                             target: "user@192.168.1.6:/data/dst",
                             recursive: true, preserveAttrs: true, resume: true)
let relayCmd = buildRelayResumeCommand(params: relayParams, root: relayRoot)
expectTrue(relayCmd.contains("--partial"), "relayResume: 带 --partial（断点续传）")
expectTrue(relayCmd.contains("--partial-dir=.rsync-partial"), "relayResume: 用 partial-dir 保留半截文件")
expectTrue(!relayCmd.contains("--append-verify"), "relayResume: 不用 append-verify（目标被改短时会写坏）")
expectTrue(relayCmd.hasPrefix("mkdir -p '"), "relayResume: 先建暂存目录")
expectTrue(relayCmd.contains("'user@192.168.1.6:/data/dst/'"), "relayResume: 不同名时目标当容器（/data/dst/big.iso）")
expectTrue(!relayCmd.contains("user@192.168.1.6:/data/dst'"), "relayResume: 不直接写完整目标路径（重复执行会套娃）")
expectTrue(relayCmd.contains("--rsync-path="), "relayResume: 远端先建父目录（rsync 不建缺失父目录）")
expectTrue(relayCmd.contains("rm -rf '"), "relayResume: 成功后清理暂存")
// 两段 rsync 用 && 串起来，中断时后续步骤不执行，暂存保留 → 下次可续
// 用 info 参数计数，不能数 "rsync" 子串（--partial-dir=.rsync-partial 里也有）
expectEqual(relayCmd.components(separatedBy: "--info=progress2").count - 1, 2, "relayResume: 恰好两段 rsync")
expectTrue(relayCmd.contains(" && rsync"), "relayResume: 两段之间用 && 串联")

// 暂存目录必须稳定（同一对源/目标两次调用得到同一路径），否则无法续传
let stage1 = relayStagingDir(params: relayParams, root: relayRoot)
let stage2 = relayStagingDir(params: relayParams, root: relayRoot)
expectEqual(stage1, stage2, "relayStagingDir: 同参数结果稳定")
expectTrue(stage1.hasPrefix(relayRoot + "/big.iso-"), "relayStagingDir: 以源文件名开头")
// 换目标机 → 目录必须变，避免两个任务写同一份暂存
let stageOther = relayStagingDir(params: CopyParams(source: "user@192.168.1.5:/data/big.iso",
                                                    target: "user@192.168.1.7:/data/dst",
                                                    recursive: true, preserveAttrs: true,
                                                    resume: true),
                                 root: relayRoot)
expectTrue(stageOther != stage1, "relayStagingDir: 不同目标得到不同暂存目录")

// 端口要透传到两段各自的 -e "ssh -p N"
let relayPortCmd = buildRelayResumeCommand(params: CopyParams(
        source: "user@192.168.1.5:2222:/data/x", target: "user@192.168.1.6:2200:/data/y",
        recursive: true, preserveAttrs: true, resume: true), root: relayRoot)
expectTrue(relayPortCmd.contains("ssh -p 2222") || relayPortCmd.contains("-p 2222"), "relayResume: 源端口透传")
expectTrue(relayPortCmd.contains("ssh -p 2200") || relayPortCmd.contains("-p 2200"), "relayResume: 目标端口透传")

// 非法输入兜底
expectEqual(buildRelayResumeCommand(params: CopyParams(source: "/local/a", target: "user@h:/b",
                                                      recursive: true, preserveAttrs: true,
                                                      resume: true), root: relayRoot),
            "", "relayResume: 非双远端返回空")


// ============================================================
// 17. buildCommandScript（Terminal 启动脚本：PATH 注入 / tty 精确关窗 / 语法校验）
// ============================================================
let script = buildCommandScript(cmdLine: "echo hi", pathPrepend: ["~/.bun/bin"], autoCloseOnSuccess: true)
expectTrue(script.hasPrefix("#!/bin/zsh"), "buildCommandScript: shebang")
expectTrue(script.contains("export PATH=\"$HOME/.bun/bin:$PATH\""), "buildCommandScript: 注入 PATH 前缀")
expectTrue(script.contains("_tty=$(tty 2>/dev/null)"), "buildCommandScript: 记录本 tab 的 tty")
expectTrue(script.contains("tty of selected tab of w"), "buildCommandScript: 按 tty 精确匹配窗口（G-8）")
expectTrue(script.contains("saving no"), "buildCommandScript: 关窗不走保存询问")
expectTrue(!script.contains("front window"), "buildCommandScript: 不再用 front window 误关")
expectTrue(script.contains("exit $_rc"), "buildCommandScript: 透出退出码")

let simpleScript = buildCommandScript(cmdLine: "echo hi", pathPrepend: [], autoCloseOnSuccess: false)
expectTrue(!simpleScript.contains("osascript"), "buildCommandScript: 非一次性任务不自动关窗")
expectTrue(!simpleScript.contains("export PATH"), "buildCommandScript: PATH 前缀为空时不输出")

// 用 zsh -n 校验生成的脚本语法（引号/续行写错会在这里被抓到）
func zshSyntaxOK(_ content: String) -> Bool {
    let path = NSTemporaryDirectory() + "ai-launcher-script-\(UUID().uuidString).command"
    guard (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-n", path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    try? FileManager.default.removeItem(atPath: path)
    return p.terminationStatus == 0
}
expectTrue(zshSyntaxOK(script), "buildCommandScript: 一次性脚本 zsh -n 语法通过")
expectTrue(zshSyntaxOK(simpleScript), "buildCommandScript: 普通脚本 zsh -n 语法通过")

// ============================================================
// 17. dirLabel / sshConfigPath / fileModificationDate
// ============================================================
// dirLabel：启动网格按钮标题 = 目录最后一段
expectEqual(dirLabel("/Users/me/project"), "project", "dirLabel: 常规绝对路径")
expectEqual(dirLabel("/Users/me/project/"), "project", "dirLabel: 忽略尾部斜杠")
expectEqual(dirLabel("/"), "/", "dirLabel: 根目录")
expectEqual(dirLabel("relative/dir"), "dir", "dirLabel: 相对路径")
expectEqual(dirLabel("/Users/me/中文项目"), "中文项目", "dirLabel: 中文目录名")
expectEqual(dirLabel(""), "", "dirLabel: 空串不崩")

// sshConfigPath：免密主机清单的固定来源
expectEqual(sshConfigPath(), NSHomeDirectory() + "/.ssh/config", "sshConfigPath: 拼接正确")
expectTrue(sshConfigPath().hasSuffix("/.ssh/config"), "sshConfigPath: 以 /.ssh/config 结尾")
expectTrue(!sshConfigPath().contains("//"), "sshConfigPath: 不含双斜杠")

// fileModificationDate：联想缓存靠它判断 ~/.ssh/config 是否被改过
let mtimeProbe = NSTemporaryDirectory() + "ai-launcher-mtime-\(UUID().uuidString).txt"
try? "x".write(toFile: mtimeProbe, atomically: true, encoding: .utf8)
let probeDate = fileModificationDate(mtimeProbe)
expectTrue(probeDate != nil, "fileModificationDate: 存在的文件能取到时间")
expectTrue(abs(probeDate?.timeIntervalSinceNow ?? -99999) < 600, "fileModificationDate: 时间是当前附近")
expectTrue(fileModificationDate(mtimeProbe + ".not-exist") == nil, "fileModificationDate: 不存在的文件返回 nil")
try? FileManager.default.removeItem(atPath: mtimeProbe)

// ============================================================
// 18. remoteHostSepIndex（远端规格 host/path 边界，IPv6 关键路径）
// ============================================================
func sepSplit(_ p: String) -> String {
    guard let idx = remoteHostSepIndex(p) else { return "<nil>" }
    return String(p[..<idx]) + " | " + String(p[p.index(after: idx)...])
}
expectEqual(sepSplit("user@host:/data"), "user@host | /data", "remoteHostSepIndex: 普通远端路径")
expectEqual(sepSplit("host:path"), "host | path", "remoteHostSepIndex: host:path")
expectEqual(sepSplit("[::1]:/data"), "[::1] | /data", "remoteHostSepIndex: 方括号 IPv6 后的冒号才是边界")
expectEqual(sepSplit("user@[::1]:/data"), "user@[::1] | /data", "remoteHostSepIndex: user + 方括号 IPv6")
expectEqual(sepSplit("user@[::1]:2222:/data"), "user@[::1] | 2222:/data",
            "remoteHostSepIndex: 方括号 + 端口时先切路径、端口留给 splitHostPort")
expectEqual(sepSplit("::1"), "<nil>", "remoteHostSepIndex: 裸 IPv6 不误判为远端路径")
expectEqual(sepSplit("[::1]/data"), "<nil>", "remoteHostSepIndex: 方括号后无冒号返回 nil")
expectEqual(sepSplit("/Users/me/data"), "<nil>", "remoteHostSepIndex: 本地绝对路径无冒号")
expectEqual(sepSplit("no-colon"), "<nil>", "remoteHostSepIndex: 无冒号返回 nil")

// ============================================================
// 19. shortHash / relayStagingRoot / relayStagingDir 边界
// ============================================================
// shortHash：暂存目录名的一部分，必须稳定，否则第二次运行接不上续传
expectEqual(shortHash("same-input"), shortHash("same-input"), "shortHash: 同输入稳定")
expectTrue(shortHash("a") != shortHash("b"), "shortHash: 不同输入不同")
let hx = shortHash("user@a:/x|user@b:/y")
expectTrue(!hx.isEmpty, "shortHash: 非空")
expectTrue(hx.count <= 7, "shortHash: 最多 7 位十六进制")
expectTrue(hx.allSatisfy { $0.isHexDigit }, "shortHash: 只含十六进制字符")
expectTrue(!shortHash("").isEmpty, "shortHash: 空串也有值")

// relayStagingRoot：跟随 home 的用户缓存目录，可整目录清除
expectEqual(relayStagingRoot(home: "/Users/tester"),
            "/Users/tester/Library/Caches/ai-launcher/relay",
            "relayStagingRoot: 按 home 拼接")
expectTrue(relayStagingRoot().hasSuffix("/Library/Caches/ai-launcher/relay"),
           "relayStagingRoot: 缺省落在用户缓存目录")

// 源是 / 时不能生成 .-xxxx 的隐藏目录
let rootSrcParams = CopyParams(source: "user@a:/", target: "user@b:/dst",
                               recursive: true, preserveAttrs: true, resume: true)
let rootSrcDir = relayStagingDir(params: rootSrcParams, root: "/tmp/relay-root")
expectTrue(rootSrcDir.hasPrefix("/tmp/relay-root/relay-"), "relayStagingDir: 根路径回落 relay- 前缀")
expectTrue(!rootSrcDir.contains("/."), "relayStagingDir: 不以点开头（Finder 里可见）")

// 源名含空格时替换成安全字符，避免暂存路径带空格
let spacedParams = CopyParams(source: "user@a:/data/my dir", target: "user@b:/dst",
                              recursive: true, preserveAttrs: true, resume: true)
let spaced = relayStagingDir(params: spacedParams, root: "/tmp/relay-root")
expectTrue(spaced.contains("/my_dir-"), "relayStagingDir: 空格替换为下划线")
expectTrue(!spaced.contains(" "), "relayStagingDir: 目录名不含空格")
expectEqual(relayStagingDir(params: spacedParams, root: "/tmp/relay-root"), spaced,
            "relayStagingDir: 含空格时仍稳定（续传前提）")

// ============================================================
// 20. 环境探测与日志：hasRsync / debugLog
// ============================================================
// hasRsync 与 shell 的判断必须一致：UI 靠它决定 rsync / scp / 续传式中转
let shellHasRsync = { () -> Bool in
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "command -v rsync >/dev/null 2>&1"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}()
expectEqual(hasRsync(), shellHasRsync, "hasRsync: 与 shell 探测结果一致")

// debugLog 是排障唯一入口，必须追加而不是覆盖
let logMarker = "debugLog-test-\(UUID().uuidString)"
debugLog(logMarker)
debugLog(logMarker)
let logText = (try? String(contentsOfFile: "/tmp/ai-launcher-debug.log", encoding: .utf8)) ?? ""
expectTrue(logText.contains(logMarker), "debugLog: 写入内容可在日志中找到")
expectEqual(logText.components(separatedBy: logMarker).count - 1, 2, "debugLog: 两次调用都追加（不覆盖）")

// ============================================================
// 21. 补充边界：IPv6 远端判定 / parseConnection 容错 / 本地拷贝降级
// ============================================================
expectTrue(isRemotePath("user@[::1]:/data"), "isRemotePath: user@[::1]:path")
expectTrue(isRemotePath("[::1]:/data"), "isRemotePath: [::1]:path")
expectTrue(!isRemotePath("::1"), "isRemotePath: 裸 IPv6 不误判")
expectTrue(!isRemotePath("~/data"), "isRemotePath: ~ 相对路径算本地")
expectTrue(!isRemotePath("/Users/me/a:b"), "isRemotePath: 本地路径含冒号仍是本地")

// parseConnection 容错：空串 / 只有前缀 / 尾部斜杠
let emptyConn = parseConnection("   ")
expectTrue(emptyConn.host.isEmpty && emptyConn.user.isEmpty && emptyConn.password.isEmpty,
           "parseConnection: 空串返回空连接")
let prefixOnly = parseConnection("ssh://")
expectTrue(prefixOnly.host.isEmpty, "parseConnection: 只有 ssh:// 不崩且 host 为空")
let trailingSlash = parseConnection("user@host:2222/")
expectEqual(trailingSlash.host, "host", "parseConnection: 尾部斜杠先剥掉再解析")
expectEqual(trailingSlash.port, "2222", "parseConnection: 尾部斜杠不影响端口")

// 本地→本地且无 rsync：降级 scp 也要带 -r/-p（scp 无断点续传，故不出现 partial 参数）
expectEqual(cmd("/Users/me/a", "/Users/me/b", rsync: false),
            "scp -r -p '/Users/me/a' '/Users/me/b'",
            "buildCopyCommand: 本地拷贝无 rsync 降级 scp")

// ============================================================
// 18. 限速（--bwlimit / scp -l）
// ============================================================
expectEqual(parseBwlimitMBps(""), 0, "bwlimit: 空串 = 不限速")
expectEqual(parseBwlimitMBps("   "), 0, "bwlimit: 全空格 = 不限速")
expectEqual(parseBwlimitMBps("10"), 10240, "bwlimit: 10 MB/s → 10240 KiB/s")
expectEqual(parseBwlimitMBps("0.5"), 512, "bwlimit: 支持小数（0.5 MB/s）")
expectEqual(parseBwlimitMBps("0"), 0, "bwlimit: 0 = 不限速")
expectEqual(parseBwlimitMBps(" 20 "), 20480, "bwlimit: 忽略首尾空格")
expectTrue(parseBwlimitMBps("abc") == nil, "bwlimit: 非数字返回 nil（不能静默当不限速）")
expectTrue(parseBwlimitMBps("-1") == nil, "bwlimit: 负数返回 nil")
expectTrue(parseBwlimitMBps("1.2.3") == nil, "bwlimit: 多个小数点返回 nil")
expectTrue(parseBwlimitMBps("1e3") == nil, "bwlimit: 科学计数法不接受")

expectEqual(bwlimitFlag(0), "", "bwlimitFlag: 0 不输出参数")
expectEqual(bwlimitFlag(10240), " --bwlimit=10240", "bwlimitFlag: 正常输出")

func cmdBW(_ source: String, _ target: String, kbps: Int,
           rsync: Bool = true, logPath: String = "") -> String {
    buildCopyCommand(cfg: cfg,
                     params: CopyParams(source: source, target: target,
                                        recursive: true, preserveAttrs: true, resume: true,
                                        bwlimitKbps: kbps),
                     rsyncAvailable: rsync, logPath: logPath)
}

expectEqual(cmdBW("/Users/me/data", "user@h:/data", kbps: 10240),
            "rsync -r -a --partial --partial-dir=.rsync-partial --info=progress2 --bwlimit=10240 '/Users/me/data' 'user@h:/data'",
            "buildCopyCommand: 限速参数紧跟 --info=progress2")
expectEqual(cmdBW("/Users/me/a", "/Users/me/b", kbps: 10240, rsync: false),
            "scp -r -p -l 81920 '/Users/me/a' '/Users/me/b'",
            "buildCopyCommand: scp 降级用 -l（Kbit/s = KiB/s × 8）")

// ============================================================
// 19. 传输日志路径（--log-file）
// ============================================================
expectEqual(safeFileComponent("report.tar.gz"), "report.tar.gz", "safeFileComponent: 正常名不变")
expectEqual(safeFileComponent("a/b:c d"), "a_b_c_d", "safeFileComponent: 路径分隔符与空格替换")
expectEqual(safeFileComponent("."), "", "safeFileComponent: 纯点名清洗后为空")

let logParams = CopyParams(source: "user@h:/data/report", target: "user@h2:/backup/report",
                           recursive: true, preserveAttrs: true, resume: true)
let logPathA = copyLogPath(params: logParams, root: "/tmp/la-logs")
expectTrue(logPathA.hasPrefix("/tmp/la-logs/report-"), "copyLogPath: 根目录可控且带源名")
expectTrue(logPathA.hasSuffix(".log"), "copyLogPath: 后缀 .log")
expectEqual(logPathA, copyLogPath(params: logParams, root: "/tmp/la-logs"),
            "copyLogPath: 同参数稳定同名（续传多次运行写同一个文件）")
var logParamsOther = logParams
logParamsOther.target = "/backup/other"
expectTrue(copyLogPath(params: logParamsOther, root: "/tmp/la-logs") != logPathA,
           "copyLogPath: 换目标换名")
var logParamsRoot = logParams
logParamsRoot.source = "user@h:/"
expectTrue(copyLogPath(params: logParamsRoot, root: "/tmp/la-logs").hasPrefix("/tmp/la-logs/copy-"),
           "copyLogPath: 源为 / 时用兜底名 copy")
expectEqual(copyLogRoot(home: "/Users/me"), "/Users/me/Library/Logs/ai-launcher",
            "copyLogRoot: 落在 ~/Library/Logs")

let logTarget = "/Users/me/Library/Logs/ai-launcher/report-1a2b3c.log"
let cmdWithLog = cmdBW("/Users/me/data", "user@h:/data", kbps: 0, logPath: logTarget)
expectTrue(cmdWithLog.contains("--log-file='\(logTarget)'"), "buildCopyCommand: 本机发起时带 --log-file")
expectTrue(cmdWithLog.hasSuffix("'/Users/me/data' 'user@h:/data'"),
           "buildCopyCommand: 日志参数在路径之前，不影响源/目标位置")
// 双远端直拷在源机执行，本机日志路径在源机可能不存在，故不加 --log-file（但限速照样带）
let cmdDirect = cmdBW("user@h1:/a", "user@h2:/b", kbps: 5120, logPath: logTarget)
expectTrue(!cmdDirect.contains("--log-file"), "buildCopyCommand: 双远端直拷不加本机日志")
expectTrue(cmdDirect.contains("--bwlimit=5120"), "buildCopyCommand: 双远端直拷仍带限速")

// 中转两段都写同一个日志文件（rsync --log-file 是追加模式）
let relayP = CopyParams(source: "user@h1:/data/a", target: "user@h2:/data/b",
                        recursive: true, preserveAttrs: true, resume: true,
                        bwlimitKbps: 2048)
let relayWithLog = buildRelayResumeCommand(params: relayP, root: "/tmp/la-stage", logPath: logTarget)
expectEqual(relayWithLog.components(separatedBy: "--log-file='\(logTarget)'").count - 1, 2,
            "buildRelayResumeCommand: 下载段与上传段各带一次日志")
expectEqual(relayWithLog.components(separatedBy: "--bwlimit=2048").count - 1, 2,
            "buildRelayResumeCommand: 两段都限速")

// ============================================================
// 20. 上次互拷任务（last-copy.json）
// ============================================================
let mem = CopyMemory(source: "user@h:/data", target: "/Users/me/backup",
                     recursive: true, preserveAttrs: false, resume: true, bwlimitMBps: "10")
let memData = encodeCopyMemory(mem)!
let memBack = decodeCopyMemory(memData)
expectEqual(memBack?.source, "user@h:/data", "memory: 源往返一致")
expectEqual(memBack?.target, "/Users/me/backup", "memory: 目标往返一致")
expectEqual(memBack?.preserveAttrs, false, "memory: 布尔选项往返一致")
expectEqual(memBack?.bwlimitMBps, "10", "memory: 限速原文往返一致（回填显示不丢格式）")

let emptyMem = CopyMemory(source: "", target: "", recursive: true, preserveAttrs: true,
                          resume: true, bwlimitMBps: "")
expectTrue(decodeCopyMemory(encodeCopyMemory(emptyMem)!) == nil, "memory: 空记录视为没有（不回填空壳）")
expectTrue(decodeCopyMemory(Data("not json".utf8)) == nil, "memory: 损坏 JSON 返回 nil")
let partialMem = Data("{\"source\":\"/a\",\"target\":\"/b\"}".utf8)
expectEqual(decodeCopyMemory(partialMem)?.recursive, true, "memory: 缺字段用缺省 true")
expectEqual(decodeCopyMemory(partialMem)?.bwlimitMBps, "", "memory: 缺限速字段回填空串")

let memPath = NSTemporaryDirectory() + "ai-launcher-mem-\(UUID().uuidString).json"
expectTrue(saveCopyMemory(mem, path: memPath), "memory: 保存成功")
expectEqual(loadCopyMemory(path: memPath)?.target, "/Users/me/backup", "memory: 从文件读回一致")
expectTrue(loadCopyMemory(path: memPath + ".missing") == nil, "memory: 文件不存在返回 nil")
try? FileManager.default.removeItem(atPath: memPath)
expectEqual(copyMemoryPath(home: "/Users/me"), "/Users/me/.config/ai-launcher/last-copy.json",
            "memory: 落点与 config 同目录")

// ============================================================
// 21. 带日志的启动脚本
// ============================================================
let logScript = buildCommandScript(cmdLine: "echo hi", pathPrepend: [], autoCloseOnSuccess: true,
                                   logPath: "/tmp/la-logs/x.log", startNote: "user@h:/a → /b")
expectTrue(logScript.contains("mkdir -p '/tmp/la-logs'"), "logScript: 先建日志目录")
expectTrue(logScript.contains(">> '/tmp/la-logs/x.log'"), "logScript: 追加写到日志文件")
expectTrue(logScript.contains("[%s] 开始"), "logScript: 记开始时间")
expectTrue(logScript.contains("[%s] 结束，退出码 %d"), "logScript: 记结束时间与退出码")
expectTrue(logScript.contains("_rc=$?"), "logScript: 取出命令退出码")
expectTrue(logScript.contains("exit $_rc"), "logScript: 透出退出码")
expectTrue(zshSyntaxOK(logScript), "logScript: zsh -n 语法通过")

// 任务摘要与路径含单引号/空格时不能把脚本写坏
let trickyScript = buildCommandScript(cmdLine: "echo hi", pathPrepend: [], autoCloseOnSuccess: false,
                                      logPath: "/tmp/my logs/x.log", startNote: "it's a → b")
expectTrue(zshSyntaxOK(trickyScript), "logScript: 摘要含单引号、路径含空格仍语法正确")

// 不带日志时脚本里不应出现 mkdir/printf（保持原来的精简形态）
let plainScript = buildCommandScript(cmdLine: "echo hi", pathPrepend: [], autoCloseOnSuccess: false)
expectTrue(!plainScript.contains("mkdir -p"), "logScript: 不传日志路径时不生成日志语句")

// ============================================================
// 22. rsync 实现识别 / 可达性探测 / 双远端选路
// 背景：中转不再由用户点按钮，改成「后台测直连，不通自动中转」。
// 这里把三件前提锁住：rsync 实现要认得出、探测命令要只连主机不带路径、选路要覆盖四种组合
// ============================================================

// —— rsync 实现：openrsync 不认 --info=progress2 / --log-file，必须与 GNU 区分开 ——
expectEqual(parseRsyncFlavor("openrsync: protocol version 29\nrsync version 2.6.9 compatible"),
            RsyncFlavor.openRsync, "parseRsyncFlavor: 系统自带 openrsync 识别为受限实现")
expectEqual(parseRsyncFlavor("rsync  version 3.5.1  protocol version 33"),
            RsyncFlavor.full, "parseRsyncFlavor: GNU rsync 3.x 识别为完整实现")
expectEqual(parseRsyncFlavor("   "), RsyncFlavor.none, "parseRsyncFlavor: 空输出视为没有 rsync")
expectEqual(parseRsyncFlavor("rsync-like 1.0"),
            RsyncFlavor.openRsync, "parseRsyncFlavor: 认不出的实现按保守处理（不加它可能不认的参数）")

// —— 直连探测：在源机上套一层 BatchMode 的 ssh，只连主机不碰路径 ——
let probeParams = CopyParams(source: "user@192.168.1.5:/data/big.iso",
                             target: "user@192.168.1.6:/data/dst",
                             recursive: true, preserveAttrs: true, resume: true)
let directProbe = buildDirectProbeCommand(params: probeParams)
expectTrue(directProbe.hasPrefix("ssh -o BatchMode=yes"),
           "directProbe: 外层 ssh 走 BatchMode（要密码就判不通，而不是卡住等输入）")
expectTrue(directProbe.contains("ConnectTimeout=5"), "directProbe: 带超时，探测不能卡住 UI")
expectTrue(directProbe.contains("'user@192.168.1.5'"), "directProbe: 外层主机被引号包住")
// 内层命令是「源机上再 ssh 一次到目标机」，作为单个远端命令参数传入，里面的引号必须已转义
expectTrue(directProbe.contains("ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 '\\''user@192.168.1.6'\\'' true"),
           "directProbe: 内层 ssh 到目标机且主机参数已转义")
expectTrue(!directProbe.contains("/data/dst"), "directProbe: 探测不碰目标路径（只验登录）")
expectTrue(directProbe.contains("command -v rsync"),
           "directProbe: 顺带验源机有 rsync（源机没有就别硬走直拷）")
expectTrue(!directProbe.contains("StrictHostKeyChecking"),
           "directProbe: 不自动接受未知主机键（不往别人的服务器写 known_hosts）")
expectEqual(buildDirectProbeCommand(params: CopyParams(
                source: "user@a:2222:/x", target: "user@b:2200:/y",
                recursive: true, preserveAttrs: true, resume: true)).contains("-p 2222"),
            true, "directProbe: 源机端口透传")
expectTrue(buildDirectProbeCommand(params: CopyParams(
                source: "user@a:2222:/x", target: "user@b:2200:/y",
                recursive: true, preserveAttrs: true, resume: true)).contains("-p 2200"),
           "directProbe: 目标机端口透传给内层 ssh")
expectEqual(buildDirectProbeCommand(params: CopyParams(
                source: "/local/a", target: "user@b:/data",
                recursive: true, preserveAttrs: true, resume: true)),
            "", "directProbe: 非双远端返回空（只有服务器↔服务器才需要判断直连）")

// —— 本机探测：中转的前提是本机两端都登得上 ——
expectEqual(buildLocalProbeCommand(host: "user@192.168.1.5"),
            "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 'user@192.168.1.5' true",
            "localProbe: 默认端口")
expectEqual(buildLocalProbeCommand(host: "user@192.168.1.5", port: "2222"),
            "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 -p 2222 'user@192.168.1.5' true",
            "localProbe: 端口在主机前")
expectTrue(buildLocalProbeCommand(host: "user@[::1]").contains("'user@::1'"),
           "localProbe: IPv6 去方括号")
expectEqual(buildLocalProbeCommand(host: ""), "", "localProbe: 空主机返回空")

// —— 选路：直连优先，不通才中转，两端都够不着就明确报错 ——
expectEqual(resolveDirectRoute(directReachable: true, localReachable: false,
                               resume: true, rsyncFlavor: .full),
            CopyRoute.direct, "route: 直连实测通过就走直连（不看本机能否中转）")
expectEqual(resolveDirectRoute(directReachable: false, localReachable: true,
                               resume: true, rsyncFlavor: .full),
            CopyRoute.relayResume, "route: 直连不通 → 可续传中转（勾了续传且本机有 rsync）")
expectEqual(resolveDirectRoute(directReachable: false, localReachable: true,
                               resume: false, rsyncFlavor: .full),
            CopyRoute.relayTar, "route: 未勾续传 → tar 流")
expectEqual(resolveDirectRoute(directReachable: false, localReachable: true,
                               resume: true, rsyncFlavor: .none),
            CopyRoute.relayTar, "route: 本机没 rsync → tar 流（不能拼 rsync 命令）")
expectEqual(resolveDirectRoute(directReachable: false, localReachable: false,
                               resume: true, rsyncFlavor: .full),
            CopyRoute.unreachable, "route: 本机也到不了 → 不可达（不静默失败）")

// —— openrsync 下不能拼 --info=progress2 / --log-file，直连与中转两条路径都要能降下来 ——
let openParams = CopyParams(source: "/Users/me/data", target: "user@h:/data",
                            recursive: true, preserveAttrs: true, resume: true)
let openCmd = buildCopyCommand(cfg: cfg, params: openParams, rsyncAvailable: true,
                               logPath: "/tmp/x.log", useProgress2: false, useLogFile: false)
expectTrue(!openCmd.contains("--info=progress2"),
           "openrsync 兼容: 直连命令不带 --info=progress2（否则 unrecognized option）")
expectTrue(!openCmd.contains("--log-file"),
           "openrsync 兼容: 直连命令不带 --log-file（openrsync 没有这个参数）")
expectTrue(openCmd.contains("--partial-dir=.rsync-partial"),
           "openrsync 兼容: 续传参数保留（openrsync 支持 --partial-dir）")

let openRelay = buildRelayResumeCommand(params: probeParams, root: "/tmp/relay-root",
                                        logPath: "/tmp/x.log",
                                        useProgress2: false, useLogFile: false)
expectEqual(openRelay.components(separatedBy: "--info=progress2").count - 1, 0,
            "openrsync 兼容: 中转两段都不带 --info=progress2")
expectEqual(openRelay.components(separatedBy: "--partial-dir").count - 1, 2,
            "openrsync 兼容: 中转两段各自仍带 --partial-dir（续传不能丢）")
expectEqual(openRelay.components(separatedBy: "--log-file").count - 1, 0,
            "openrsync 兼容: 中转两段都不带 --log-file")

// ============================================================
// 写出的 JSON 不转义斜杠（配置文件可读性）
// JSONSerialization 默认把 "/" 写成 "\/"，而 config.json 里几乎全是 macOS 路径，
// 手改时变成 "\/Users\/me\/git\/a"。两种写法等价，但可读性差很多。
// ============================================================
let cfgJSON = encodeJSON(["dirs": ["/Users/me/git/a", "/Users/me/git/b"]])
if let d = cfgJSON, let text = String(data: d, encoding: .utf8) {
    expectTrue(!text.contains("\\/"), "encodeJSON: 不把 / 转义成 \\/（否则手改配置难读）")
    expectTrue(text.contains("\"/Users/me/git/a\""), "encodeJSON: 路径原样写出（前引号紧跟 /）")
} else {
    expectTrue(false, "encodeJSON: 能序列化出数据")
}
if let d = cfgJSON, let back = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    expectEqual((back["dirs"] as? [String] ?? []).joined(separator: ","),
                "/Users/me/git/a,/Users/me/git/b", "encodeJSON: 不转义的写法往返后路径一致")
} else {
    expectTrue(false, "encodeJSON: 输出能被 JSONSerialization 读回")
}

// last-copy.json 里也只有路径，同一个坑，一并约束
let memJSON = encodeCopyMemory(CopyMemory(source: "/Users/me/a", target: "u@10.0.0.1:/data/b",
                                          recursive: true, preserveAttrs: true, resume: true,
                                          bwlimitMBps: ""))
if let d = memJSON, let text = String(data: d, encoding: .utf8) {
    expectTrue(!text.contains("\\/"), "encodeCopyMemory: 源/目标路径不转义斜杠")
} else {
    expectTrue(false, "encodeCopyMemory: 能序列化出数据")
}
// 不转义之后仍要能读回，且分不清「本地/远端」的值不能丢
if let d = memJSON, let m = decodeCopyMemory(d) {
    expectEqual(m.target, "u@10.0.0.1:/data/b", "encodeCopyMemory: 往返后远端目标串一致")
} else {
    expectTrue(false, "encodeCopyMemory: 输出能被 decodeCopyMemory 读回")
}

// ============================================================
// 结果回收：从日志新增内容里读退出码
// 拷贝跑在 Terminal 里，app 拿不到 terminationStatus，只能读脚本层那行「结束，退出码 N」
// ============================================================
let noEnd = parseCopyLogOutcome("[2026-11-10 10:00:00] 开始 a → b\n")
expectTrue(!noEnd.finished, "parseCopyLogOutcome: 只有开始行时不算结束")
expectEqual(noEnd.exitCode, nil, "parseCopyLogOutcome: 未结束时没有退出码")

let okEnd = parseCopyLogOutcome("[2026-11-10 10:00:00] 开始 a → b\n[2026-11-10 10:00:09] 结束，退出码 0\n")
expectTrue(okEnd.finished, "parseCopyLogOutcome: 有结束行即结束")
expectEqual(okEnd.exitCode, 0, "parseCopyLogOutcome: 退出码 0 解析正确")

let failEnd = parseCopyLogOutcome("[2026-11-10 10:00:09] 结束，退出码 23\n")
expectEqual(failEnd.exitCode, 23, "parseCopyLogOutcome: 非 0 退出码（23 = rsync 部分文件未传）")

// 同一任务续传会追加多段，本次结果必须是最后一段
let twice = parseCopyLogOutcome("""
[2026-11-10 10:00:09] 结束，退出码 0
[2026-11-10 10:05:00] 开始 a → b
[2026-11-10 10:05:03] 结束，退出码 12
""")
expectEqual(twice.exitCode, 12, "parseCopyLogOutcome: 多段日志取最后一次的退出码")

// rsync 明细里没有这个措辞，不能误判
let rsyncDetail = parseCopyLogOutcome("sent 1,234 bytes  received 56 bytes  2,580.00 bytes/sec\ntotal size is 1,024\n")
expectTrue(!rsyncDetail.finished, "parseCopyLogOutcome: rsync 明细不会被当成结束")

// —— 「开始」行 = 脚本真的执行了 ——
// `.command` 交给 Terminal 是单向通道：open 与 NSWorkspace 的 completionHandler 都只回报
// 「请求已交给 Terminal」（实测 error=nil），文稿被拦时也一样。所以只能由脚本自己报。
expectTrue(noEnd.started, "parseCopyLogOutcome: 读到开始行即 started（脚本确实跑起来了）")
expectTrue(okEnd.started, "parseCopyLogOutcome: 开始+结束时 started 仍为真")
expectTrue(!failEnd.started, "parseCopyLogOutcome: 只有结束行时 started 为假（读到的是上一次运行的后半段）")
expectTrue(twice.started, "parseCopyLogOutcome: 多段日志里任意一段有开始行即 started")
expectTrue(!rsyncDetail.started, "parseCopyLogOutcome: rsync 明细不会被当成开始")

// 只有「[时间] 」开头的才是脚本层标记；rsync 自己的行是 "2026/11/11 22:01:07 [14720] …"
let looksLikeStart = parseCopyLogOutcome("2026/11/11 22:01:07 [14720] 开始 处理 xx\n")
expectTrue(!looksLikeStart.started, "parseCopyLogOutcome: 不以 [ 开头的行不算开始（避免 rsync 明细误判）")

// 脚本产物必须真的写出「开始」行——否则上面的 started 永远不会为真
let scriptForStart = buildCommandScript(cmdLine: "true", pathPrepend: [], autoCloseOnSuccess: false,
                                        logPath: "/tmp/_ai_start_probe.log", startNote: "a → b")
expectTrue(scriptForStart.contains("开始"), "buildCommandScript: 脚本第一条动作就要写开始行")
expectTrue(scriptForStart.range(of: "开始")!.lowerBound < scriptForStart.range(of: "true")!.lowerBound,
           "buildCommandScript: 开始行必须写在真正命令之前")

// —— 只读新增内容：读全量会把上一次的结束行当成这次的结果 ——
let tailDir = NSTemporaryDirectory() + "ai-launcher-tail-\(getpid())"
try? FileManager.default.createDirectory(atPath: tailDir, withIntermediateDirectories: true)
let tailFile = tailDir + "/t.log"
try? "第一段\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: tailFile))

let first = readNewText(path: tailFile, fromOffset: 0)
expectEqual(first.text, "第一段\n", "readNewText: 从 0 读能拿到全部内容")
expectEqual(first.offset, Int64(first.text.utf8.count), "readNewText: 返回的 offset 是文件大小")

if let h = FileHandle(forWritingAtPath: tailFile) {
    h.seekToEndOfFile()
    h.write("第二段\n".data(using: .utf8)!)
    try? h.close()
}
let second = readNewText(path: tailFile, fromOffset: first.offset)
expectEqual(second.text, "第二段\n", "readNewText: 带 offset 时只返回新增内容（旧结束行不干扰）")

// 文件被清空重建：offset 比文件还大，退回从 0 读
try? "重建\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: tailFile))
let third = readNewText(path: tailFile, fromOffset: 9_999)
expectEqual(third.text, "重建\n", "readNewText: offset 超过文件大小时从 0 重读")

let missing = readNewText(path: tailDir + "/不存在.log", fromOffset: 0)
expectEqual(missing.text, "", "readNewText: 文件不存在时返回空串不崩")

// —— 体积文案与目录占用（「清除中转暂存」要先把占用说清楚）——
expectEqual(humanSize(0), "0 B", "humanSize: 0")
expectEqual(humanSize(1536), "1.5 KB", "humanSize: 1536 → 1.5 KB")
expectEqual(humanSize(5 * 1024 * 1024), "5.0 MB", "humanSize: 5 MiB → 5.0 MB")

let sizeDir = tailDir + "/stage"
try? FileManager.default.createDirectory(atPath: sizeDir, withIntermediateDirectories: true)
try? Data(count: 100).write(to: URL(fileURLWithPath: sizeDir + "/a"))
try? Data(count: 200).write(to: URL(fileURLWithPath: sizeDir + "/b"))
expectEqual(directorySizeBytes(sizeDir), 300, "directorySizeBytes: 递归统计两个文件的字节数")
expectEqual(directorySizeBytes(tailDir + "/no-such-dir"), 0, "directorySizeBytes: 不存在时返回 0")
try? FileManager.default.removeItem(atPath: tailDir)

// ============================================================
// 汇总
// ============================================================
print("\n======== 测试汇总：\(passCount) 通过，\(failures.count) 失败 ========")
if !failures.isEmpty {
    print("失败用例：")
    for f in failures { print("  - \(f)") }
    exit(1)
}
exit(0)
