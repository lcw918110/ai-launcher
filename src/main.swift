// AI启动器：常驻 Dock 的窗口式启动器（UI 层）
// - 固定窗口列出「目录 × CLI」按钮，点一下即在 Terminal 启动
// - 目录与 CLI 从 ~/.config/ai-launcher/config.json 读取，点「刷新」即时生效
// - 通过临时 .command 文件启动 Terminal，无需自动化授权
// 纯逻辑（连接串解析/命令拼装/配置读写/免密主机）在 src/Core.swift，测试见 tests/main.swift
import Cocoa

// 免授权启动：写临时 .command 文件并 open，Terminal 新窗口执行
func launchInTerminal(dir: String, tool: ToolConfig) {
    debugLog("launchInTerminal dir=\(dir) cmd=\(tool.cmd)")
    let esc = dir.replacingOccurrences(of: "'", with: "'\\''")
    let cmdLine = "cd '\(esc)' && export PATH=\"$HOME/.bun/bin:/opt/homebrew/bin:$PATH\" && clear && exec \(tool.cmd)"
    launchCommandInTerminal(cmdLine)
}

// 通用：把任意命令行写入临时 .command 文件，open 到 Terminal 执行（免授权、真 TTY 可交互输密码）
// autoCloseOnSuccess：命令退出码为 0 时，短暂展示完成提示后自动关闭 Terminal 窗口（用于拷贝等一次性任务）
func launchCommandInTerminal(_ cmdLine: String, autoCloseOnSuccess: Bool = false) {
    debugLog("launchCommandInTerminal cmd=\(cmdLine) autoClose=\(autoCloseOnSuccess)")
    let tail: String
    if autoCloseOnSuccess {
        tail = """
        local _rc=$?
        echo "===== 拷贝完成（退出码 $_rc）====="
        if [ $_rc -eq 0 ]; then
            sleep 2
            osascript -e 'tell application "Terminal" to close (front window)' >/dev/null 2>&1
        fi
        exit $_rc
        """
    } else {
        tail = ""
    }
    let content = """
    #!/bin/zsh
    export PATH="$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
    \(cmdLine)
    \(tail)
    """
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("ai-launcher-\(UUID().uuidString).command")
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
    chmod(path, 0o755)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [path]
    do { try p.run() } catch {
        NSLog("[AI启动器] open 失败: %@", "\(error)")
    }
    // 顺带清理超过 1 天的旧启动文件
    cleanupOldCommandFiles()
}

