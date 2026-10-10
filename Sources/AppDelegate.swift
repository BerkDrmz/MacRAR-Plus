import AppKit
import UniformTypeIdentifiers
import SwiftUI

enum Command {
    case extractHere([String])
    case extractFolder([String])
    case extractTo([String])
    case test([String])
    case compress([String])
    case compressDialog([String])
    case setDefault
    case installQuickActions
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    var windows: [ArchiveWindowController] = []
    private var batchWindow: BatchWindowController?
    private var activityWindow: NSWindowController?
    var pendingCommand: Command?
    var pendingFiles: [String] = []
    private var launched = false
    var headless: Bool { pendingCommand != nil }

    static func isArchive(_ path: String) -> Bool { Formats.isArchive(path) }

    // MARK: Yaşam döngüsü

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        launched = true
        scheduleDebugSnapshot()
        if ProcessInfo.processInfo.environment["MACRAR_DEBUG_ABOUT"] != nil { showAbout(nil) }
        if let cmd = pendingCommand {
            NSApp.activate(ignoringOtherApps: true)
            runCommand(cmd)
            return
        }
        let files = pendingFiles
        pendingFiles = []
        if files.isEmpty {
            if windows.isEmpty { showEmptyWindow() }
        } else {
            handleOpen(files)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if let log = ProcessInfo.processInfo.environment["MACRAR_DEBUG_LOG"] {
            let line = "\(Date().timeIntervalSince1970) openFiles(\(filenames.count)): \(filenames.map { ($0 as NSString).lastPathComponent }) launched=\(launched) modal=\(NSApp.modalWindow != nil)\n"
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
        }
        // Finder'a hemen yanıt ver; dosyaları Apple olayı işleyicisinin dışında, modal pencere yokken işle
        sender.reply(toOpenOrPrint: .success)
        if launched {
            scheduleOpen(filenames)
        } else {
            pendingFiles += filenames
        }
    }

