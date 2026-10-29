// Core：与 UI 无关的纯逻辑层（仅依赖 Foundation，可单独编译测试，见 tests/main.swift）
// 包含：连接串解析、路径/主机拆分、shell 转义、互拷命令拼装、配置读写、免密主机解析
// 规则：本文件不得 import Cocoa / AppKit，不得包含顶层可执行语句
import Foundation

let configPath = NSHomeDirectory() + "/.config/ai-launcher/config.json"

struct ToolConfig {
    let name: String   // 菜单显示名
    let cmd: String    // 实际执行的命令
}

// —— 互拷（两台机器之间拷贝文件/文件夹）——
struct CopyHostConfig {
    let name: String   // 预设显示名
    let spec: String   // user@host 或 host（不含路径）
}

struct CopyConfig {
    let hosts: [CopyHostConfig]
    let defaultFlags: [String]     // rsync 额外参数数组
    // 注：defaultDirection / auth 字段已废弃（方向由路径自动推导，密码走 TTY 交互），
    // 读取时忽略旧配置里的这两个键，向后兼容。
}

struct CopyParams {
    var source: String      // 本地路径 或 user@host[:port]:path
    var target: String      // 本地路径 或 user@host[:port]:path
    var recursive: Bool
    var preserveAttrs: Bool
    var resume: Bool        // 断点续传
    var hostSpec: String    // 所选预设的 spec（user@host 或 host）
}

// 连接信息（用户名/密码/主机/端口分离）
struct ConnectionInfo {
    var user: String
    var password: String
    var host: String
    var port: String
}

// 从 host（可能含 :port 后缀）中拆出 host 与 port
func splitHostPort(_ hostPart: String) -> (host: String, port: String) {
    // 仅当冒号后是纯数字才视为端口
    if let colon = hostPart.lastIndex(of: ":") {
        let h = String(hostPart[..<colon])
        let p = String(hostPart[hostPart.index(after: colon)...])
        if !p.isEmpty && p.allSatisfy({ $0.isNumber }) {
            return (h, p)
        }
    }
    return (hostPart, "")
}

// 判断字符串是否为 IP 或主机名（用于「主机在前」格式的识别）
// 主机在前格式：192.168.198.102\tjykj/P@ssw0rdo1! 或 host user/pass 等
func looksLikeHost(_ s: String) -> Bool {
    if s.isEmpty { return false }
    // IP 形式：x.x.x.x
    let ipParts = s.split(separator: ".")
    if ipParts.count == 4 && ipParts.allSatisfy({ $0.allSatisfy { $0.isNumber } }) {
        return true
    }
    // 域名形式：含点且不含 @ / : / 空格等分隔
    if s.contains(".") && !s.contains("@") && !s.contains(":") && !s.contains("/") {
        return true
    }
    return false
}

