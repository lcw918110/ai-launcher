// Core：与 UI 无关的纯逻辑层（仅依赖 Foundation，可单独编译测试，见 tests/main.swift）
// 包含：连接串解析、路径/主机拆分、shell 转义、互拷命令拼装、配置读写、免密主机解析
// 规则：本文件不得 import Cocoa / AppKit，不得包含顶层可执行语句
import Foundation

let configPath = NSHomeDirectory() + "/.config/ai-launcher/config.json"

// 启动脚本 PATH 前缀的缺省值（可在 config.json 用 pathPrepend 覆盖；空数组表示不注入）
let defaultPathPrepend: [String] = ["~/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]

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
    var bwlimitKbps: Int = 0 // rsync --bwlimit，单位 KiB/s；0 表示不限速
}

// 连接信息（用户名/密码/主机/端口分离）
struct ConnectionInfo {
    var user: String
    var password: String
    var host: String
    var port: String
}

// 去掉 IPv6 方括号：[::1] -> ::1（ssh 的 host 参数不能带方括号，rsync/scp 的规格要带）
// 兼容 user@[::1] 这种带用户名的写法，只剥主机部分
func stripBrackets(_ host: String) -> String {
    if let at = host.lastIndex(of: "@") {
        let user = String(host[...at])
        return user + stripBrackets(String(host[host.index(after: at)...]))
    }
    if host.hasPrefix("[") && host.hasSuffix("]") {
        return String(host.dropFirst().dropLast())
    }
    return host
}

// 从 host（可能含 :port 后缀）中拆出 host 与 port
// IPv6 规则：带方括号的 [::1]:2222 按方括号后的冒号拆端口；裸 IPv6（多个冒号）整体视为主机
func splitHostPort(_ hostPart: String) -> (host: String, port: String) {
    // 方括号形式（可能带 user@ 前缀）：取最后一个 "]" 之后的 ":" 判断端口
    if let close = hostPart.lastIndex(of: "]") {
        let host = String(hostPart[...close])
        let after = hostPart.index(after: close)
        guard after < hostPart.endIndex, hostPart[after] == ":" else { return (host, "") }
        let p = String(hostPart[hostPart.index(after: after)...])
        if !p.isEmpty && p.allSatisfy({ $0.isNumber }) { return (host, p) }
        return (host, "")
    }
    // 裸 IPv6（冒号 >= 2）不拆端口，否则 "::1" 会被拆成 host="::" port="1"
    if hostPart.filter({ $0 == ":" }).count > 1 {
        return (hostPart, "")
    }
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
// 主机在前格式：192.0.2.102\tuser/S3cret@pass! 或 host user/pass 等
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
//      例：192.0.2.102\tuser/S3cret@pass! 或 192.0.2.102 user/S3cret@pass!
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

// 找出「主机 与 路径」之间的冒号位置（兼容 IPv6）
// [::1]:/p -> 方括号后的冒号；裸 IPv6（多个冒号）不含主机分隔符
func remoteHostSepIndex(_ p: String) -> String.Index? {
    if let close = p.lastIndex(of: "]") {
        let after = p.index(after: close)
        guard after < p.endIndex, p[after] == ":" else { return nil }
        return after
    }
    guard let idx = p.firstIndex(of: ":") else { return nil }
    // 以冒号开头（裸 IPv6 如 "::1"）不当作远端路径；IPv6 请用方括号写法 [::1]:path
    if idx == p.startIndex { return nil }
    return idx
}

// 判断是否为远端路径（user@host:path 或 host:path）
func isRemotePath(_ p: String) -> Bool {
    // 本地绝对路径以 / 开头
    if p.hasPrefix("/") { return false }
    guard let idx = remoteHostSepIndex(p) else { return false }
    let head = p[..<idx]
    return !head.contains("/")
}

// 拆分远端路径为 (host, path)
func splitRemotePath(_ p: String) -> (host: String, path: String)? {
    guard let idx = remoteHostSepIndex(p) else { return nil }
    let host = String(p[..<idx])
    let path = String(p[p.index(after: idx)...])
    return (host, path)
}

// 拆分远端规格 user@host[:port]:path -> (user@host, port, path)
// rsync/scp 不支持 host:port:path 冒号写法，端口需拆出后走 ssh -p / scp -P
// 注意：第一个冒号是 host 与「端口/路径」的边界，端口后面还会跟一个冒号
func splitRemoteSpec(_ p: String) -> (host: String, port: String, path: String)? {
    guard let idx = remoteHostSepIndex(p) else { return nil }
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
    // hostSpec 可能是 user@host 或 user@host[:port]；端口用 -p 单独传，IPv6 去方括号
    let (hostPart, port) = splitHostPort(hostSpec)
    let sshHost = stripBrackets(hostPart.isEmpty ? hostSpec : hostPart)
    var portArg: [String] = []
    if !port.isEmpty { portArg = ["-p", port] }
    let remoteCmd = "ls -1p " + remotePathArg(path.isEmpty ? "~" : path)
    var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
    args += portArg
    args += [sshHost, remoteCmd]

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

// —— 限速（--bwlimit）——
// UI 里输入的是 MB/s（允许小数，如 0.5），rsync 要的是 KiB/s。空或 0 表示不限速。
// 非法输入（负数、非数字、多个小数点）返回 nil，由调用方提示而不是静默当成不限速。
func parseBwlimitMBps(_ text: String) -> Int? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return 0 }
    // 只允许数字与一个小数点，避免 Double("1e9")、"nan"、"inf" 这类意外值
    var dotCount = 0
    for ch in t {
        if ch == "." { dotCount += 1; if dotCount > 1 { return nil }; continue }
        if !ch.isNumber { return nil }
    }
    guard let mbps = Double(t), mbps.isFinite, mbps >= 0 else { return nil }
    let kbps = Int((mbps * 1024).rounded())
    return kbps > 0 ? kbps : 0
}