func cleanupOldCommandFiles() {
    let fm = FileManager.default
    let tmp = NSTemporaryDirectory()
    if let files = try? fm.contentsOfDirectory(atPath: tmp) {
        let cutoff = Date().addingTimeInterval(-86400)
        for f in files where f.hasPrefix("ai-launcher-") && f.hasSuffix(".command") {
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var toolPopup: NSPopUpButton!
    // 互拷表单控件
    var copySourceField: NSTextField!
    var copyTargetField: NSTextField!
    var copyConnField: NSTextField!      // 连接串输入框（粘贴自动解析）
    var copyUserField: NSTextField!      // 用户名
    var copyPassField: NSSecureTextField! // 密码（仅回显/可选；安全取舍：绝不写入 .command、不落盘，实际认证走 ssh 真 TTY 交互输密码）
    var copyHostField: NSTextField!      // IP/主机
    var copyPortField: NSTextField!      // 端口
    var copyRecursiveCheck: NSButton!
    var copyPreserveCheck: NSButton!
    var copyResumeCheck: NSButton!
    var copyStatusLabel: NSTextField!
    // 免密机器联想（实时筛选 ~/.ssh/config）
    var sshHostsCache: [SSHHost] = []
    var autocompleteSourceField: NSTextField?   // 触发联想的输入框（用于选中后填回正确框）
    var isBrowsingRemote = false                // 远端浏览进行中（防重入）

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AI启动器] 启动")
        ensureConfigExists()
        setupMainMenu()
        buildWindow()
        if gSelfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runSelfTest()
            }
        }
    }

    // 主菜单：让 App 激活时顶部菜单栏可用（含退出）
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出 AI 启动器（⌘Q）", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // —— 自测：模拟点击第一个启动按钮，验证完整链路 ——
    private func runSelfTest() {
        var buttons: [NSButton] = []
        if let stack = window?.contentView as? NSStackView {
            for case let row as NSStackView in stack.views {
                for case let b as NSButton in row.views where (b.identifier?.rawValue ?? "").hasPrefix("launch\u{1}") {
                    buttons.append(b)
                }
            }
        }
        if let first = buttons.first {
            debugLog("[自测] 找到 \(buttons.count) 个启动按钮，模拟点击「\(first.title)」")
            first.performClick(nil)
        } else {
            debugLog("[自测] 未找到任何启动按钮！")
        }

        // 自测：验证互拷区块已构建 + 命令拼装 + 连接串解析
        debugLog("[自测] 互拷源输入框存在 = \(copySourceField != nil)")
        debugLog("[自测] 互拷目标输入框存在 = \(copyTargetField != nil)")
        debugLog("[自测] 互拷连接串输入框存在 = \(copyConnField != nil)")
        debugLog("[自测] 互拷用户名输入框存在 = \(copyUserField != nil)")
        debugLog("[自测] 互拷密码输入框存在 = \(copyPassField != nil)")
        debugLog("[自测] 互拷主机输入框存在 = \(copyHostField != nil)")
        debugLog("[自测] 互拷端口输入框存在 = \(copyPortField != nil)")
        debugLog("[自测] 互拷开始按钮状态标签存在 = \(copyStatusLabel != nil)")

        // 纯逻辑回归测试已迁移到 tests/main.swift（swiftc src/Core.swift tests/main.swift，无 GUI 副作用）：
        // 覆盖连接串解析、方向推导、命令拼装、远端路径参数、填充决策、配置/免密主机解析。
        // 此处仅保留 GUI 存在性检查与模拟点击，验证界面链路。

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            debugLog("[自测] 结束，退出")
            NSApp.terminate(nil)
        }
    }

    // 点 Dock 图标重新显示窗口
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window == nil { buildWindow() } else { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func buildWindow() {
        let (dirs, tools) = loadConfig()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        let title = NSTextField(labelWithString: "AI 终端启动器")
        title.font = NSFont.boldSystemFont(ofSize: 16)
        stack.addView(title, in: .leading)

        for dir in dirs {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: "📂 \(dirLabel(dir))")
            label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            row.addView(label, in: .leading)
            for tool in tools {
                let b = NSButton(title: tool.name, target: self, action: #selector(launchTool(_:)))
                b.bezelStyle = .rounded
                b.controlSize = .small
                b.identifier = NSUserInterfaceItemIdentifier("launch\u{1}\(dir)\u{1}\(tool.cmd)")
                row.addView(b, in: .trailing)
            }
            row.setHuggingPriority(.defaultHigh, for: .horizontal)
            stack.addView(row, in: .leading)
        }

        // 其他目录行
        let otherRow = NSStackView()
        otherRow.orientation = .horizontal
        otherRow.spacing = 8
        let popup = NSPopUpButton()
        for tool in tools {
            popup.addItem(withTitle: tool.name)
            popup.lastItem?.representedObject = tool.cmd
        }
        toolPopup = popup
        let otherLabel = NSTextField(labelWithString: "📂 其他目录")
        otherLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let otherBtn = NSButton(title: "选择目录并启动", target: self, action: #selector(otherDirLaunch(_:)))
        otherBtn.bezelStyle = .rounded
        otherBtn.controlSize = .small
        otherRow.addView(otherLabel, in: .leading)
        otherRow.addView(popup, in: .leading)
        otherRow.addView(otherBtn, in: .trailing)
        stack.addView(otherRow, in: .leading)

        // 底部：刷新 + 提示
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        let refresh = NSButton(title: "↻ 刷新（重读配置）", target: self, action: #selector(refresh(_:)))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small
        let hint = NSTextField(labelWithString: "改 ~/.config/ai-launcher/config.json 后点刷新")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        bottomRow.addView(refresh, in: .leading)
        bottomRow.addView(hint, in: .trailing)
        stack.addView(bottomRow, in: .leading)

        // —— 📦 互拷区块 ——
        buildCopySection(into: stack)

        let size = stack.fittingSize
        let w = max(size.width, 460)
        let h = size.height
        let rect = NSRect(x: 0, y: 0, width: w, height: h)

        if window == nil {
            window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
            window.title = "AI 终端启动器"
            window.isReleasedWhenClosed = false // 关窗不释放，点 Dock 图标可随时找回
            window.center()
        }
        window.contentView = stack
        window.setFrame(rect.integral, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // —— 📦 互拷区块构建 ——
    private func buildCopySection(into stack: NSStackView) {
        let sep = NSBox()
        sep.boxType = .separator
        stack.addView(sep, in: .leading)

        let title = NSTextField(labelWithString: "📦 互拷")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        stack.addView(title, in: .leading)

        // 源路径
        let srcRow = NSStackView()
        srcRow.orientation = .horizontal
        srcRow.spacing = 8
        let srcLabel = NSTextField(labelWithString: "源路径")
        srcLabel.font = NSFont.systemFont(ofSize: 12)
        copySourceField = NSTextField(string: "")
        copySourceField.placeholderString = "本地路径 或 user@host:路径"
        copySourceField.controlSize = .small
        copySourceField.delegate = self
        copySourceField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let srcPick = NSButton(title: "选择…", target: self, action: #selector(pickSource(_:)))
        srcPick.bezelStyle = .rounded
        srcPick.controlSize = .small
        let srcBrowse = NSButton(title: "浏览远端", target: self, action: #selector(browseRemoteSource(_:)))
        srcBrowse.bezelStyle = .rounded
        srcBrowse.controlSize = .small
        srcRow.addView(srcLabel, in: .leading)
        srcRow.addView(copySourceField, in: .leading)
        srcRow.addView(srcPick, in: .trailing)
        srcRow.addView(srcBrowse, in: .trailing)
        stack.addView(srcRow, in: .leading)

        // 目标路径
        let dstRow = NSStackView()
        dstRow.orientation = .horizontal
        dstRow.spacing = 8
        let dstLabel = NSTextField(labelWithString: "目标路径")
        dstLabel.font = NSFont.systemFont(ofSize: 12)
        copyTargetField = NSTextField(string: "")
        copyTargetField.placeholderString = "本地路径 或 user@host:路径"
        copyTargetField.controlSize = .small
        copyTargetField.delegate = self
        copyTargetField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let dstPick = NSButton(title: "选择…", target: self, action: #selector(pickTarget(_:)))
        dstPick.bezelStyle = .rounded
        dstPick.controlSize = .small
        let dstBrowse = NSButton(title: "浏览远端", target: self, action: #selector(browseRemoteTarget(_:)))
        dstBrowse.bezelStyle = .rounded
        dstBrowse.controlSize = .small
        dstRow.addView(dstLabel, in: .leading)
        dstRow.addView(copyTargetField, in: .leading)
        dstRow.addView(dstPick, in: .trailing)
        dstRow.addView(dstBrowse, in: .trailing)
        stack.addView(dstRow, in: .leading)

        // 连接串（粘贴自动解析）
        let connRow = NSStackView()
        connRow.orientation = .horizontal
        connRow.spacing = 8
        let connLabel = NSTextField(labelWithString: "连接串")
        connLabel.font = NSFont.systemFont(ofSize: 12)
        copyConnField = NSTextField(string: "")
        copyConnField.placeholderString = "user@host / user:pass@host / ssh://… / host:port"
        copyConnField.controlSize = .small
        copyConnField.delegate = self
        copyConnField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let parseBtn = NSButton(title: "解析", target: self, action: #selector(parseConn(_:)))
        parseBtn.bezelStyle = .rounded
        parseBtn.controlSize = .small
        connRow.addView(connLabel, in: .leading)
        connRow.addView(copyConnField, in: .leading)
        connRow.addView(parseBtn, in: .trailing)
        stack.addView(connRow, in: .leading)

        // 用户名 / 密码 / IP / 端口（独立字段）
        let credRow = NSStackView()
        credRow.orientation = .horizontal
        credRow.spacing = 8
        copyUserField = NSTextField(string: "")
        copyUserField.placeholderString = "用户名"
        copyUserField.controlSize = .small
        copyUserField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        copyPassField = NSSecureTextField(string: "")
        copyPassField.placeholderString = "密码（可选，走 TTY 交互）"
        copyPassField.controlSize = .small
        copyPassField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        copyHostField = NSTextField(string: "")
        copyHostField.placeholderString = "IP/主机"
        copyHostField.controlSize = .small
        copyHostField.delegate = self
        copyHostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        copyPortField = NSTextField(string: "")
        copyPortField.placeholderString = "端口"
        copyPortField.controlSize = .small
        copyPortField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true
        credRow.addView(copyUserField, in: .leading)
        credRow.addView(copyPassField, in: .leading)
        credRow.addView(copyHostField, in: .leading)
        credRow.addView(copyPortField, in: .leading)
        stack.addView(credRow, in: .leading)

        // 选项复选
        let optRow = NSStackView()
        optRow.orientation = .horizontal
        optRow.spacing = 12
        copyRecursiveCheck = NSButton(checkboxWithTitle: "递归", target: nil, action: nil)
        copyRecursiveCheck.controlSize = .small
        copyRecursiveCheck.state = .on
        copyPreserveCheck = NSButton(checkboxWithTitle: "保留属性", target: nil, action: nil)
        copyPreserveCheck.controlSize = .small
        copyPreserveCheck.state = .on
        copyResumeCheck = NSButton(checkboxWithTitle: "断点续传", target: nil, action: nil)
        copyResumeCheck.controlSize = .small
        copyResumeCheck.state = .on
        optRow.addView(copyRecursiveCheck, in: .leading)
        optRow.addView(copyPreserveCheck, in: .leading)
        optRow.addView(copyResumeCheck, in: .leading)
        stack.addView(optRow, in: .leading)

        // 开始按钮 + 状态
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        let startBtn = NSButton(title: "开始拷贝", target: self, action: #selector(startCopy(_:)))
        startBtn.bezelStyle = .rounded
        startBtn.controlSize = .small
        copyStatusLabel = NSTextField(labelWithString: "就绪")
        copyStatusLabel.font = NSFont.systemFont(ofSize: 11)
        copyStatusLabel.textColor = .secondaryLabelColor
        actionRow.addView(startBtn, in: .leading)
        actionRow.addView(copyStatusLabel, in: .leading)
        stack.addView(actionRow, in: .leading)
    }

    // 选中免密机器后，按触发框类型智能填回，并联动填 IP/主机、用户名
    // （TriggerField / FillPlan / buildFillPlan 已迁至 src/Core.swift 纯函数）
    func applySSHHostToFields(_ spec: String) {
        let trigger: TriggerField
        if let src = autocompleteSourceField {
            if src === copySourceField { trigger = .source }
            else if src === copyTargetField { trigger = .target }
            else if src === copyConnField { trigger = .conn }
            else if src === copyHostField { trigger = .host }
            else { trigger = .none }
        } else {
            trigger = .none
        }

        let plan = buildFillPlan(
            trigger: trigger, spec: spec,
            sourceEmpty: copySourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            targetEmpty: copyTargetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            connEmpty: copyConnField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hostEmpty: copyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            userEmpty: copyUserField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )

        if let v = plan.sourceValue { copySourceField.stringValue = v }
        if let v = plan.targetValue { copyTargetField.stringValue = v }
        if let v = plan.connValue { copyConnField.stringValue = v }
        if let v = plan.hostValue { copyHostField.stringValue = v }
        if let v = plan.userValue { copyUserField.stringValue = v }

        let filled: String
        switch trigger {
        case .source: filled = "源路径前缀"
        case .target: filled = "目标路径前缀"
        case .conn: filled = "连接串"
        case .host: filled = "主机"
        case .none: filled = "路径前缀"
        }
        copyStatusLabel.stringValue = "已填入\(filled) \(spec)"
        debugLog("[互拷] 免密机器带入: \(spec) 触发框=\(filled)")
        // 清理触发框记录，避免残留状态影响后续操作
        autocompleteSourceField = nil
    }

    // —— 实时联想：输入时筛选免密机器，弹出菜单供选择 ——
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // 只在四个目标输入框触发联想
        guard field === copySourceField || field === copyTargetField ||
              field === copyConnField || field === copyHostField else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // 输入太短（<2 字符）不联想
        guard input.count >= 2 else { return }
        // 记录触发联想的输入框
        autocompleteSourceField = field
        // 缓存免密机器
        if sshHostsCache.isEmpty {
            sshHostsCache = loadSSHKnownHosts()
        }
        // 模糊匹配：host 或 user 或 user@host 包含输入片段
        let matches = sshHostsCache.filter { h in
            h.host.contains(input) || h.user.contains(input) || h.display.contains(input)
        }
        // 无匹配则直接返回（联想自动消失）
        guard !matches.isEmpty else { return }
        // 弹出联想菜单
        let menu = NSMenu()
        for h in matches.prefix(10) {
            let item = NSMenuItem(title: h.display, action: #selector(autocompleteSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = h.display
            menu.addItem(item)
        }
        // 在输入框下方弹出
        let fieldFrame = field.frame
        let point = NSPoint(x: fieldFrame.minX, y: fieldFrame.minY - 4)
        menu.popUp(positioning: nil, at: point, in: field.superview ?? field)
    }

    @objc func autocompleteSelected(_ sender: NSMenuItem) {
        guard let spec = sender.representedObject as? String else { return }
        applySSHHostToFields(spec)
    }

    // 解析连接串并回填凭据字段（用户名/密码/IP/端口）
    // 注意：不再自动填路径前缀——路径前缀由「联想选中」和「浏览远端」精确填到对应框，
    // 避免「源空填源、源非空填目标」的串框隐患。
    @objc func parseConn(_ sender: Any) {
        let raw = copyConnField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = parseConnection(raw)
        if info.host.isEmpty {
            copyStatusLabel.stringValue = "无法识别连接串，请检查格式"
            // 不记录原始串：连接串可能携带明文密码
            debugLog("[互拷] 连接串解析失败（长度 \(raw.count)）")
            return
        }
        copyUserField.stringValue = info.user
        copyPassField.stringValue = info.password
        copyHostField.stringValue = info.host
        copyPortField.stringValue = info.port

        copyStatusLabel.stringValue = "已解析：\(info.user.isEmpty ? "" : info.user + "@")\(info.host)\(info.port.isEmpty ? "" : ":" + info.port)"
        // 日志脱敏：不落原始连接串与明文密码
        debugLog("[互拷] 连接串解析成功: user=\(info.user) host=\(info.host) port=\(info.port) pass=\(maskSecret(info.password))")
    }

    @objc func pickSource(_ sender: Any) {
        if let p = pickPath(message: "选择源路径（文件或文件夹）") {
            copySourceField.stringValue = p
        }
    }

    @objc func pickTarget(_ sender: Any) {
        if let p = pickPath(message: "选择目标路径（文件或文件夹）") {
            copyTargetField.stringValue = p
        }
    }

    func pickPath(message: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url {
            return url.path
        }
        return nil
    }

    // 从当前连接信息或路径中解析出 hostSpec（user@host[:port]）
    // preferredField：优先从该字段提取 host（用于「浏览远端」时，浏览哪个框就用哪个框的 host）
    func currentHostSpec(preferredField: NSTextField? = nil) -> String {
        // 优先从 preferredField 提取 host（若有 user@host:path）
        if let pf = preferredField {
            let v = pf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if isRemotePath(v), let sp = splitRemotePath(v) {
                return sp.host
            }
        }
        // 其次用全局凭据（IP/主机框 + 用户名 + 端口）
        let connUser = copyUserField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let connHost = copyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let connPort = copyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !connHost.isEmpty {
            return buildHostSpec(ConnectionInfo(user: connUser, password: "", host: connHost, port: connPort))
        }
        // 最后从源/目标路径里提取 host（若有 user@host:path）
        for field in [copySourceField, copyTargetField] {
            let v = field?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if isRemotePath(v), let sp = splitRemotePath(v) {
                return sp.host
            }
        }
        return ""
    }

    // 浏览远端目录：ssh ls 列目录，用户点选后回填
    @objc func browseRemoteSource(_ sender: Any) {
        browseRemote(into: copySourceField)
    }
    @objc func browseRemoteTarget(_ sender: Any) {
        browseRemote(into: copyTargetField)
    }

    func browseRemote(into field: NSTextField) {
        guard !isBrowsingRemote else {
            copyStatusLabel.stringValue = "正在浏览远端，请稍候…"
            return
        }
        // 优先从当前浏览的 field 提取 host（避免串到另一个路径框的 host）
        let hostSpec = currentHostSpec(preferredField: field)
        if hostSpec.isEmpty {
            copyStatusLabel.stringValue = "浏览远端前请先解析连接串或填写 IP/主机"
            return
        }
        // 初始路径：若字段已有 user@host:path，取 path；否则默认 ~
        var initPath = "~"
        let cur = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if isRemotePath(cur), let sp = splitRemotePath(cur), !sp.path.isEmpty {
            initPath = sp.path
        }
        // 弹出输入框让用户填/确认远端路径
        let alert = NSAlert()
        alert.messageText = "浏览远端目录"
        alert.informativeText = "输入远端路径（相对或绝对），将列出其子目录"
        alert.addButton(withTitle: "列出")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = initPath
        alert.accessoryView = input
        if alert.runModal() != .alertFirstButtonReturn {
            return
        }
        let path = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // ssh 列目录放后台线程执行：ConnectTimeout 最长 8 秒，同步跑在主线程会卡死整个窗口
        isBrowsingRemote = true
        copyStatusLabel.stringValue = "正在列出远端目录…（\(hostSpec)）"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = sshListDir(hostSpec: hostSpec, path: path)
            DispatchQueue.main.async {
                self?.finishBrowseRemote(r, hostSpec: hostSpec, path: path, into: field)
            }
        }
    }

    // 浏览远端的目录选择回填（sshListDir 完成后回到主线程执行）
    private func finishBrowseRemote(_ r: (ok: Bool, output: String, error: String),
                                    hostSpec: String, path: String, into field: NSTextField) {
        isBrowsingRemote = false
        if !r.ok {
            copyStatusLabel.stringValue = "远端浏览失败：\(r.error.isEmpty ? "无法连接" : r.error)"
            debugLog("[互拷] 远端浏览失败 host=\(hostSpec) path=\(path) err=\(r.error)")
            let hint = NSAlert()
            hint.messageText = "远端浏览失败"
            hint.informativeText = "无法列出远端目录，可能原因：\n· 未配置 ssh 免密（请先 ssh-copy-id 到目标机）\n· 主机/端口错误\n· 网络不通\n\n错误信息：\(r.error)\n\n你也可以直接在路径框手动填写 user@host:路径。"
            hint.addButton(withTitle: "知道了")
            hint.runModal()
            return
        }
        let lines = r.output.split(separator: "\n").map { String($0) }
        if lines.isEmpty {
            copyStatusLabel.stringValue = "远端目录为空"
            return
        }
        // 用 NSAlert + NSPopUpButton 列目录供选择
        let sel = NSAlert()
        sel.messageText = "选择远端目录/文件"
        sel.informativeText = "当前目录：\(path)"
        sel.addButton(withTitle: "选中")
        sel.addButton(withTitle: "取消")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 25))
        for line in lines {
            popup.addItem(withTitle: line)
        }
        sel.accessoryView = popup
        if sel.runModal() != .alertFirstButtonReturn {
            return
        }
        guard let chosen = popup.selectedItem?.title else { return }
        // 拼成 user@host:path 回填
        let base = path.hasSuffix("/") ? path : path + "/"
        let full = hostSpec + ":" + base + chosen
        field.stringValue = full
        copyStatusLabel.stringValue = "已选择远端路径 \(full)"
        debugLog("[互拷] 远端浏览选中 host=\(hostSpec) path=\(path) chosen=\(chosen) -> \(full)")
    }

    @objc func startCopy(_ sender: Any) {
        let cfg = loadCopyConfig()
        var src = copySourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var dst = copyTargetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // 连接信息（用户名/密码/IP/端口）
        // 安全取舍：密码字段（copyPassField）此处【故意不读取】——密码绝不进入命令行、
        // 不写入 .command 文件、不落盘；实际认证由 ssh 在 Terminal 真 TTY 中交互提示输密码。
        // 密码框仅作回显/占位，用户仍需在 Terminal 里手动输密码（或依赖 ssh 密钥免密）。
        let connUser = copyUserField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let connHost = copyHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let connPort = copyPortField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let connSpec = buildHostSpec(ConnectionInfo(user: connUser, password: "", host: connHost, port: connPort))

        // 空路径检查
        if src.isEmpty && dst.isEmpty {
            copyStatusLabel.stringValue = "请填写源路径和目标路径"
            return
        }
        if src.isEmpty {
            copyStatusLabel.stringValue = "请填写源路径"
            return
        }
        if dst.isEmpty {
            copyStatusLabel.stringValue = "请填写目标路径"
            return
        }

        // 用连接信息补全纯路径前缀（仅对非 / 开头、无冒号的路径，视为远端相对路径）
        if !isRemotePath(src) && !src.hasPrefix("/") && !src.contains(":") {
            if connSpec.isEmpty {
                copyStatusLabel.stringValue = "源路径看起来是远端相对路径，但未填 IP/主机"
                return
            }
            src = connSpec + ":" + src
        }
        if !isRemotePath(dst) && !dst.hasPrefix("/") && !dst.contains(":") {
            if connSpec.isEmpty {
                copyStatusLabel.stringValue = "目标路径看起来是远端相对路径，但未填 IP/主机"
                return
            }
            dst = connSpec + ":" + dst
        }

        // 方向自动推导（不再依赖方向控件）
        let direction = deriveDirection(src: src, dst: dst)

        let params = CopyParams(
            source: src,
            target: dst,
            recursive: copyRecursiveCheck.state == .on,
            preserveAttrs: copyPreserveCheck.state == .on,
            resume: copyResumeCheck.state == .on,
            hostSpec: connSpec
        )

        // 本机是否有 rsync 一次性探测（结果同时用于命令拼装与降级提示）
        let rsyncOK = hasRsync()
        let cmd = buildCopyCommand(cfg: cfg, params: params, rsyncAvailable: rsyncOK)
        if cmd.isEmpty {
            copyStatusLabel.stringValue = "无法拼接命令，请检查路径格式"
            return
        }
        debugLog("[互拷] 方向=\(direction) 拼装命令: \(cmd)")

        // 状态提示
        switch direction {
        case "direct":
            copyStatusLabel.stringValue = "直拷：将在源机执行 rsync（若源机无 rsync 请改用拉取中转）"
        case "local":
            copyStatusLabel.stringValue = "本地拷贝：进行中…（Terminal 窗口查看进度）"
        default:
            copyStatusLabel.stringValue = "进行中…（Terminal 窗口查看进度）"
        }
        // 无 rsync 降级 scp 时明确告知（scp 不支持断点续传，不能静默降级）
        if !rsyncOK && direction != "local" && direction != "direct" {
            copyStatusLabel.stringValue += "（本机无 rsync，已降级 scp，断点续传不可用）"
        }

        // 普通执行（非 exec），前后 echo 提示，保留进度与完成提示
        let fullCmd = "echo '===== 开始拷贝 ====='; " + cmd
        launchCommandInTerminal(fullCmd, autoCloseOnSuccess: true)
    }

    @objc func launchTool(_ sender: NSButton) {
        debugLog("按钮点击: \(sender.title) id=\(sender.identifier?.rawValue ?? "nil")")
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("launch\u{1}") else { return }
        let parts = id.components(separatedBy: "\u{1}")
        guard parts.count == 3 else { return }
        let dir = parts[1], cmd = parts[2]
        launchInTerminal(dir: dir, tool: ToolConfig(name: cmd, cmd: cmd))
    }

    @objc func otherDirLaunch(_ sender: Any) {
        debugLog("其他目录启动点击")
        guard let item = toolPopup.selectedItem,
              let cmd = item.representedObject as? String else { return }
        if let dir = pickOtherDir() {
            launchInTerminal(dir: dir, tool: ToolConfig(name: cmd, cmd: cmd))
        }
    }

    // —— 互拷表单状态快照：刷新重建窗口时保留用户已填内容，避免清空 ——
    struct CopyFormState {
        var source: String; var target: String; var conn: String
        var user: String; var pass: String; var host: String; var port: String
        var recursive: Bool; var preserve: Bool; var resume: Bool
    }

    func captureCopyForm() -> CopyFormState {
        CopyFormState(source: copySourceField.stringValue, target: copyTargetField.stringValue,
                      conn: copyConnField.stringValue, user: copyUserField.stringValue,
                      pass: copyPassField.stringValue, host: copyHostField.stringValue,
                      port: copyPortField.stringValue,
                      recursive: copyRecursiveCheck.state == .on,
                      preserve: copyPreserveCheck.state == .on,
                      resume: copyResumeCheck.state == .on)
    }

    func restoreCopyForm(_ s: CopyFormState) {
        copySourceField.stringValue = s.source
        copyTargetField.stringValue = s.target
        copyConnField.stringValue = s.conn
        copyUserField.stringValue = s.user
        copyPassField.stringValue = s.pass
        copyHostField.stringValue = s.host
        copyPortField.stringValue = s.port
        copyRecursiveCheck.state = s.recursive ? .on : .off
        copyPreserveCheck.state = s.preserve ? .on : .off
        copyResumeCheck.state = s.resume ? .on : .off
    }

    @objc func refresh(_ sender: Any) {
        let form = copySourceField != nil ? captureCopyForm() : nil
        buildWindow()
        if let form = form { restoreCopyForm(form) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
let gSelfTest = CommandLine.arguments.contains("--selftest")
app.run()