    private var queuedFiles: [String] = []
    private func scheduleOpen(_ files: [String]) {
        queuedFiles += files
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.flushQueuedFiles() }
    }
    private func flushQueuedFiles() {
        guard !queuedFiles.isEmpty else { return }
        if NSApp.modalWindow != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.flushQueuedFiles() }
            return
        }
        let files = queuedFiles
        queuedFiles = []
        handleOpen(files)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if TaskCenter.shared.hasActiveTasks {
            Dialogs.info(P("İşlem devam ediyor", "Operation in progress"), P("Verilerin korunması için işlem tamamlandığında çıkın veya önce işlem penceresinden iptal edin.", "Wait until the operation finishes, or cancel it from the operation window before quitting."))
            return .terminateCancel
        }
        for controller in windows {
            if let window = controller.window, !controller.windowShouldClose(window) { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !headless { showEmptyWindow() }
        return true
    }

    // MARK: Pencereler

    @discardableResult
    func showEmptyWindow() -> ArchiveWindowController {
        let wc = ArchiveWindowController()
        windows.append(wc)
        wc.showWindow(nil)
        return wc
    }

    func windowClosed(_ wc: ArchiveWindowController) {
        windows.removeAll { $0 === wc }
    }

    static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func handleOpen(_ rawFiles: [String]) {
        // Aynı dosya hem argüman hem de LaunchServices üzerinden gelebilir → tekilleştir
        var seen = Set<String>()
        let files = rawFiles.map { Self.resolved($0) }.filter { seen.insert($0).inserted }
        let archives = files.filter { Self.isArchive($0) }
        let others = files.filter { !Self.isArchive($0) }
        for a in archives { openArchive(a, reuse: nil) }
        if !others.isEmpty {
            compressWithDialog(items: others, host: nil) { [weak self] path in
                if let path { self?.openArchive(path, reuse: nil) }
                else if self?.windows.isEmpty == true { self?.showEmptyWindow() }
            }
        }
    }

    func openArchive(_ path: String, reuse: ArchiveWindowController?, ownedTemporaryFolder: String? = nil) {
        let path = Formats.firstVolume(Self.resolved(path))
        if let existing = windows.first(where: { $0.archivePath.map(Self.resolved) == path }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let wc: ArchiveWindowController
        if let reuse, reuse.info == nil {
            wc = reuse
        } else if let empty = windows.first(where: { $0.info == nil && $0.archivePath == nil }) {
            wc = empty
        } else {
            wc = ArchiveWindowController()
            windows.append(wc)
        }
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        if let ownedTemporaryFolder { wc.adoptTemporaryFolder(ownedTemporaryFolder) }
        wc.open(path)
        // Listing runs asynchronously; a window stays open until its result arrives.
    }

    /// Seçenek penceresi gösterip sıkıştırır. completion(oluşan arşiv yolu / nil)
    func compressWithDialog(items: [String], host: NSWindow?, completion: @escaping (String?) -> Void) {
        let defaults = UserDefaults.standard
        let format = ArchiveFormat(rawValue: defaults.integer(forKey: "plus.compress.format")) ?? .zip
        let selectedFormat = defaults.object(forKey: "plus.compress.format") == nil ? ArchiveFormat.zip : format
        var opts = CompressOptions(archivePath: CompressOptions.defaultArchivePath(for: items, format: selectedFormat), format: selectedFormat)
        if let destination = defaults.string(forKey: "plus.compress.destination"), FileManager.default.fileExists(atPath: destination) { opts.archivePath = (destination as NSString).appendingPathComponent((opts.archivePath as NSString).lastPathComponent) }
        if defaults.object(forKey: "plus.compress.level") != nil { opts.level = max(0, min(5, defaults.integer(forKey: "plus.compress.level"))) }
        guard let chosen = CompressDialog(options: opts, itemCount: items.count).run() else { completion(nil); return }
        Ops.compress(items: items, options: chosen, host: host) { ok, path in
            completion(ok ? path : nil)
        }
    }

    // MARK: Komut satırı / Finder hızlı eylem modu

    private func runCommand(_ cmd: Command) {
        switch cmd {
        case .setDefault:
            setDefaultHandler { _ in NSApp.terminate(nil) }
        case .installQuickActions:
            let n = QuickActions.installAll()
            print("\(n) hızlı eylem kuruldu: \(QuickActions.servicesDir)")
            NSApp.terminate(nil)
        case .extractHere(let a):
            processArchives(Self.dedupeVolumes(a), dest: { ($0 as NSString).deletingLastPathComponent })
        case .extractFolder(let a):
            processArchives(Self.dedupeVolumes(a), dest: { Ops.folderNamedAfterArchive($0) })
        case .extractTo(let a):
            let list = Self.dedupeVolumes(a)
            guard let first = list.first,
                  let d = Dialogs.chooseFolder(title: L("Nereye çıkartılsın?"), prompt: L("Çıkart"),
                                               initial: (first as NSString).deletingLastPathComponent) else {
                NSApp.terminate(nil); return
            }
            processArchives(list, dest: { _ in d })
        case .test(let a):
            testArchives(Self.dedupeVolumes(a))
        case .compress(let items):
            let existing = items.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { NSApp.terminate(nil); return }
            var opts = CompressOptions(archivePath: CompressOptions.defaultArchivePath(for: existing, format: .rar5), format: .rar5)
            // Hata ayıklama: MACRAR_DEBUG_FORMAT=zip|7z|tar.gz… ve MACRAR_DEBUG_PASSWORD ile biçim/şifre seçimi
            if let f = ProcessInfo.processInfo.environment["MACRAR_DEBUG_FORMAT"],
               let fmt = ArchiveFormat.allCases.first(where: { $0.ext == f }) {
                opts.format = fmt
                opts.archivePath = CompressOptions.defaultArchivePath(for: existing, format: fmt)
                opts.password = ProcessInfo.processInfo.environment["MACRAR_DEBUG_PASSWORD"]
                opts.encryptNames = ProcessInfo.processInfo.environment["MACRAR_DEBUG_ENCNAMES"] != nil
            }
            Ops.compress(items: existing, options: opts, host: nil) { _, _ in NSApp.terminate(nil) }
        case .compressDialog(let items):
            let existing = items.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existing.isEmpty else { NSApp.terminate(nil); return }
            compressWithDialog(items: existing, host: nil) { _ in NSApp.terminate(nil) }
        }
    }

    /// Çok parçalı arşivlerde yalnızca ilk parçayı bırakır (ad.part2.rar, ad.7z.002 vb. atlanır)
    static func dedupeVolumes(_ paths: [String]) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"^(.*)\.(?:part(\d+)\.(?:rar|sfx)|(7z|zip|rar|tar|bin)\.(\d{3,}))$"#, options: .caseInsensitive)
        var best: [String: (Int, String)] = [:]
        var order: [String] = []
        var result: [String] = []
        for raw in paths {
            let p = Formats.firstVolume(raw)
            let ns = p as NSString
            if let m = regex.firstMatch(in: p, range: NSRange(location: 0, length: ns.length)) {
                let partRAR = m.range(at: 2).location != NSNotFound
                let base = ns.substring(with: m.range(at: 1)) + (partRAR ? ".rar" : "." + ns.substring(with: m.range(at: 3)).lowercased())
                let numRange = partRAR ? m.range(at: 2) : m.range(at: 4)
                let num = Int(ns.substring(with: numRange)) ?? 0
                if let cur = best[base] {
                    if num < cur.0 { best[base] = (num, p) }
                } else {
                    best[base] = (num, p)
                    order.append(base)
                }
            } else {
                result.append(p)
            }
        }
        for b in order { if let v = best[b] { result.append(v.1) } }
        return result
    }

    private func processArchives(_ archives: [String], dest: @escaping (String) -> String, index: Int = 0) {
        guard index < archives.count else { NSApp.terminate(nil); return }
        let a = archives[index]
        var pw: String? = nil
        guard let info = Ops.listInteractive(archive: a, password: &pw) else {
            processArchives(archives, dest: dest, index: index + 1)
            return
        }
        Ops.extract(info: info, names: nil, dest: dest(a), password: pw, host: nil) { [weak self] _, _ in
            self?.processArchives(archives, dest: dest, index: index + 1)
        }
    }

    private func testArchives(_ archives: [String], index: Int = 0) {
        guard index < archives.count else { NSApp.terminate(nil); return }
        let a = archives[index]
        var pw: String? = nil
        guard let info = Ops.listInteractive(archive: a, password: &pw) else {
            testArchives(archives, index: index + 1)
            return
        }
        Ops.test(info: info, password: pw, host: nil) { [weak self] _, _ in
            self?.testArchives(archives, index: index + 1)
        }
    }

    // MARK: Hata ayıklama: MACRAR_SNAPSHOT=/yol/önek → açık pencereleri PNG olarak kaydedip çıkar

    private func scheduleDebugSnapshot() {
        guard let prefix = ProcessInfo.processInfo.environment["MACRAR_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["MACRAR_SNAPSHOT_DELAY"] ?? "") ?? 2.0
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            var i = 0
            for w in NSApp.windows where w.isVisible {
                guard let frame = w.contentView?.superview else { continue }
                func dump(_ v: NSView) {
                    if let p = v as? NSProgressIndicator { print("progress bar value:", p.doubleValue, "indeterminate:", p.isIndeterminate) }
                    v.subviews.forEach(dump)
                }
                dump(frame)
                guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
                frame.cacheDisplay(in: frame.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
                    i += 1
                }
            }
            exit(0)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Varsayılan uygulama

    func setDefaultHandler(extensions: [String] = ["rar"], completion: @escaping (Error?) -> Void) {
        var types: [UTType] = []
        for e in extensions {
            if e == "rar", let t = UTType("com.rarlab.rar-archive") { types.append(t); continue }
            if let t = UTType(filenameExtension: e) { types.append(t) }
        }
        func next(_ i: Int) {
            guard i < types.count else { completion(nil); return }
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: types[i]) { err in
                DispatchQueue.main.async {
                    if let err { completion(err) } else { next(i + 1) }
                }
            }
        }
        next(0)
    }

    @objc func makeDefaultForAll(_ sender: Any?) {
        setDefaultHandler(extensions: ["rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab", "iso", "lzh", "arj"]) { err in
            if let err {
                Dialogs.error(L("Varsayılan uygulama ayarlanamadı"), err.localizedDescription)
            } else {
                Dialogs.info(L("Tamam"), L("MacRAR artık yaygın arşiv biçimleri için varsayılan uygulama."))
            }
        }
    }

    @objc func makeDefault(_ sender: Any?) {
        setDefaultHandler { err in
            if let err {
                Dialogs.error(L("Varsayılan uygulama ayarlanamadı"), err.localizedDescription)
            } else {
                Dialogs.info(L("Tamam"), L("MacRAR artık .rar dosyaları için varsayılan uygulama."))
            }
        }
    }

    @objc func installQuickActionsAction(_ sender: Any?) {
        let n = QuickActions.installAll()
        Dialogs.info(L("Finder hızlı eylemleri yüklendi"), LF("%d hızlı eylem kuruldu. Finder'da bir dosyaya sağ tıklayıp \"Hızlı Eylemler\" menüsünden kullanabilirsiniz.", n))
    }

    @objc func energySettings(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = P("Kaynak kullanımı", "Resource usage")
        alert.informativeText = P("Pil dostu: 1 motor iş parçacığı, RAR/7z sıkıştırma sözlüğü 16 MB. Dengeli: en fazla 4 iş parçacığı, 64 MB sözlük. Hızlı: en fazla 8. Küçük sözlük daha az bellek kullanır, sıkıştırma oranını azaltabilir. Düşük güç veya yüksek sıcaklıkta yeni işler pil dostu sınırlara geçer. Boşta tarama yapılmaz.", "Energy saver: 1 engine thread, 16 MB RAR/7z compression dictionary. Balanced: up to 4 threads, 64 MB dictionary. Fast: up to 8. Smaller dictionaries use less memory and may reduce compression ratios. New jobs use energy saver limits in Low Power Mode or high thermal states. No idle scanning.")
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        choice.addItems(withTitles: EnergyMode.allCases.map { $0.title })
        choice.selectItem(at: EnergyMode.allCases.firstIndex(of: EnergyPolicy.mode) ?? 0)
        alert.accessoryView = choice; alert.addButton(withTitle: P("Kaydet", "Save")); alert.addButton(withTitle: L("İptal"))
        if alert.runModal() == .alertFirstButtonReturn { EnergyPolicy.mode = EnergyMode.allCases[choice.indexOfSelectedItem] }
    }

    @objc func showBatch(_ sender: Any?) {
        if batchWindow == nil { batchWindow = BatchWindowController() }
        batchWindow?.showWindow(nil); batchWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showActivity(_ sender: Any?) {
        if activityWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = P("İşlem geçmişi", "Activity history") + " — MacRAR Plus"
            w.contentView = NSHostingView(rootView: ActivityView()); w.isReleasedWhenClosed = false; w.center()
            activityWindow = NSWindowController(window: w)
        }
        activityWindow?.showWindow(nil); activityWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Hakkında

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        credits.append(NSAttributedString(string: P("MacRAR Plus · Geliştirilmiş yerel sürüm\n", "MacRAR Plus · Enhanced native edition\n"), attributes: base))
        credits.append(NSAttributedString(string: P("Geliştirici: BerkDrmz\n", "Developer: BerkDrmz\n"), attributes: base))
        var link = base
        link[.link] = URL(string: "https://github.com/BerkDrmz")!
        link[.foregroundColor] = NSColor.linkColor
        credits.append(NSAttributedString(string: "github.com/BerkDrmz", attributes: link))
        credits.append(NSAttributedString(string: "\n\nMacRAR · MIT (Source-LICENSE.txt)\nRAR/UNRAR © Alexander Roshal (RARLAB)\n7-Zip © Igor Pavlov", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "MacRAR Plus",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "MacRAR Plus © 2026 BerkDrmz",
        ])
    }

    // MARK: Menü

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu()
        app.addItem(withTitle: PlusText("MacRAR Hakkında"), action: #selector(showAbout(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("RAR Dosyaları İçin Varsayılan Uygulama Yap"), action: #selector(makeDefault(_:)), keyEquivalent: "")
        app.addItem(withTitle: L("Tüm Arşivler (ZIP, 7z, TAR…) İçin Varsayılan Yap"), action: #selector(makeDefaultForAll(_:)), keyEquivalent: "")
        app.addItem(withTitle: L("Finder Hızlı Eylemlerini (Yeniden) Yükle"), action: #selector(installQuickActionsAction(_:)), keyEquivalent: "")
        app.addItem(withTitle: P("Kaynak kullanımı…", "Resource usage…"), action: #selector(energySettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: PlusText("MacRAR'ı Gizle"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: L("Diğerlerini Gizle"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Tümünü Göster"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: PlusText("MacRAR'dan Çık"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: L("Dosya"))
        file.addItem(withTitle: L("Arşiv Aç…"), action: #selector(ArchiveWindowController.openArchive(_:)), keyEquivalent: "o")
        file.addItem(withTitle: L("Yeni Arşiv Oluştur…"), action: #selector(ArchiveWindowController.newArchive(_:)), keyEquivalent: "n")
        let compressSelection = file.addItem(withTitle: P("Seçilenleri sıkıştır…", "Compress selected…"), action: #selector(ArchiveWindowController.compressSelected(_:)), keyEquivalent: "k")
        compressSelection.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: L("Buraya Çıkart"), action: #selector(ArchiveWindowController.extractHere(_:)), keyEquivalent: "e")
        let ef = file.addItem(withTitle: L("Klasöre Çıkart"), action: #selector(ArchiveWindowController.extractToFolder(_:)), keyEquivalent: "e")
        ef.keyEquivalentModifierMask = [.command, .option]
        let et = file.addItem(withTitle: L("Şuraya Çıkart…"), action: #selector(ArchiveWindowController.extractTo(_:)), keyEquivalent: "e")
        et.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L("Seçilenleri Buraya Çıkart"), action: #selector(ArchiveWindowController.extractSelectedHere(_:)), keyEquivalent: "")
        file.addItem(withTitle: L("Seçilenleri Şuraya Çıkart…"), action: #selector(ArchiveWindowController.extractSelectedTo(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: L("Arşivi Test Et"), action: #selector(ArchiveWindowController.testArchive(_:)), keyEquivalent: "t")
        file.addItem(withTitle: L("Arşiv Bilgisi"), action: #selector(ArchiveWindowController.showInfo(_:)), keyEquivalent: "i")
        file.addItem(withTitle: P("Arşivi Finder’da göster", "Reveal archive in Finder"), action: #selector(ArchiveWindowController.revealArchive(_:)), keyEquivalent: "")
        file.addItem(withTitle: P("Dosya listesini CSV olarak aktar…", "Export file list as CSV…"), action: #selector(ArchiveWindowController.exportCSV(_:)), keyEquivalent: "")
        file.addItem(withTitle: P("Dosya listesini JSON olarak aktar…", "Export file list as JSON…"), action: #selector(ArchiveWindowController.exportJSON(_:)), keyEquivalent: "")
        file.addItem(.separator())
        let add = file.addItem(withTitle: L("Arşive Dosya Ekle…"), action: #selector(ArchiveWindowController.addFiles(_:)), keyEquivalent: "a")
        add.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: P("Yeniden adlandır…", "Rename…"), action: #selector(ArchiveWindowController.renameSelected(_:)), keyEquivalent: "")
        file.addItem(withTitle: P("Düzenlenen dosyaları arşive kaydet…", "Save edited files to archive…"), action: #selector(ArchiveWindowController.saveEditedFiles(_:)), keyEquivalent: "s")
        file.addItem(withTitle: L("Seçilenleri Arşivden Sil"), action: #selector(ArchiveWindowController.deleteSelected(_:)), keyEquivalent: "\u{8}")
        file.addItem(.separator())
        file.addItem(withTitle: L("Kapat"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Düzen"))
        edit.addItem(withTitle: L("Geri Al"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Yinele"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: P("Arşivde ara", "Search archive"), action: #selector(ArchiveWindowController.focusSearch(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: P("Aramayı ve filtreleri temizle", "Clear search and filters"), action: #selector(ArchiveWindowController.clearSearch(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: P("Arşiv yollarını kopyala", "Copy archive paths"), action: #selector(ArchiveWindowController.copyPaths(_:)), keyEquivalent: "")
        edit.addItem(withTitle: P("Dosya adlarını kopyala", "Copy file names"), action: #selector(ArchiveWindowController.copyNames(_:)), keyEquivalent: "")
        edit.addItem(withTitle: P("Arşiv okumayı iptal et", "Cancel archive loading"), action: #selector(ArchiveWindowController.cancelLoading(_:)), keyEquivalent: ".")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Kes"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Kopyala"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Yapıştır"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Tümünü Seç"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: L("Pencere"))
        win.addItem(withTitle: L("Küçült"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: L("Büyüt"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: L("Tümünü Öne Getir"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        winItem.submenu = win
        NSApp.windowsMenu = win

        let toolsItem = NSMenuItem(); main.addItem(toolsItem)
        let tools = NSMenu(title: P("Araçlar", "Tools"))
        tools.addItem(withTitle: P("Toplu işlemler…", "Batch operations…"), action: #selector(showBatch(_:)), keyEquivalent: "b").keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(withTitle: P("İşlem geçmişi…", "Activity history…"), action: #selector(showActivity(_:)), keyEquivalent: "")
        tools.addItem(withTitle: P("Arama rehberi…", "Search guide…"), action: #selector(ArchiveWindowController.searchHelp(_:)), keyEquivalent: "")
        tools.addItem(withTitle: P("Arşiv haritası…", "Archive map…"), action: #selector(ArchiveWindowController.showMap(_:)), keyEquivalent: "m").keyEquivalentModifierMask = [.command, .shift]
        tools.addItem(.separator())
        tools.addItem(withTitle: P("10 MB’den büyük dosyaları bul", "Find files larger than 10 MB"), action: #selector(ArchiveWindowController.findLargeFiles(_:)), keyEquivalent: "")
        tools.addItem(withTitle: P("Boş dosyaları bul", "Find empty files"), action: #selector(ArchiveWindowController.findEmptyFiles(_:)), keyEquivalent: "")
        tools.addItem(withTitle: P("Şifreli dosyaları bul", "Find encrypted files"), action: #selector(ArchiveWindowController.findEncryptedFiles(_:)), keyEquivalent: "")
        toolsItem.submenu = tools
        file.addItem(withTitle: P("Hızlı önizleme", "Quick preview"), action: #selector(ArchiveWindowController.previewSelected(_:)), keyEquivalent: "y")
        NSApp.mainMenu = main
    }
}
