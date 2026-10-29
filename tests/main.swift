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

r = pc("192.168.198.101")
expectEqual(r.host, "192.168.198.101", "parse 纯 IP")

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
r = pc("192.168.198.102\tjykj/P@ssw0rdo1!")
expectEqual(r.host, "192.168.198.102", "parse tab 分隔: host")
expectEqual(r.user, "jykj", "parse tab 分隔: user")
expectEqual(r.password, "P@ssw0rdo1!", "parse tab 分隔: pass")

r = pc("192.168.198.102 jykj/P@ssw0rdo1!")
expectEqual(r.user, "jykj", "parse 空格分隔: user")
expectEqual(r.password, "P@ssw0rdo1!", "parse 空格分隔: pass")

r = pc("192.168.198.102:jykj:P@ssw0rdo1!")
expectEqual(r.host, "192.168.198.102", "parse 冒号分隔: host")
expectEqual(r.user, "jykj", "parse 冒号分隔: user")
expectEqual(r.password, "P@ssw0rdo1!", "parse 冒号分隔: pass")

r = pc("192.168.198.102|jykj|P@ssw0rdo1!")
expectEqual(r.user, "jykj", "parse 竖线分隔: user")
expectEqual(r.password, "P@ssw0rdo1!", "parse 竖线分隔: pass")

r = pc("192.168.198.102,jykj/P@ssw0rdo1!")
expectEqual(r.user, "jykj", "parse 逗号分隔: user")
expectEqual(r.password, "P@ssw0rdo1!", "parse 逗号分隔: pass")

r = pc("192.168.198.102 jykj")
expectEqual(r.user, "jykj", "parse 仅主机+用户")
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
expectEqual(buildHostSpec(ConnectionInfo(user: "jykj", password: "", host: "192.168.1.5", port: "")),
            "jykj@192.168.1.5", "buildHostSpec: 无端口")
expectEqual(buildHostSpec(ConnectionInfo(user: "jykj", password: "", host: "192.168.1.5", port: "2222")),
            "jykj@192.168.1.5:2222", "buildHostSpec: 带端口")
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
expectEqual(remotePathArg("/home/jykj"), "'/home/jykj'", "remotePathArg: 绝对路径")
expectEqual(remotePathArg("my dir"), "'my dir'", "remotePathArg: 含空格")
expectEqual(remotePathArg(""), "''", "remotePathArg: 空串")

expectEqual(maskSecret(""), "", "maskSecret: 空串原样")
expectEqual(maskSecret("secret"), "***", "maskSecret: 非空脱敏")

// ============================================================
// 6. isRemotePath / splitRemotePath / splitRemoteSpec
// ============================================================
expectTrue(!isRemotePath("/Users/me/data"), "isRemotePath: 本地绝对路径")
expectTrue(isRemotePath("jykj@host:/home/data"), "isRemotePath: user@host:path")
expectTrue(isRemotePath("host:path"), "isRemotePath: host:path")
expectTrue(!isRemotePath("plain"), "isRemotePath: 相对路径无冒号")
expectTrue(!isRemotePath("a/b:c"), "isRemotePath: 冒号前含斜杠视为本地")

let srp = splitRemotePath("jykj@host:/p")
expectEqual(srp?.host, "jykj@host", "splitRemotePath: host")
expectEqual(srp?.path, "/p", "splitRemotePath: path")
expectTrue(splitRemotePath("nocolon") == nil, "splitRemotePath: 无冒号返回 nil")

let srs = splitRemoteSpec("jykj@192.168.1.5:2222:/data")
expectEqual(srs?.host, "jykj@192.168.1.5", "splitRemoteSpec: host（含端口时拆出）")
expectEqual(srs?.port, "2222", "splitRemoteSpec: port")
expectEqual(srs?.path, "/data", "splitRemoteSpec: path")
let srs2 = splitRemoteSpec("jykj@host:/p")
expectEqual(srs2?.host, "jykj@host", "splitRemoteSpec: 无端口 host")
expectTrue(srs2?.port.isEmpty ?? false, "splitRemoteSpec: 无端口 port 为空")
expectEqual(srs2?.path, "/p", "splitRemoteSpec: 无端口 path")
expectTrue(splitRemoteSpec("plain") == nil, "splitRemoteSpec: 无冒号返回 nil")

// ============================================================
// 7. deriveDirection
// ============================================================
expectEqual(deriveDirection(src: "/Users/me/data", dst: "jykj@h:/home/data"), "push", "deriveDirection: 本机→远端")
expectEqual(deriveDirection(src: "jykj@h:/home/data", dst: "/Users/me/data"), "pull", "deriveDirection: 远端→本机")
expectEqual(deriveDirection(src: "jykj@h:/a", dst: "u@h2:/b"), "direct", "deriveDirection: 双远端直拷")
expectEqual(deriveDirection(src: "/a", dst: "/b"), "local", "deriveDirection: 双本机")

// ============================================================
// 8. buildCopyCommand（命令拼装 + 自定义端口 + scp 降级）
// ============================================================
let cfg = CopyConfig(hosts: [], defaultFlags: [])
func cmd(_ source: String, _ target: String,
         recursive: Bool = true, preserveAttrs: Bool = true, resume: Bool = true,
         rsync: Bool = true) -> String {
    buildCopyCommand(cfg: cfg, params: CopyParams(
        source: source, target: target,
        recursive: recursive, preserveAttrs: preserveAttrs, resume: resume,
        hostSpec: ""), rsyncAvailable: rsync)
}

expectEqual(cmd("/Users/me/data", "jykj@192.168.198.101:/home/jykj/data"),
            "rsync -r -a --partial --append-verify --info=progress2 '/Users/me/data' 'jykj@192.168.198.101:/home/jykj/data'",
            "buildCopyCommand: push 全选项")

