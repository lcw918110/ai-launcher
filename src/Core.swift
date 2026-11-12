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
// 只剩 defaultFlags。历史上还有 hosts（「预设」下拉）与 defaultDirection / auth：
// - hosts 已删除：它要求手工维护一份「显示名 + user@host」清单，与 ~/.ssh/config 重复；
//   互拷的免密联想本来就实时读 ~/.ssh/config，改那边一处即可，不必维护两份。
// - defaultDirection / auth：方向由源/目标路径自动推导，密码走 Terminal 真 TTY 交互，两个键早已无意义。
struct CopyConfig {
    let defaultFlags: [String]     // rsync 额外参数数组
}

struct CopyParams {
    var source: String      // 本地路径 或 user@host[:port]:path
    var target: String      // 本地路径 或 user@host[:port]:path
    var preserveAttrs: Bool
    var resume: Bool        // 断点续传
    var bwlimitKbps: Int = 0 // rsync --bwlimit，单位 KiB/s；0 表示不限速
    // 注：没有 recursive 开关。互拷的对象本来就是目录/文件树，递归是固有行为；
    // 旧版那个复选框被 rsync 的 -a 吞掉（勾「保留属性」时取消「递归」照样递归），
    // 是个看得见却无效的控件，0.5.2 起删掉，命令里恒定带 -r。
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

// 连接串粘了却没点「解析」时，makeCopyParams 根本不读它，等于静默忽略用户输入。
// 判据：连接串非空 + 凭据框全空（解析、联想选中、浏览远端都会填凭据框）。
// 不替用户猜、不抢焦点，只在「开始拷贝」前拦一下并说清楚。
func needsParseReminder(conn: String, user: String, host: String, port: String) -> Bool {
    let c = conn.trimmingCharacters(in: .whitespacesAndNewlines)
    if c.isEmpty { return false }
    return user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
           host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
           port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

// 「解析」把 host 补进哪个路径框：**焦点在哪个框就补哪个框**（用户 0.5.4 明确要求）。
// 只有完全没有焦点记录时才兜底；兜底只补「空的那个框」，绝不改写用户已经写好的路径——
// 旧规则「目标空就填源」会把用户填好的本地源路径改成远端，目标反而空着，人工测试直接发现。
// 也不能要求用户一定点过路径框：窗口不是 key 时 textDidBeginEditing 一次都不发，
// 路径由 last-copy.json 回填时真人同样没点过框（0.5.1 的教训）。
enum ParseTargetField: String {
    case none, source, target
}

func resolveParseTarget(lastFocused: ParseTargetField,
                        source: String, target: String) -> ParseTargetField {
    if lastFocused != .none { return lastFocused }
    let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.isEmpty && t.isEmpty { return .target }   // 源已填 → 远端是目标
    if s.isEmpty && !t.isEmpty { return .source }   // 目标已填 → 远端是源
    return .target                                   // 两框都空（本地推远端）或都有内容：固定规则，状态栏写明怎么改
}

// 把解析出的 user@host[:port] 补进路径框的值（「解析」按钮回填路径用）
// - 空：留成 "user@host:"，末尾的冒号就是接着写路径的位置
// - 已是远端路径：只换 host 前缀、保留原路径，因此重复解析同一串结果不变（幂等）
// - 本地/相对路径：加前缀，等于「同一个路径在远端」
func applyHostToPath(_ path: String, hostSpec: String) -> String {
    let cur = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if cur.isEmpty { return hostSpec + ":" }
    // 用 splitRemoteSpec 而不是 splitRemotePath：路径框里可能已有 "user@host:端口:/路径"，
    // 只按第一个冒号拆会把端口当路径（"2200:/data"），拼出来就是 "host:2200:2200:/data"
    if isRemotePath(cur), let sp = splitRemoteSpec(cur) { return hostSpec + ":" + sp.path }
    return hostSpec + ":" + cur
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

// —— 「浏览远端」的前置校验（纯函数，先拦脏输入再碰 NSAlert / ssh）——
// 旧实现只判断路径里有没有冒号：ssh://bad 被拆成 host="ssh"、乱码:xxx 被拆成 host="乱码"，
// 照样弹「浏览远端目录」输入框并真的发起 ssh，最后给用户一个看不懂的「远端浏览失败」。
// 另外 splitRemotePath 只拆第一个冒号，host:2200:/data 会丢端口、起始路径变成 "2200:/data"。
struct BrowseHostPlan {
    let hostSpec: String     // 要 ssh 的 user@host[:port]；被拦下时为空
    let startPath: String    // 远端起始路径（空路径默认 ~）
    let error: String        // 非空 = 拦下，不弹窗、不发起 ssh
    let note: String         // 非空 = 状态栏附带说明主机来自哪里
}

// 无点的 ssh 别名只有在 ~/.ssh/config 里出现过才认，否则 "notahost" 也会被拿去连。
// IP / 域名 / 方括号 IPv6 直接放行；主机部分只允许 ASCII 主机名字符集。
func validBrowseHost(_ host: String, knownHosts: [String]) -> Bool {
    if host.isEmpty { return false }
    let allowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@[]:-")
    if host.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
    var hostOnly = host
    if let at = hostOnly.lastIndex(of: "@") {
        hostOnly = String(hostOnly[hostOnly.index(after: at)...])
    }
    if hostOnly.hasPrefix("[") && hostOnly.hasSuffix("]") { return true }
    if looksLikeHost(hostOnly) { return true }
    return knownHosts.contains(hostOnly) || knownHosts.contains(host)
}

func browseHostPlan(fieldText: String,
                    credUser: String, credHost: String, credPort: String,
                    otherPaths: [String],
                    knownHosts: [String]) -> BrowseHostPlan {
    let field = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !field.isEmpty {
        let bad = "路径框里的「\(field)」不是有效的远端地址：清空它，或先粘贴连接串点「解析」"
        if field.contains("://") || field.hasPrefix("/") || !isRemotePath(field) {
            return BrowseHostPlan(hostSpec: "", startPath: "", error: bad, note: "")
        }
        guard let sp = splitRemoteSpec(field), validBrowseHost(sp.host, knownHosts: knownHosts) else {
            return BrowseHostPlan(hostSpec: "", startPath: "",
                                  error: "路径框里的「\(field)」不是有效的远端地址：主机不在 ~/.ssh/config 里，或格式不对",
                                  note: "")
        }
        // splitRemoteSpec 把端口单独拆出来，这里拼回 hostSpec，浏览时端口不再丢
        let spec = sp.host + (sp.port.isEmpty ? "" : ":" + sp.port)
        return BrowseHostPlan(hostSpec: spec, startPath: sp.path.isEmpty ? "~" : sp.path,
                              error: "", note: "")
    }
    // 路径框为空：按「解析结果」的主机浏览（含端口），状态栏说明来源
    if !credHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let spec = buildHostSpec(ConnectionInfo(user: credUser, password: "",
                                                host: credHost, port: credPort))
        return BrowseHostPlan(hostSpec: spec, startPath: "~", error: "",
                              note: "路径框为空，已按「解析结果」的主机浏览")
    }
    // 兼容：另一个路径框里写了合法远端地址
    for p in otherPaths {
        let v = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRemotePath(v), let sp = splitRemoteSpec(v), validBrowseHost(sp.host, knownHosts: knownHosts) {
            let spec = sp.host + (sp.port.isEmpty ? "" : ":" + sp.port)
            return BrowseHostPlan(hostSpec: spec, startPath: "~", error: "",
                                  note: "已按另一个路径框里的主机浏览")
        }
    }
    return BrowseHostPlan(hostSpec: "", startPath: "",
                          error: "浏览远端前请先粘贴连接串并点「解析」", note: "")
}

// 连接串里的密码：解析出来只用来判断「有没有」，不回填、不进命令、不落盘。
// 但状态栏必须一次说全，否则用户会以为解析把密码弄丢了。
func passwordNotice(_ info: ConnectionInfo) -> String {
    info.password.isEmpty ? "" : "；连接串里的密码不保存，请在 Terminal 按 ssh 提示输入"
}

// 高级选项折叠后，按钮 tooltip 要能说出当前默认值（隐藏 ≠ 没接线）。
func advancedSummary(preserve: Bool, resume: Bool, bwlimit: String) -> String {
    let b = bwlimit.trimmingCharacters(in: .whitespacesAndNewlines)
    return "保留属性 \(preserve ? "✓" : "✗") · 断点续传 \(resume ? "✓" : "✗") · " +
           (b.isEmpty ? "不限速" : "限速 \(b) MB/s")
}

// —— 本机 rsync 到底能做到什么 ——
// macOS 自带的 /usr/bin/rsync 已经是 openrsync（自称 2.6.9 兼容）：认 --partial-dir、--bwlimit，
// 但**不认 --info=progress2，也没有 --log-file**。所以「命令存在」不等于「这堆参数能跑」——
// 只看 command -v 就拼 3.x 参数，会拼出一条必然报 unrecognized option 的命令，
// 而且只会在没装 Homebrew rsync 的机器上复现。
enum RsyncFlavor {
    case none        // 没装 rsync：退回 scp
    case openRsync   // 系统自带：能用，但不支持 --info=progress2 / --log-file
    case full        // GNU rsync 3.x：全支持
}

// 由 `rsync --version` 的输出判断实现（纯函数，便于断言，不 spawn 进程）
func parseRsyncFlavor(_ versionOutput: String) -> RsyncFlavor {
    let t = versionOutput.lowercased()
    if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .none }
    if t.contains("openrsync") { return .openRsync }
    if t.contains("rsync version") || t.contains("rsync  version") { return .full }
    // 认不出来的实现按保守处理：功能照跑，只是不加它可能不认的参数
    return .openRsync
}

// 探测本机 rsync 实现（有副作用：会 spawn 子进程；结果作为参数传入各拼装函数以便测试）
func rsyncFlavor() -> RsyncFlavor {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", "command -v rsync >/dev/null 2>&1 && rsync --version 2>&1 | head -2"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return .none }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return .none }
    return parseRsyncFlavor(String(data: data, encoding: .utf8) ?? "")
}

// 本机有没有 rsync（与 `command -v rsync` 同义，保留给「有/没有」的二值判断）
func hasRsync() -> Bool {
    rsyncFlavor() != .none
}

// —— 可达性探测：直连能不能走，只能实测 ——
// 直拷的前提是「源机 → 目标机」免密，不是「本机 → 两端」。这个前提在界面上看不出来，
// 也没有配置项可填，所以在源机上跑一次 BatchMode 的 ssh 来验：连不上或要密码就退非 0。
// 故意不加 StrictHostKeyChecking=accept-new：探测不该往别人的服务器写 known_hosts，
// 首次连接遇到未知主机键就判为不通 —— 改走中转即可，功能不损失。
func buildDirectProbeCommand(params: CopyParams) -> String {
    guard let s = splitRemoteSpec(params.source),
          let t = splitRemoteSpec(params.target),
          !s.path.isEmpty, !t.path.isEmpty else {
        return ""
    }
    let opts = "-o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1"
    // 在源机上执行：先确认它有 rsync（直拷靠它），再 ssh 到目标机验免密。
    // 两件事任一不成立都判直连不通 —— 都该走中转，而不是让直拷在 Terminal 里报错
    var inner = "command -v rsync >/dev/null 2>&1 && ssh " + opts
    if !t.port.isEmpty { inner += " -p \(t.port)" }
    inner += " " + shellQuote(stripBrackets(t.host)) + " true"
    var outer = "ssh " + opts
    if !s.port.isEmpty { outer += " -p \(s.port)" }
    return outer + " " + shellQuote(stripBrackets(s.host)) + " " + shellQuote(inner)
}

// 本机能否免密登录某台机器（中转的前提：本机持有两端凭证）
// host 传 splitRemoteSpec 出来的 user@host（不含端口），端口单独传
func buildLocalProbeCommand(host: String, port: String = "") -> String {
    guard !host.isEmpty else { return "" }
    let hostPart = stripBrackets(splitHostPort(host).0)
    var cmd = "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1"
    if !port.isEmpty { cmd += " -p \(port)" }
    return cmd + " " + shellQuote(hostPart.isEmpty ? host : hostPart) + " true"
}

// 双远端最终走哪条路。探测结果由调用方传入（探测要 spawn ssh，不进纯逻辑层）
enum CopyRoute {
    case direct       // 两端免密已实测通过：在源机执行 rsync
    case relayResume  // 直连不通，本机两端都到得了：两段 rsync，中断可续
    case relayTar     // 同上但没有可用的 rsync，或用户不要续传：tar 流，不占本地磁盘
    case unreachable  // 本机也到不了其中一端：给明确失败，不静默
}

func resolveDirectRoute(directReachable: Bool, localReachable: Bool,
                        resume: Bool, rsyncFlavor: RsyncFlavor) -> CopyRoute {
    if directReachable { return .direct }
    guard localReachable else { return .unreachable }
    return (resume && rsyncFlavor != .none) ? .relayResume : .relayTar
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

// —— 拷贝结果回收 ——
// 拷贝跑在 Terminal 里（真 TTY 才能交互输密码），app 拿不到 Process 的退出码，
// 只能读脚本层写进日志的那行「结束，退出码 N」。所以「进行中…」不能一直挂着：
// 轮询新增内容，看到结束行就把成功/失败写回状态栏，用户切走再回来也能知道结果。

struct CopyOutcome {
    var started: Bool      // 日志里出现了脚本层的「开始」行 = 脚本真的执行了
    var finished: Bool
    var exitCode: Int?
}

// 同一任务多次运行会追加多条结束行，取最后一条；rsync 明细里不会出现这个措辞
//
// started 的意义：`.command` 交给 Terminal 是**单向通道** —— open 与 NSWorkspace 的
// completionHandler 都只回报「请求已交给 Terminal」（实测 error=nil、bundle=com.apple.Terminal），
// 即使沙箱/策略把文稿拦了下来也一样。所以「脚本有没有真的跑起来」只能由脚本自己报：
// buildCommandScript 的第一条动作就是写「[时间] 开始 …」，读到它才算开始。
func parseCopyLogOutcome(_ text: String) -> CopyOutcome {
    var started = false
    var lastExit: Int?
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        // rsync 自己的明细行形如 "2026/11/11 22:01:07 [14720] …"，开头不是 "["，
        // 而脚本层的标记行一定以 "[时间] " 开头，两者不会混
        if line.hasPrefix("[") && line.contains("] 开始") { started = true }
        guard let r = line.range(of: "结束，退出码 ") else { continue }
        let digits = line[r.upperBound...].prefix { $0.isNumber }
        if let v = Int(digits) { lastExit = v }
    }
    return CopyOutcome(started: started, finished: lastExit != nil, exitCode: lastExit)
}

// 只读「本次运行新增」的内容。
// 必须记 offset：日志是追加的，读全量会把上一次运行留下的结束行当成这一次的结果，
// 出现「刚点下去就报失败」这种假象。文件被清空/重建时退回从 0 读。
func readNewText(path: String, fromOffset: Int64, maxBytes: Int = 65_536) -> (text: String, offset: Int64) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    guard let size = (attrs?[.size] as? NSNumber)?.int64Value else {
        return ("", fromOffset)          // 日志还没建出来（脚本刚启动），下次再看
    }
    var start = max(0, fromOffset)
    if size < start { start = 0 }
    if size - start > Int64(maxBytes) { start = size - Int64(maxBytes) }
    guard size > start, let fh = FileHandle(forReadingAtPath: path) else {
        return ("", size)
    }
    defer { try? fh.close() }
    try? fh.seek(toOffset: UInt64(start))
    let data = fh.readDataToEndOfFile()
    // 从中间截断可能切断多字节字符，用容错解码而不是失败返回空串
    return (String(decoding: data, as: UTF8.self), size)
}

