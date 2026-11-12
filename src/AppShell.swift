// UI 基础件与「在 Terminal 里跑命令」这条路径：无状态函数，不依赖 AppDelegate
// - 通过临时 .command 文件 + open 启动 Terminal，无需自动化授权，且是真 TTY（能交互输密码）
import Cocoa

// 滚动视图的文档视图：翻转坐标，让内容从顶部开始排列
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}


// 免授权启动：写临时 .command 文件并 open，Terminal 新窗口执行
func launchInTerminal(dir: String, tool: ToolConfig) {
    debugLog("launchInTerminal dir=\(dir) cmd=\(tool.cmd)")
    // 收尾逻辑在 Core 纯函数里（可测、可 zsh -n 校验）：退出 CLI 后回到可用 shell
    launchCommandInTerminal(buildToolLaunchLine(dir: dir, cmd: tool.cmd))
}

var lastCommandScriptPath = ""   // 最近一份启动脚本；open 失败时用来告诉用户手动执行哪一份
var lastLaunchMarkerPath = ""    // 与上面那份脚本配套的「真的跑起来了」标记文件

// 兜底：把脚本路径放进剪贴板，并返回一段能直接显示的话。
// 为什么必须有这条兜底：`.command` 交给 Terminal 是单向通道，被沙箱/门禁拦下时程序拿不到
// 任何错误（open 退出码仍是 0），用户只会看到一个看不懂的系统弹窗，然后什么也没发生。
func fallbackForNotStartedLaunch(scriptPath: String) -> String {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(scriptPath, forType: .string)
    debugLog("[启动] 脚本没跑起来，已把路径放进剪贴板: \(scriptPath)")
    return launchNotStartedNotice(scriptPath: scriptPath)
}

// 启动后盯着标记文件：到时限还没有痕迹 = 被拦下 → 走兜底。
// 用 Timer 而不是 sleep：不阻塞主线程，用户接着点别的按钮照常响应。
@discardableResult
func watchLaunchStart(scriptPath: String, onNotStarted: @escaping (String) -> Void) -> Timer {
    let marker = startMarkerPath(for: scriptPath)
    let t = Timer(timeInterval: Double(launchStartGraceSeconds), repeats: false) { _ in
        guard launchStartVerdict(hasMarker: FileManager.default.fileExists(atPath: marker),
                                 waitedSeconds: launchStartGraceSeconds) == .notStarted else { return }
        debugLog("[启动] 到时限仍无标记，判定没跑起来: \(scriptPath)")
        onNotStarted(fallbackForNotStartedLaunch(scriptPath: scriptPath))
    }
    RunLoop.main.add(t, forMode: .common)
    return t
}

// 被拦下时用我们自己的弹窗替代那个看不懂的系统提示：说清原因，并给出此刻能走通的路
func showLaunchBlockedAlert(notice: String, scriptPath: String) {
    // 自测会自己退出，弹模态框会卡住它；自测里只记日志（断言走 marker 与剪贴板）
    guard !gSelfTest else {
        debugLog("[启动] 自测模式不弹模态框，兜底文案: \(notice)")
        return
    }
    let alert = NSAlert()
    alert.messageText = "没能打开终端窗口"
    alert.informativeText = notice
    alert.addButton(withTitle: "好")
    alert.addButton(withTitle: "在 Finder 中显示")
    if alert.runModal() == .alertSecondButtonReturn {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: scriptPath)])
    }
}

// 通用：把任意命令行写入临时 .command 文件，open 到 Terminal 执行（免授权、真 TTY 可交互输密码）
// autoCloseOnSuccess：命令退出码为 0 时，短暂展示完成提示后自动关闭 Terminal 窗口（用于拷贝等一次性任务）
// logPath：非空时把「开始/结束 + 退出码」写进日志（rsync 明细由 --log-file 写同一个文件）
// 返回：open 是否成功提交。注意 void 通道的局限见 parseCopyLogOutcome 的注释 ——
// open 返回 0 只代表「请求已交给 LaunchServices」，文稿被拦时它照样返回 0。
@discardableResult
func launchCommandInTerminal(_ cmdLine: String, autoCloseOnSuccess: Bool = false,
                             logPath: String = "", startNote: String = "") -> Bool {
    debugLog("launchCommandInTerminal cmd=\(cmdLine) autoClose=\(autoCloseOnSuccess) log=\(logPath)")
    let pathPrepend = loadPathPrepend()
    debugLog("启动脚本 PATH 前缀: \(pathPrepend.joined(separator: ":"))")
    // 标记文件与脚本同名同目录：清理旧脚本时一起清掉，不会越攒越多
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("ai-launcher-\(UUID().uuidString).command")
    let markerPath = startMarkerPath(for: path)
    // 脚本内容由 Core 的纯函数生成（可测、可用 zsh -n 校验）
    let content = buildCommandScript(cmdLine: cmdLine,
                                     pathPrepend: pathPrepend,
                                     autoCloseOnSuccess: autoCloseOnSuccess,
                                     logPath: logPath,
                                     startNote: startNote,
                                     markerPath: markerPath)
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    lastCommandScriptPath = path
    lastLaunchMarkerPath = markerPath
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [path]
    do { try p.run() } catch {
        debugLog("[启动] open 无法执行: \(error)")
        cleanupOldCommandFiles()
        return false
    }
    p.waitUntilExit()
    // open 对「文稿被拦」不报错，但对「文件不存在 / 没有能打开它的程序」会返回非 0 —— 这类才抓得住
    if p.terminationStatus != 0 {
        debugLog("[启动] open 退出码 \(p.terminationStatus)，脚本留在 \(path)")
    }
    // 顺带清理超过 1 天的旧启动文件
    cleanupOldCommandFiles()
    return p.terminationStatus == 0
}

func cleanupOldCommandFiles() {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory()
    if let files = try? fm.contentsOfDirectory(atPath: tmp) {
        let cutoff = Date().addingTimeInterval(-86400)
        for f in files where f.hasPrefix("ai-launcher-")
            && (f.hasSuffix(".command") || f.hasSuffix(".started")) {
            let p = (tmp as NSString).appendingPathComponent(f)
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let mtime = attrs[.modificationDate] as? Date, mtime < cutoff {
                try? fm.removeItem(atPath: p)
            }
        }
    }
}

func pickOtherDir() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "选择要在哪个目录启动 CLI"
    if panel.runModal() == .OK, let url = panel.url {
        return url.path
    }
    return nil
}
