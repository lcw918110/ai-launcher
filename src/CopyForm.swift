// 互拷表单：控件构建、免密主机联想、远端浏览、表单状态快照（AppDelegate 的扩展）
import Cocoa

extension AppDelegate {

    // —— 📦 互拷区块构建 ——
    func buildCopySection(into stack: NSStackView) {
        let sep = NSBox()
        sep.boxType = .separator
        stack.addView(sep, in: .leading)

        let title = NSTextField(labelWithString: "📦 互拷")
        title.font = NSFont.boldSystemFont(ofSize: 15)
        stack.addView(title, in: .leading)

        // 源头只有一个：~/.ssh/config。改那边一条 Host 就会出现在联想里，
        // 不必再在 config.json 里手抄一份「显示名 + user@host」的清单（原先的「预设」下拉已删除）

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

        // 连接串：粘贴后要点「解析」才会生效（不自动解析——自动解析会抢走正在输入的焦点）。
        // 万一用户粘完直接点「开始拷贝」，startCopy 会明确拦下并提示，不会静默忽略。
        let connRow = NSStackView()
        connRow.orientation = .horizontal
        connRow.spacing = 8
        let connLabel = NSTextField(labelWithString: "连接串")
        connLabel.font = NSFont.systemFont(ofSize: 12)
        copyConnField = NSTextField(string: "")
        copyConnField.placeholderString = "粘贴后点「解析」：user@host / ssh://… / host:port"
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

        // 「解析结果」只读展示：由「解析 / 联想选中 / 浏览远端」填入。
        // 以前这行是可编辑输入框，但改了 IP 框并不会改变命令（命令用的是路径框里的 user@host），
        // 属于「看得见、改了没反应」；密码框更是一开始就故意不进命令。现在改成明确的只读展示，
        // 要换主机就改连接串再点一次「解析」。
        let credRow = NSStackView()
        credRow.orientation = .horizontal
        credRow.spacing = 6
        func credCaption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        let credLabel = credCaption("解析结果（只读）")
        copyUserField = NSTextField(string: "")
        copyUserField.controlSize = .small
        copyUserField.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        copyHostField = NSTextField(string: "")
        copyHostField.controlSize = .small
        copyHostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        copyPortField = NSTextField(string: "")
        copyPortField.controlSize = .small
        copyPortField.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        let credFields: [NSTextField] = [copyUserField, copyHostField, copyPortField]
        for f in credFields {
            f.isEditable = false
            f.isSelectable = true   // 可选中复制，但不能改
            f.toolTip = "解析结果，只读；要换主机请改连接串再点「解析」"
        }
        credRow.addView(credLabel, in: .leading)
        credRow.addView(credCaption("用户"), in: .leading)
        credRow.addView(copyUserField, in: .leading)
        credRow.addView(credCaption("主机"), in: .leading)
        credRow.addView(copyHostField, in: .leading)
        credRow.addView(credCaption("端口"), in: .leading)
        credRow.addView(copyPortField, in: .leading)
        stack.addView(credRow, in: .leading)

        // 选项复选（递归不再是可关的开关：命令恒定带 -r，旧「递归」复选框被 -a 吞掉，已删）
        let optRow = NSStackView()
        optRow.orientation = .horizontal
        optRow.spacing = 12
        copyPreserveCheck = NSButton(checkboxWithTitle: "保留属性", target: nil, action: nil)
        copyPreserveCheck.controlSize = .small
        copyPreserveCheck.state = .on
        copyResumeCheck = NSButton(checkboxWithTitle: "断点续传", target: nil, action: nil)
        copyResumeCheck.controlSize = .small
        copyResumeCheck.state = .on
        optRow.addView(copyPreserveCheck, in: .leading)
        optRow.addView(copyResumeCheck, in: .leading)
        // 限速：留空表示不限速；输入 MB/s（可带小数），传给 rsync 时换算成 KiB/s
        let limitLabel = NSTextField(labelWithString: "限速")
        limitLabel.font = NSFont.systemFont(ofSize: 11)
        limitLabel.textColor = .secondaryLabelColor
        copyBwlimitField = NSTextField(string: "")
        copyBwlimitField.placeholderString = "不限"
        copyBwlimitField.controlSize = .small
        copyBwlimitField.toolTip = "MB/s，留空不限制；避免大文件占满专线。scp 降级时也生效，tar 流中转不生效"
        copyBwlimitField.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let limitUnit = NSTextField(labelWithString: "MB/s")
        limitUnit.font = NSFont.systemFont(ofSize: 11)
        limitUnit.textColor = .secondaryLabelColor
        optRow.addView(limitLabel, in: .leading)
        optRow.addView(copyBwlimitField, in: .leading)
        optRow.addView(limitUnit, in: .leading)

        // 高级选项默认收起：三个值仍按默认选中并始终被 makeCopyParams 读取（隐藏 ≠ 没接线）。
        // 折叠按钮的 tooltip 用 advancedSummary 说出当前默认值，收起时也能看见生效状态。
        optRow.isHidden = true
        let toggleRow = NSStackView()
        toggleRow.orientation = .horizontal
        toggleRow.spacing = 8
        let advancedToggle = NSButton(title: "高级选项 ▸", target: self,
                                      action: #selector(toggleAdvancedOptions(_:)))
        advancedToggle.bezelStyle = .rounded
        advancedToggle.controlSize = .small
        advancedToggle.toolTip = advancedSummary(preserve: true, resume: true, bwlimit: "")
        let advancedHint = NSTextField(labelWithString: "默认已开启，点开可改")
        advancedHint.font = NSFont.systemFont(ofSize: 11)
        advancedHint.textColor = .secondaryLabelColor
        toggleRow.addView(advancedToggle, in: .leading)
        toggleRow.addView(advancedHint, in: .leading)
        stack.addView(toggleRow, in: .leading)
        stack.addView(optRow, in: .leading)

        // 开始按钮 + 状态
        // 只有一个按钮：直连能不能走由后台实测决定，中转对用户不可见（见 startDirectResolve）
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        let startBtn = NSButton(title: "开始拷贝", target: self, action: #selector(startCopy(_:)))
        startBtn.bezelStyle = .rounded
        startBtn.controlSize = .small
        copyStartBtn = startBtn
        copyStatusLabel = NSTextField(labelWithString: "就绪")
        copyStatusLabel.font = NSFont.systemFont(ofSize: 11)
        copyStatusLabel.textColor = .secondaryLabelColor
        actionRow.addView(startBtn, in: .leading)
        actionRow.addView(copyStatusLabel, in: .leading)
        stack.addView(actionRow, in: .leading)
    }


    // 展开 / 收起高级选项。控件始终存在、默认值始终生效，只是不占主界面。
    @objc func toggleAdvancedOptions(_ sender: NSButton) {
        let row = copyPreserveCheck.superview as? NSStackView
        let expanding = row?.isHidden ?? false
        row?.isHidden = !expanding
        sender.title = expanding ? "高级选项 ▾" : "高级选项 ▸"
        // tooltip 读的是三个控件当前的值，收起后仍能看见「默认选中了什么」
        sender.toolTip = advancedSummary(preserve: copyPreserveCheck.state == .on,
                                         resume: copyResumeCheck.state == .on,
                                         bwlimit: copyBwlimitField.stringValue)
    }

    // 选中免密机器后，按触发框类型智能填回，并联动填 IP/主机、用户名
    // （TriggerField / FillPlan / buildFillPlan 已迁至 src/Core.swift 纯函数）
    // forceTrigger 参数随 0.5.0 删掉「预设」下拉后就没有调用方了，一并移除
    func applySSHHostToFields(_ spec: String) {
        let trigger: TriggerField
        if let src = autocompleteSourceField {
            if src === copySourceField { trigger = .source }
            else if src === copyTargetField { trigger = .target }
            else if src === copyConnField { trigger = .conn }
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

    // —— 实时联想：输入停顿 0.15s 后弹候选（非阻塞 Popover，不再抢键盘）——
    // 顺带记住「最近聚焦过的路径框」：解析回填优先填它（没记录时由 resolveParseTarget 按内容兜底）
    // 显式 @objc：这是 NSControlTextEditingDelegate 的可选方法，写在 extension 里靠推断不可靠
    @objc func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === copySourceField || field === copyTargetField { lastPathField = field }
    }

    @objc func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // 只在三个可编辑的输入框触发联想（凭据行已改只读，不再是联想入口）
        guard field === copySourceField || field === copyTargetField ||
              field === copyConnField else { return }
        // 输入时再记一次，防止 beginEditing 通知因窗口未激活而漏发
        if field === copySourceField || field === copyTargetField { lastPathField = field }
        autocompleteSourceField = field
        // 去抖：连续输入期间不弹，停手后再弹
        suggestionTimer?.invalidate()
        suggestionTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            self?.refreshSuggestions(for: field)
        }
    }

    // 取联想查询词；返回 nil 表示当前不该联想
    private func suggestionQuery(for field: NSTextField) -> String? {
        var input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field === copySourceField || field === copyTargetField {
            // 已在写远端路径（user@host:path）就不再联想主机
            if input.contains(":") { return nil }
            if let slash = input.lastIndex(of: "/") {
                input = String(input[input.index(after: slash)...])
            }
        }
        guard input.count >= 2 else { return nil }
        return input
    }

    // ~/.ssh/config 改动后自动重载缓存（不必重启应用）
    func reloadSSHHostsIfNeeded() {
        let mtime = fileModificationDate(sshConfigPath())
        if sshHostsCache.isEmpty || mtime != sshHostsMTime {
            sshHostsMTime = mtime
            sshHostsCache = loadSSHKnownHosts()
            debugLog("[互拷] 重载免密主机 \(sshHostsCache.count) 台")
        }
    }

    private func refreshSuggestions(for field: NSTextField) {
        // 焦点已不在该输入框则收起
        guard let editor = window?.firstResponder as? NSTextView,
              let editingField = editor.delegate as? NSTextField,
              editingField === field else {
            closeSuggestions()
            return
        }
        guard let query = suggestionQuery(for: field) else {
            closeSuggestions()
            return
        }
        reloadSSHHostsIfNeeded()
        // 模糊匹配：host / user / user@host 包含输入片段
        let matches = sshHostsCache.filter { h in
            h.host.contains(query) || h.user.contains(query) || h.display.contains(query)
        }
        guard !matches.isEmpty else {
            closeSuggestions()
            return
        }
        let controller = ensureSuggestions()
        controller.onPick = { [weak self] spec in
            self?.applySSHHostToFields(spec)
        }
        controller.update(items: matches.prefix(10).map { $0.display })
        controller.show(relativeTo: field)
    }

    private func ensureSuggestions() -> SuggestionController {
        if let existing = suggestions { return existing }
        let created = SuggestionController()
        suggestions = created
        return created
    }

    func closeSuggestions() {
        suggestionTimer?.invalidate()
        suggestionTimer = nil
        suggestions?.close()
    }

    // 候选框打开时接管 ↑↓ / 回车 / Tab / Esc（返回 true 表示已处理，不再交给输入框）
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let controller = suggestions, controller.isShown else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            controller.moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            controller.moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            controller.commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSuggestions()
            return true
        default:
            return false
        }
    }

    // 解析连接串：回填凭据字段，并把 host 前缀补进一个路径框
    // 选框走 Core 纯函数 resolveParseTarget：优先「最近聚焦过的框」，没记录时按框里有没有内容决定。
    // 不取当场 firstResponder —— 点按钮时焦点必然在连接串框；也不能要求用户一定点过路径框，
    // 否则路径是 last-copy.json 回填时按「解析」什么都不填（人工测试复现过）。
    @objc func parseConn(_ sender: Any) {
        let raw = copyConnField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = parseConnection(raw)
        if info.host.isEmpty {
            copyStatusLabel.stringValue = "无法识别连接串，请检查格式"
            // 不记录原始串：连接串可能携带明文密码
            debugLog("[互拷] 连接串解析失败（长度 \(raw.count)）")
            return
        }
        // 密码不回填到任何控件：它从不参与命令，显示出来只会让人误以为认证已经配好
        copyUserField.stringValue = info.user
        copyHostField.stringValue = info.host
        copyPortField.stringValue = info.port

        // 密码绝不进路径（rsync 不认 URL 里的密码，还会把明文摊在命令行上）
        let spec = buildHostSpec(ConnectionInfo(user: info.user, password: "",
                                                host: info.host, port: info.port))
        let parsed = "已解析：\(spec)"
        // 日志脱敏：不落原始连接串与明文密码
        debugLog("[互拷] 连接串解析成功: user=\(info.user) host=\(info.host) port=\(info.port) pass=\(maskSecret(info.password))")

        // 焦点在哪个路径框，解析结果就补到哪个框。先看当场真正持有键盘的框，
        // 再看「最近聚焦过」的记录（点按钮时焦点通常已在连接串框，这条是主路径）。
        // 刻意不抢焦点：程序若把光标挪到被填的框，下一次解析就会按程序挑的框走，
        // 反而违背「焦点在哪补哪」。
        let focused: ParseTargetField
        if let editor = window?.firstResponder as? NSTextView,
           let f = editor.delegate as? NSTextField,
           f === copySourceField || f === copyTargetField {
            focused = f === copySourceField ? .source : .target
        } else if let f = lastPathField {
            focused = f === copySourceField ? .source : .target
        } else {
            focused = .none
        }
        let decision = resolveParseTarget(lastFocused: focused,
                                          source: copySourceField.stringValue,
                                          target: copyTargetField.stringValue)
        let field: NSTextField = decision == .target ? copyTargetField : copySourceField
        let filled = applyHostToPath(field.stringValue, hostSpec: spec)
        field.stringValue = filled
        let name = decision == .target ? "目标路径" : "源路径"
        // 没检测到焦点时是程序按「只补空框」选的，得说清楚填了哪个、怎么改用焦点指定。
        // 密码也在这里一次说全：它从不进命令行/脚本/磁盘，只在 Terminal 里按 ssh 提示输入。
        let hint = focused == .none ? "（焦点在哪就补哪：点一下路径框再解析）" : ""
        copyStatusLabel.stringValue = "\(parsed)，已填入\(name)：\(filled)\(hint)\(passwordNotice(info))"
        debugLog("[互拷] 连接串解析并回填\(name): \(filled) 决策=\(decision.rawValue) 焦点记录=\(focused.rawValue) 含密码=\(!info.password.isEmpty)")
    }

    @objc func pickSource(_ sender: Any) {
        if let p = pickPath(message: "选择源路径（文件或文件夹）") {
            copySourceField.stringValue = p
            lastPathField = copySourceField
        }
    }

    @objc func pickTarget(_ sender: Any) {
        if let p = pickPath(message: "选择目标路径（文件或文件夹）") {
            copyTargetField.stringValue = p
            lastPathField = copyTargetField
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

    // 浏览远端目录：ssh ls 列目录，用户点选后回填
    // 主机与起始路径的判定已抽成 Core 纯函数 browseHostPlan（可单测、可在弹窗前拦脏输入）。
    @objc func browseRemoteSource(_ sender: Any) {
        browseRemote(into: copySourceField)
    }
    @objc func browseRemoteTarget(_ sender: Any) {
        browseRemote(into: copyTargetField)
    }

    func browseRemote(into field: NSTextField) {
        // 浏览的是哪个框，就记住哪个框：「浏览远端」选完路径后紧接着点「解析」，前缀应该补给它
        lastPathField = field
        guard !isBrowsingRemote else {
            copyStatusLabel.stringValue = "正在浏览远端，请稍候…"
            return
        }
        // 前置校验：路径框里是 URL 片段 / 乱码 / 本地路径 / 未知别名时，
        // 在弹输入框或发起 ssh 之前拦下并说清原因，别让用户点完「列出」才看到看不懂的报错。
        let others = [copySourceField, copyTargetField]
            .compactMap { $0 }.filter { $0 !== field }.map { $0.stringValue }
        let known = sshHostsCache.flatMap { [$0.host, $0.display] }
        let plan = browseHostPlan(fieldText: field.stringValue,
                                  credUser: copyUserField.stringValue,
                                  credHost: copyHostField.stringValue,
                                  credPort: copyPortField.stringValue,
                                  otherPaths: others,
                                  knownHosts: known)
        if !plan.error.isEmpty {
            copyStatusLabel.stringValue = plan.error
            debugLog("[互拷] 浏览远端被前置校验拦下: \(plan.error)")
            return
        }
        // 起始路径来自 splitRemoteSpec：host:2200:/data 的端口不再被当成路径的一部分
        let alert = NSAlert()
        alert.messageText = "浏览远端目录"
        alert.informativeText = "主机 \(plan.hostSpec)\n输入远端起始路径，之后可逐层「进入下一层 / 上一级」"
        alert.addButton(withTitle: "列出")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = plan.startPath
        alert.accessoryView = input
        if alert.runModal() != .alertFirstButtonReturn {
            return
        }
        var path = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "~" }
        browseStep(hostSpec: plan.hostSpec, path: path, into: field, note: plan.note)
    }

    // 列「一层」：ssh 放后台线程执行（ConnectTimeout 最长 8 秒，同步跑主线程会卡死窗口）
    private func browseStep(hostSpec: String, path: String, into field: NSTextField, note: String = "") {
        isBrowsingRemote = true
        copyStatusLabel.stringValue = (note.isEmpty ? "" : note + "；") +
            "正在列出远端目录…（\(hostSpec):\(path)）"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = sshListDir(hostSpec: hostSpec, path: path)
            DispatchQueue.main.async {
                self?.handleBrowseStep(r, hostSpec: hostSpec, path: path, into: field)
            }
        }
    }

    // 选择框：选为路径 / 进入下一层 / 上一级 / 取消（提交后回到主线程再次 browseStep）
    private func handleBrowseStep(_ r: (ok: Bool, output: String, error: String),
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
        let entries = r.output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let sel = NSAlert()
        sel.messageText = "远端目录：\(path)"
        sel.informativeText = entries.isEmpty
            ? "该目录为空。可点「选为路径」直接使用这个目录。"
            : "共 \(entries.count) 项（目录以 / 结尾）。选中一条后：可「进入下一层」或「选为路径」。"
        sel.addButton(withTitle: "选为路径")
        sel.addButton(withTitle: "进入下一层")
        sel.addButton(withTitle: "上一级")
        sel.addButton(withTitle: "取消")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for entry in entries { popup.addItem(withTitle: entry) }
        if !entries.isEmpty { sel.accessoryView = popup }
        switch sel.runModal() {
        case .alertFirstButtonReturn:
            let full = hostSpec + ":" + path
            field.stringValue = full
            copyStatusLabel.stringValue = "已选择远端路径 \(full)"
            debugLog("[互拷] 远端浏览选中 host=\(hostSpec) path=\(path)")
        case .alertSecondButtonReturn:
            guard let chosen = popup.selectedItem?.title else { return }
            guard chosen.hasSuffix("/") else {
                copyStatusLabel.stringValue = "「\(chosen)」不是目录，无法进入；可直接把它选为路径"
                return
            }
            browseStep(hostSpec: hostSpec,
                       path: remoteJoin(base: path, name: String(chosen.dropLast())),
                       into: field)
        case .alertThirdButtonReturn:
            browseStep(hostSpec: hostSpec, path: remoteParent(path), into: field)
        default:
            return   // 取消
        }
    }

    // —— 互拷表单状态快照：刷新重建窗口时保留用户已填内容，避免清空 ——
    struct CopyFormState {
        var source: String; var target: String; var conn: String
        var user: String; var host: String; var port: String
        var preserve: Bool; var resume: Bool
        var bwlimit: String
    }

    func captureCopyForm() -> CopyFormState {
        CopyFormState(source: copySourceField.stringValue, target: copyTargetField.stringValue,
                      conn: copyConnField.stringValue, user: copyUserField.stringValue,
                      host: copyHostField.stringValue, port: copyPortField.stringValue,
                      preserve: copyPreserveCheck.state == .on,
                      resume: copyResumeCheck.state == .on,
                      bwlimit: copyBwlimitField.stringValue)
    }

    func restoreCopyForm(_ s: CopyFormState) {
        copySourceField.stringValue = s.source
        copyTargetField.stringValue = s.target
        copyConnField.stringValue = s.conn
        copyUserField.stringValue = s.user
        copyHostField.stringValue = s.host
        copyPortField.stringValue = s.port
        copyPreserveCheck.state = s.preserve ? .on : .off
        copyResumeCheck.state = s.resume ? .on : .off
        copyBwlimitField.stringValue = s.bwlimit
    }

    // 启动时回填上次任务：续传要求源/目标不变再点一次，重启后表单若是空的就等于续不上。
    // 只在源和目标都为空时回填，避免覆盖用户刚输入的内容。
    func restoreLastCopyIfEmpty() {
        let srcEmpty = copySourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let dstEmpty = copyTargetField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard srcEmpty && dstEmpty, let m = loadCopyMemory() else { return }
        copySourceField.stringValue = m.source
        copyTargetField.stringValue = m.target
        copyPreserveCheck.state = m.preserveAttrs ? .on : .off
        copyResumeCheck.state = m.resume ? .on : .off
        copyBwlimitField.stringValue = m.bwlimitMBps
        copyStatusLabel.stringValue = "已回填上次任务：再点「开始拷贝」即从断点继续（日志在 ~/Library/Logs/ai-launcher）"
        debugLog("[互拷] 回填上次任务: \(m.source) → \(m.target)")
    }
}
