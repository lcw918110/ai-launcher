#!/bin/zsh
# 控件接线检查：界面上的输入控件必须有「值被生产路径读取」的证据。
# 只创建、只回显、只在表单快照里搬运、只在自测里断言「存在」——都不算接线。
#
# 来由（2026-11-12）：界面长期摆着密码框（从不进命令）、「递归」复选框（被 rsync -a 吞掉）、
# 可编辑的凭据三框（改了不影响命令），而 GUI 自测只断言「控件存在 = true」，于是假绿。
# 这条检查把「值 → 行为」变成硬门槛：新增控件若没有消费点，测试脚本直接失败。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import re, sys, pathlib

SKIP_FUNCS = {
    # 控件构建区只是把控件摆出来；表单快照只是搬运值，都不构成「消费」
    "CopyForm.swift": {"buildCopySection", "captureCopyForm", "restoreCopyForm",
                       "restoreLastCopyIfEmpty"},
    "AppDelegate.swift": {"buildWindow"},
}
# 纯输出控件不参与检查（它们本来就只被写）
OUTPUTS = {"copyStatusLabel", "copyStartBtn"}
DECL = re.compile(r'^\s*var (\w+):\s*(?:NSTextField|NSSecureTextField|NSButton|NSPopUpButton)')


def skip_lines(fname, lines):
    skip = set()
    names = SKIP_FUNCS.get(fname, set())
    for i, ln in enumerate(lines):
        m = re.search(r'func\s+(\w+)', ln)
        if m and m.group(1) in names:
            skip.add(i)
            for j in range(i + 1, len(lines)):
                skip.add(j)
                if lines[j].startswith("    }"):
                    break
    return skip


def analyze(files):
    """files: {文件名: [行]} -> (输入控件列表, 孤儿列表)"""
    controls = []
    for ln in files.get("AppDelegate.swift", []):
        m = DECL.match(ln)
        if m and (m.group(1).startswith("copy") or m.group(1) == "toolPopup") \
                and m.group(1) not in OUTPUTS:
            controls.append(m.group(1))

    orphans = []
    for v in controls:
        reads = 0
        for fname, lines in files.items():
            skip = skip_lines(fname, lines)
            for i, ln in enumerate(lines):
                if i in skip:
                    continue
                s = ln.strip()
                if s.startswith("//") or s.startswith("*"):
                    continue
                if "[自测]" in s or "[TDD]" in s or "[WIRING]" in s:
                    continue
                # 去掉对该控件的「写」，剩下的出现才算「值被读取」
                cleaned = re.sub(
                    r'\b' + v + r'\.(?:stringValue|state|isEditable|toolTip|title|placeholderString)'
                    r'\s*(?:\+?=)(?!=)[^,)]*', '', ln)
                if re.search(r'\b' + v + r'\.(?:stringValue|state|selectedItem)\b', cleaned):
                    reads += 1
        if reads == 0:
            orphans.append(v)
    return controls, orphans


def launch_recovery_errors(files):
    """启动工具的脚本收尾契约（0.5.3）：CLI 退出后必须回到可用的交互 shell。
    旧写法 exec <cmd> 会顶替掉 shell，且脚本后面的行永远不执行，收尾不可控。"""
    shell_lines = files.get("AppShell.swift", [])
    shell = "\n".join(ln for ln in shell_lines if not ln.strip().startswith("//"))
    core = "\n".join(files.get("Core.swift", []))
    errs = []
    if "buildToolLaunchLine(dir: dir, cmd: tool.cmd)" not in shell:
        errs.append("AppShell.launchInTerminal 没有走 Core 的 buildToolLaunchLine")
    if re.search(r'exec\s+\\\((?:tool\.cmd|cmd)\)', shell):
        errs.append("启动工具又用 exec 顶替了 CLI，退出后只剩死窗口")
    # 只看函数体本身：Swift 源码里双引号写成 \"，不能拿拼好的命令行字面量去比
    m = re.search(r'func buildToolLaunchLine[\s\S]*?\n\}', core)
    body = m.group(0) if m else ""
    if '${SHELL:-/bin/zsh}' not in body or '-il' not in body:
        errs.append("Core.buildToolLaunchLine 没有 exec 到交互式 shell")
    if '; exec' not in body:
        errs.append("收尾用 && 连接，CLI 失败或被 Ctrl-C 时回不到 shell")
    return errs