// 解析连接串，支持多种格式，返回 (user, password, host, port)
// 支持：
//   1) user@host / user:password@host / ssh://user@host / ssh://user:password@host
//   2) host / user@host:port / host:port / 纯 IP 或域名
//   3) 主机在前格式（Excel 复制常见）：host<TAB|空格|:|,|;|\|>user/pass
//      例：192.168.198.102\tjykj/P@ssw0rdo1! 或 192.168.198.102 jykj/P@ssw0rdo1!
func parseConnection(_ input: String) -> ConnectionInfo {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return ConnectionInfo(user: "", password: "", host: "", port: "") }

    // 去掉 ssh:// 前缀
    if let range = s.range(of: "ssh://", options: .caseInsensitive) {
        s = String(s[range.upperBound...])
    }
    // 去掉可能的尾部斜杠
    while s.hasSuffix("/") { s.removeLast() }

    var user = ""
    var password = ""
    var hostPart = ""

    // 优先尝试「主机在前 + 分隔符 + 用户/密码」格式
    // 特征：开头是 IP/域名，后面紧跟分隔符。密码里可能含 @，所以不能先按 @ 判断。
    // 常见分隔符：Tab、空格、冒号、逗号、分号、竖线
    let seps: [Character] = ["\t", " ", ":", ",", ";", "|"]
    var hostFirstMatched = false
    for sep in seps {
        if let idx = s.firstIndex(of: sep) {
            let first = String(s[..<idx]).trimmingCharacters(in: .whitespaces)
            let rest = String(s[s.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            // 仅当 first 像主机（IP/域名）且 rest 非空时，视为「主机 用户/密码」
            if looksLikeHost(first) && !rest.isEmpty {
                // 特例：host:2222 / IP:2222 —— rest 为纯数字时是端口不是用户名，
                // 不走主机在前分支，交给下方 @ 拆分 + splitHostPort 统一处理
                if sep == ":" && rest.allSatisfy({ $0.isNumber }) {
                    continue
                }
                hostPart = first
                // rest 可能是 user/pass 或 user:pass 或 user|pass 或 user
                if let slash = rest.firstIndex(of: "/") {
                    user = String(rest[..<slash])
                    password = String(rest[rest.index(after: slash)...])
                } else if let colon2 = rest.firstIndex(of: ":") {
                    user = String(rest[..<colon2])
                    password = String(rest[rest.index(after: colon2)...])
                } else if let pipe = rest.firstIndex(of: "|") {
                    user = String(rest[..<pipe])
                    password = String(rest[rest.index(after: pipe)...])
                } else {
                    user = rest
                }
                hostFirstMatched = true
                break
            }
        }
    }

    if !hostFirstMatched {
        // 按最后一个 @ 拆分 user[:password] 与 host[:port]
        if let at = s.lastIndex(of: "@") {
            let userInfo = String(s[..<at])
            hostPart = String(s[s.index(after: at)...])
            // userInfo 可能是 user 或 user:password
            if let colon = userInfo.firstIndex(of: ":") {
                user = String(userInfo[..<colon])
                password = String(userInfo[userInfo.index(after: colon)...])
            } else {
                user = userInfo
            }
        } else {
            hostPart = s
        }
    }

    // hostPart 可能是 host 或 host:port
    let (host, port) = splitHostPort(hostPart)

    return ConnectionInfo(user: user, password: password, host: host, port: port)
}

// 由连接信息拼出 user@host[:port] 形式（供 rsync/scp 使用）
func buildHostSpec(_ info: ConnectionInfo) -> String {
    var host = info.host
    if !info.port.isEmpty { host += ":" + info.port }
    if info.user.isEmpty {
        return host
    }
    return info.user + "@" + host
}

// 单引号转义：把任意字符串安全地包进单引号（复用 '\'' 手法）
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// 远端 shell 的路径参数：单引号内的 ~ 不会被展开（ls '~' 会去找字面名为 ~ 的文件），
// 因此 ~ 开头的路径要让 ~ 保持裸写、其余部分引号拼接：~ -> ~，~/foo -> ~'/foo'
func remotePathArg(_ p: String) -> String {
    if p == "~" { return "~" }
    if p.hasPrefix("~/") { return "~" + shellQuote(String(p.dropFirst())) }
    return shellQuote(p)
}

// 日志脱敏：密码等敏感信息只出现是否存在，不落明文
func maskSecret(_ s: String) -> String {
    s.isEmpty ? "" : "***"
}

// 判断是否为远端路径（user@host:path 或 host:path）
func isRemotePath(_ p: String) -> Bool {
    // 本地绝对路径以 / 开头；含 ":" 且冒号前不含 "/" 视为远端
    if p.hasPrefix("/") { return false }
    if let idx = p.firstIndex(of: ":") {
        let head = p[..<idx]
        return !head.contains("/")
    }
    return false
}

// 拆分远端路径为 (host, path)
func splitRemotePath(_ p: String) -> (host: String, path: String)? {
    guard let idx = p.firstIndex(of: ":") else { return nil }
    let host = String(p[..<idx])
    let path = String(p[p.index(after: idx)...])
    return (host, path)
}

// 拆分远端规格 user@host[:port]:path -> (user@host, port, path)
// rsync/scp 不支持 host:port:path 冒号写法，端口需拆出后走 ssh -p / scp -P
// 注意：第一个冒号是 host 与「端口/路径」的边界，端口后面还会跟一个冒号
func splitRemoteSpec(_ p: String) -> (host: String, port: String, path: String)? {
    guard let idx = p.firstIndex(of: ":") else { return nil }
    let host = String(p[..<idx])
    let rest = String(p[p.index(after: idx)...])
    // rest 可能是纯 path，也可能是 "port:path"
    if let colon2 = rest.firstIndex(of: ":") {
        let maybePort = String(rest[..<colon2])
        if !maybePort.isEmpty && maybePort.allSatisfy({ $0.isNumber }) {
            let path = String(rest[rest.index(after: colon2)...])
            return (host, maybePort, path)
        }
    }
    return (host, "", rest)
}

// 由源/目标路径自动推导方向
// 返回 "push"（本机→远端）/ "pull"（远端→本机）/ "direct"（服务器↔服务器直拷）/ "local"（本机↔本机）
func deriveDirection(src: String, dst: String) -> String {
    let srcRemote = isRemotePath(src)
    let dstRemote = isRemotePath(dst)
    if srcRemote && dstRemote { return "direct" }
    if srcRemote && !dstRemote { return "pull" }
    if !srcRemote && dstRemote { return "push" }
    return "local"
}

// 用 ssh 列出远端目录内容（BatchMode=yes 禁用密码交互，仅密钥免密可用）
// 返回 (成功?, 目录列表字符串, 错误信息)
func sshListDir(hostSpec: String, path: String) -> (ok: Bool, output: String, error: String) {
    // hostSpec 可能是 user@host 或 user@host[:port]；端口用 -p 单独传
    var hostNoPort = hostSpec
    var portArg: [String] = []
    if let colon = hostSpec.lastIndex(of: ":") {
        let p = String(hostSpec[hostSpec.index(after: colon)...])
        if !p.isEmpty && p.allSatisfy({ $0.isNumber }) {
            hostNoPort = String(hostSpec[..<colon])
            portArg = ["-p", p]
        }
    }
    let remoteCmd = "ls -1p " + remotePathArg(path.isEmpty ? "~" : path)
    var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
    args += portArg
    args += [hostNoPort, remoteCmd]

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = args
    let out = Pipe()
    let err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.launch()
    // 先读完管道再等退出：若先 waitUntilExit，输出超过管道缓冲（64KB）时会与子进程互相等待而死锁
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let outStr = String(data: outData, encoding: .utf8) ?? ""
    let errStr = String(data: errData, encoding: .utf8) ?? ""
    let ok = p.terminationStatus == 0
    return (ok, outStr, errStr)
}

// 判断本机是否有 rsync（有副作用：会 spawn 子进程；结果通过参数传入 buildCopyCommand 以便测试）
func hasRsync() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "command -v rsync >/dev/null 2>&1"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.launch()
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// 拼接互拷命令。返回命令行字符串
// 服务器↔服务器直拷：ssh 到源机执行 rsync（避免本机中转）
// rsyncAvailable：本机是否有 rsync（由调用方用 hasRsync() 探测后传入，保持本函数无副作用可测）
// 自定义端口：rsync/scp 不支持 user@host:port:path，端口拆出后走 -e "ssh -p N" / scp -P
func buildCopyCommand(cfg: CopyConfig, params: CopyParams, rsyncAvailable: Bool) -> String {
    let srcRemote = isRemotePath(params.source)
    let dstRemote = isRemotePath(params.target)

    let recursiveFlag = params.recursive ? " -r" : ""
    let preserveFlag = params.preserveAttrs ? " -a" : ""
    let resumeFlags = params.resume ? " --partial --append-verify" : ""
    let extraFlags = cfg.defaultFlags.isEmpty ? "" : " " + cfg.defaultFlags.joined(separator: " ")

    // 服务器↔服务器直拷：ssh 到源机执行 rsync
    if srcRemote && dstRemote {
        guard let s = splitRemoteSpec(params.source),
              let t = splitRemoteSpec(params.target) else {
            return ""
        }
        // 在源机上跑 rsync；-e ssh 让源机 ssh 到目标机（目标机端口非 22 时须带 -p）
        var inner = "rsync" + recursiveFlag + preserveFlag + resumeFlags + " --info=progress2" + extraFlags
        if !t.port.isEmpty {
            inner += " -e " + shellQuote("ssh -p \(t.port)")
        }
        inner += " " + shellQuote(s.path) + " " + shellQuote(t.host + ":" + t.path)
        // 用 -t 分配伪终端以支持目标机密码交互；源机端口非 22 时 ssh -p 指定
        var sshArgs = "ssh -t"
        if !s.port.isEmpty {
            sshArgs += " -p \(s.port)"
        }
        return sshArgs + " " + shellQuote(s.host) + " " + shellQuote(inner)
    }

    // 本机有 rsync：用 rsync（远端侧重写掉端口，端口走 -e "ssh -p N"）
    if rsyncAvailable {
        var base = "rsync" + recursiveFlag + preserveFlag + resumeFlags + " --info=progress2" + extraFlags
        var srcArg = params.source
        var dstArg = params.target
        var remotePorts: [String] = []
        if srcRemote, let s = splitRemoteSpec(params.source) {
            srcArg = s.host + ":" + s.path
            if !s.port.isEmpty { remotePorts.append(s.port) }
        }
        if dstRemote, let t = splitRemoteSpec(params.target) {
            dstArg = t.host + ":" + t.path
            if !t.port.isEmpty { remotePorts.append(t.port) }
        }
        if let port = remotePorts.first {
            base += " -e " + shellQuote("ssh -p \(port)")
        }
        return base + " " + shellQuote(srcArg) + " " + shellQuote(dstArg)
    }

    // 无 rsync：降级 scp（-r 递归 -p 保留属性；注意 scp 不支持断点续传，端口用 -P）
    var scpFlags = ""
    if params.recursive { scpFlags += " -r" }
    if params.preserveAttrs { scpFlags += " -p" }
    var srcArg = params.source
    var dstArg = params.target
    var remotePorts: [String] = []
    if srcRemote, let s = splitRemoteSpec(params.source) {
        srcArg = s.host + ":" + s.path
        if !s.port.isEmpty { remotePorts.append(s.port) }
    }
    if dstRemote, let t = splitRemoteSpec(params.target) {
        dstArg = t.host + ":" + t.path
        if !t.port.isEmpty { remotePorts.append(t.port) }
    }
    if let port = remotePorts.first {
        scpFlags += " -P \(port)"
    }
    return "scp" + scpFlags + " " + shellQuote(srcArg) + " " + shellQuote(dstArg)
}

func defaultConfigJSON() -> [String: Any] {
    // 缺省配置用占位路径（不携带任何本机/内网信息），首次启动写出后由用户自行修改
    return [
        "dirs": [
            "/path/to/project-a",
            "/path/to/project-b",
        ],
        "tools": [
            ["name": "opencode", "cmd": "opencode"],
        ],
        "copy": [
            "hosts": [],
            "defaultFlags": [],
        ],
    ]
}

func ensureConfigExists(path: String = configPath) {
    let manager = FileManager.default
    let dir = (path as NSString).deletingLastPathComponent
    try? manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !manager.fileExists(atPath: path) {
        if let data = try? JSONSerialization.data(withJSONObject: defaultConfigJSON(), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

func loadConfig(path: String = configPath) -> (dirs: [String], tools: [ToolConfig]) {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let d = defaultConfigJSON()
        let dirs = d["dirs"] as? [String] ?? []
        let tools = (d["tools"] as? [Any] ?? []).compactMap { item -> ToolConfig? in
            guard let dict = item as? [String: String],
                  let name = dict["name"], let cmd = dict["cmd"] else { return nil }
            return ToolConfig(name: name, cmd: cmd)
        }
        return (dirs, tools)
    }
    let dirs = json["dirs"] as? [String] ?? []
    let tools = (json["tools"] as? [Any] ?? []).compactMap { item -> ToolConfig? in
        guard let dict = item as? [String: Any],
              let name = dict["name"] as? String, let cmd = dict["cmd"] as? String else { return nil }
        return ToolConfig(name: name, cmd: cmd)
    }
    return (dirs, tools)
}

// 读取 copy 段（可选，缺省返回空配置，向后兼容不报错；废弃键 defaultDirection/auth 直接忽略）
func loadCopyConfig(path: String = configPath) -> CopyConfig {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let copy = json["copy"] as? [String: Any] else {
        return CopyConfig(hosts: [], defaultFlags: [])
    }
    let hosts = (copy["hosts"] as? [Any] ?? []).compactMap { item -> CopyHostConfig? in
        guard let dict = item as? [String: Any],
              let name = dict["name"] as? String,
              let spec = dict["spec"] as? String else { return nil }
        return CopyHostConfig(name: name, spec: spec)
    }
    let flags = (copy["defaultFlags"] as? [Any] ?? []).compactMap { $0 as? String }
    return CopyConfig(hosts: hosts, defaultFlags: flags)
}

// —— 免密机器：读 ~/.ssh/config 解析 Host/HostName/User ——
struct SSHHost {
    let host: String    // HostName（实际连接地址；无 HostName 时为 Host 别名）
    let hostName: String // HostName 原值
    let user: String    // User
    var display: String { user.isEmpty ? host : "\(user)@\(host)" }
    var spec: String { user.isEmpty ? host : "\(user)@\(host)" }
}

func loadSSHKnownHosts(path: String = NSHomeDirectory() + "/.ssh/config") -> [SSHHost] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }
    var hosts: [SSHHost] = []
    var curHost = ""
    var curHostName = ""
    var curUser = ""

    func flush() {
        if !curHost.isEmpty {
            // 跳过通配符 Host（如 Host *）与注释
            if !curHost.contains("*") && !curHost.contains("?") {
                let hn = curHostName.isEmpty ? curHost : curHostName
                hosts.append(SSHHost(host: hn, hostName: curHostName.isEmpty ? curHost : curHostName, user: curUser))
            }
        }
        curHost = ""; curHostName = ""; curUser = ""
    }

    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { flush(); continue }
        if line.hasPrefix("#") { continue }
        // 按空格/制表符拆分关键字与值
        let parts = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { continue }
        let key = String(parts[0]).lowercased()
        let value = String(parts[1])
        switch key {
        case "host":
            flush()
            curHost = value
        case "hostname":
            curHostName = value
        case "user":
            curUser = value
        default:
            break
        }
    }
    flush()
    return hosts
}