// —— 启动通道：程序永远只能看到「请求已提交」，看不到「真的跑起来了」——
// open 的退出码对这件事没有信息量：文稿被沙箱/门禁拦下时它照样返回 0，
// 系统只会弹一个「不允许 Sandbox 在终端中打开文稿」，不给程序任何回调（0.4.9 实测）。
// 所以「有没有跑起来」的唯一可信证据是脚本自己写下的标记文件：
// buildCommandScript 的第一条动作就是创建它，命令再挂也一定留痕。
let launchStartGraceSeconds = 8      // 冷启动 Terminal 通常 1 秒内跑起来；8 秒还没痕迹就按「没跑起来」处理

enum LaunchStart: Equatable {
    case started         // 标记文件出现 = 真的在跑
    case waiting         // 还没到时限，不下结论
    case notStarted      // 到时限仍无痕迹 = 被拦下（沙箱 / 门禁 / 没有可打开它的程序）
}

func startMarkerPath(for scriptPath: String) -> String {
    scriptPath + ".started"
}

// 判定只吃「事实 + 等了多久」，不猜原因：原因写在兜底文案里让用户能看懂
func launchStartVerdict(hasMarker: Bool, waitedSeconds: Int) -> LaunchStart {
    if hasMarker { return .started }
    return waitedSeconds >= launchStartGraceSeconds ? .notStarted : .waiting
}