def browse_guard_errors(files):
    """浏览远端前置校验（0.5.4）：脏输入必须在 NSAlert / ssh 之前由 Core 纯函数拦下。
    旧写法 currentHostSpec + splitRemotePath 会把 ssh://bad 拆成 host="ssh"、
    把乱码当主机，还会丢掉 host:2200:/data 的端口。"""
    form = "\n".join(files.get("CopyForm.swift", []))
    core = "\n".join(files.get("Core.swift", []))
    errs = []
    if "browseHostPlan(fieldText:" not in form:
        errs.append("CopyForm.browseRemote 没有走 Core 的 browseHostPlan 前置校验")
    if "currentHostSpec(" in form or "splitRemotePath(cur)" in form:
        errs.append("浏览远端又绕回 splitRemotePath / currentHostSpec")
    if "func browseHostPlan" not in core:
        errs.append("Core 缺少 browseHostPlan 纯函数")
    return errs


def advanced_fold_errors(files):
    """高级选项默认收起但值仍接线（0.5.4）：不能把控件删掉，也不能收起后没有摘要。"""
    form = "\n".join(files.get("CopyForm.swift", []))
    errs = []
    if "optRow.isHidden = true" not in form or "func toggleAdvancedOptions" not in form:
        errs.append("高级选项没有默认收起 / 没有展开动作")
    if form.count("advancedSummary(") < 2:
        errs.append("折叠按钮 tooltip 没有用 advancedSummary 读三个控件当前值")
    return errs


def launch_evidence_errors(files):
    """启动必须留痕（0.5.5）：`.command` 交给 Terminal 是单向通道 —— open 的退出码在
    「文稿被沙箱/门禁拦下」时照样是 0，程序收不到任何错误，用户只看到一个看不懂的系统弹窗。
    所以「跑起来了没有」只能由脚本自己写的标记文件证明；谁把它退化成「open 成功 = 启动成功」，
    这里就红。"""
    core = "\n".join(files.get("Core.swift", []))
    shell = "\n".join(files.get("AppShell.swift", []))
    errs = []
    for fn in ("launchStartVerdict", "startMarkerPath", "launchNotStartedNotice"):
        if f"func {fn}" not in core:
            errs.append(f"Core 缺少 {fn}（启动实证失效）")
    if "launchStartGraceSeconds" not in core:
        errs.append("Core 缺少启动判定时限 launchStartGraceSeconds")
    m = re.search(r'func buildCommandScript[\s\S]*?\n\}', core)
    body = m.group(0) if m else ""
    if "markerPath" not in body or ": > " not in body:
        errs.append("buildCommandScript 不再写启动标记文件")
    # 启动结果必须用值类型往返（0.5.6）：两个全局 mutable 谁先调用谁覆盖，自测与生产会读到彼此的值
    if "-> LaunchReport" not in shell or ".submitted(scriptPath:" not in shell:
        errs.append("launchCommandInTerminal 没有返回 LaunchReport")
    for name in ("lastCommandScriptPath", "lastLaunchMarkerPath"):
        if re.search(r'^var\s+' + name, shell, re.M):
            errs.append(f"又出现了全局状态 {name}（应走 LaunchReport 返回值）")
    if "struct LaunchReport" not in core:
        errs.append("Core 缺少 LaunchReport（启动结果没法用值传递）")
    # 任何真正发起启动的文件，都必须同时判断「有没有跑起来」
    for fname, lines in files.items():
        if fname == "AppShell.swift":
            continue
        text = "\n".join(lines)
        if "launchCommandInTerminal(" in text and \
                "launchStartVerdict(" not in text and "watchLaunchStart(" not in text:
            errs.append(f"{fname} 只用 open 的返回值判断启动成功（没有检查启动标记）")
    # 横幅（===== 开始 xxx =====）只能由 Core 的 buildCopyScriptLine 生成：
    # 手拼过四遍，每加一条拷贝路径就多一处漏，引号也是各写各的
    runner = "\n".join(files.get("CopyRunner.swift", []))
    if "===== " in runner:
        errs.append("CopyRunner 又手拼了横幅，应走 Core 的 buildCopyScriptLine")
    return errs


# 自检：喂一份「旧 exec 写法」的假代码，检查器必须报错。
# 否则检查器本身就成了新的假绿（0.5.0 的教训）。
fake = {
    "AppDelegate.swift": ["    var copyGhostField: NSTextField!"],
    "CopyForm.swift": [
        "    func buildCopySection(into stack: NSStackView) {",
        "        copyGhostField = NSTextField(string: \"\")",
        "    }",
        "    func parseConn(_ sender: Any) {",
        "        copyGhostField.stringValue = \"x\"",
        "    }",
        "    func captureCopyForm() {",
        "        let _ = copyGhostField.stringValue",
        "    }",
    ],
}
_, fake_orphans = analyze(fake)
if "copyGhostField" not in fake_orphans:
    print("检查器自检失败：假控件未被识别为孤儿（检查逻辑失效）")
    sys.exit(1)

