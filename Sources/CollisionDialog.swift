import AppKit

struct ArchiveCollision {
    let path: String
    let incomingSize: Int64
    let incomingDate: String
    let existingSize: Int64
    let existingDate: Date?
    static func find(entries: [ArchiveEntry], destination: String) throws -> [ArchiveCollision] {
        let fm = FileManager.default
        return try entries.compactMap { entry in
            let url = URL(fileURLWithPath: destination).appendingPathComponent(ArchiveSafety.relativePath(entry.name))
            guard fm.fileExists(atPath: url.path) else { return nil }
            let attributes = try fm.attributesOfItem(atPath: url.path)
            if entry.isDirectory, attributes[.type] as? FileAttributeType == .typeDirectory { return nil }
            return ArchiveCollision(path: entry.name, incomingSize: entry.size, incomingDate: entry.mtime,
                                    existingSize: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                    existingDate: attributes[.modificationDate] as? Date)
        }
    }
}

final class CollisionDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var collisions: [ArchiveCollision] = []
    private var choices: [Int: Int] = [:]
    private var defaultChoice = 0
    private let all = NSPopUpButton()
    private let table = NSTableView()
    private let date = DateFormatter()
    private let titles = [L("Üzerine Yaz"), L("Yeniden Adlandır"), P("Atla", "Skip")]

    @objc private func applyAll() {
        defaultChoice = all.indexOfSelectedItem; choices.removeAll(); table.reloadData()
    }
    @objc private func changed(_ sender: NSPopUpButton) { choices[sender.tag] = sender.indexOfSelectedItem }
    func numberOfRows(in tableView: NSTableView) -> Int { collisions.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        if column?.identifier.rawValue == "action" {
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 18, width: 150, height: 28))
            popup.addItems(withTitles: titles); popup.selectItem(at: choices[row] ?? defaultChoice)
            popup.tag = row; popup.target = self; popup.action = #selector(changed)
            return popup
        }
        let id = NSUserInterfaceItemIdentifier("comparison")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
        if cell.textField == nil {
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = NSRect(x: 4, y: 6, width: 335, height: 56); label.autoresizingMask = [.width]
            label.font = .systemFont(ofSize: 11); label.maximumNumberOfLines = 3
            cell.addSubview(label); cell.textField = label; cell.identifier = id
        }
        let collision = collisions[row]
        let incoming = P("Arşiv: ", "Archive: ") + Fmt.size(collision.incomingSize) + " · " + collision.incomingDate
        let current = P("Hedef: ", "Destination: ") + Fmt.size(collision.existingSize) + " · " + (collision.existingDate.map(date.string) ?? "—")
        cell.textField?.stringValue = collision.path + "\n" + incoming + "\n" + current
        cell.toolTip = cell.textField?.stringValue
        return cell
    }
    static func run(_ collisions: [ArchiveCollision]) -> [String: ArchiveSafety.Collision]? {
        guard !collisions.isEmpty else { return [:] }
        let controller = CollisionDialog(); controller.collisions = collisions
        controller.date.dateStyle = .short; controller.date.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = P("Aynı adlı dosyalar", "Files with the same name")
        alert.informativeText = P("Her dosya için karar verin. Arşiv ve hedef boyutları ile tarihlerini karşılaştırabilirsiniz.", "Choose an action for each file. Compare archive and destination sizes and dates.")
        controller.all.addItems(withTitles: controller.titles)
        let apply = NSButton(title: P("Tümüne uygula", "Apply to all"), target: controller, action: #selector(applyAll))
        let bar = NSStackView(views: [controller.all, apply]); bar.orientation = .horizontal
        let comparison = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("comparison")); comparison.width = 345
        let action = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action")); action.width = 155
        controller.table.addTableColumn(comparison); controller.table.addTableColumn(action)
        controller.table.headerView = nil; controller.table.rowHeight = 72
        controller.table.usesAlternatingRowBackgroundColors = true
        controller.table.dataSource = controller; controller.table.delegate = controller
        let height = min(320, collisions.count * 74)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        scroll.hasVerticalScroller = true; scroll.documentView = controller.table
        let content = NSStackView(views: [bar, scroll]); content.orientation = .vertical; content.alignment = .leading
        content.frame = NSRect(x: 0, y: 0, width: 520, height: height + 40)
        scroll.widthAnchor.constraint(equalToConstant: 520).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(height)).isActive = true
        alert.accessoryView = content
        alert.addButton(withTitle: P("Devam et", "Continue")); alert.addButton(withTitle: L("İptal"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let policies: [ArchiveSafety.Collision] = [.overwrite, .rename, .skip]
        return Dictionary(collisions.enumerated().map { ($0.element.path, policies[controller.choices[$0.offset] ?? controller.defaultChoice]) }, uniquingKeysWith: { _, last in last })
    }
}