expectEqual(cmd("/Users/me/data", "jykj@192.168.1.5:2222:/data"),
            "rsync -r -a --partial --append-verify --info=progress2 -e 'ssh -p 2222' '/Users/me/data' 'jykj@192.168.1.5:/data'",
            "buildCopyCommand: push 自定义端口走 -e ssh -p（回归）")

expectEqual(cmd("jykj@192.168.1.5:2222:/data/x", "/Users/me/data", rsync: false),
            "scp -r -p -P 2222 'jykj@192.168.1.5:/data/x' '/Users/me/data'",
            "buildCopyCommand: pull 无 rsync 降级 scp -P（回归）")

expectEqual(cmd("jykj@192.168.198.101:/home/data", "/Users/me/data"),
            "rsync -r -a --partial --append-verify --info=progress2 'jykj@192.168.198.101:/home/data' '/Users/me/data'",
            "buildCopyCommand: pull 默认端口")

// 直拷：ssh 到源机执行 rsync，源机端口走 ssh -p，目标机端口走内层 -e "ssh -p"
expectEqual(cmd("jykj@192.168.1.5:2222:/data/a", "jykj@192.168.1.6:2200:/data/b"),
            "ssh -t -p 2222 'jykj@192.168.1.5' 'rsync -r -a --partial --append-verify --info=progress2 -e '\\''ssh -p 2200'\\'' '\\''/data/a'\\'' '\\''jykj@192.168.1.6:/data/b'\\'''",
            "buildCopyCommand: 双远端直拷+双端口")

expectEqual(cmd("jykj@h1:/a", "jykj@h2:/b"),
            "ssh -t 'jykj@h1' 'rsync -r -a --partial --append-verify --info=progress2 '\\''/a'\\'' '\\''jykj@h2:/b'\\'''",
            "buildCopyCommand: 双远端直拷默认端口")

expectEqual(cmd("/Users/me/a", "/Users/me/b", recursive: true, preserveAttrs: false, resume: false),
            "rsync -r --info=progress2 '/Users/me/a' '/Users/me/b'",
            "buildCopyCommand: 本地拷贝最小选项")

expectEqual(cmd("/Users/me/my data", "jykj@h:/tmp/x y", recursive: false, preserveAttrs: false, resume: false),
            "rsync --info=progress2 '/Users/me/my data' 'jykj@h:/tmp/x y'",
            "buildCopyCommand: 路径含空格正确加引号")

// 注：isRemotePath 为真时 splitRemoteSpec 必然可解析，故「解析失败返回空」不可达；
// 这里改为覆盖「双远端但缺路径」的边界：host: 后为空路径仍应产出合法直拷命令
expectEqual(cmd("jykj@h1:/a", "jykj@h2:"),
            "ssh -t 'jykj@h1' 'rsync -r -a --partial --append-verify --info=progress2 '\\''/a'\\'' '\\''jykj@h2:'\\'''",
            "buildCopyCommand: 双远端空路径仍可拼命令")

// ============================================================
// 9. buildFillPlan（填充决策六场景，覆盖串框 bug 回归）
// ============================================================
let spec = "jykj@192.168.198.102"
var p = buildFillPlan(trigger: .target, spec: spec,
                      sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.targetValue, "\(spec):", "fillPlan 场景1: 目标框触发-都空 → 填目标框")
expectEqual(p.hostValue, "192.168.198.102", "fillPlan 场景1: 联动填主机")
expectEqual(p.userValue, "jykj", "fillPlan 场景1: 联动填用户")
expectTrue(p.sourceValue == nil && p.connValue == nil, "fillPlan 场景1: 不串到其他框")

p = buildFillPlan(trigger: .source, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.sourceValue, "\(spec):", "fillPlan 场景2: 源框触发-都空 → 填源框")

p = buildFillPlan(trigger: .conn, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.connValue, spec, "fillPlan 场景3: 连接串框触发 → 填连接串框")

p = buildFillPlan(trigger: .host, spec: spec,
                  sourceEmpty: true, targetEmpty: true, connEmpty: true, hostEmpty: true, userEmpty: true)
expectEqual(p.hostValue, "192.168.198.102", "fillPlan 场景4: IP框触发 → 填主机框")
expectEqual(p.userValue, "jykj", "fillPlan 场景4: 联动填用户框")
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
expectEqual(cc.hosts.first?.spec, "u@1.2.3.4", "loadCopyConfig: hosts")
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

Host 192.168.198.101
  User jykj

# 注释行
Host myserver
  HostName example.com
  User admin
"""
try? sshConf.write(toFile: sshPath, atomically: true, encoding: .utf8)
let hosts = loadSSHKnownHosts(path: sshPath)
expectEqual(hosts.count, 2, "loadSSHKnownHosts: 跳过通配符 Host *")
expectEqual(hosts[0].spec, "jykj@192.168.198.101", "loadSSHKnownHosts: 无 HostName 用 Host 别名")
expectEqual(hosts[1].spec, "admin@example.com", "loadSSHKnownHosts: HostName 覆盖别名")
expectTrue(loadSSHKnownHosts(path: tmpDir + "/not-exist").isEmpty, "loadSSHKnownHosts: 文件不存在返回空")

// ============================================================
// 12. sshListDir 优雅失败（不可达主机）
// ============================================================
let sl = sshListDir(hostSpec: "nonexistent-host.invalid", path: "~")
expectTrue(!sl.ok, "sshListDir: 不可达主机返回失败")
expectTrue(!sl.error.isEmpty, "sshListDir: 失败时带回错误信息")

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
