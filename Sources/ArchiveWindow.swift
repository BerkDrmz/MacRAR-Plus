import AppKit
import UniformTypeIdentifiers
import SwiftUI
import Quartz

// MARK: - Ağaç düğümü

final class Node: NSObject {
    let name: String
    let path: String
    let isDir: Bool
    var entry: ArchiveEntry?
    var children: [Node] = []
    weak var parent: Node?

    init(name: String, path: String, isDir: Bool) {
        self.name = name; self.path = path; self.isDir = isDir
    }

    lazy var totalSize: Int64 = {
        if !isDir { return entry?.size ?? 0 }
        return children.reduce(0) { $0 + $1.totalSize }
    }()
    lazy var totalPacked: Int64 = {
        if !isDir { return entry?.packedSize ?? 0 }
        return children.reduce(0) { $0 + $1.totalPacked }
    }()
    lazy var containsEncrypted: Bool = {
        if !isDir { return entry?.encrypted ?? false }
        return children.contains { $0.containsEncrypted }
    }()

    func sortRecursively() {
        children.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children.forEach { $0.sortRecursively() }
    }

    static func buildTree(_ entries: [ArchiveEntry]) -> Node {
        let root = Node(name: "", path: "", isDir: true)
        var map: [String: Node] = ["": root]
        func ensure(_ path: String) -> Node {
            if let n = map[path] { return n }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = ensure(parentPath)
            let n = Node(name: (path as NSString).lastPathComponent, path: path, isDir: true)
            n.parent = parent
            parent.children.append(n)
            map[path] = n
            return n
        }
        for e in entries {
            let clean = e.name.hasSuffix("/") ? String(e.name.dropLast()) : e.name
            if e.isDirectory {
                ensure(clean).entry = e
            } else {
                let parent = ensure((clean as NSString).deletingLastPathComponent)
                let n = Node(name: (clean as NSString).lastPathComponent, path: clean, isDir: false)
                n.entry = e
                n.parent = parent
                parent.children.append(n)
                map[clean] = n
            }
        }
        root.sortRecursively()
        return root
    }

    func flatten(into out: inout [Node]) {
        for c in children {
            out.append(c)
            c.flatten(into: &out)
        }
    }

    /// Parent links preserve exact path boundaries without comparing every
    /// selected path against every other selected path.
    static func selectionRoots(_ nodes: [Node]) -> [Node] {
        let directories = Set(nodes.filter { $0.isDir }.map(ObjectIdentifier.init))
        guard !directories.isEmpty else { return nodes }
        return nodes.filter { node in
            var ancestor = node.parent
            while let current = ancestor {
                if directories.contains(ObjectIdentifier(current)) { return false }
                ancestor = current.parent
            }
            return true
        }
    }
}

// MARK: - Pencere

