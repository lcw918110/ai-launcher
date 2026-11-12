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
PY
