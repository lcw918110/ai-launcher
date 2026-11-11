// 互拷执行：参数校验、直连探测与选路、启动 Terminal、轮询日志回收结果
import Cocoa

extension AppDelegate {

    // 收集并校验表单，得到可用的 CopyParams（开始拷贝 / 本机中转共用）
    private func makeCopyParams() -> (params: CopyParams?, direction: String, error: String?) {
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

        if src.isEmpty && dst.isEmpty { return (nil, "", "请填写源路径和目标路径") }
        if src.isEmpty { return (nil, "", "请填写源路径") }
        if dst.isEmpty { return (nil, "", "请填写目标路径") }

        // 用连接信息补全纯路径前缀（仅对非 / 开头、无冒号的路径，视为远端相对路径）
        if !isRemotePath(src) && !src.hasPrefix("/") && !src.contains(":") {
            if connSpec.isEmpty { return (nil, "", "源路径看起来是远端相对路径，但未填 IP/主机") }
            src = connSpec + ":" + src
        }
        if !isRemotePath(dst) && !dst.hasPrefix("/") && !dst.contains(":") {
            if connSpec.isEmpty { return (nil, "", "目标路径看起来是远端相对路径，但未填 IP/主机") }
            dst = connSpec + ":" + dst
        }

        let direction = deriveDirection(src: src, dst: dst)
        // 限速：留空/0 = 不限速；非数字要明确报错，不能静默当成不限速（用户以为限了其实没限）
        let bwText = copyBwlimitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bwKbps = parseBwlimitMBps(bwText) else {
            return (nil, "", "限速只接受数字（MB/s，可带小数），留空表示不限速；当前填的是「\(bwText)」")
        }
        let params = CopyParams(
            source: src,
            target: dst,
            recursive: copyRecursiveCheck.state == .on,
            preserveAttrs: copyPreserveCheck.state == .on,
            resume: copyResumeCheck.state == .on,
            bwlimitKbps: bwKbps
        )
        return (params, direction, nil)
    }

    @objc func startCopy(_ sender: Any) {
        let cfg = loadCopyConfig()
        let built = makeCopyParams()
        guard let params = built.params else {
            copyStatusLabel.stringValue = built.error ?? "参数不完整"
            return
        }
        let direction = built.direction
        // 日志落点按「源 + 目标」哈希固定：续传的多次运行会追加到同一个文件，事后能连起来看
        let logPath = copyLogPath(params: params)
        rememberCurrentCopy(params: params)

        // 双远端：直连能不能走必须实测（取决于「源机→目标机」免密，界面上看不出来），
        // 所以先探测再选路，用户只看到一个「开始拷贝」
        if direction == "direct" {
            startDirectResolve(cfg: cfg, params: params, logPath: logPath)
            return
        }

        // 本机↔远端 / 本地：本机 rsync 能力一次性探测（同时决定 rsync/scp 与可选参数）
        let flavor = rsyncFlavor()
        let cmd = buildCopyCommand(cfg: cfg, params: params, rsyncAvailable: flavor != .none,
                                   logPath: logPath, useProgress2: flavor == .full,
                                   useLogFile: flavor == .full)
        if cmd.isEmpty {
            copyStatusLabel.stringValue = "无法拼接命令，请检查路径格式"
            return
        }
        debugLog("[互拷] 方向=\(direction) rsync=\(flavor) 拼装命令: \(cmd)")

        copyStatusLabel.stringValue = direction == "local"
            ? "本地拷贝：进行中…（Terminal 窗口查看进度）"
            : "进行中…（Terminal 窗口查看进度）"
        // 降级/受限要明说，不能静默（scp 没有断点续传，openrsync 没有进度与明细日志）
        if direction != "local" {
            if flavor == .none {
                copyStatusLabel.stringValue += "（本机无 rsync，已降级 scp，断点续传不可用）"
            } else if flavor == .openRsync {
                copyStatusLabel.stringValue += "（系统自带 openrsync：无单行进度与明细日志，续传仍可用）"
            }
        }
        copyStatusLabel.stringValue += " 日志：\((logPath as NSString).lastPathComponent)"

        // 普通执行（非 exec），前后 echo 提示，保留进度与完成提示
        let fullCmd = "echo '===== 开始拷贝 ====='; " + cmd
        guard launchCommandInTerminal(fullCmd, autoCloseOnSuccess: true, logPath: logPath,
                                      startNote: "\(params.source) → \(params.target)") else {
            copyStatusLabel.stringValue = terminalLaunchFailedText()
            return
        }
        beginOutcomeWatch(logPath: logPath)
    }