final class ArchiveWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private(set) var archivePath: String?
    private(set) var info: ArchiveInfo?
    private var password: String?
    private var root = Node(name: "", path: "", isDir: true)
    private var filtered: [Node]? = nil
    private var filterText = ""

    private let outline = ArchiveOutlineView()
    private let model = WorkspaceModel()
    private var welcome: NSView!
    private var inspector: NSView!
    private var inspectorWidth: NSLayoutConstraint!
    private var showsInspector = false
    private var archiveViews: [NSView] = []
    private var generation = 0
    private var loadCancellation: TaskCancellation?
    private var searchWork: DispatchWorkItem?
    private var mapWindow: NSWindowController?
    private var mapCancellation: TaskCancellation?
    private struct EditedFile { let root: String; let path: String; var baseline: ContentRevision; var archiveRevision: ArchiveRevision }
    private var editedFiles: [EditedFile] = []
    private var previewCache: [String: (url: URL, folder: String, size: Int64)] = [:]
    private var navigationPreview: PreviewWindowController?
    private var previewWindows: [PreviewWindowController] = []
    private var temporaryFolders: [String] = []
    private var allNodes: [Node] = []
    private var orderedSearchNodes: [Node]?
    private var treeSortKey: String?
    private var previewCandidates: [Node]?
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: L("Bir arşiv açmak için ⌘O kullanın\nveya bir arşiv dosyasını (RAR, ZIP, 7z…) bu pencereye sürükleyin."))
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q
    }()
    // Finder'a sürükleme oturumu (soru bir kez sorulur, öğeler tek seferde çıkartılır)
    private var dragNodes: [Node] = []
    private var dragDecision: Bool? = nil
    private var dragTempDir: String? = nil
    private var dragExtracted = false
    private var dragExtractOK = false
    private var dragPending = 0

    static let nameCol = NSUserInterfaceItemIdentifier("name")
    static let sizeCol = NSUserInterfaceItemIdentifier("size")
    static let packedCol = NSUserInterfaceItemIdentifier("packed")
    static let ratioCol = NSUserInterfaceItemIdentifier("ratio")
    static let dateCol = NSUserInterfaceItemIdentifier("date")
    static let crcCol = NSUserInterfaceItemIdentifier("crc")
    static let lockCol = NSUserInterfaceItemIdentifier("lock")

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "MacRAR Plus"
        w.minSize = NSSize(width: 720, height: 480)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("PlusSimpleArchiveWindow")
        super.init(window: w)
        w.delegate = self
        buildUI()
        buildToolbar()
        for column in outline.tableColumns {
            let key = "plus.simple.column." + column.identifier.rawValue
            if UserDefaults.standard.object(forKey: key) != nil { column.isHidden = UserDefaults.standard.bool(forKey: key) }
        }
        if let key = UserDefaults.standard.string(forKey: "plus.sort.key") {
            outline.sortDescriptors = [NSSortDescriptor(key: key, ascending: UserDefaults.standard.bool(forKey: "plus.sort.ascending"))]
        }
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        model.open = { [weak self] in self?.openArchive(nil) }
        model.create = { [weak self] in self?.newArchive(nil) }
        model.preview = { [weak self] in self?.previewSelected(nil) }
        model.extractSelected = { [weak self] in self?.extractSelectedTo(nil) }
        model.compressSelected = { [weak self] in self?.compressSelected(nil) }
        model.extractAll = { [weak self] in self?.extractTo(nil) }
        model.openPath = { [weak self] path in AppDelegate.shared.openArchive(path, reuse: self) }
        model.dropped = { paths in AppDelegate.shared.handleOpen(paths) }
        model.filter = { [weak self] category in
            self?.model.category = category
            self?.applyFilter()
        }
        outline.onPreview = { [weak self] in self?.previewSelected(nil) }
        func col(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat = 45, align: NSTextAlignment = .left) -> NSTableColumn {
            let c = NSTableColumn(identifier: id)
            c.title = title; c.width = width; c.minWidth = min; c.headerCell.alignment = align
            if id != Self.lockCol { c.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: true) }
            return c
        }
        outline.addTableColumn(col(Self.nameCol, L("Ad"), width: 280, min: 180))
        outline.addTableColumn(col(Self.lockCol, "", width: 24, min: 24, align: .center))
        outline.addTableColumn(col(Self.sizeCol, L("Boyut"), width: 90, align: .right))
        outline.addTableColumn(col(Self.packedCol, L("Paketli"), width: 90, align: .right))
        outline.addTableColumn(col(Self.ratioCol, L("Oran"), width: 55, align: .right))
        outline.addTableColumn(col(Self.dateCol, L("Değiştirilme"), width: 140))
        outline.addTableColumn(col(Self.crcCol, "CRC32", width: 80))
        outline.tableColumn(withIdentifier: Self.packedCol)?.isHidden = true
        outline.tableColumn(withIdentifier: Self.ratioCol)?.isHidden = true
        outline.tableColumn(withIdentifier: Self.dateCol)?.isHidden = true
        outline.tableColumn(withIdentifier: Self.crcCol)?.isHidden = true
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self; outline.delegate = self
        outline.allowsMultipleSelection = true
        outline.usesAlternatingRowBackgroundColors = false
        outline.rowHeight = 34
        outline.intercellSpacing = NSSize(width: 8, height: 2)
        outline.autoresizesOutlineColumn = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.target = self; outline.doubleAction = #selector(doubleClicked)
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.menu = buildContextMenu()
        outline.setAccessibilityLabel(P("Arşiv dosyaları", "Archive files"))
        let columnsMenu = NSMenu()
        for c in outline.tableColumns where c.identifier != Self.nameCol && c.identifier != Self.lockCol {
            let item = columnsMenu.addItem(withTitle: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = c; item.state = c.isHidden ? .off : .on
        }
        outline.headerView?.menu = columnsMenu
        scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        let header = NSHostingView(rootView: ArchiveHeader(model: model))
        let actions = NSHostingView(rootView: ArchiveActions(model: model))
        let details = NSHostingView(rootView: ArchiveInspector(model: model))
        details.sizingOptions = []
        inspector = details
        inspector.isHidden = true
        let welcomeView = NSHostingView(rootView: WelcomeView(model: model))
        welcomeView.sizingOptions = []
        welcome = welcomeView
        header.sizingOptions = []; actions.sizingOptions = []
        let center = NSView()
        let statusBar = NSView()
        archiveViews = [header, scroll, actions, statusBar]
        for v in [center, inspector!] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        for v in [header, scroll, actions, statusBar, welcome!] { v.translatesAutoresizingMaskIntoConstraints = false; center.addSubview(v) }
        statusLabel.translatesAutoresizingMaskIntoConstraints = false; statusBar.addSubview(statusLabel)
        inspectorWidth = inspector.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            center.leadingAnchor.constraint(equalTo: content.leadingAnchor), center.topAnchor.constraint(equalTo: content.topAnchor), center.bottomAnchor.constraint(equalTo: content.bottomAnchor), center.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: content.trailingAnchor), inspector.topAnchor.constraint(equalTo: content.topAnchor), inspector.bottomAnchor.constraint(equalTo: content.bottomAnchor), inspectorWidth,
            header.topAnchor.constraint(equalTo: center.topAnchor), header.leadingAnchor.constraint(equalTo: center.leadingAnchor), header.trailingAnchor.constraint(equalTo: center.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 60),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: center.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: center.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: actions.topAnchor),
            actions.leadingAnchor.constraint(equalTo: center.leadingAnchor), actions.trailingAnchor.constraint(equalTo: center.trailingAnchor), actions.bottomAnchor.constraint(equalTo: statusBar.topAnchor), actions.heightAnchor.constraint(equalToConstant: 70),
            statusBar.leadingAnchor.constraint(equalTo: center.leadingAnchor), statusBar.trailingAnchor.constraint(equalTo: center.trailingAnchor), statusBar.bottomAnchor.constraint(equalTo: center.bottomAnchor), statusBar.heightAnchor.constraint(equalToConstant: 24),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 18), statusLabel.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -18), statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            welcome.leadingAnchor.constraint(equalTo: center.leadingAnchor), welcome.trailingAnchor.constraint(equalTo: center.trailingAnchor), welcome.topAnchor.constraint(equalTo: center.topAnchor), welcome.bottomAnchor.constraint(equalTo: center.bottomAnchor)
        ])
        updateStatus()
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let col = sender.representedObject as? NSTableColumn else { return }
        col.isHidden.toggle(); sender.state = col.isHidden ? .off : .on
        UserDefaults.standard.set(col.isHidden, forKey: "plus.simple.column." + col.identifier.rawValue)
    }

    func windowDidResize(_ notification: Notification) { updateInspectorVisibility() }

    private func updateInspectorVisibility() {
        let visible = showsInspector && info != nil && (window?.contentView?.bounds.width ?? 960) >= 960
        inspectorWidth.constant = visible ? 235 : 0
        inspector.isHidden = !visible
    }

    @objc func toggleInspector(_ sender: Any?) {
        showsInspector.toggle()
        if showsInspector, let window, window.contentView!.bounds.width < 960 {
            window.setContentSize(NSSize(width: 960, height: window.contentView!.bounds.height))
        }
        updateInspectorVisibility()
    }

    private func buildContextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: P("Hızlı önizleme", "Quick preview"), action: #selector(previewSelected), keyEquivalent: "")
        m.addItem(withTitle: P("Yolu kopyala", "Copy path"), action: #selector(copyPaths), keyEquivalent: "")
        m.addItem(withTitle: P("Dosya adlarını kopyala", "Copy file names"), action: #selector(copyNames), keyEquivalent: "")
        m.addItem(withTitle: L("Aç"), action: #selector(openSelected), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: L("Seçilenleri Buraya Çıkart"), action: #selector(extractSelectedHere), keyEquivalent: "")
        m.addItem(withTitle: L("Seçilenleri Şuraya Çıkart…"), action: #selector(extractSelectedTo), keyEquivalent: "")
        m.addItem(withTitle: P("Seçilenleri sıkıştır…", "Compress selected…"), action: #selector(compressSelected), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: P("Yeniden adlandır…", "Rename…"), action: #selector(renameSelected), keyEquivalent: "")
        m.addItem(withTitle: P("Düzenlenen dosyaları arşive kaydet…", "Save edited files to archive…"), action: #selector(saveEditedFiles), keyEquivalent: "")
        m.addItem(withTitle: L("Arşivden Sil"), action: #selector(deleteSelected), keyEquivalent: "")
        return m
    }

    // MARK: Toolbar

    private enum TB {
        static let open = NSToolbarItem.Identifier("open")
        static let newArchive = NSToolbarItem.Identifier("new")
        static let extractTo = NSToolbarItem.Identifier("extractTo")
        static let extractHere = NSToolbarItem.Identifier("extractHere")
        static let extractFolder = NSToolbarItem.Identifier("extractFolder")
        static let test = NSToolbarItem.Identifier("test")
        static let add = NSToolbarItem.Identifier("add")
        static let delete = NSToolbarItem.Identifier("delete")
        static let info = NSToolbarItem.Identifier("info")
        static let search = NSToolbarItem.Identifier("search")
        static let preview = NSToolbarItem.Identifier("preview")
        static let batch = NSToolbarItem.Identifier("batch")
        static let more = NSToolbarItem.Identifier("more")
    }

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "PlusSimpleToolbar")
        tb.delegate = self
        tb.displayMode = .iconAndLabel
        tb.allowsUserCustomization = true
        tb.autosavesConfiguration = true
        window?.toolbar = tb
        window?.toolbarStyle = .unified
    }

    // MARK: Arşiv yükleme

    func open(_ path: String) {
        if archivePath != nil, let window, !windowShouldClose(window) { return }
        editedFiles.removeAll()
        archivePath = path
        navigationPreview?.close(); navigationPreview = nil
        previewCache.values.forEach { try? FileManager.default.removeItem(atPath: $0.folder) }; previewCache.removeAll()
        password = nil
        reload()
    }

    private func reload() {
        guard let path = archivePath else { return }
        mapCancellation?.cancel(); mapWindow?.close(); mapWindow = nil
        navigationPreview?.close(); navigationPreview = nil
        previewCache.values.forEach { try? FileManager.default.removeItem(atPath: $0.folder) }; previewCache.removeAll()
        loadCancellation?.cancel()
        generation += 1
        let loadGeneration = generation
        model.loading = true; model.loadName = (path as NSString).lastPathComponent
        updateStatus()
        loadCancellation = Ops.listAsync(archive: path, password: password) { [weak self] loaded, password in
            guard let self, self.generation == loadGeneration else { return }
            self.model.loading = false
            guard let loaded else {
                if self.info == nil { self.archivePath = nil }
                self.updateStatus(); return
            }
            self.password = password
            self.info = loaded
            self.model.update(loaded)
            self.root = Node.buildTree(loaded.entries)
            self.allNodes = []; self.root.flatten(into: &self.allNodes)
            self.orderedSearchNodes = nil; self.treeSortKey = nil
            self.applyFilter()
            self.window?.title = (path as NSString).lastPathComponent + " — MacRAR Plus"
            self.window?.subtitle = (path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            self.window?.representedURL = URL(fileURLWithPath: path)
            if self.root.children.count == 1, let only = self.root.children.first, only.isDir { self.outline.expandItem(only) }
            if ProcessInfo.processInfo.environment["MACRAR_DEBUG_EXPAND"] != nil { self.outline.expandItem(nil, expandChildren: true) }
            if let size = ProcessInfo.processInfo.environment["MACRAR_DEBUG_WINDOW"] {
                let parts = size.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { self.window?.setContentSize(NSSize(width: parts[0], height: parts[1])) }
            }
            if let filter = ProcessInfo.processInfo.environment["MACRAR_DEBUG_FILTER"] {
                self.filterText = filter; self.applyFilter()
            }
            if ProcessInfo.processInfo.environment["MACRAR_DEBUG_SELECT"] != nil { self.outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            self.updateStatus(); self.updateInspector()
            self.window?.makeFirstResponder(self.outline)
            NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
            ArchiveLibrary.shared.opened(path)
            if let dest = ProcessInfo.processInfo.environment["MACRAR_DEBUG_DRAG"] { self.simulateDrag(to: dest) }
        }
    }

    /// Hata ayıklama: ilk üst düzey öğeleri Finder'a sürüklenmiş gibi hedefe yazar
    private func simulateDrag(to dest: String) {
        let nodes = Array(root.children.prefix(2))
        guard !nodes.isEmpty else { return }
        outlineView(outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: nodes)
        for n in nodes {
            let p = NSFilePromiseProvider(fileType: "public.data", delegate: self)
            p.userInfo = n
            let url = URL(fileURLWithPath: (dest as NSString).appendingPathComponent(n.name))
            promiseQueue.addOperation { [self] in
                let done = DispatchSemaphore(value: 0)
                filePromiseProvider(p, writePromiseTo: url) { err in
                    print("drag-sim:", n.name, err.map { "HATA \($0)" } ?? "OK")
                    done.signal()
                }
                done.wait()
            }
        }
    }

    private func applyFilter() {
        previewCandidates = nil
        if filterText.isEmpty && model.category == .all { filtered = nil; sortNodes() }
        else {
            let query = ArchiveQuery(filterText)
            if orderedSearchNodes == nil {
                if let sort = outline.sortDescriptors.first {
                    orderedSearchNodes = allNodes.sorted { compareNodes($0, $1, sort: sort) }
                } else { orderedSearchNodes = allNodes }
            }
            filtered = orderedSearchNodes!.filter { node in
                (model.category == .all || node.entry.map { model.category.matches($0) } == true) &&
                query.matches(path: node.path, size: node.totalSize, modified: node.entry?.mtime ?? "", directory: node.isDir, encrypted: node.containsEncrypted)
            }
        }
        outline.reloadData()
        model.hasMatches = filtered?.isEmpty != true
        updateStatus(); updateInspector()
    }

    private func compareNodes(_ a: Node, _ b: Node, sort: NSSortDescriptor) -> Bool {
        if a.isDir != b.isDir { return a.isDir }
        let result: ComparisonResult
        switch sort.key {
        case "size", "packed":
            let x = sort.key == "size" ? a.totalSize : a.totalPacked
            let y = sort.key == "size" ? b.totalSize : b.totalPacked
            result = x == y ? a.name.localizedStandardCompare(b.name) : x < y ? .orderedAscending : .orderedDescending
        case "ratio":
            let x = Double((a.entry?.ratio ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
            let y = Double((b.entry?.ratio ?? "").replacingOccurrences(of: "%", with: "")) ?? 0
            result = x == y ? a.name.localizedStandardCompare(b.name) : x < y ? .orderedAscending : .orderedDescending
        case "date": result = (a.entry?.mtime ?? "").compare(b.entry?.mtime ?? "")
        case "crc": result = (a.entry?.crc ?? "").compare(b.entry?.crc ?? "")
        default: result = a.name.localizedStandardCompare(b.name)
        }
        return sort.ascending ? result == .orderedAscending : result == .orderedDescending
    }

    private func sortNodes() {
        guard let sort = outline.sortDescriptors.first else { return }
        let key = "\(sort.key ?? "name"):\(sort.ascending)"
        guard treeSortKey != key else { return }
        func sortTree(_ n: Node) {
            n.children.sort { compareNodes($0, $1, sort: sort) }
            n.children.forEach(sortTree)
        }
        sortTree(root); treeSortKey = key
    }

    private func updateInspector() {
        let selected = selectedNodes()
        updateInspectorVisibility()
        model.selectionCount = selected.count
        model.selectedName = selected.count == 1 ? selected[0].name : "\(selected.count) " + P("öğe seçili", "items selected")
        model.selectedPath = selected.count == 1 ? selected[0].path : P("Çoklu seçim", "Multiple selection")
        let unique = Node.selectionRoots(selected)
        model.selectedSize = unique.reduce(0) { $0 + $1.totalSize }
        model.selectedPacked = unique.reduce(0) { $0 + $1.totalPacked }
        model.selectedEncrypted = selected.contains { $0.containsEncrypted }
        model.selectedDate = selected.count == 1 ? selected[0].entry?.mtime ?? "" : ""
        model.selectedCRC = selected.count == 1 ? selected[0].entry?.crc ?? "" : ""
        model.canPreview = selected.count == 1 && !selected[0].isDir
    }

    private func updateStatus() {
        welcome?.isHidden = info != nil
        archiveViews.forEach { $0.isHidden = info == nil }
        if model.loading { statusLabel.stringValue = P("Arşiv okunuyor…", "Reading archive…"); return }
        guard info != nil else { statusLabel.stringValue = ""; return }
        if let filtered {
            statusLabel.stringValue = filtered.isEmpty ? P("Eşleşme yok. Aramayı veya dosya filtresini değiştir.", "No matches. Change the search or file filter.") : LF("%d eşleşme", filtered.count)
        } else {
            statusLabel.stringValue = P("Çift tıklayarak aç · Boşluk ile önizle", "Double-click to open · Space to preview")
        }
    }

    // MARK: Seçim yardımcıları

    private func selectedNodes() -> [Node] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? Node }
    }

    /// Seçili düğümlerin arşiv yolları (alt öğeleri zaten kapsayan klasörler sadeleştirilir)
    private func selectedPaths() -> [String] { Self.paths(for: selectedNodes()) }

    private static func paths(for nodes: [Node]) -> [String] {
        Node.selectionRoots(nodes).map(\.path)
    }

    // MARK: Eylemler

    @objc func openArchive(_ sender: Any?) {
        let files = Dialogs.chooseFiles(title: L("Arşiv Aç"), prompt: L("Aç"), archivesOnly: true)
        for f in files { AppDelegate.shared.openArchive(f, reuse: self.info == nil ? self : nil) }
    }

    @objc func newArchive(_ sender: Any?) {
        let items = Dialogs.chooseFiles(title: L("Sıkıştırılacak dosya ve klasörleri seçin"), prompt: L("Seç"), archivesOnly: false)
        guard !items.isEmpty else { return }
        AppDelegate.shared.compressWithDialog(items: items, host: window) { [weak self] path in
            guard let self, let path else { return }
            AppDelegate.shared.openArchive(path, reuse: self.info == nil ? self : nil)
        }
    }

    @objc func compressSelected(_ sender: Any?) {
        guard validate(#selector(compressSelected)), let info else { return }
        let names = selectedPaths()
        guard !names.isEmpty else { return }
        let base = (info.path as NSString).deletingPathExtension
        var options = CompressOptions(archivePath: base + P("-seçilenler.zip", "-selected.zip"), format: .zip)
        options.level = max(0, min(5, UserDefaults.standard.object(forKey: "plus.compress.level") as? Int ?? 3))
        guard let chosen = CompressDialog(options: options, itemCount: names.count, allowsDeletingSources: false).run() else { return }
        model.compressingSelection = true
        Ops.compressSelection(info: info, names: names, options: chosen, password: password, host: window) { [self] ok, path, pw in
            model.compressingSelection = false
            if self.info?.path == info.path { password = pw ?? password }
            if ok, let path { AppDelegate.shared.openArchive(path, reuse: nil) }
        }
    }

    @objc func extractHere(_ sender: Any?) {
        guard let info else { return }
        let dest = (info.path as NSString).deletingLastPathComponent
        doExtract(names: nil, dest: dest)
    }

    @objc func extractToFolder(_ sender: Any?) {
        guard let info else { return }
        doExtract(names: nil, dest: Ops.folderNamedAfterArchive(info.path))
    }

    @objc func extractTo(_ sender: Any?) {
        guard let info else { return }
        guard let dest = Dialogs.chooseFolder(title: L("Nereye çıkartılsın?"), prompt: L("Çıkart"),
                                              initial: (info.path as NSString).deletingLastPathComponent) else { return }
        doExtract(names: nil, dest: dest)
    }

    @objc func extractSelectedHere(_ sender: Any?) {
        guard let info else { return }
        let names = selectedPaths()
        guard !names.isEmpty else { return }
        doExtract(names: names, dest: (info.path as NSString).deletingLastPathComponent)
    }

    @objc func extractSelectedTo(_ sender: Any?) {
        guard let info else { return }
        let names = selectedPaths()
        guard !names.isEmpty else { return }
        guard let dest = Dialogs.chooseFolder(title: L("Seçilenler nereye çıkartılsın?"), prompt: L("Çıkart"),
                                              initial: (info.path as NSString).deletingLastPathComponent) else { return }
        doExtract(names: names, dest: dest)
    }

    private func doExtract(names: [String]?, dest: String) {
        guard let info else { return }
        Ops.extract(info: info, names: names, dest: dest, password: password, host: window) { [weak self] ok, pw in
            self?.password = pw ?? self?.password
            if ok { Ops.revealInFinder(dest) }
        }
    }

    @objc func testArchive(_ sender: Any?) {
        guard let info else { return }
        Ops.test(info: info, password: password, host: window) { [weak self] _, pw in
            self?.password = pw ?? self?.password
        }
    }

    @objc func addFiles(_ sender: Any?) {
        guard info != nil else { newArchive(sender); return }
        let items = Dialogs.chooseFiles(title: L("Arşive eklenecek dosya ve klasörleri seçin"), prompt: L("Ekle"), archivesOnly: false)
        guard !items.isEmpty else { return }
        addItems(items)
    }

    private func addItems(_ items: [String]) {
        guard let info else { return }
        Ops.add(info: info, items: items, password: password, host: window) { [weak self] ok, pw in
            guard let self else { return }
            self.password = pw ?? self.password
            if ok { self.reload() }
        }
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard let info else { return }
        let names = selectedPaths()
        guard !names.isEmpty else { return }
        let list = names.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (names.count > 5 ? " …" : "")
        guard Dialogs.confirm(LF("%d öğe arşivden silinsin mi?", names.count), list + L("\n\nBu işlem geri alınamaz."), okTitle: L("Sil"), destructive: true) else { return }
        Ops.delete(info: info, names: names, password: password, host: window) { [weak self] ok, pw in
            guard let self else { return }
            self.password = pw ?? self.password
            if ok { self.reload() }
        }
    }

    @objc func showInfo(_ sender: Any?) {
        guard let info else { return }
        let fileSize = info.storedSize
        let text = LF("Dosya: %@\nArşiv boyutu: %@\nBiçim: %@\nDosya sayısı: %d\nKlasör sayısı: %d\nToplam boyut: %@\nPaketli boyut: %@\nŞifreli: %@",
                      info.path, Fmt.size(fileSize), info.details, info.fileCount, info.entries.count - info.fileCount,
                      Fmt.size(info.totalSize), Fmt.size(info.totalPacked), info.hasEncryptedFiles ? L("Evet") : L("Hayır"))
        Dialogs.info((info.path as NSString).lastPathComponent, text)
    }

    @objc func openSelected(_ sender: Any?) {
        for n in selectedNodes() { openNode(n) }
    }

    @objc private func doubleClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? Node else { return }
        if n.isDir {
            if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
        } else {
            openNode(n)
        }
    }

    private func openNode(_ n: Node) {
        guard let info else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-\(UUID().uuidString)").path
        Ops.extract(info: info, names: [n.path], dest: tmp, password: password, host: window, quiet: true) { [weak self] ok, pw in
            self?.password = pw ?? self?.password
            guard ok else { try? FileManager.default.removeItem(atPath: tmp); return }
            let target = (tmp as NSString).appendingPathComponent(n.path)
            if Formats.isArchive(target) { AppDelegate.shared.openArchive(target, reuse: nil, ownedTemporaryFolder: tmp) }
            else {
                TaskCenter.shared.work(title: P("Editör kopyası hazırlanıyor", "Preparing editor copy"), host: self?.window, body: { token in
                    try ContentRevision.read(URL(fileURLWithPath: target), cancelled: { token.cancelled })
                }) { result in
                    guard case .success(let baseline) = result else { try? FileManager.default.removeItem(atPath: tmp); return }
                    if let archiveRevision = info.revision {
                        self?.editedFiles.append(EditedFile(root: tmp, path: n.path, baseline: baseline, archiveRevision: archiveRevision))
                    }
                    // Editor copies belong to the user and survive closing this window.
                    NSWorkspace.shared.open(URL(fileURLWithPath: target))
                }
            }
        }
    }

    @objc func previewSelected(_ sender: Any?) {
        guard let node = selectedNodes().first, selectedNodes().count == 1, !node.isDir else { return }
        previewNode(node)
    }
    private func previewNode(_ node: Node) {
        guard let info, !model.loading else { return }
        if let cached = previewCache[node.path], FileManager.default.fileExists(atPath: cached.url.path) { showPreview(node, url: cached.url); return }
        if node.totalSize > 100 * 1024 * 1024 {
            guard Dialogs.confirm(P("Büyük dosya önizlemesi", "Large file preview"), Fmt.size(node.totalSize), okTitle: P("Önizle", "Preview")) else { return }
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-preview-\(UUID().uuidString)").path
        let previewGeneration = generation
        Ops.extract(info: info, names: [node.path], dest: tmp, password: password, host: window, quiet: true) { [weak self] ok, pw in
            guard let self, ok, self.generation == previewGeneration else { try? FileManager.default.removeItem(atPath: tmp); return }
            self.password = pw ?? self.password
            if self.previewCache.count >= 8 || self.previewCache.values.reduce(Int64(0), { $0 + $1.size }) + node.totalSize > 200 * 1024 * 1024 {
                self.navigationPreview?.close(); self.navigationPreview = nil
                self.previewCache.values.forEach { try? FileManager.default.removeItem(atPath: $0.folder) }; self.previewCache.removeAll()
            }
            let url = URL(fileURLWithPath: (tmp as NSString).appendingPathComponent(node.path))
            self.previewCache[node.path] = (url, tmp, node.totalSize)
            self.showPreview(node, url: url)
        }
    }
    private func showPreview(_ node: Node, url: URL) {
        if previewCandidates == nil { previewCandidates = (filtered ?? allNodes).filter { !$0.isDir } }
        let candidates = previewCandidates!
        let index = candidates.firstIndex(where: { $0.path == node.path }) ?? 0
        if navigationPreview?.window?.isVisible != true { navigationPreview = PreviewWindowController(url: url, temporaryFolder: nil) }
        navigationPreview?.navigate = { [weak self] delta in
            let next = index + delta
            guard candidates.indices.contains(next) else { return }
            self?.previewNode(candidates[next])
        }
        navigationPreview?.update(url: url, canPrevious: index > 0, canNext: index + 1 < candidates.count)
        navigationPreview?.showWindow(nil)
    }

    @objc func renameSelected(_ sender: Any?) {
        guard let info, let node = selectedNodes().first, selectedNodes().count == 1 else { return }
        let alert = NSAlert(); alert.messageText = P("Arşiv yolunu değiştir", "Rename archive path")
        let field = NSTextField(string: node.path); field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: P("Kaydet", "Save")); alert.addButton(withTitle: L("İptal")); alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Ops.rename(info: info, old: node.path, new: field.stringValue, password: password, host: window) { [weak self] ok in if ok { self?.reload() } }
    }
    @objc func saveEditedFiles(_ sender: Any?) {
        guard let info else { return }
        let files = editedFiles, currentGeneration = generation
        TaskCenter.shared.work(title: P("Editör değişiklikleri kontrol ediliyor", "Checking editor changes"), host: window, body: { token in
            try files.map { file in try ContentRevision.read(URL(fileURLWithPath: file.root).appendingPathComponent(file.path), cancelled: { token.cancelled }) }
        }) { [weak self] result in
            guard let self, self.generation == currentGeneration, self.editedFiles.count == files.count else { return }
            guard case .success(let snapshots) = result else {
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled { Dialogs.error(P("Editör kopyası okunamadı", "Could not read editor copy"), error.localizedDescription) }
                return
            }
            let changed = files.indices.filter { snapshots[$0] != files[$0].baseline }
            guard !changed.isEmpty else { Dialogs.info(P("Değişiklik yok", "No changes"), P("Dış editörde kaydedilmiş bir değişiklik bulunamadı.", "No changes saved by an external editor were found.")); return }
            guard Dialogs.confirm(P("Değişiklikler arşive kaydedilsin mi?", "Save changes to the archive?"), changed.map { files[$0].path }.joined(separator: "\n"), okTitle: P("Kaydet", "Save")) else { return }
            func next(_ position: Int) {
                guard self.generation == currentGeneration else { return }
                guard position < changed.count else { self.reload(); return }
                let index = changed[position], file = self.editedFiles[index]
                Ops.saveEdited(info: info, relativePath: file.path, directory: file.root, password: self.password, host: self.window, expectedRevision: file.archiveRevision, sourceExpectedRevision: snapshots[index], didCommit: { [weak self] revision in
                    guard let self, self.generation == currentGeneration else { return }
                    for i in self.editedFiles.indices where self.editedFiles[i].archiveRevision == file.archiveRevision { self.editedFiles[i].archiveRevision = revision }
                }) { [weak self] ok in
                    guard let self, ok, self.generation == currentGeneration else { return }
                    self.editedFiles[index].baseline = snapshots[index]
                    next(position + 1)
                }
            }
            next(0)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        let changed = editedFiles.filter { (try? FileRevision.read(URL(fileURLWithPath: ($0.root as NSString).appendingPathComponent($0.path)))) != $0.baseline.metadata }
        if !changed.isEmpty {
            let alert = NSAlert(); alert.messageText = P("Kaydedilmemiş arşiv değişiklikleri var", "Unsaved archive changes")
            alert.informativeText = P("Dış editördeki değişiklikleri arşive kaydetmeden kapatırsanız geçici kopyalar korunur. Dosya menüsünden arşive kaydedebilirsiniz.", "Closing before saving to the archive keeps the temporary copies. Use the File menu to save them to the archive.")
            alert.addButton(withTitle: P("Kopyaları koruyarak kapat", "Close and keep copies")); alert.addButton(withTitle: P("Geri dön", "Go back"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            let roots = Set(changed.map { $0.root }); temporaryFolders.removeAll { roots.contains($0) }
            roots.forEach { Ops.revealInFinder($0) }
        }
        return true
    }

    func adoptTemporaryFolder(_ path: String) { temporaryFolders.append(path) }

    @objc func focusSearch(_ sender: Any?) {
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == TB.search }) as? NSSearchToolbarItem { window?.makeFirstResponder(item.searchField) }
    }
    @objc func cancelLoading(_ sender: Any?) { loadCancellation?.cancel() }

    @objc func copyPaths(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedPaths().joined(separator: "\n"), forType: .string)
    }

    @objc func copyNames(_ sender: Any?) {
        guard !selectedNodes().isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedNodes().map(\.name).joined(separator: "\n"), forType: .string)
    }

    @objc func revealArchive(_ sender: Any?) {
        guard let archivePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: archivePath)])
    }

    @objc func clearSearch(_ sender: Any?) {
        searchWork?.cancel(); searchWork = nil; filterText = ""; model.category = .all
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == TB.search }) as? NSSearchToolbarItem { item.searchField.stringValue = "" }
        applyFilter()
    }

    @objc func findLargeFiles(_ sender: Any?) { useQuery("type:file size>10MB") }
    @objc func findEmptyFiles(_ sender: Any?) { useQuery("type:file size<1B") }
    @objc func findEncryptedFiles(_ sender: Any?) { useQuery("type:file encrypted:yes") }

    private func useQuery(_ text: String) {
        searchWork?.cancel(); searchWork = nil; filterText = text; model.category = .all
        if let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == TB.search }) as? NSSearchToolbarItem { item.searchField.stringValue = text }
        applyFilter()
    }

    @objc func showMap(_ sender: Any?) {
        guard let info, !model.loading, window?.attachedSheet == nil else { return }
        if let mapWindow { mapWindow.showWindow(nil); mapWindow.window?.makeKeyAndOrderFront(nil); return }
        let mapGeneration = generation
        mapCancellation = TaskCenter.shared.work(title: P("Arşiv haritası hazırlanıyor", "Preparing archive map"), host: window, body: { token in
            try ArchiveMap.build(info.entries, cancelled: { token.cancelled })
        }, completion: { [weak self] result in
            guard let self, self.generation == mapGeneration else { return }
            self.mapCancellation = nil
            switch result {
            case .success(let map):
                let view = ArchiveMapView(map: map, name: (info.path as NSString).lastPathComponent) { [weak self] path in self?.locateEntry(path) }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.title = P("Arşiv haritası", "Archive map"); window.minSize = NSSize(width: 600, height: 480)
                window.contentView = NSHostingView(rootView: view); window.isReleasedWhenClosed = false; window.center()
                self.mapWindow = NSWindowController(window: window); self.mapWindow?.showWindow(nil)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(P("Arşiv haritası hazırlanamadı", "Could not prepare archive map"), error.localizedDescription) }
            }
        })
    }

    private func locateEntry(_ path: String) {
        guard !model.loading, window?.attachedSheet == nil, let node = allNodes.first(where: { $0.path == path }) else { return }
        clearSearch(nil)
        var ancestors: [Node] = [], parent = node.parent
        while let current = parent, current !== root { ancestors.append(current); parent = current.parent }
        for ancestor in ancestors.reversed() { outline.expandItem(ancestor) }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(outline)
    }

    @objc func searchHelp(_ sender: Any?) {
        Dialogs.info(P("Arşivde arama rehberi", "Archive search guide"), P(
            "Kelimeler birlikte eşleşir; büyük/küçük harf fark etmez.\n\n\"yıllık rapor\" — tam ifade\n-yedek — bu kelimeyi içeren yolları hariç tut\next:pdf,txt — dosya uzantıları\nsize>10MB size<1GB — boyut aralığı\nafter:2026-01-01 before:2026-12-31 — tarih aralığı (dahil)\ntype:file / type:folder — dosyalar / klasörler\nencrypted:yes / encrypted:no — şifreli / şifresiz\n\nÖrnek: \"yıllık rapor\" -yedek ext:pdf type:file\n\n* ve ? her zaman gerçek karakter olarak aranır. CSV/JSON aktarımı seçili klasörlerin tüm içeriğini; seçim yoksa filtreye uyan kayıtları içerir.",
            "Terms are combined and are case insensitive.\n\n\"annual report\" — exact phrase\n-backup — exclude paths containing this term\next:pdf,txt — file extensions\nsize>10MB size<1GB — size range\nafter:2026-01-01 before:2026-12-31 — inclusive date range\ntype:file / type:folder — files / folders\nencrypted:yes / encrypted:no — encrypted / unencrypted\n\nExample: \"annual report\" -backup ext:pdf type:file\n\n* and ? are always literal characters. CSV/JSON exports include all contents of selected folders; without a selection, matching listing records are exported."))
    }

    @objc func exportCSV(_ sender: Any?) { exportInventory(.csv) }
    @objc func exportJSON(_ sender: Any?) { exportInventory(.json) }

    private func exportInventory(_ format: ArchiveInventory.Format) {
        guard !model.loading, let info, let window, window.attachedSheet == nil else { return }
        // Flush the debounce so export scope and selection agree with the visible rows.
        if searchWork != nil { searchWork?.cancel(); searchWork = nil; applyFilter() }
        let selected = selectedPaths(), matchingPaths = filtered.map { Set($0.map(\.path)) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = (info.path as NSString).lastPathComponent + (format == .csv ? "-files.csv" : "-files.json")
        panel.title = P("Dosya listesini dışa aktar", "Export file list")
        panel.message = selected.isEmpty ? P("Mevcut filtreye uyan arşiv kayıtları aktarılır.", "Export archive records matching the current filter.") : P("Seçilen öğeler ve seçili klasörlerin tüm içeriği aktarılır.", "Export selected items and all contents of selected folders.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            TaskCenter.shared.work(title: P("Dosya listesi kaydediliyor", "Saving file list"), host: self?.window, commitsChanges: true, body: { token in
                let records = try ArchiveInventory.records(entries: info.entries, selection: selected.isEmpty ? nil : selected,
                                                           matchingPaths: matchingPaths, cancelled: { token.cancelled })
                let data = try ArchiveInventory.data(records, format: format, cancelled: { token.cancelled })
                try ArchiveInventory.write(data, to: destination, protecting: info, cancelled: { token.cancelled })
            }, completion: { result in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    Dialogs.error(P("Dosya listesi kaydedilemedi", "Could not save file list"), error.localizedDescription)
                }
            })
        }
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue.trimmingCharacters(in: .whitespaces)
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.searchWork = nil
            self?.applyFilter()
        }
        searchWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    @objc func selectAllItems(_ sender: Any?) {
        outline.selectAll(nil)
    }

    // MARK: Doğrulama

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        validate(item.action)
    }

    private func validate(_ action: Selector?) -> Bool {
        guard let action else { return false }
        if model.loading { return action == #selector(openArchive) || action == #selector(newArchive) || action == #selector(cancelLoading) || action == #selector(focusSearch) }
        if window?.attachedSheet != nil { return false }
        switch action {
        case #selector(compressSelected):
            return info != nil && !outline.selectedRowIndexes.isEmpty && !model.compressingSelection
        case #selector(openArchive), #selector(newArchive):
            return true
        case #selector(extractHere), #selector(extractToFolder), #selector(extractTo), #selector(testArchive), #selector(showInfo), #selector(exportCSV), #selector(exportJSON), #selector(revealArchive), #selector(showMap), #selector(findLargeFiles), #selector(findEmptyFiles), #selector(findEncryptedFiles):
            return info != nil
        case #selector(addFiles):
            return info == nil || info?.supportsModification == true
        case #selector(renameSelected): return info?.supportsModification == true && selectedNodes().count == 1
        case #selector(saveEditedFiles): return info?.supportsModification == true && !editedFiles.isEmpty
        case #selector(deleteSelected):
            return info?.supportsModification == true && !outline.selectedRowIndexes.isEmpty
        case #selector(toggleInspector): return info != nil
        case #selector(previewSelected): return model.canPreview
        case #selector(extractSelectedHere), #selector(extractSelectedTo), #selector(openSelected), #selector(copyPaths), #selector(copyNames):
            return info != nil && !outline.selectedRowIndexes.isEmpty
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        mapCancellation?.cancel(); mapWindow?.close(); mapWindow = nil
        generation += 1; loadCancellation?.cancel(); searchWork?.cancel()
        navigationPreview?.close()
        previewCache.values.forEach { try? FileManager.default.removeItem(atPath: $0.folder) }
        previewWindows.forEach { $0.close() }
        temporaryFolders.forEach { try? FileManager.default.removeItem(atPath: $0) }
        AppDelegate.shared.windowClosed(self)
    }
}

// MARK: - Toolbar delegate

extension ArchiveWindowController: NSToolbarDelegate, NSToolbarItemValidation {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [TB.open, TB.newArchive, .flexibleSpace, TB.search, TB.more]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [TB.extractTo, TB.extractFolder, TB.preview, TB.test, TB.add, TB.extractHere, TB.delete, TB.info, TB.batch, .space]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == TB.more {
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = P("Diğer", "More")
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: item.label)
            item.showsIndicator = true
            let menu = NSMenu()
            func action(_ title: String, _ selector: Selector, target: AnyObject? = nil) {
                let entry = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
                entry.target = target ?? self
            }
            action(P("Dosya bilgilerini göster / gizle", "Show / hide file details"), #selector(toggleInspector))
            menu.addItem(.separator())
            action(L("Arşive Dosya Ekle…"), #selector(addFiles))
            action(P("Arşivi test et", "Test archive"), #selector(testArchive))
            action(P("Arşiv haritası…", "Archive map…"), #selector(showMap))
            action(P("Finder’da göster", "Show in Finder"), #selector(revealArchive))
            menu.addItem(.separator())
            action(P("Dosya listesini CSV olarak aktar…", "Export file list as CSV…"), #selector(exportCSV))
            action(P("Dosya listesini JSON olarak aktar…", "Export file list as JSON…"), #selector(exportJSON))
            menu.addItem(.separator())
            action(P("Toplu işlemler…", "Batch operations…"), #selector(AppDelegate.showBatch), target: AppDelegate.shared)
            action(P("İşlem geçmişi…", "Activity history…"), #selector(AppDelegate.showActivity), target: AppDelegate.shared)
            item.menu = menu
            return item
        }
        if id == TB.search {
            let s = NSSearchToolbarItem(itemIdentifier: id)
            s.label = L("Ara")
            s.searchField.toolTip = P("Örnek: \"yıllık rapor\" -yedek ext:pdf type:file · Araçlar → Arama rehberi", "Example: \"annual report\" -backup ext:pdf type:file · Tools → Search guide")
            s.searchField.placeholderString = L("Arşivde ara")
            s.searchField.target = self
            s.searchField.action = #selector(searchChanged(_:))
            s.searchField.sendsSearchStringImmediately = true
            s.searchField.sendsWholeSearchString = false
            return s
        }
        let specs: [NSToolbarItem.Identifier: (String, String, Selector, String)] = [
            TB.open: (L("Aç"), "folder", #selector(openArchive), L("Arşiv aç")),
            TB.newArchive: (P("Yeni arşiv", "New archive"), "doc.zipper", #selector(newArchive), L("Yeni arşiv oluştur")),
            TB.extractTo: (L("Çıkart…"), "square.and.arrow.down", #selector(extractTo), L("Seçilen klasöre çıkart")),
            TB.extractHere: (L("Buraya"), "arrow.down.doc", #selector(extractHere), L("Arşivin bulunduğu klasöre çıkart")),
            TB.extractFolder: (L("Klasöre"), "folder.badge.plus", #selector(extractToFolder), L("Arşiv adıyla yeni klasöre çıkart")),
            TB.test: (L("Test"), "checkmark.shield", #selector(testArchive), L("Arşivi test et")),
            TB.add: (L("Ekle"), "plus.rectangle.on.folder", #selector(addFiles), L("Arşive dosya ekle")),
            TB.delete: (L("Sil"), "trash", #selector(deleteSelected), L("Seçilenleri arşivden sil")),
            TB.preview: (P("Önizle", "Preview"), "eye", #selector(previewSelected), P("Hızlı önizleme · Boşluk", "Quick preview · Space")),
            TB.batch: (P("Toplu", "Batch"), "square.stack.3d.up", #selector(AppDelegate.showBatch), P("Toplu işlemler", "Batch operations")),
            TB.info: (L("Bilgi"), "info.circle", #selector(showInfo), L("Arşiv bilgisi")),
        ]
        guard let (label, symbol, sel, tip) = specs[id] else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = id == TB.batch ? AppDelegate.shared : self
        item.action = sel
        item.isBordered = true
        return item
    }
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { validate(item.action) }
}

// MARK: - Outline data source / delegate

extension ArchiveWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let f = filtered { return item == nil ? f.count : 0 }
        return ((item as? Node) ?? root).children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let f = filtered { return f[index] }
        return ((item as? Node) ?? root).children[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if filtered != nil { return false }
        return (item as? Node)?.isDir ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let col = tableColumn, let node = item as? Node else { return nil }
        let id = col.identifier
        var cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
        if cell == nil {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingMiddle
            tf.font = .systemFont(ofSize: 13)
            c.addSubview(tf)
            c.textField = tf
            if id == Self.nameCol {
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(iv)
                c.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 20),
                    iv.heightAnchor.constraint(equalToConstant: 20),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
                ])
            } else {
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4).isActive = true
                if id == Self.sizeCol || id == Self.packedCol || id == Self.ratioCol { tf.alignment = .right }
                if id == Self.lockCol { tf.alignment = .center }
                if id == Self.crcCol || id == Self.dateCol { tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
            }
            NSLayoutConstraint.activate([
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            cell = c
        }
        let e = node.entry
        switch id {
        case Self.nameCol:
            cell?.textField?.stringValue = filtered != nil ? node.path : node.name
            cell?.imageView?.image = icon(for: node)
        case Self.sizeCol:
            cell?.textField?.stringValue = Fmt.size(node.totalSize)
        case Self.packedCol:
            cell?.textField?.stringValue = Fmt.size(node.totalPacked)
        case Self.ratioCol:
            cell?.textField?.stringValue = e?.ratio ?? ""
        case Self.dateCol:
            cell?.textField?.stringValue = e?.mtime ?? ""
        case Self.crcCol:
            cell?.textField?.stringValue = node.isDir ? "" : (e?.crc ?? "")
        case Self.lockCol:
            cell?.textField?.stringValue = node.containsEncrypted ? "●" : ""
        default: break
        }
        return cell
    }

    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private func icon(for node: Node) -> NSImage {
        if node.isDir { return NSWorkspace.shared.icon(for: .folder) }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if let c = Self.iconCache.object(forKey: ext as NSString) { return c }
        let img: NSImage
        if let t = UTType(filenameExtension: ext) { img = NSWorkspace.shared.icon(for: t) } else { img = NSWorkspace.shared.icon(for: .data) }
        Self.iconCache.setObject(img, forKey: ext as NSString)
        return img
    }

    func outlineViewSelectionDidChange(_ notification: Notification) { updateStatus(); updateInspector() }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        let selected = selectedNodes()
        if let sort = outlineView.sortDescriptors.first { UserDefaults.standard.set(sort.key, forKey: "plus.sort.key"); UserDefaults.standard.set(sort.ascending, forKey: "plus.sort.ascending") }
        orderedSearchNodes = nil
        applyFilter()
        outlineView.selectRowIndexes(IndexSet(selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
    }

    // Sürükle-bırak: arşiv dosyası bırakıldığında aç, diğer dosyaları arşive ekle
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView !== outlineView else { return [] }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return [] }
        outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return false }
        let paths = urls.map { $0.path }
        let archives = paths.filter { AppDelegate.isArchive($0) }
        let others = paths.filter { !AppDelegate.isArchive($0) }
        if self.info == nil || others.isEmpty {
            for a in archives { AppDelegate.shared.openArchive(a, reuse: self.info == nil ? self : nil) }
            if !others.isEmpty, self.info == nil {
                AppDelegate.shared.compressWithDialog(items: others, host: window) { [weak self] path in
                    if let self, let path { AppDelegate.shared.openArchive(path, reuse: self) }
                }
            }
        } else {
            DispatchQueue.main.async { [weak self] in self?.addItems(others) }
        }
        return true
    }

    // Arşivden Finder'a sürükleme (dosya vaadi)
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        dragNodes = draggedItems.compactMap { $0 as? Node }
        dragDecision = nil
        dragTempDir = nil
        dragExtracted = false
        dragExtractOK = false
        dragPending = dragNodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? Node else { return nil }
        let type: String
        if node.isDir { type = UTType.folder.identifier }
        else { type = UTType(filenameExtension: (node.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier }
        let p = NSFilePromiseProvider(fileType: type, delegate: self)
        p.userInfo = node
        return p
    }
}

extension ArchiveWindowController: NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (p.userInfo as? Node)?.name ?? "dosya"
    }
    func operationQueue(for p: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let node = p.userInfo as? Node, let info else { completionHandler(nil); return }
        let sem = DispatchSemaphore(value: 0)
        var error: Error? = nil
        var source: URL?
        var taskID: UUID?
        let cancellation = TaskCancellation()

        DispatchQueue.main.async { [self] in
            let nodes = dragNodes.isEmpty ? [node] : dragNodes
            let destFolder = url.deletingLastPathComponent()

            // Oturum başına bir kez sor
            if dragDecision == nil {
                let list = nodes.prefix(6).map { $0.name }.joined(separator: ", ") + (nodes.count > 6 ? " …" : "")
                let destName = destFolder.lastPathComponent
                let title = nodes.count == 1
                    ? LF("\"%@\" \"%@\" klasörüne çıkartılsın mı?", nodes[0].name, destName)
                    : LF("%d öğe \"%@\" klasörüne çıkartılsın mı?", nodes.count, destName)
                dragDecision = Dialogs.confirm(title, LF("Arşiv: %@\nHedef: %@\nÖğeler: %@", (info.path as NSString).lastPathComponent, destFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), list), okTitle: L("Çıkart"))
            }
            guard dragDecision == true else { error = CocoaError(.userCancelled); sem.signal(); return }

            func moveIntoPlace() {
                guard let tmp = dragTempDir else { error = CocoaError(.fileNoSuchFile); sem.signal(); return }
                source = URL(fileURLWithPath: (tmp as NSString).appendingPathComponent(node.path))
                taskID = TaskCenter.shared.begin { cancellation.cancel() }
                sem.signal()
            }

            if dragExtracted {
                if dragExtractOK { moveIntoPlace() } else { error = CocoaError(.userCancelled); sem.signal() }
                return
            }

            // İlk öğe: sürüklenen tüm öğeleri tek seferde geçici klasöre çıkart
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-drag-\(UUID().uuidString)").path
            dragTempDir = tmp
            dragExtracted = true
            Ops.extract(info: info, names: Self.paths(for: nodes), dest: tmp, password: password, host: window, quiet: true) { ok, pw in
                self.password = pw ?? self.password
                self.dragExtractOK = ok
                if ok { moveIntoPlace() } else { error = CocoaError(.userCancelled); sem.signal() }
            }
        }

        sem.wait()
        // The delegate runs on promiseQueue. Cross-volume copies stay here;
        // only prompts and drag-session state belong to the main queue.
        if let source, error == nil {
            do { try cancellation.check(); try ArchiveSafety.place(source: source, destination: url) }
            catch let e { error = e }
        }
        var cleanup: String?
        DispatchQueue.main.sync {
            if let taskID { TaskCenter.shared.finish(taskID) }
            dragPending -= 1
            if dragPending <= 0 { cleanup = dragTempDir; dragTempDir = nil }
        }
        if let cleanup { try? FileManager.default.removeItem(atPath: cleanup) }
        completionHandler(error)
    }
}