// 没跑起来时给用户看的话：既解释那个看不懂的系统弹窗，也给出此刻就能走通的路
func launchNotStartedNotice(scriptPath: String) -> String {
    let name = (scriptPath as NSString).lastPathComponent
    return "⚠️ 脚本没跑起来：macOS 没有把「\(name)」交给终端"
        + "（如果弹出了「不允许 Sandbox 在终端中打开文稿」，原因就是这个：发起请求的进程处在受限沙箱里，"
        + "系统直接拒掉这次文稿交接，而且不返回任何错误码）。"
        + "脚本已留在 \(scriptPath)，把它粘贴到终端里执行即可。"
}

// 体积文案（暂存目录占用、给用户看，不参与计算）
func humanSize(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB"]
    var v = Double(bytes) / 1024
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return String(format: "%.1f %@", v, units[i])
}

// 目录占用（递归；软链接不跟随，避免统计到别处或循环）
func directorySizeBytes(_ path: String) -> Int64 {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: path) else { return 0 }
    var total: Int64 = 0
    for case let rel as String in en {
        let full = path + "/" + rel
        guard let a = try? fm.attributesOfItem(atPath: full),
              let type = a[.type] as? FileAttributeType, type != .typeDirectory,
              type != .typeSymbolicLink,
              let n = a[.size] as? NSNumber else { continue }
        total += n.int64Value
    }
    return total
}