fake_old_exec = {
    "AppShell.swift": [
        "func launchInTerminal(dir: String, tool: ToolConfig) {",
        '    let cmdLine = "cd ... && clear && exec \\(tool.cmd)"',
        "    launchCommandInTerminal(cmdLine)",
        "}",
    ],
    "Core.swift": [],
}
if not launch_recovery_errors(fake_old_exec):
    print("检查器自检失败：旧的 exec 收尾未被识别（检查逻辑失效）")
    sys.exit(1)
fake_missing_il = {
    "AppShell.swift": ["    launchCommandInTerminal(buildToolLaunchLine(dir: dir, cmd: tool.cmd))"],
    "Core.swift": ['    return "cd ... && clear && \\(cmd)"'],
}
if not launch_recovery_errors(fake_missing_il):
    print("检查器自检失败：缺交互 shell 的收尾未被识别（检查逻辑失效）")
    sys.exit(1)

fake_browse_bypass = {
    "CopyForm.swift": [
        "func browseRemote(into field: NSTextField) {",
        "    let hostSpec = currentHostSpec(preferredField: field)",
        "    let sp = splitRemotePath(cur)",
        "}",
    ],
    "Core.swift": [],
}
if not browse_guard_errors(fake_browse_bypass):
    print("检查器自检失败：绕过浏览远端前置校验未被识别")
    sys.exit(1)

fake_no_fold = {
    "CopyForm.swift": [
        "func toggleAdvancedOptions(_ sender: NSButton) {}",
        "optRow.isHidden = false",
        "advancedSummary(preserve: true, resume: true, bwlimit: \"\")",
    ],
    "Core.swift": [],
}
if not advanced_fold_errors(fake_no_fold):
    print("检查器自检失败：高级选项没有默认收起未被识别")
    sys.exit(1)

fake_open_only = {
    "Core.swift": [
        "func buildCommandScript() {}",
    ],
    "AppShell.swift": [
        "func launchCommandInTerminal() { try? p.run() }",
    ],
    "CopyRunner.swift": [
        "guard launchCommandInTerminal(cmd) else { return }",
        "beginOutcomeWatch(logPath: logPath)",
    ],
}
if not launch_evidence_errors(fake_open_only):
    print("检查器自检失败：把「open 返回 0」当启动成功的写法未被识别")
    sys.exit(1)

fake_hand_banner = {
    "Core.swift": ["func launchStartVerdict() {}", "func startMarkerPath() {}",
                   "func launchNotStartedNotice() {}", "let launchStartGraceSeconds = 8",
                   "func buildCommandScript() { markerPath: ; : > }", "struct LaunchReport {}"],
    "AppShell.swift": ["func launchCommandInTerminal() -> LaunchReport { .submitted(scriptPath: p) }"],
    "CopyRunner.swift": ['let line = "echo \'===== 开始拷贝 =====\'; " + cmd',
                         "launchCommandInTerminal(line)", "launchStartVerdict("],
}
if not any("buildCopyScriptLine" in e for e in launch_evidence_errors(fake_hand_banner)):
    print("检查器自检失败：CopyRunner 手拼横幅未被识别")
    sys.exit(1)

root = pathlib.Path(sys.argv[1])
files = {p.name: p.read_text(encoding="utf-8").splitlines()
         for p in sorted((root / "src").glob("*.swift"))}
controls, orphans = analyze(files)
print(f"控件接线检查：{len(controls)} 个输入控件，检查器自检通过")
for v in controls:
    mark = "✗" if v in orphans else "✓"
    print(f"  {mark} {v}")
if orphans:
    print("以下控件只有创建 / 回显 / 快照搬运，没有任何生产路径读取它的值：")
    for v in orphans:
        print(f"  - {v}（要么接上行为，要么从界面删掉）")
    sys.exit(1)

recovery_errs = launch_recovery_errors(files)
print("启动脚本收尾检查：" + ("通过（CLI 退出后回到可用 shell）" if not recovery_errs else "失败"))
for e in recovery_errs:
    print(f"  ✗ {e}")
if recovery_errs:
    sys.exit(1)

browse_errs = browse_guard_errors(files)
print("浏览远端前置校验：" + ("通过（脏输入在弹窗前拦下、端口保留）" if not browse_errs else "失败"))
for e in browse_errs:
    print(f"  ✗ {e}")
if browse_errs:
    sys.exit(1)

fold_errs = advanced_fold_errors(files)
print("高级选项折叠：" + ("通过（默认收起且值仍接线）" if not fold_errs else "失败"))
for e in fold_errs:
    print(f"  ✗ {e}")
if fold_errs:
    sys.exit(1)

evidence_errs = launch_evidence_errors(files)
print("启动实证：" + ("通过（有标记文件、没人只看 open 返回值）" if not evidence_errs else "失败"))
for e in evidence_errs:
    print(f"  ✗ {e}")
if evidence_errs:
    sys.exit(1)
PY
