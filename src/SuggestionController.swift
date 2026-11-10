// 免密主机候选框（非阻塞 Popover + NSTableView）
import Cocoa

// 免密主机联想列表：用 NSPopover + NSTableView 实现非阻塞候选框
// （NSMenu.popUp 会进入同步事件追踪循环抢走键盘，连续输入会被菜单打断）
final class SuggestionController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let popover = NSPopover()
    private let tableView = NSTableView()
    private let scroll = NSScrollView()
    private var items: [String] = []
    var onPick: ((String) -> Void)?

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("suggestion"))
        column.width = 240
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.frame = NSRect(x: 0, y: 0, width: 260, height: 120)
        let vc = NSViewController()
        vc.view = scroll
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.animates = false
    }

    var isShown: Bool { popover.isShown }

    func update(items newItems: [String]) {
        items = newItems
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func show(relativeTo field: NSTextField) {
        let rows = min(items.count, 8)
        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let height = max(CGFloat(rows) * rowHeight + 4, 26)
        scroll.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        popover.contentSize = scroll.frame.size
        popover.contentViewController?.preferredContentSize = scroll.frame.size
        if popover.isShown { popover.close() }
        popover.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY)
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    // ↑↓ 在候选里移动
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = tableView.selectedRow < 0 ? 0 : tableView.selectedRow
        let next = min(max(current + delta, 0), items.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // 回车 / Tab 采用当前候选
    func commitSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        let value = items[row]
        close()
        onPick?(value)
    }

    @objc private func rowClicked(_ sender: Any) {
        commitSelection()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = row < items.count ? items[row] : ""
        return cell
    }
}
