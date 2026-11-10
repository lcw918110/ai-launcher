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

        // 预设主机（config 的 copy.hosts）：选中即填连接串 / 用户名 / 主机
        copyHosts = loadCopyConfig().hosts
        if !copyHosts.isEmpty {
            let presetRow = NSStackView()
            presetRow.orientation = .horizontal
            presetRow.spacing = 8
            let presetLabel = NSTextField(labelWithString: "预设")
            presetLabel.font = NSFont.systemFont(ofSize: 12)
            let popup = NSPopUpButton()
            popup.addItem(withTitle: "选择预设主机…")
            for h in copyHosts {
                popup.addItem(withTitle: "\(h.name)（\(h.spec)）")
            }
            popup.target = self
            popup.action = #selector(presetChanged(_:))
            copyPresetPopup = popup
            presetRow.addView(presetLabel, in: .leading)
            presetRow.addView(popup, in: .trailing)
            stack.addView(presetRow, in: .leading)
        }

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
        copyPassField.placeholderString = "密码（Terminal 输入）"
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


    // 选中免密机器后，按触发框类型智能填回，并联动填 IP/主机、用户名
    // （TriggerField / FillPlan / buildFillPlan 已迁至 src/Core.swift 纯函数）
    // forceTrigger：预设下拉等场景直接指定填哪个框，不依赖「最后编辑的输入框」
    func applySSHHostToFields(_ spec: String, forceTrigger: TriggerField? = nil) {
        let trigger: TriggerField
        if let forced = forceTrigger {
            trigger = forced
        } else if let src = autocompleteSourceField {
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

    // —— 实时联想：输入停顿 0.15s 后弹候选（非阻塞 Popover，不再抢键盘）——
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // 只在四个目标输入框触发联想
        guard field === copySourceField || field === copyTargetField ||
              field === copyConnField || field === copyHostField else { return }
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

    // 预设主机下拉（config 的 copy.hosts）
    @objc func presetChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem - 1
        guard idx >= 0, idx < copyHosts.count else { return }
        let host = copyHosts[idx]
        copyConnField.stringValue = host.spec
        applySSHHostToFields(host.spec, forceTrigger: .conn)
        copyStatusLabel.stringValue = "已选预设 \(host.name)：\(host.spec)"
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
        // 弹出输入框让用户填/确认起始远端路径
        let alert = NSAlert()
        alert.messageText = "浏览远端目录"
        alert.informativeText = "输入远端起始路径，之后可逐层「进入下一层 / 上一级」"
        alert.addButton(withTitle: "列出")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = initPath
        alert.accessoryView = input
        if alert.runModal() != .alertFirstButtonReturn {
            return
        }
        var path = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = "~" }
        browseStep(hostSpec: hostSpec, path: path, into: field)
    }

    // 列「一层」：ssh 放后台线程执行（ConnectTimeout 最长 8 秒，同步跑主线程会卡死窗口）
    private func browseStep(hostSpec: String, path: String, into field: NSTextField) {
        isBrowsingRemote = true
        copyStatusLabel.stringValue = "正在列出远端目录…（\(hostSpec):\(path)）"
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
        var user: String; var pass: String; var host: String; var port: String
        var recursive: Bool; var preserve: Bool; var resume: Bool
        var bwlimit: String
    }

    func captureCopyForm() -> CopyFormState {
        CopyFormState(source: copySourceField.stringValue, target: copyTargetField.stringValue,
                      conn: copyConnField.stringValue, user: copyUserField.stringValue,
                      pass: copyPassField.stringValue, host: copyHostField.stringValue,
                      port: copyPortField.stringValue,
                      recursive: copyRecursiveCheck.state == .on,
                      preserve: copyPreserveCheck.state == .on,
                      resume: copyResumeCheck.state == .on,
                      bwlimit: copyBwlimitField.stringValue)
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
        copyRecursiveCheck.state = m.recursive ? .on : .off
        copyPreserveCheck.state = m.preserveAttrs ? .on : .off
        copyResumeCheck.state = m.resume ? .on : .off
        copyBwlimitField.stringValue = m.bwlimitMBps
        copyStatusLabel.stringValue = "已回填上次任务：再点「开始拷贝」即从断点继续（日志在 ~/Library/Logs/ai-launcher）"
        debugLog("[互拷] 回填上次任务: \(m.source) → \(m.target)")
    }
}
