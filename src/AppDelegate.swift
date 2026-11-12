// AppDelegate：窗口、菜单、生命周期
// 互拷相关的实现分在 CopyForm.swift（表单与浏览）与 CopyRunner.swift（执行与结果回收）
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var toolPopup: NSPopUpButton!
    // 互拷表单控件
    var copySourceField: NSTextField!
    var copyTargetField: NSTextField!
    var copyConnField: NSTextField!      // 连接串输入框（粘贴后点「解析」生效）
    // 以下三个是「解析结果」的只读展示，不是输入控件；要换主机改连接串再解析一次
    var copyUserField: NSTextField!      // 用户名
    var copyHostField: NSTextField!      // IP/主机
    var copyPortField: NSTextField!      // 端口
    var copyPreserveCheck: NSButton!
    var copyResumeCheck: NSButton!
    var copyBwlimitField: NSTextField!   // 限速（MB/s，空 = 不限速）
    var copyStatusLabel: NSTextField!
    var copyStartBtn: NSButton?          // 探测直连期间临时置灰，避免连点重复发起
    // 结果回收：拷贝在 Terminal 里跑，app 只能靠轮询日志新增内容得知退出码
    var outcomeTimer: Timer?
    var outcomeLogPath = ""
    var outcomeOffset: Int64 = 0
    var outcomeBaseStatus = ""           // 轮询期间保留「走的哪条路」这句，只在其后追加已运行时长
    var outcomeHasStarted = false        // 日志里出现过脚本层的「开始」行 = 拷贝真的在跑
    var outcomeStartedAt = Date()
    var lastPathField: NSTextField?        // 最近聚焦过的路径框（源/目标）；「解析」据此决定往哪个框回填
    var pathFocusObserver: NSObjectProtocol?  // 直接听 textDidBeginEditing 通知，不只看 delegate 回调
    var contentStack: NSStackView!        // 滚动视图里的内容栈（自测与刷新用）
    // 免密机器联想（实时筛选 ~/.ssh/config）
    var sshHostsCache: [SSHHost] = []
    var sshHostsMTime: Date?                    // ~/.ssh/config 修改时间，变了就重载缓存
    var autocompleteSourceField: NSTextField?   // 触发联想的输入框（用于选中后填回正确框）
    var suggestions: SuggestionController?      // 非阻塞候选框
    var suggestionTimer: Timer?                 // 输入去抖
    var isBrowsingRemote = false                // 远端浏览进行中（防重入）

    deinit {
        if let observer = pathFocusObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[AI启动器] 启动")
        ensureConfigExists()
        setupMainMenu()
        buildWindow()
        // 焦点记录双保险：delegate 回调之外，直接听系统的 textDidBeginEditing 通知。
        // 窗口不是 key（自动化/后台）时 delegate 可能一次都不发，通知这条链更直接。
        pathFocusObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidBeginEditingNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self = self, let f = note.object as? NSTextField else { return }
            if f === self.copySourceField || f === self.copyTargetField { self.lastPathField = f }
        }
        // 自测要的是干净的表单，回填会干扰断言
        if !gSelfTest { restoreLastCopyIfEmpty() }
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
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editMenuItem)

        // 「工具」：出问题时的入口都放这儿。日志与暂存目录都在 ~/Library 深处，
        // 让用户自己去 Finder 里翻等于没有这个功能。
        let toolMenuItem = NSMenuItem()
        let toolMenu = NSMenu(title: "工具")
        toolMenuItem.submenu = toolMenu
        func addToolItem(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            toolMenu.addItem(item)
        }
        addToolItem("打开日志目录", #selector(openLogDir(_:)))
        addToolItem("打开中转暂存目录", #selector(openRelayStagingDir(_:)))
        addToolItem("清除中转暂存…", #selector(clearRelayStaging(_:)))
        toolMenu.addItem(.separator())
        addToolItem("打开配置文件", #selector(openConfigFile(_:)))
        mainMenu.addItem(toolMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // —— 「工具」菜单：把 ~/Library 里的两个目录和一键清理摆到菜单上 ——
    @objc func openLogDir(_ sender: Any) {
        let root = copyLogRoot()
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    @objc func openRelayStagingDir(_ sender: Any) {
        let root = relayStagingRoot()
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
    }

    // 暂存目录平时是空的（中转成功会自动清），留着的是「中断了还没续完」的；清之前把占用和后果说清楚
    @objc func clearRelayStaging(_ sender: Any) {
        let root = relayStagingRoot()
        let bytes = directorySizeBytes(root)
        let alert = NSAlert()
        if bytes == 0 {
            alert.messageText = "中转暂存是空的"
            alert.informativeText = "\(root)\n\n中转成功时程序会自动清理暂存；留下的只可能是中断未续完的任务。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        alert.messageText = "清除中转暂存？"
        alert.informativeText = "将删除 \(humanSize(bytes))：\(root)\n\n这是未完成的中转留下的一半数据，删掉后这些任务下次要从头传。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ok = (try? FileManager.default.removeItem(atPath: root)) != nil
        copyStatusLabel?.stringValue = ok
            ? "已清除中转暂存（释放 \(humanSize(bytes))）"
            : "清除失败，可手动删除：\(root)"
    }

    @objc func openConfigFile(_ sender: Any) {
        ensureConfigExists()
        NSWorkspace.shared.open(URL(fileURLWithPath: configPath))
    }

    // —— 自测：模拟点击第一个启动按钮，验证完整链路 ——
    private func runSelfTest() {
        // 按钮覆盖契约：所有自测里的真人点击都走这里记账，末尾会核对「每个互拷按钮都有用例」。
        // 新增按钮却没补用例 → 自测红，逼着把明显 bug 挡在人工介入之前（0.5.4）。
        var clickedTitles: Set<String> = []
        func buttonKey(_ title: String) -> String {
            title.hasPrefix("高级选项") ? "高级选项" : title
        }
        func click(_ b: NSButton?) {
            guard let b = b else { return }
            clickedTitles.insert(buttonKey(b.title))
            b.performClick(nil)
        }
        var buttons: [NSButton] = []
        if let stack = contentStack {
            for case let row as NSStackView in stack.views {
                for case let b as NSButton in row.views where (b.identifier?.rawValue ?? "").hasPrefix("launch\u{1}") {
                    buttons.append(b)
                }
            }
        }
        let didClickLaunch = buttons.first != nil && !CommandLine.arguments.contains("--no-launch")
        if let first = buttons.first, didClickLaunch {
            debugLog("[自测] 找到 \(buttons.count) 个启动按钮，模拟点击「\(first.title)」")
            click(first)
        } else {
            debugLog("[自测] 找到 \(buttons.count) 个启动按钮（--no-launch：不点击、不弹 Terminal）")
        }

        // 启动工具收尾：真人点击后读「真正写到磁盘的那份 .command」，而不是调用函数看返回值。
        // --no-launch 时明确记 SKIP，绝不算 PASS（0.5.0 的假绿就是这么来的）。
        if !didClickLaunch {
            debugLog("[WIRING] 启动脚本收尾 = SKIP（--no-launch 未点击启动按钮）")
        } else {
            let p = lastCommandScriptPath
            let text = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
            let uiToolShell = !text.isEmpty && !text.contains(" && exec ") &&
                text.contains("exec \"${SHELL:-/bin/zsh}\" -il") && text.contains("cd '")
            debugLog("[WIRING] 启动脚本收尾 = \(uiToolShell ? "PASS" : "FAIL") 脚本=\(p) 长度=\(text.count)")

            // 0.5.5：脚本内容像不像只是必要条件，真正要验的是「终端有没有执行它」。
            // 沙箱里 open 返回 0、文稿却被拦下（系统弹「不允许 Sandbox 在终端中打开文稿」），
            // 所以这里按标记文件判事实，两条分支都必须成立才算 PASS：
            //   真跑了 → 标记文件存在；没跑 → 兜底文案 + 剪贴板里的脚本路径都在。
            let marker = lastLaunchMarkerPath
            var started = !marker.isEmpty && FileManager.default.fileExists(atPath: marker)
            var waited = 0.0
            while !started && waited < 3.0 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                waited += 0.4
                started = !marker.isEmpty && FileManager.default.fileExists(atPath: marker)
            }
            if started {
                debugLog("[TDD] 启动实证 = 终端真的执行了脚本 → PASS（标记 \(marker)，等了 \(String(format: "%.1f", waited))s）")
            } else {
                let notice = fallbackForNotStartedLaunch(scriptPath: p)
                let clip = NSPasteboard.general.string(forType: .string) ?? ""
                let ok = notice.contains("没跑起来") && clip == p && !notice.contains("已交给 Terminal")
                debugLog("[TDD] 启动实证 = 文稿没被交给终端（本机实例在受限环境里）→ 兜底 \(ok ? "PASS" : "FAIL") 剪贴板=\(clip)")
            }
        }

        // 不再用「控件存在 = true」这种假绿断言：控件被创建了不等于接线了。
        // 界面契约改由下面的 [WIRING] 行为断言（控件状态 + 真人点击结果）与 Core 单测覆盖。
        debugLog("[自测] 上次任务记录存在 = \(loadCopyMemory() != nil) 日志目录 = \(copyLogRoot())")
        debugLog("[自测] 窗口内容在滚动视图内 = \(window?.contentView is NSScrollView) 可缩放 = \(window?.styleMask.contains(.resizable) ?? false)")
        debugLog("[自测] 配置 PATH 前缀 = \(loadPathPrepend().joined(separator: ":"))")
        // —— 「解析」回填：模拟真人操作的 GUI 冒烟（TDD）——
        // 规矩：不手动设 lastPathField、不直接调 parseConn，全部走 firstResponder + 按钮 performClick。
        // 上一版的自测手工塞了 lastPathField，等于绕开了「用户到底有没有点过路径框」这一环，假绿。
        var parseBtn: NSButton?
        if let stack = contentStack {
            for case let row as NSStackView in stack.views {
                for case let b as NSButton in row.views where b.title == "解析" { parseBtn = b }
            }
        }
        func resetParseFields() {
            for f in [copySourceField, copyTargetField, copyConnField,
                      copyUserField, copyHostField, copyPortField] { f?.stringValue = "" }
            _ = window.makeFirstResponder(copyConnField)
            lastPathField = nil                 // 刚启动、还没点过任何路径框
            closeSuggestions()
        }
        debugLog("[TDD] 找到「解析」按钮 = \(parseBtn != nil)")

        // A：真人点过源路径框，再去连接串框粘贴，然后点「解析」——焦点在源就填源
        // --selftest 里窗口不是 key，makeFirstResponder 不发 textDidBeginEditing；
        // post 系统通知补上真机会发的那一条，模拟的是真人聚焦而不是手设状态变量。
        resetParseFields()
        _ = window.makeFirstResponder(copySourceField)
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copySourceField)
        copySourceField.stringValue = "/tmp/demo"
        _ = window.makeFirstResponder(copyConnField)
        copyConnField.stringValue = "jykj@192.0.2.9:2200"
        click(parseBtn)
        let tddA = copySourceField.stringValue == "jykj@192.0.2.9:2200:/tmp/demo"
        debugLog("[TDD] A 焦点在源路径框 → \(tddA ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 状态=\(copyStatusLabel.stringValue)")

        // B：从没点过路径框，但源路径已被程序回填（last-copy.json）——人工反馈「解析只给源路径」
        // 的新契约：源是用户写好的本地路径，不许被改写；host 补到空的目标框。
        resetParseFields()
        copySourceField.stringValue = "/tmp/demo"
        copyConnField.stringValue = "jykj@192.0.2.9:2200"
        click(parseBtn)
        let tddB = copySourceField.stringValue == "/tmp/demo" &&
                   copyTargetField.stringValue == "jykj@192.0.2.9:2200:"
        debugLog("[TDD] B 源已填、没点过框 → \(tddB ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 目标=\(copyTargetField.stringValue)")

        // C：两个路径框都空、从没点过 —— 默认按「本地推到远端」补目标，状态栏说明怎么换
        resetParseFields()
        copyConnField.stringValue = "jykj@192.0.2.9:2200"
        click(parseBtn)
        let tddC = copyTargetField.stringValue == "jykj@192.0.2.9:2200:" && copySourceField.stringValue.isEmpty
        debugLog("[TDD] C 两框都空 → \(tddC ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 目标=\(copyTargetField.stringValue)")

        // D：焦点在目标框，源框另有内容 —— 只填目标，不许串到源
        resetParseFields()
        copySourceField.stringValue = "/tmp/keep"
        _ = window.makeFirstResponder(copyTargetField)
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copyTargetField)
        copyTargetField.stringValue = "/data/in"
        _ = window.makeFirstResponder(copyConnField)
        copyConnField.stringValue = "jykj@192.0.2.9"
        click(parseBtn)
        let tddD = copyTargetField.stringValue == "jykj@192.0.2.9:/data/in" && copySourceField.stringValue == "/tmp/keep"
        debugLog("[TDD] D 点过目标框 → \(tddD ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 目标=\(copyTargetField.stringValue)")

        // E：焦点记录的监听链真的接上了（post 系统通知，不是手动改状态变量）
        resetParseFields()
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copySourceField)
        let tddE = lastPathField === copySourceField
        debugLog("[TDD] E 通知能记录焦点 → \(tddE ? "PASS" : "FAIL")")

        // F：有焦点记录时优先听它，哪怕另一个框有内容（焦点优先于内容规则）
        resetParseFields()
        copySourceField.stringValue = "/tmp/keep"
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copyTargetField)
        copyConnField.stringValue = "jykj@192.0.2.9"
        click(parseBtn)
        let tddF = copyTargetField.stringValue == "jykj@192.0.2.9:" && copySourceField.stringValue == "/tmp/keep"
        debugLog("[TDD] F 焦点优先于内容 → \(tddF ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 目标=\(copyTargetField.stringValue)")

        let passed = [tddA, tddB, tddC, tddD, tddE, tddF].filter { $0 }.count
        debugLog("[TDD] 解析回填 \(passed)/6 PASS")
        resetParseFields()

        // —— 界面接线契约（TDD 红灯）——
        // 「递归」复选框默认被 -a 吞掉、密码框从不进命令、凭据三框改了也不影响命令：
        // 这三类都是「可见但没接线」。断言的是控件状态与真人点击后的结果，不是「控件存在」。
        let uiRows: [NSStackView] = (contentStack?.views ?? []).compactMap { $0 as? NSStackView }
        let uiViews = uiRows.flatMap { $0.views }
        let uiButtons = uiViews.compactMap { $0 as? NSButton }
        let uiNoRecursive = !uiButtons.contains { $0.title == "递归" }
        let uiNoPassword = !uiViews.contains { $0 is NSSecureTextField }
        let uiCredsReadOnly = !copyUserField.isEditable && !copyHostField.isEditable && !copyPortField.isEditable
        debugLog("[WIRING] 界面无「递归」复选框 = \(uiNoRecursive ? "PASS" : "FAIL")")
        debugLog("[WIRING] 界面无密码输入框 = \(uiNoPassword ? "PASS" : "FAIL")")
        debugLog("[WIRING] 凭据框只读 = \(uiCredsReadOnly ? "PASS" : "FAIL")")
        // 真人操作：粘连接串 → 点「解析」，凭据框应显示结果且不可手改（能改却不生效才是坑）
        resetParseFields()
        copyConnField.stringValue = "jykj@192.0.2.9:2200"
        click(parseBtn)
        let uiParsedReadOnly = copyHostField.stringValue == "192.0.2.9" && !copyHostField.isEditable
        debugLog("[WIRING] 解析后主机只读且有值 = \(uiParsedReadOnly ? "PASS" : "FAIL") 主机=\(copyHostField.stringValue) 可编辑=\(copyHostField.isEditable)")
        // 真人操作：粘连接串不点「解析」直接点「开始拷贝」——必须明确拦下，不能静默忽略。
        // 路径框故意留空：即使这道防线被删，也只会得到「请填写源路径」，不会真拉起 Terminal 跑拷贝。
        var startBtn: NSButton?
        for row in uiRows {
            for case let b as NSButton in row.views where b.title == "开始拷贝" { startBtn = b }
        }
        resetParseFields()
        copyConnField.stringValue = "jykj@192.0.2.9:2200"
        click(startBtn)
        let uiConnGuard = copyStatusLabel.stringValue.contains("连接串还没解析")
        debugLog("[WIRING] 未解析连接串被拦下 = \(uiConnGuard ? "PASS" : "FAIL") 状态=\(copyStatusLabel.stringValue)")
        let wiringPassed = [uiNoRecursive, uiNoPassword, uiCredsReadOnly, uiParsedReadOnly, uiConnGuard].filter { $0 }.count
        debugLog("[WIRING] 界面接线 \(wiringPassed)/5 PASS")
        resetParseFields()

        // —— 0.5.4 人工反馈四连（TDD 红灯）——
        // 这些都属于「自己就该验出来」的明显 bug：解析焦点、密码去向、无效远端地址、折叠选项。
        // 规矩不变：只走 firstResponder 切换 + 系统通知 + 按钮 performClick，不手设被测状态。
        // G：焦点从源切到目标、连点两次「解析」，第二次必须落在目标框（不许残留上次焦点）
        resetParseFields()
        copySourceField.stringValue = "/tmp/keep"
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copySourceField)
        copyConnField.stringValue = "jykj@192.0.2.9"
        click(parseBtn)
        NotificationCenter.default.post(name: NSControl.textDidBeginEditingNotification, object: copyTargetField)
        copyConnField.stringValue = "jykj@192.0.2.9"
        click(parseBtn)
        let tddG = copySourceField.stringValue == "jykj@192.0.2.9:/tmp/keep" &&
                   copyTargetField.stringValue == "jykj@192.0.2.9:"
        debugLog("[TDD] G 焦点切换后连点两次解析 → \(tddG ? "PASS" : "FAIL") 源=\(copySourceField.stringValue) 目标=\(copyTargetField.stringValue)")

        // H：连接串里带密码 → 状态栏一次说全「不保存、在终端输」，且明文不落到任何回填控件
        resetParseFields()
        copyConnField.stringValue = "jykj:S3cret@192.0.2.9:2200"
        click(parseBtn)
        let leaked = [copySourceField.stringValue, copyTargetField.stringValue,
                      copyUserField.stringValue, copyHostField.stringValue, copyPortField.stringValue]
                     .contains(where: { $0.contains("S3cret") })
        let tddH = copyStatusLabel.stringValue.contains("密码") &&
                   !copyStatusLabel.stringValue.contains("S3cret") && !leaked
        debugLog("[TDD] H 密码去向写明且不落明文 → \(tddH ? "PASS" : "FAIL") 状态=\(copyStatusLabel.stringValue)")

        // K：源路径填无效信息 → 点「浏览远端」必须在弹窗 / 发起 ssh 之前拦下。
        // 红灯阶段先用不会弹 NSAlert 的 "abc"（当前实现只提示「请先解析」，不是新文案）；
        // 绿灯后会把 ssh:// 片段、非 ASCII、未知别名等脏输入一并纳入矩阵。
        var browseBtn: NSButton?
        for row in uiRows {
            // 源路径行在前：取第一个「浏览远端」，下面的脏输入写在源路径框
            for case let b as NSButton in row.views where b.title == "浏览远端" {
                if browseBtn == nil { browseBtn = b }
            }
        }
        resetParseFields()
        copySourceField.stringValue = "abc"
        click(browseBtn)
        let tddK = copyStatusLabel.stringValue.contains("不是有效的远端地址") && !isBrowsingRemote
        debugLog("[TDD] K 无效源路径点浏览远端被拦下 → \(tddK ? "PASS" : "FAIL") 状态=\(copyStatusLabel.stringValue)")

        // L：脏输入矩阵。修复前这些会弹 NSAlert 卡住自测、甚至真的发起 ssh，
        // 现在全部必须在弹窗之前被拦下。每条都是真人点击同一个按钮。
        let dirtyCases: [(String, String)] = [
            ("ssh://bad", "URL 片段"),
            ("乱码:xxx", "非 ASCII 主机"),
            ("notahost:/tmp", "未知别名"),
            ("/Users/me/wrong", "本地路径误填"),
        ]
        var dirtyPassed = 0
        for (input, label) in dirtyCases {
            resetParseFields()
            copySourceField.stringValue = input
            click(browseBtn)
            let ok = copyStatusLabel.stringValue.contains("不是有效的远端地址") && !isBrowsingRemote
            if ok { dirtyPassed += 1 }
            debugLog("[TDD] L 脏输入「\(label)」=\(input) → \(ok ? "PASS" : "FAIL") 状态=\(copyStatusLabel.stringValue)")
        }
        debugLog("[TDD] L 脏输入矩阵 \(dirtyPassed)/\(dirtyCases.count) PASS")

        // Q：目标路径框旁边的「浏览远端」同样要有真人点击用例（两个按钮同 title，契约按 title 会漏）
        var targetBrowseBtn: NSButton?
        var browseSeen = 0
        for row in uiRows {
            for case let b as NSButton in row.views where b.title == "浏览远端" {
                browseSeen += 1
                if browseSeen == 2 { targetBrowseBtn = b }
            }
        }
        resetParseFields()
        copyTargetField.stringValue = "ssh://bad"
        click(targetBrowseBtn)
        let tddQ = copyStatusLabel.stringValue.contains("不是有效的远端地址") && !isBrowsingRemote
        debugLog("[TDD] Q 目标框的浏览远端同样被拦下 → \(tddQ ? "PASS" : "FAIL") 状态=\(copyStatusLabel.stringValue)")

        // M/N/O：高级选项默认折叠、点开可见、默认值仍在（隐藏 ≠ 没接线）
        var advancedBtn: NSButton?
        for row in uiRows {
            for case let b as NSButton in row.views where b.title.hasPrefix("高级选项") { advancedBtn = b }
        }
        let optRow = copyPreserveCheck.superview as? NSStackView
        let tddM = advancedBtn != nil && (optRow?.isHidden ?? false)
        debugLog("[TDD] M 高级选项默认折叠 → \(tddM ? "PASS" : "FAIL") 按钮=\(advancedBtn?.title ?? "无") 隐藏=\(optRow?.isHidden ?? false)")
        click(advancedBtn)
        let tddN = (optRow?.isHidden ?? true) == false &&
                   copyPreserveCheck.state == .on && copyResumeCheck.state == .on &&
                   copyBwlimitField.stringValue.isEmpty &&
                   (advancedBtn?.toolTip?.contains("保留属性") ?? false)
        debugLog("[TDD] N 展开后默认选中且 tooltip 显示摘要 → \(tddN ? "PASS" : "FAIL") 隐藏=\(optRow?.isHidden ?? true) tooltip=\(advancedBtn?.toolTip ?? "无")")
        click(advancedBtn)
        let tddO = optRow?.isHidden ?? false
        debugLog("[TDD] O 再点收起 → \(tddO ? "PASS" : "FAIL")")

        // P：按钮覆盖契约 —— 互拷区每个非面板按钮都必须有一条真人点击用例。
        // 以后新增按钮却没补用例，这里立刻红，不用等人工发现它点不动 / 点了报错。
        var copySectionButtons: [NSButton] = []
        var inCopySection = false
        for v in contentStack?.views ?? [] {
            if let label = v as? NSTextField, label.stringValue.contains("互拷") { inCopySection = true }
            guard inCopySection, let row = v as? NSStackView else { continue }
            // 只看「动作按钮」：复选框 target/action 为空，它们由控件接线检查与默认值断言覆盖
            for case let b as NSButton in row.views where b.title != "选择…" && b.action != nil {
                copySectionButtons.append(b)
            }
        }
        let expectedButtons: Set<String> = ["解析", "浏览远端", "开始拷贝", "高级选项"]
        let actualButtons = Set(copySectionButtons.map { buttonKey($0.title) })
        let missingCases = expectedButtons.subtracting(clickedTitles)
        let untestedButtons = actualButtons.subtracting(expectedButtons)
        let tddP = missingCases.isEmpty && untestedButtons.isEmpty && !actualButtons.isEmpty
        debugLog("[WIRING] 按钮覆盖契约 = \(tddP ? "PASS" : "FAIL") 界面按钮=\(actualButtons.sorted()) 已点用例=\(clickedTitles.sorted()) 缺用例=\(missingCases.sorted()) 未覆盖新按钮=\(untestedButtons.sorted())")
        let dirtyOK = dirtyPassed == dirtyCases.count
        let manualPassed = [tddG, tddH, tddK, dirtyOK, tddQ, tddM, tddN, tddO, tddP].filter { $0 }.count
        debugLog("[TDD] 人工反馈四连 \(manualPassed)/9 PASS")
        resetParseFields()

        debugLog("[自测] 工具菜单（日志/暂存/配置）存在 = \(NSApp.mainMenu?.items.contains { $0.submenu?.title == "工具" } ?? false)")

        // 滚动布局是否真的生效：文档高度 vs 可视高度
        if let scroll = window?.contentView as? NSScrollView {
            let docH = scroll.documentView?.frame.height ?? 0
            let clipH = scroll.contentView.bounds.height
            debugLog("[自测] 滚动文档高=\(Int(docH)) 可视高=\(Int(clipH)) 需要滚动=\(docH > clipH + 1)")
        }

        // 窗口是否完整落在屏幕可见区内（防止刷新后窗口顶出屏幕，底部按钮点不到）
        if let w = window, let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let f = w.frame
            let inside = f.minX >= vf.minX - 0.5 && f.maxX <= vf.maxX + 0.5 &&
                         f.minY >= vf.minY - 0.5 && f.maxY <= vf.maxY + 0.5
            debugLog("[自测] 窗口在可见区内=\(inside) 窗口=\(Int(f.width))x\(Int(f.height))@(\(Int(f.minX)),\(Int(f.minY))) 可见区=\(Int(vf.width))x\(Int(vf.height))@(\(Int(vf.minX)),\(Int(vf.minY)))")
        }

        // 联想候选框冒烟：模拟输入免密主机片段，验证 Popover 能弹出且不崩
        // 凭据行已改只读，联想入口用连接串框（源/目标/连接串三个之一）
        reloadSSHHostsIfNeeded()
        if let first = sshHostsCache.first, window.makeFirstResponder(copyConnField) {
            copyConnField.stringValue = String(first.host.prefix(3))
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: copyConnField))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                debugLog("[自测] 联想候选框弹出 = \(self.suggestions?.isShown ?? false)（输入 \(self.copyConnField.stringValue)）")
                self.closeSuggestions()
            }
        } else {
            debugLog("[自测] 跳过联想冒烟（~/.ssh/config 无可用主机）")
        }

        // 纯逻辑回归测试已迁移到 tests/main.swift（swiftc src/Core.swift tests/main.swift，无 GUI 副作用）：
        // 覆盖连接串解析、方向推导、命令拼装、远端路径参数、填充决策、配置/免密主机解析。
        // 此处仅保留 GUI 存在性检查与模拟点击，验证界面链路。

        // --selftest-copy：真跑一次拷贝，验证「结果回收」把退出码写回状态栏。
        // 这条链路没法用断言覆盖（要 Terminal + RunLoop），只能这样冒烟；
        // 只在显式带该参数时触发，正常启动与普通 --selftest 都不会拷贝任何东西。
        if CommandLine.arguments.contains("--selftest-copy") {
            if let m = loadCopyMemory() {
                copySourceField.stringValue = m.source
                copyTargetField.stringValue = m.target
                copyResumeCheck.state = m.resume ? .on : .off
                debugLog("[自测] 拷贝冒烟: \(m.source) → \(m.target)")
                startCopy(self)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
                    debugLog("[自测] 状态栏 = \(self?.copyStatusLabel?.stringValue ?? "nil")")
                }
            } else {
                debugLog("[自测] 拷贝冒烟跳过：没有 last-copy.json")
            }
        }

        // 拷贝冒烟要多等一轮，否则状态栏还没回写就退出了
        let quitAfter: Double = CommandLine.arguments.contains("--selftest-copy") ? 14.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
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
        contentStack = stack

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

        // 内容放进滚动视图：目录一多也不会把窗口撑出屏幕，窗口高度限制在屏幕可用范围内
        let fitting = stack.fittingSize
        let contentW = max(fitting.width, 480)
        // visibleFrame 已扣掉菜单栏与 Dock；再留 40pt 余量，避免窗口贴死屏幕边缘
        let screenH = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maxWindowH = max(360, screenH - 40)
        let windowH = min(fitting.height, maxWindowH)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = doc

        NSLayoutConstraint.activate([
            // 内容宽度跟窗口一致，高度由内容自身决定
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        let rect = NSRect(x: 0, y: 0, width: contentW, height: windowH)

        if window == nil {
            window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
            window.title = "AI 终端启动器"
            window.isReleasedWhenClosed = false // 关窗不释放，点 Dock 图标可随时找回
            window.contentMinSize = NSSize(width: 480, height: 320)
            window.center()
        }
        window.contentView = scroll
        // 用 setContentSize 而不是 setFrame：后者带着 rect 的原点 (0,0)，刷新会把窗口甩到屏幕左下角，
        // 内容变高时还会顶出屏幕底部（底部的「开始拷贝」就看不见了）
        window.setContentSize(NSSize(width: contentW, height: windowH))
        clampWindowToScreen()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 把窗口夹回当前屏幕的可见区域（扣掉菜单栏与 Dock），用户拖到边缘也不至于整块跑出去
    private func clampWindowToScreen() {
        guard let window = window, let screen = window.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var f = window.frame
        if f.height > vf.height { f.size.height = vf.height }
        if f.width > vf.width { f.size.width = vf.width }
        if f.minX < vf.minX { f.origin.x = vf.minX }
        if f.maxX > vf.maxX { f.origin.x = vf.maxX - f.width }
        if f.minY < vf.minY { f.origin.y = vf.minY }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        if f != window.frame { window.setFrame(f, display: true) }
    }


    // 启动工具一律走这里：open 之后还要盯住「脚本到底有没有跑起来」。
    // 沙箱/门禁会静默拦下文稿交接（open 仍返回 0），只靠返回值就会「看起来成功、实际什么都没发生」，
    // 用户那边只看到一个看不懂的系统弹窗 —— 所以没跑起来时要由我们自己说清并给出可走的路（0.5.5）。
    private func launchToolInTerminal(dir: String, cmd: String) {
        launchInTerminal(dir: dir, tool: ToolConfig(name: cmd, cmd: cmd))
        let scriptPath = lastCommandScriptPath
        guard !scriptPath.isEmpty else { return }
        watchLaunchStart(scriptPath: scriptPath) { [weak self] notice in
            self?.copyStatusLabel?.stringValue = notice
            showLaunchBlockedAlert(notice: notice, scriptPath: scriptPath)
        }
    }

    @objc func launchTool(_ sender: NSButton) {
        debugLog("按钮点击: \(sender.title) id=\(sender.identifier?.rawValue ?? "nil")")
        guard let id = sender.identifier?.rawValue,
              id.hasPrefix("launch\u{1}") else { return }
        let parts = id.components(separatedBy: "\u{1}")
        guard parts.count == 3 else { return }
        let dir = parts[1], cmd = parts[2]
        launchToolInTerminal(dir: dir, cmd: cmd)
    }

    @objc func otherDirLaunch(_ sender: Any) {
        debugLog("其他目录启动点击")
        guard let item = toolPopup.selectedItem,
              let cmd = item.representedObject as? String else { return }
        if let dir = pickOtherDir() {
            launchToolInTerminal(dir: dir, cmd: cmd)
        }
    }

    @objc func refresh(_ sender: Any) {
        closeSuggestions()
        let form = copySourceField != nil ? captureCopyForm() : nil
        buildWindow()
        if let form = form { restoreCopyForm(form) }
    }
}
