// 入口文件：只做 NSApplication 启动，其余代码按职责拆在同目录
// - Core.swift                   纯逻辑（无 AppKit 依赖，可单测）
// - AppShell.swift               启动 Terminal、写临时 .command、目录选择等无状态辅助
// - AppDelegate.swift            窗口 / 菜单 / 生命周期
// - CopyForm.swift               互拷表单：控件构建、免密主机联想、远端浏览
// - CopyRunner.swift             互拷执行：参数校验、直连探测选路、结果回收
// - SuggestionController.swift   免密主机候选框（NSPopover）
import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 全局开关：--selftest 跑界面链路冒烟；--selftest-copy 再真跑一次拷贝（需要 last-copy.json）
let gSelfTest = CommandLine.arguments.contains("--selftest")
app.run()