func dirLabel(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

func debugLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = "/tmp/ai-launcher-debug.log"
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }
}

// —— 填充决策（纯函数，可测）——
// 把「选中免密机器后填哪个框」的决策逻辑抽离，避免 UI 状态串框
enum TriggerField { case source, target, conn, host, none }

struct FillPlan {
    var sourceValue: String? = nil
    var targetValue: String? = nil
    var connValue: String? = nil
    var hostValue: String? = nil
    var userValue: String? = nil
}

// 纯函数：根据触发框类型 + 各框当前是否为空，决定填充方案
// spec 形如 user@host；prefix 形如 user@host:
func buildFillPlan(trigger: TriggerField, spec: String,
                   sourceEmpty: Bool, targetEmpty: Bool,
                   connEmpty: Bool, hostEmpty: Bool, userEmpty: Bool) -> FillPlan {
    var plan = FillPlan()
    let user = spec.contains("@") ? String(spec[..<spec.lastIndex(of: "@")!]) : ""
    let host = spec.contains("@") ? String(spec[spec.index(after: spec.lastIndex(of: "@")!)...]) : spec
    let prefix = spec + ":"

    // 联动填充 IP/主机 + 用户名（全局信息，始终补空）
    if hostEmpty { plan.hostValue = host }
    if userEmpty { plan.userValue = user }

    // 根据触发框决定填哪个路径/连接框
    switch trigger {
    case .source:
        plan.sourceValue = prefix
    case .target:
        plan.targetValue = prefix
    case .conn:
        plan.connValue = spec
    case .host:
        plan.hostValue = host
    case .none:
        // 兜底：源空填源，目标空填目标
        if sourceEmpty { plan.sourceValue = prefix }
        else if targetEmpty { plan.targetValue = prefix }
    }
    return plan
}