// 拼到 rsync 的限速参数；0 不输出
func bwlimitFlag(_ kbps: Int) -> String {
    kbps > 0 ? " --bwlimit=\(kbps)" : ""
}

// 文件名清洗：保留字母数字与 . - _，其余替换成 _（远端路径里的 / 会打断文件名）
func safeFileComponent(_ name: String) -> String {
    let safe = String(name.map { ch -> Character in
        if ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" { return ch }
        return "_"
    })
    // 纯点名（如 "."）会变成以点开头的隐藏文件，去掉点后若为空用调用方给的兜底名
    return safe.replacingOccurrences(of: ".", with: "").isEmpty ? "" : safe
}

// —— 传输日志：按「源 + 目标」哈希命名，同一任务复用同一文件，续传的多次运行会追加到一起 ——
func copyLogRoot(home: String = NSHomeDirectory()) -> String {
    home + "/Library/Logs/ai-launcher"
}

func copyLogPath(params: CopyParams, root: String = copyLogRoot()) -> String {
    let raw = splitDirAndName(splitRemoteSpec(params.source)?.path ?? params.source).name
    let safe = safeFileComponent(raw)
    let name = safe.isEmpty ? "copy" : safe
    return root + "/" + name + "-" + shortHash(params.source + "|" + params.target) + ".log"
}