    // open 的退出码只在「文件没有、没有程序能打开它」这类错误上可信；
    // 文稿被系统拦下时它照样返回 0，那种情况由脚本自己回报（见 parseCopyLogOutcome）。
    func terminalLaunchFailedText() -> String {
        lastCommandScriptPath.isEmpty
            ? "无法交给 Terminal（open 返回失败）：检查「系统设置 → 隐私与安全性」后重试"
            : "无法交给 Terminal（open 返回失败）：可在终端里手动执行 \(lastCommandScriptPath)"
    }

    // 轮询日志新增内容，把退出码写回状态栏。
    // 拷贝跑在 Terminal 里（真 TTY 才能交互输密码），app 拿不到 Process 的 terminationStatus，
    // 只能读脚本层写的那行「结束，退出码 N」；否则状态栏会永远停在「进行中…」。
    func beginOutcomeWatch(logPath: String) {
        outcomeTimer?.invalidate()
        outcomeLogPath = logPath
        // 从当前文件大小起算：同一任务的日志是追加的，读全量会把上一次的结束行当成这次的结果
        let attrs = try? FileManager.default.attributesOfItem(atPath: logPath)
        outcomeOffset = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        outcomeBaseStatus = copyStatusLabel?.stringValue ?? ""
        outcomeHasStarted = false
        outcomeStartedAt = Date()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.pollCopyOutcome() }
        // .common：滚动窗口时 RunLoop 处于 tracking 模式，默认模式下的 timer 不触发
        RunLoop.main.add(t, forMode: .common)
        outcomeTimer = t
        debugLog("[互拷] 开始回收结果: \(logPath) 起始 offset=\(outcomeOffset)")
    }

    func stopOutcomeWatch() {
        outcomeTimer?.invalidate()
        outcomeTimer = nil
        outcomeLogPath = ""
    }

    func pollCopyOutcome() {
        guard !outcomeLogPath.isEmpty else { stopOutcomeWatch(); return }
        let r = readNewText(path: outcomeLogPath, fromOffset: outcomeOffset)
        outcomeOffset = r.offset
        let outcome = parseCopyLogOutcome(r.text)
        // 开始行可能出现在更早的一段里，所以只置位不回退
        if outcome.started { outcomeHasStarted = true }
        let name = (outcomeLogPath as NSString).lastPathComponent

        if outcome.finished, let code = outcome.exitCode {
            stopOutcomeWatch()
            if code == 0 {
                copyStatusLabel?.stringValue = "✅ 拷贝完成（退出码 0）· 日志：\(name)"
            } else {
                copyStatusLabel?.stringValue = "❌ 拷贝失败（退出码 \(code)）· 菜单「工具 → 打开日志目录」看明细 · 日志：\(name)"
            }
            debugLog("[互拷] 结果回收: 退出码 \(code) 日志 \(name)")
            return
        }

        // 状态只陈述已知事实，不用时间推断：
        // - 日志里还没有「开始」行 → 只能说「已交给 Terminal」，不能声称在跑
        //   （open / NSWorkspace 都只回报“请求已交给 Terminal”，文稿被系统拦下时也一样）
        // - 见到「开始」行 → 拷贝确实在跑，这时才给时长
        // 超过 6 小时不再轮询
        let secs = Int(Date().timeIntervalSince(outcomeStartedAt))
        if secs > 6 * 3600 { stopOutcomeWatch(); return }
        copyStatusLabel?.stringValue = outcomeBaseStatus
            + (outcomeHasStarted ? " · 运行中 \(secs)s" : " · 已交给 Terminal，等待脚本开始")
    }

    // 记住这次任务：续传要求「源/目标不变、再点一次」，app 重启后要能自动回填
    func rememberCurrentCopy(params: CopyParams) {
        let mem = CopyMemory(source: params.source,
                             target: params.target,
                             recursive: params.recursive,
                             preserveAttrs: params.preserveAttrs,
                             resume: params.resume,
                             bwlimitMBps: copyBwlimitField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        saveCopyMemory(mem)
    }

    // 双远端选路：后台实测「源机 → 目标机」能否免密直连，再决定直连 / 中转。
    // 不再让用户点「经本机中转」—— 直连能跑就跑直连，跑不了自动兜底，
    // 中转的两种实现（两段 rsync / tar 流）也只由 rsync 能力与「断点续传」决定。
    func startDirectResolve(cfg: CopyConfig, params: CopyParams, logPath: String) {
        copyStatusLabel.stringValue = "检测直连：源机 → 目标机 …"
        copyStartBtn?.isEnabled = false   // 探测是异步的，置灰避免连点重复发起
        let directProbe = buildDirectProbeCommand(params: params)
        debugLog("[互拷] 直连探测命令: \(directProbe)")

        DispatchQueue.global(qos: .userInitiated).async {
            let directOK = self.runProbe(directProbe)
            var localOK = false
            if !directOK,
               let s = splitRemoteSpec(params.source),
               let t = splitRemoteSpec(params.target) {
                // 中转的前提是本机两端都登得上；源机到不了目标机时，只能靠本机各连一次
                localOK = self.runProbe(buildLocalProbeCommand(host: s.host, port: s.port)) &&
                    self.runProbe(buildLocalProbeCommand(host: t.host, port: t.port))
            }
            let flavor = rsyncFlavor()
            let route = resolveDirectRoute(directReachable: directOK, localReachable: localOK,
                                           resume: params.resume, rsyncFlavor: flavor)
            DispatchQueue.main.async {
                self.copyStartBtn?.isEnabled = true
                self.launchDirect(route: route, cfg: cfg, params: params,
                                  logPath: logPath, flavor: flavor)
            }
        }
    }

    // 只关心退出码的探测：探测命令自带 ConnectTimeout，正常几秒内返回
    func runProbe(_ cmdLine: String) -> Bool {
        guard !cmdLine.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmdLine]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // 按选路结果拼命令并启动；顺带把「为什么走这条路」写在状态栏，用户不用猜
    func launchDirect(route: CopyRoute, cfg: CopyConfig, params: CopyParams,
                      logPath: String, flavor: RsyncFlavor) {
        let note = "\(params.source) → \(params.target)"

        switch route {
        case .unreachable:
            debugLog("[互拷] 双远端不可达: \(note)")
            copyStatusLabel.stringValue = "两端都不可达：源机到不了目标机，本机也登不上其中一端（先确认免密与网络）"
            return

        case .direct:
            let cmd = buildCopyCommand(cfg: cfg, params: params, rsyncAvailable: flavor != .none,
                                       logPath: logPath, useProgress2: flavor == .full,
                                       useLogFile: flavor == .full)
            if cmd.isEmpty {
                copyStatusLabel.stringValue = "无法拼接命令，请检查路径格式"
                return
            }
            debugLog("[互拷] 直连（实测通过）: \(cmd)")
            copyStatusLabel.stringValue = "直连：在源机执行 rsync（源机→目标机免密已实测通过）"
            guard launchCommandInTerminal("echo '===== 开始拷贝（直连）====='; " + cmd,
                                          autoCloseOnSuccess: true, logPath: logPath, startNote: note) else {
                copyStatusLabel.stringValue = terminalLaunchFailedText()
                return
            }
            beginOutcomeWatch(logPath: logPath)

        case .relayResume:
            let cmd = buildRelayResumeCommand(params: params, logPath: logPath,
                                              useProgress2: flavor == .full,
                                              useLogFile: flavor == .full)
            if cmd.isEmpty {
                copyStatusLabel.stringValue = "中转命令拼装失败，请检查两端路径"
                return
            }
            let stage = relayStagingDir(params: params)
            debugLog("[互拷] 续传式中转（直连不通）: \(cmd)")
            copyStatusLabel.stringValue =
                "直连不通，已自动改走本机中转（两段 rsync）：源机 → 本机暂存 → 目标机，中断后再点一次即续传"
            guard launchCommandInTerminal("echo '===== 开始中转（可续传）====='; echo '暂存目录: \(stage.replacingOccurrences(of: "'", with: "'\\''"))'; " + cmd,
                                          autoCloseOnSuccess: true, logPath: logPath, startNote: note) else {
                copyStatusLabel.stringValue = terminalLaunchFailedText()
                return
            }
            beginOutcomeWatch(logPath: logPath)

        case .relayTar:
            let cmd = buildRelayCopyCommand(params: params)
            if cmd.isEmpty {
                copyStatusLabel.stringValue = "中转命令拼装失败，请检查两端路径"
                return
            }
            debugLog("[互拷] tar 流中转（直连不通）: \(cmd)")
            if !params.resume {
                copyStatusLabel.stringValue = "直连不通，已自动改走本机中转（tar 流）：不占本地磁盘，但未勾「断点续传」故中断要重来"
            } else {
                copyStatusLabel.stringValue = "直连不通，已自动改走本机中转（tar 流）：本机无可用 rsync，不占盘但不可续传"
            }
            // tar 流没有 --log-file，日志里只有开始/结束与退出码，明细仍在 Terminal 里
            guard launchCommandInTerminal("echo '===== 开始中转拷贝 ====='; " + cmd,
                                          autoCloseOnSuccess: true, logPath: logPath, startNote: note) else {
                copyStatusLabel.stringValue = terminalLaunchFailedText()
                return
            }
            beginOutcomeWatch(logPath: logPath)
        }
    }
}