// 拼接互拷命令。返回命令行字符串
// logPath：rsync --log-file 的落点（空串不加）。只在「本机发起」的 rsync 上加；
// 双远端直拷是在源机上执行的，本机路径在源机不存在，故不加
// 服务器↔服务器直拷：ssh 到源机执行 rsync（避免本机中转）
// rsyncAvailable：本机是否有 rsync（由调用方用 hasRsync() 探测后传入，保持本函数无副作用可测）
// 自定义端口：rsync/scp 不支持 user@host:port:path，端口拆出后走 -e "ssh -p N" / scp -P
// useProgress2 / useLogFile：GNU rsync 才有的两个能力，由调用方按 rsyncFlavor() 传入；
// 系统自带的 openrsync 两个都不认，传 false 后命令里就不出现，避免拼出跑不通的参数
func buildCopyCommand(cfg: CopyConfig, params: CopyParams, rsyncAvailable: Bool,
                      logPath: String = "", useProgress2: Bool = true,
                      useLogFile: Bool = true) -> String {
    let srcRemote = isRemotePath(params.source)
    let dstRemote = isRemotePath(params.target)

    // 递归恒定：-a 本身含 -r，但关掉「保留属性」时也必须递归，所以显式写死 -r
    let recursiveFlag = " -r"
    let preserveFlag = params.preserveAttrs ? " -a" : ""
    // 续传统一用 --partial-dir：半截文件留在目标端的 .rsync-partial 里，重跑时 rsync 以它为基底做增量，
    // 不会把「看起来完整、实际缺尾」的文件留在最终路径；也不用 --append-verify —— 目标文件被改短时
    // 它会先追加一段垃圾再靠校验发现，大文件等于白传一遍
    let resumeFlags = params.resume ? " --partial --partial-dir=.rsync-partial" : ""
    let bwFlag = bwlimitFlag(params.bwlimitKbps)
    let extraFlags = cfg.defaultFlags.isEmpty ? "" : " " + cfg.defaultFlags.joined(separator: " ")
    let progressFlag = useProgress2 ? " --info=progress2" : ""

    // 服务器↔服务器直拷：ssh 到源机执行 rsync
    if srcRemote && dstRemote {
        guard let s = splitRemoteSpec(params.source),
              let t = splitRemoteSpec(params.target) else {
            return ""
        }
        // 在源机上跑 rsync；-e ssh 让源机 ssh 到目标机（目标机端口非 22 时须带 -p）
        // 日志不加：命令在源机上跑，本机日志路径在源机不一定存在
        var inner = "rsync" + recursiveFlag + preserveFlag + resumeFlags + progressFlag + bwFlag + extraFlags
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
        let logFlag = (useLogFile && !logPath.isEmpty) ? " --log-file=" + shellQuote(logPath) : ""
        var base = "rsync" + recursiveFlag + preserveFlag + resumeFlags + progressFlag +
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
    var scpFlags = " -r"
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
                             logPath: String = "", useProgress2: Bool = true,
                             useLogFile: Bool = true) -> String {
    guard let s = splitRemoteSpec(params.source),
          let t = splitRemoteSpec(params.target),
          !s.path.isEmpty, !t.path.isEmpty else {
        return ""
    }
    let stage = relayStagingDir(params: params, root: root)
    let name = splitDirAndName(s.path).name
    // 递归恒定：-a 本身含 -r，但关掉「保留属性」时也必须递归，所以显式写死 -r
    let recursiveFlag = " -r"
    let preserveFlag = params.preserveAttrs ? " -a" : ""
    // --partial-dir 把半截文件留在专属目录里，重跑时 rsync 以它为基底做增量，比 --append-verify 安全
    let resumeFlags = params.resume ? " --partial --partial-dir=.rsync-partial" : ""
    // 两段都写同一个日志文件：rsync 的 --log-file 是追加模式，一次中转的下载段与上传段会接在一起
    let logFlag = (useLogFile && !logPath.isEmpty) ? " --log-file=" + shellQuote(logPath) : ""
    let flags = recursiveFlag + preserveFlag + resumeFlags + (useProgress2 ? " --info=progress2" : "") +
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

// —— 启动工具的命令行（纯函数，可测、可 zsh -n 校验）——
// 启动工具的命令行：cd 到配置目录 → 清屏 → 跑 CLI → 回到该目录的交互式 shell。
// 不能用 `exec <cmd>`：exec 会用 CLI 顶替掉 shell，CLI 一退出窗口里只剩一个已结束、
// 不能再输入的会话；而且脚本里写在 exec 后面的行永远不会执行，收尾就完全不可控。
// 末尾 exec 到交互登录 shell 后，Terminal 打开 .command 时追加的 `; exit;` 再也执行不到，
// 窗口保持可用，工作目录仍是配置目录。用分号连接：CLI 失败/被 Ctrl-C 也能回到 shell。
func buildToolLaunchLine(dir: String, cmd: String) -> String {
    let esc = dir.replacingOccurrences(of: "'", with: "'\\''")
    return "cd '\(esc)' && clear && \(cmd); exec \"${SHELL:-/bin/zsh}\" -il"
}

// —— 生成 Terminal 启动脚本（纯函数，便于 zsh -n 语法校验与断言）——
// autoCloseOnSuccess：成功时按 tty 精确关闭本 tab 所在窗口（匹配不到则不关，避免误关其它窗口）
// logPath：非空时把「开始/结束 + 退出码」追加进日志；rsync 自身的明细由 --log-file 写同一个文件
// startNote：日志里记的这次任务摘要（源 → 目标），便于事后回看是哪一次运行
// markerPath：非空时首条动作就创建它 —— 这是「脚本真的跑起来了」的唯一可信证据
// （open 返回 0 只代表请求已提交，见 launchStartVerdict 上方注释）
func buildCommandScript(cmdLine: String, pathPrepend: [String], autoCloseOnSuccess: Bool,
                        logPath: String = "", startNote: String = "",
                        markerPath: String = "") -> String {
    let pathLine = buildPathExport(pathPrepend)
    var lines: [String] = ["#!/bin/zsh"]
    // 第一件事就留痕：后面 cd/命令/exec 全部失败，也还能证明「终端确实执行了这份脚本」
    if !markerPath.isEmpty { lines.append(": > " + shellQuote(markerPath)) }
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

// 写 JSON 统一走这里：不带 withoutEscapingSlashes 时，JSONSerialization 会把每个 "/" 写成 "\/"，
// 而这个文件里几乎全是 macOS 路径（/Users/...），手改时就变成 "\/Users\/me\/git\/a"，既难读又容易改错。
// 两种写法是等价的 JSON，解析结果完全一样，纯粹是可读性问题。
// 注：只有程序自己写出的文件受影响，手工编辑保存的不会带转义。
func encodeJSON(_ obj: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: obj,
                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
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
            "defaultFlags": [],
        ],
    ]
}

func ensureConfigExists(path: String = configPath) {
    let manager = FileManager.default
    let dir = (path as NSString).deletingLastPathComponent
    try? manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if !manager.fileExists(atPath: path) {
        if let data = encodeJSON(defaultConfigJSON()) {
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

// 读取 copy 段（可选，缺省返回空配置，向后兼容不报错；废弃键 hosts / defaultDirection / auth 直接忽略）
func loadCopyConfig(path: String = configPath) -> CopyConfig {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let copy = json["copy"] as? [String: Any] else {
        return CopyConfig(defaultFlags: [])
    }
    let flags = (copy["defaultFlags"] as? [Any] ?? []).compactMap { $0 as? String }
    return CopyConfig(defaultFlags: flags)
}

// —— 上次互拷任务 ——
// 续传的前提是「源/目标不变、再点一次」，但 app 重启后表单是空的，等于续不上。
// 单独存一个文件而不是写回 config.json：config 是手写的，程序不该去改它的格式。
// 只存路径与选项，不存密码（密码从不落盘，仍由 ssh 在真 TTY 里交互）。
struct CopyMemory {
    var source: String
    var target: String
    var preserveAttrs: Bool
    var resume: Bool
    var bwlimitMBps: String   // 原样保存用户输入（空表示不限速），回填后显示一致
    // 注：不存 recursive（递归恒真），旧文件里若有该键，读取时忽略即可。
}

func copyMemoryPath(home: String = NSHomeDirectory()) -> String {
    home + "/.config/ai-launcher/last-copy.json"
}

func encodeCopyMemory(_ m: CopyMemory) -> Data? {
    let dict: [String: Any] = [
        "source": m.source,
        "target": m.target,
        "preserveAttrs": m.preserveAttrs,
        "resume": m.resume,
        "bwlimitMBps": m.bwlimitMBps,
    ]
    return encodeJSON(dict)
}

// 容错：缺字段用缺省值；源和目标都为空视为「没有记录」（避免回填一个空壳）
// 旧版写的 recursive 键直接忽略（递归现在恒真），不必升级用户手上的 last-copy.json
func decodeCopyMemory(_ data: Data) -> CopyMemory? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let source = json["source"] as? String ?? ""
    let target = json["target"] as? String ?? ""
    if source.isEmpty && target.isEmpty { return nil }
    return CopyMemory(source: source,
                      target: target,
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