// 拼接互拷命令。返回命令行字符串
// logPath：rsync --log-file 的落点（空串不加）。只在「本机发起」的 rsync 上加；
// 双远端直拷是在源机上执行的，本机路径在源机不存在，故不加
// 服务器↔服务器直拷：ssh 到源机执行 rsync（避免本机中转）
// rsyncAvailable：本机是否有 rsync（由调用方用 hasRsync() 探测后传入，保持本函数无副作用可测）
// 自定义端口：rsync/scp 不支持 user@host:port:path，端口拆出后走 -e "ssh -p N" / scp -P
func buildCopyCommand(cfg: CopyConfig, params: CopyParams, rsyncAvailable: Bool,
                      logPath: String = "") -> String {
    let srcRemote = isRemotePath(params.source)
    let dstRemote = isRemotePath(params.target)

    let recursiveFlag = params.recursive ? " -r" : ""
    let preserveFlag = params.preserveAttrs ? " -a" : ""
    // 续传统一用 --partial-dir：半截文件留在目标端的 .rsync-partial 里，重跑时 rsync 以它为基底做增量，
    // 不会把「看起来完整、实际缺尾」的文件留在最终路径；也不用 --append-verify —— 目标文件被改短时
    // 它会先追加一段垃圾再靠校验发现，大文件等于白传一遍
    let resumeFlags = params.resume ? " --partial --partial-dir=.rsync-partial" : ""
    let bwFlag = bwlimitFlag(params.bwlimitKbps)
    let extraFlags = cfg.defaultFlags.isEmpty ? "" : " " + cfg.defaultFlags.joined(separator: " ")

    // 服务器↔服务器直拷：ssh 到源机执行 rsync
    if srcRemote && dstRemote {
        guard let s = splitRemoteSpec(params.source),
              let t = splitRemoteSpec(params.target) else {
            return ""
        }
        // 在源机上跑 rsync；-e ssh 让源机 ssh 到目标机（目标机端口非 22 时须带 -p）
        // 日志不加：命令在源机上跑，本机日志路径在源机不一定存在
        var inner = "rsync" + recursiveFlag + preserveFlag + resumeFlags + " --info=progress2" + bwFlag + extraFlags
        if !t.port.isEmpty {
            inner += " -e " + shellQuote("ssh -p \(t.port)")
        }
        inner += " " + shellQuote(s.path) + " " + shellQuote(t.host + ":" + t.path)
        // 用 -t 分配伪终端以支持目标机密码交互；源机端口非 22 时 ssh -p 指定
        var sshArgs = "ssh -t"
        if !s.port.isEmpty {
            sshArgs += " -p \(s.port)"
        }
        return sshArgs + " " + shellQuote(stripBrackets(s.host)) + " " + shellQuote(inner)
    }

    // 本机有 rsync：用 rsync（远端侧重写掉端口，端口走 -e "ssh -p N"）
    if rsyncAvailable {
        // --log-file 让 rsync 自己写日志（客户端侧），不经过管道，因此不干扰 ssh 的交互式密码输入
        let logFlag = logPath.isEmpty ? "" : " --log-file=" + shellQuote(logPath)
        var base = "rsync" + recursiveFlag + preserveFlag + resumeFlags + " --info=progress2" +
            bwFlag + logFlag + extraFlags
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
    // 限速也能生效：scp -l 的单位是 Kbit/s，换算成 KiB/s * 8
    var scpFlags = ""
    if params.recursive { scpFlags += " -r" }
    if params.preserveAttrs { scpFlags += " -p" }
    if params.bwlimitKbps > 0 { scpFlags += " -l \(params.bwlimitKbps * 8)" }
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

// —— 启动脚本 PATH：可配置，不再硬编码本机的 bun/Homebrew 路径 ——
func loadPathPrepend(path: String = configPath) -> [String] {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = json["pathPrepend"] as? [Any] else {
        return defaultPathPrepend
    }
    // 显式给出空数组表示「不注入额外路径」，与缺省值区分开
    return raw.compactMap { $0 as? String }
}

// 生成 shell 的 PATH 导出语句；~ 展开成 $HOME（写在双引号里由 shell 展开）
func buildPathExport(_ dirs: [String]) -> String {
    var parts: [String] = []
    for raw in dirs {
        let d = raw.trimmingCharacters(in: .whitespaces)
        if d.isEmpty { continue }
        if d == "~" {
            parts.append("$HOME")
        } else if d.hasPrefix("~/") {
            parts.append("$HOME" + String(d.dropFirst()))
        } else {
            parts.append(d.replacingOccurrences(of: "\"", with: ""))
        }
    }
    guard !parts.isEmpty else { return "" }
    return "export PATH=\"" + parts.joined(separator: ":") + ":$PATH\""
}

// —— 远端目录导航（浏览远端用，纯函数可测）——
// 拼接：~/a + b -> ~/a/b；/ + b -> /b；base 为空 -> 直接返回 name
func remoteJoin(base: String, name: String) -> String {
    if name.isEmpty { return base }
    if name == ".." { return remoteParent(base) }
    if name == "." { return base.isEmpty ? "~" : base }
    if name.hasPrefix("/") { return name }
    if base.isEmpty { return name }
    if base == "/" { return "/" + name }
    if base.hasSuffix("/") { return base + name }
    return base + "/" + name
}

// 上一层：~ -> ~；~ -> ~；~/a -> ~；~/a/b -> ~/a；/a -> /；/ -> /
func remoteParent(_ path: String) -> String {
    if path.isEmpty { return "~" }
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    if p == "~" || p == "/" { return p }
    if p.hasPrefix("~/") {
        let rest = String(p.dropFirst(2))
        guard let idx = rest.lastIndex(of: "/") else { return "~" }
        return "~/" + String(rest[..<idx])
    }
    if p.hasPrefix("/") {
        guard let idx = p.lastIndex(of: "/") else { return "/" }
        return idx == p.startIndex ? "/" : String(p[..<idx])
    }
    // 相对路径
    guard let idx = p.lastIndex(of: "/") else { return "." }
    return idx == p.startIndex ? "/" : String(p[..<idx])
}

// 把路径拆成 (目录, 名称)：/a/b -> (/a, b)；/ -> (/, .)；a -> (., a)
func splitDirAndName(_ path: String) -> (dir: String, name: String) {
    var p = path
    while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
    if p.isEmpty || p == "/" { return ("/", ".") }
    guard let idx = p.lastIndex(of: "/") else { return (".", p) }
    let dir = idx == p.startIndex ? "/" : String(p[..<idx])
    let name = String(p[p.index(after: idx)...])
    return (dir, name.isEmpty ? "." : name)
}

// —— 可续传中转：源机 → 本机暂存 → 目标机（两段 rsync，中断后重跑从断点继续）——
// 暂存根目录：跟随系统缓存目录，卸载应用可整目录清除
func relayStagingRoot(home: String = NSHomeDirectory()) -> String {
    home + "/Library/Caches/ai-launcher/relay"
}

// djb2 短哈希：同一对源/目标必须得到同一个暂存目录名，否则第二次运行无法续传
func shortHash(_ s: String) -> String {
    var h: UInt64 = 5381
    for b in s.utf8 { h = (h &* 33) &+ UInt64(b) }
    return String(h & 0xFFFFFFF, radix: 16)
}

// 暂存子目录：<源文件名>-<短哈希>，哈希由「源规格 + 目标规格」决定
func relayStagingDir(params: CopyParams, root: String = relayStagingRoot()) -> String {
    let name = splitDirAndName(splitRemoteSpec(params.source)?.path ?? "").name
    let safe = safeFileComponent(name)
    // 源是 / 或 . 时清洗后为空，若不兜底会生成以点开头的隐藏目录（Finder 里看不见）
    let dirName = (safe.isEmpty ? "relay" : safe) + "-" + shortHash(params.source + "|" + params.target)
    return root + "/" + dirName
}

// 两段式中转命令：先拉到本机暂存（--partial 断点续传），再推到目标机，成功后清理暂存
// 与 tar 流的区别：占用本地磁盘（约等于一份源数据），但中断可续、有大文件进度
func buildRelayResumeCommand(params: CopyParams, root: String = relayStagingRoot(),
                             logPath: String = "") -> String {
    guard let s = splitRemoteSpec(params.source),
          let t = splitRemoteSpec(params.target),
          !s.path.isEmpty, !t.path.isEmpty else {
        return ""
    }
    let stage = relayStagingDir(params: params, root: root)
    let name = splitDirAndName(s.path).name
    let recursiveFlag = params.recursive ? " -r" : ""
    let preserveFlag = params.preserveAttrs ? " -a" : ""
    // --partial-dir 把半截文件留在专属目录里，重跑时 rsync 以它为基底做增量，比 --append-verify 安全
    let resumeFlags = params.resume ? " --partial --partial-dir=.rsync-partial" : ""
    // 两段都写同一个日志文件：rsync 的 --log-file 是追加模式，一次中转的下载段与上传段会接在一起
    let logFlag = logPath.isEmpty ? "" : " --log-file=" + shellQuote(logPath)
    let flags = recursiveFlag + preserveFlag + resumeFlags + " --info=progress2" +
        bwlimitFlag(params.bwlimitKbps) + logFlag

    func sshE(_ host: String, _ port: String) -> String {
        port.isEmpty ? "" : " -e " + shellQuote("ssh -p \(port)")
    }
    let (tdir, tname) = splitDirAndName(t.path)
    // 目标目录的取法与 tar 流一致：同名时目标就是最终路径（用其父目录），不同名时目标当容器
    let targetBase = (tname == name) ? tdir : t.path
    let tdst = targetBase.hasSuffix("/") ? targetBase : targetBase + "/"
    let download = "rsync" + flags + sshE(s.host, s.port) + " " +
        shellQuote(s.host + ":" + s.path) + " " + shellQuote(stage + "/")
    // 目标写成「目录/」：落点是 <目标>/<源名>，重复执行只做同步、不会套娃。
    // --rsync-path 让远端先建目录 —— rsync 自己不会创建缺失的目录（否则报 mkdir failed）
    let rsyncPath = "mkdir -p " + shellQuote(targetBase) + " && rsync"
    let upload = "rsync" + flags + sshE(t.host, t.port) +
        " --rsync-path=" + shellQuote(rsyncPath) + " " +
        shellQuote(stage + "/" + name) + " " + shellQuote(t.host + ":" + tdst)
    return "mkdir -p " + shellQuote(stage) + " && " + download + " && " + upload +
        " && echo '中转完成，清理本机暂存' && rm -rf " + shellQuote(stage)
}

// 服务器↔服务器直拷失败时的一键中转：本机 tar 流（不占本地磁盘、不依赖源机 rsync）
// ssh 源机 tar 出 -> 本机管道 -> ssh 目标机 tar 入（目标路径自动 mkdir -p）
// 注：tar 流没有限速参数，bwlimit 只对 rsync 生效；这条路径的限速需要外部工具（pv/tsocket），不做
func buildRelayCopyCommand(params: CopyParams) -> String {
    guard let s = splitRemoteSpec(params.source),
          let t = splitRemoteSpec(params.target),
          !s.path.isEmpty, !t.path.isEmpty else {
        return ""
    }
    let (sdir, sname) = splitDirAndName(s.path)
    // tar 打包「源父目录 + 源条目」，解包目录按目标末段是否与源同名决定：
    //   同名（/data/report → /backup/report）：解到目标父目录，结果就是目标路径本身；
    //   不同名（/data/report → /backup）：目标当容器目录，解到目标里，结果是 /backup/report。
    // 两种情况都幂等，重复执行不会套娃成 …/report/report。
    let (tdir, tname) = splitDirAndName(t.path)
    let unpackDir = (tname == sname) ? tdir : t.path
    var srcSSH = "ssh"
    if !s.port.isEmpty { srcSSH += " -p \(s.port)" }
    var dstSSH = "ssh"
    if !t.port.isEmpty { dstSSH += " -p \(t.port)" }
    let srcCmd = "tar -cf - -C " + shellQuote(sdir) + " " + shellQuote(sname)
    let dstCmd = "mkdir -p " + shellQuote(unpackDir) + " && tar -xf - -C " + shellQuote(unpackDir)
    return srcSSH + " " + shellQuote(stripBrackets(s.host)) + " " + shellQuote(srcCmd) +
        " | " + dstSSH + " " + shellQuote(stripBrackets(t.host)) + " " + shellQuote(dstCmd)
}

// —— 生成 Terminal 启动脚本（纯函数，便于 zsh -n 语法校验与断言）——
// autoCloseOnSuccess：成功时按 tty 精确关闭本 tab 所在窗口（匹配不到则不关，避免误关其它窗口）
// logPath：非空时把「开始/结束 + 退出码」追加进日志；rsync 自身的明细由 --log-file 写同一个文件
// startNote：日志里记的这次任务摘要（源 → 目标），便于事后回看是哪一次运行
func buildCommandScript(cmdLine: String, pathPrepend: [String], autoCloseOnSuccess: Bool,
                        logPath: String = "", startNote: String = "") -> String {
    let pathLine = buildPathExport(pathPrepend)
    var lines: [String] = ["#!/bin/zsh"]
    if !pathLine.isEmpty { lines.append(pathLine) }
    // 记录本 tab 的 tty，供成功关窗时精确匹配
    lines.append("_tty=$(tty 2>/dev/null)")
    let logging = !logPath.isEmpty
    if logging {
        // 日志目录可能还不存在（首次运行），先建出来
        lines.append("mkdir -p " + shellQuote((logPath as NSString).deletingLastPathComponent))
        lines.append("printf '[%s] 开始 %s\\n' \"$(date '+%F %T')\" " + shellQuote(startNote) +
                     " >> " + shellQuote(logPath))
    }
    lines.append(cmdLine)
    if logging || autoCloseOnSuccess {
        lines.append("_rc=$?")
    }
    if logging {
        lines.append("printf '[%s] 结束，退出码 %d\\n' \"$(date '+%F %T')\" \"$_rc\" >> " + shellQuote(logPath))
    }
    if autoCloseOnSuccess {
        lines.append("echo \"===== 拷贝完成（退出码 $_rc）=====\"")
        lines.append("if [ $_rc -eq 0 ]; then")
        lines.append("    sleep 2")
        lines.append("    osascript -e 'tell application \"Terminal\"' \\")
        lines.append("      -e 'try' \\")
        lines.append("      -e 'repeat with w in windows' \\")
        lines.append("      -e 'if (tty of selected tab of w) is \"'\"$_tty\"'\" then' \\")
        lines.append("      -e 'close w saving no' \\")
        lines.append("      -e 'exit repeat' \\")
        lines.append("      -e 'end if' \\")
        lines.append("      -e 'end repeat' \\")
        lines.append("      -e 'end try' \\")
        lines.append("      -e 'end tell' >/dev/null 2>&1")
        lines.append("fi")
    }
    if logging || autoCloseOnSuccess {
        lines.append("exit $_rc")
    }
    return lines.joined(separator: "\n") + "\n"
}

// 文件修改时间（用于 ~/.ssh/config 变更后刷新免密主机缓存）
func fileModificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

func sshConfigPath() -> String {
    NSHomeDirectory() + "/.ssh/config"
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
        "pathPrepend": defaultPathPrepend,
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

// —— 上次互拷任务 ——
// 续传的前提是「源/目标不变、再点一次」，但 app 重启后表单是空的，等于续不上。
// 单独存一个文件而不是写回 config.json：config 是手写的，程序不该去改它的格式。
// 只存路径与选项，不存密码（密码从不落盘，仍由 ssh 在真 TTY 里交互）。
struct CopyMemory {
    var source: String
    var target: String
    var recursive: Bool
    var preserveAttrs: Bool
    var resume: Bool
    var bwlimitMBps: String   // 原样保存用户输入（空表示不限速），回填后显示一致
}

func copyMemoryPath(home: String = NSHomeDirectory()) -> String {
    home + "/.config/ai-launcher/last-copy.json"
}

func encodeCopyMemory(_ m: CopyMemory) -> Data? {
    let dict: [String: Any] = [
        "source": m.source,
        "target": m.target,
        "recursive": m.recursive,
        "preserveAttrs": m.preserveAttrs,
        "resume": m.resume,
        "bwlimitMBps": m.bwlimitMBps,
    ]
    return try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
}

// 容错：缺字段用缺省值；源和目标都为空视为「没有记录」（避免回填一个空壳）
func decodeCopyMemory(_ data: Data) -> CopyMemory? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let source = json["source"] as? String ?? ""
    let target = json["target"] as? String ?? ""
    if source.isEmpty && target.isEmpty { return nil }
    return CopyMemory(source: source,
                      target: target,
                      recursive: json["recursive"] as? Bool ?? true,
                      preserveAttrs: json["preserveAttrs"] as? Bool ?? true,
                      resume: json["resume"] as? Bool ?? true,
                      bwlimitMBps: json["bwlimitMBps"] as? String ?? "")
}

func loadCopyMemory(path: String = copyMemoryPath()) -> CopyMemory? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return decodeCopyMemory(data)
}

@discardableResult
func saveCopyMemory(_ m: CopyMemory, path: String = copyMemoryPath()) -> Bool {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard let data = encodeCopyMemory(m) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
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
