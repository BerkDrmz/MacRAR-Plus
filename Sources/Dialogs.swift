import AppKit
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Basit iletişim kutuları

enum Dialogs {
    static func activate() { NSApp.activate(ignoringOtherApps: true) }

    static func askPassword(archiveName: String, wrong: Bool = false) -> String? {
        if let dbg = ProcessInfo.processInfo.environment["MACRAR_DEBUG_PASSWORD"], !wrong { return dbg == "__cancel__" ? nil : dbg }
        activate()
        let alert = NSAlert()
        alert.messageText = wrong ? L("Şifre hatalı") : L("Şifre gerekli")
        alert.informativeText = LF("\"%@\" arşivi şifreli. Lütfen şifreyi girin.", archiveName)
        alert.icon = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
        alert.addButton(withTitle: L("Tamam"))
        alert.addButton(withTitle: L("İptal"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = L("Şifre")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    enum OverwriteMode { case overwrite, rename, skip, cancel }

    static func askOverwrite(existing: [String], dest: String) -> OverwriteMode {
        activate()
        let alert = NSAlert()
        alert.messageText = L("Hedefte aynı adlı öğeler var")
        let shown = existing.prefix(5).joined(separator: ", ") + (existing.count > 5 ? " …" : "")
        alert.informativeText = LF("\"%@\" klasöründe şu öğeler zaten mevcut:\n%@\n\nNe yapılsın?", (dest as NSString).lastPathComponent, shown)
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Üzerine Yaz"))
        alert.addButton(withTitle: L("Yeniden Adlandır"))
        alert.addButton(withTitle: P("Mevcutları atla", "Skip existing"))
        alert.addButton(withTitle: L("İptal"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .rename
        case NSApplication.ModalResponse(rawValue: 1002): return .skip
        default: return .cancel
        }
    }

    static func error(_ title: String, _ detail: String) {
        if ProcessInfo.processInfo.environment["MACRAR_DEBUG_NONINTERACTIVE"] != nil { fputs("\(title): \(detail)\n", stderr); return }
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail.isEmpty ? L("Bilinmeyen hata.") : detail
        alert.alertStyle = .critical
        alert.addButton(withTitle: L("Tamam"))
        alert.runModal()
    }

    static func info(_ title: String, _ detail: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: L("Tamam"))
        alert.runModal()
    }

    static func confirm(_ title: String, _ detail: String, okTitle: String = L("Tamam"), destructive: Bool = false) -> Bool {
        if ProcessInfo.processInfo.environment["MACRAR_DEBUG_CONFIRM"] != nil { return true }
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = destructive ? .warning : .informational
        alert.addButton(withTitle: okTitle)
        alert.addButton(withTitle: L("İptal"))
        if destructive, #available(macOS 11.0, *) { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func chooseFolder(title: String, prompt: String, initial: String? = nil) -> String? {
        activate()
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let initial { panel.directoryURL = URL(fileURLWithPath: initial) }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    static func chooseFiles(title: String, prompt: String, archivesOnly: Bool) -> [String] {
        activate()
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.prompt = prompt
        panel.canChooseDirectories = !archivesOnly
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // Imported UTIs and later volumes can disagree with the system picker.
        // The bundled engine validates the selected file's actual format.
        return panel.runModal() == .OK ? panel.urls.map { $0.path } : []
    }
}

// MARK: - İlerleme çubuğu (animasyonsuz, anında güncellenir)

final class PlainProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        let w = max(r.height, r.width * CGFloat(min(1, max(0, fraction))))
        if fraction > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
                                    xRadius: r.height / 2, yRadius: r.height / 2)
            NSColor.controlAccentColor.setFill()
            fill.fill()
        }
    }
}

// MARK: - İlerleme penceresi

final class ProgressPanel: NSWindowController {
    private static let panelWidth: CGFloat = 500
    private let titleLabel = NSTextField(labelWithString: "")
    private let fileLabel = NSTextField(labelWithString: "")
    private let bar = PlainProgressBar()
    private let detailLabel = NSTextField(labelWithString: "")
    private let toggleButton = NSButton(title: L("Detayları Göster"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L("İptal"), target: nil, action: nil)
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let startTime = Date()
    private var lastLogged = ""
    /// unrar çıktısındaki hedef klasör öneki (dosya adlarını kısaltmak için)
    var stripPrefix: String?
    var onCancel: (() -> Void)?
    private weak var host: NSWindow?

    init(title: String) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "MacRAR Plus"
        w.isReleasedWhenClosed = false
        super.init(window: w)

        titleLabel.stringValue = title
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingHead        // sondaki dosya adı her zaman görünür
        fileLabel.maximumNumberOfLines = 1
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileLabel.stringValue = L("Hazırlanıyor…")

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true

        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        toggleButton.target = self
        toggleButton.action = #selector(toggleDetails)
        toggleButton.bezelStyle = .inline
        toggleButton.font = .systemFont(ofSize: 11)
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)

        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.backgroundColor = .textBackgroundColor
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logView.textContainer?.lineBreakMode = .byCharWrapping
        logView.textContainerInset = NSSize(width: 4, height: 4)
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        let bottomRow = NSStackView(views: [detailLabel, toggleButton, cancelButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 10
        bottomRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, fileLabel, bar, bottomRow, logScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = true
        stack.setCustomSpacing(14, after: bar)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = w.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func cancelPressed() {
        cancelButton.isEnabled = false
        fileLabel.stringValue = L("İptal ediliyor…")
        onCancel?()
    }

    @objc private func toggleDetails() {
        let show = logScroll.isHidden
        logScroll.isHidden = !show
        toggleButton.title = show ? L("Detayları Gizle") : L("Detayları Göster")
        resizeToFit(animate: true)
        if show { scrollLogToEnd() }
    }

    /// Pencereyi içeriğin gerektirdiği yüksekliğe getirir (büyütür ve küçültür), üst kenar sabit kalır
    private func resizeToFit(animate: Bool) {
        guard let w = window, let c = w.contentView else { return }
        c.layoutSubtreeIfNeeded()
        let fit = c.fittingSize
        let contentRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: fit.height)
        if w.sheetParent != nil {
            w.setContentSize(contentRect.size)
            return
        }
        var frame = w.frameRect(forContentRect: contentRect)
        let old = w.frame
        frame.origin = NSPoint(x: old.origin.x, y: old.maxY - frame.height)
        w.setFrame(frame, display: true, animate: animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func show(on host: NSWindow?) {
        self.host = host
        guard let w = window else { return }
        resizeToFit(animate: false)
        if ProcessInfo.processInfo.environment["MACRAR_DEBUG_DETAILS"] != nil { toggleDetails() }
        if ProcessInfo.processInfo.environment["MACRAR_DEBUG_DETAILS"] == "toggle" { toggleDetails() }
        if let host, host.isVisible {
            host.beginSheet(w)
        } else {
            w.center()
            showWindow(nil)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func dismiss() {
        guard let w = window else { return }
        if let host, host.isVisible, host.attachedSheet == w {
            host.endSheet(w)
        }
        w.orderOut(nil)
        close()
    }

    func setFile(_ raw: String) {
        var name = raw
        if let p = stripPrefix, !p.isEmpty {
            let pre = p.hasSuffix("/") ? p : p + "/"
            if name.hasPrefix(pre) { name = String(name.dropFirst(pre.count)) }
            else if name == p { name = (p as NSString).lastPathComponent }
        }
        fileLabel.stringValue = name
        guard name != lastLogged else { return }
        lastLogged = name
        if let storage = logView.textStorage, storage.length > 250_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 125_000)) }
        logView.textStorage?.append(NSAttributedString(string: name + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if !logScroll.isHidden { scrollLogToEnd() }
    }

    private func scrollLogToEnd() {
        logView.scrollToEndOfDocument(nil)
    }

    func setFraction(_ f: Double?) {
        if let f {
            let v = min(1, max(0, f))
            bar.fraction = v
            var text = LF("%%%d", Int(v * 100))
            let elapsed = Date().timeIntervalSince(startTime)
            if v >= 0.02, v < 1, elapsed > 2 {
                let remaining = elapsed * (1 - v) / v
                text += LF("  •  kalan ~%@  •  geçen %@", Self.format(remaining), Self.format(elapsed))
            } else if elapsed > 2 {
                text += LF("  •  geçen %@", Self.format(elapsed))
            }
            detailLabel.stringValue = text
        } else {
            bar.fraction = 0
            detailLabel.stringValue = ""
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        if s < 60 { return LF("%d sn", s) }
        if s < 3600 { return LF("%d dk %d sn", s / 60, s % 60) }
        return LF("%d sa %d dk", s / 3600, (s % 3600) / 60)
    }
}

// MARK: - Sıkıştırma seçenekleri

enum ArchiveFormat: Int, CaseIterable {
    case rar5 = 0, sevenZip, zip, tar, tgz, txz, tbz2

    var title: String {
        switch self {
        case .rar5: return "RAR 5"
        case .sevenZip: return "7z"
        case .zip: return "ZIP"
        case .tar: return L("TAR (sıkıştırmasız)")
        case .tgz: return "TAR.GZ"
        case .txz: return "TAR.XZ"
        case .tbz2: return "TAR.BZ2"
        }
    }
    var ext: String {
        switch self {
        case .rar5: return "rar"
        case .sevenZip: return "7z"
        case .zip: return "zip"
        case .tar: return "tar"
        case .tgz: return "tar.gz"
        case .txz: return "tar.xz"
        case .tbz2: return "tar.bz2"
        }
    }
    var isRar: Bool { self == .rar5 }
    var isTarFamily: Bool { self == .tar || self == .tgz || self == .txz || self == .tbz2 }
    var supportsPassword: Bool { isRar || self == .sevenZip || self == .zip }
    var supportsEncryptNames: Bool { isRar || self == .sevenZip }
    var supportsSolid: Bool { isRar || self == .sevenZip }
    var supportsRecovery: Bool { isRar }
    var supportsSFX: Bool { isRar }
    var supportsVolumes: Bool { isRar || self == .sevenZip || self == .zip }
    var supportsLevel: Bool { self != .tar }
    var supportsAppend: Bool { !isTarFamily || self == .tar }

    static func detect(fromPath path: String) -> ArchiveFormat? {
        let lower = path.lowercased()
        if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { return .tgz }
        if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { return .txz }
        if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".tbz") { return .tbz2 }
        switch (lower as NSString).pathExtension {
        case "rar": return .rar5
        case "7z": return .sevenZip
        case "zip": return .zip
        case "tar": return .tar
        default: return nil
        }
    }

    /// Yolun arşiv uzantısını bu biçime göre değiştirir
    func replacingExtension(in path: String) -> String {
        var base = path
        let lower = base.lowercased()
        for suf in [".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".txz", ".tbz2", ".tbz", ".rar", ".7z", ".zip", ".tar"] {
            if lower.hasSuffix(suf) { base = String(base.dropLast(suf.count)); break }
        }
        return base + "." + ext
    }
}

struct CompressOptions {
    var archivePath: String
    var format: ArchiveFormat = .zip
    var level: Int = 3                 // 0-5
    var password: String? = nil
    var encryptNames: Bool = false
    var solid: Bool = false
    var recoveryRecord: Bool = false
    var volumeSize: String? = nil      // "100M" gibi
    var sfx: Bool = false
    var deleteAfter: Bool = false

    func validatePassword() throws {
        guard let password, !password.isEmpty else { return }
        guard !password.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ArchiveSafetyError(message: P("Şifre sıfır karakteri içeremez.", "The password cannot contain a NUL character."))
        }
        if format == .zip, password.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) {
            throw ArchiveSafetyError(message: P("Bu ZIP motoru şifrede yalnızca standart İngilizce harfleri, rakamları, boşluk ve noktalama işaretlerini destekliyor. Türkçe karakter veya emoji içeren şifreler için 7z biçimini seçin.", "This ZIP engine supports only printable ASCII passwords. Choose 7z for passwords containing other characters or emoji."))
        }
    }

    struct Step {
        let title: String
        let tool: RarTool
        let args: [String]
        var cleanup: (() -> Void)? = nil
    }

    /// 0-5 düzeyini 7zz -mx değerine çevirir
    private var mx: Int { [0, 1, 3, 5, 7, 9][max(0, min(5, level))] }

    private var sevenZipCommon: [String] {
        var a = ["a", "-spd", "-y", "-bsp1", "-bb1"]
        if let v = volumeSize, !v.isEmpty, format.supportsVolumes { a.append("-v\(v)") }

        return a
    }

    func buildSteps(items: [String]) -> [Step] {
        switch format {
        case .rar5:
            var a = ["a", "-ep1", "-r", "-y", "-m\(level)", "-ma5"]
            if solid { a.append("-s") }
            if recoveryRecord { a.append("-rr3") }
            if let v = volumeSize, !v.isEmpty { a.append("-v\(v)") }
            if sfx { a.append("-sfx" + RarRunner.resourceDir.appendingPathComponent("default.sfx").path) }

            if let pw = password, !pw.isEmpty { a += RarRunner.passwordArgs(pw, encryptHeaders: encryptNames) }
            return [Step(title: L("Sıkıştırılıyor"), tool: .rar, args: a + ["--", archivePath] + items)]

        case .sevenZip:
            var a = sevenZipCommon + ["-t7z", "-mx=\(mx)", solid ? "-ms=on" : "-ms=off"]
            if let pw = password, !pw.isEmpty {
                a.append("-p" + pw)
                if encryptNames { a.append("-mhe=on") }
            }
            return [Step(title: L("Sıkıştırılıyor"), tool: .sevenZip, args: a + ["--", archivePath] + items)]

        case .zip:
            var a = sevenZipCommon + ["-tzip", "-mx=\(mx)"]
            if let pw = password, !pw.isEmpty { a += ["-p" + pw, "-mem=AES256"] }
            return [Step(title: L("Sıkıştırılıyor"), tool: .sevenZip, args: a + ["--", archivePath] + items)]

        case .tar:
            let a = sevenZipCommon + ["-ttar"]
            return [Step(title: L("Paketleniyor"), tool: .sevenZip, args: a + ["--", archivePath] + items)]

        case .tgz, .txz, .tbz2:
            let outer: String = format == .tgz ? "gzip" : (format == .txz ? "xz" : "bzip2")
            let tmpTar = (archivePath as NSString).deletingLastPathComponent + "/.macrarplus-intermediate-\(UUID().uuidString).tar"
            let step1 = ["a", "-spd", "-y", "-bsp1", "-bb1", "-ttar"]
            // Delete only after every compression stage has succeeded.
            let step2 = ["a", "-y", "-bsp1", "-bb1", "-t\(outer)", "-mx=\(mx)", "--", archivePath, tmpTar]
            return [
                Step(title: L("Paketleniyor"), tool: .sevenZip, args: step1 + ["--", tmpTar] + items),
                Step(title: L("Sıkıştırılıyor"), tool: .sevenZip, args: step2, cleanup: { try? FileManager.default.removeItem(atPath: tmpTar) }),
            ]
        }
    }

    static func defaultArchivePath(for items: [String], format: ArchiveFormat = .zip) -> String {
        guard let first = items.first else { return L("arşiv") + "." + format.ext }
        let parent = (first as NSString).deletingLastPathComponent
        var base: String
        if items.count == 1 {
            base = (first as NSString).lastPathComponent
            if !isDirectoryPath(first) { base = (base as NSString).deletingPathExtension }
        } else {
            base = (parent as NSString).lastPathComponent
        }
        if base.isEmpty || base == "/" { base = L("arşiv") }
        return (parent as NSString).appendingPathComponent(base + "." + format.ext)
    }
}

final class CompressDialog: NSWindowController, NSWindowDelegate {
    private let pathField = NSTextField()
    private let formatPopup = NSPopUpButton()
    private let levelPopup = NSPopUpButton()
    private let profilePopup = NSPopUpButton()
    private let pwField = NSSecureTextField()
    private let pw2Field = NSSecureTextField()
    private let encryptNamesBox = NSButton(checkboxWithTitle: L("Dosya adlarını da şifrele"), target: nil, action: nil)
    private let solidBox = NSButton(checkboxWithTitle: L("Katı (solid) arşiv"), target: nil, action: nil)
    private let rrBox = NSButton(checkboxWithTitle: L("Kurtarma kaydı ekle (%3)"), target: nil, action: nil)
    private let sfxBox = NSButton(checkboxWithTitle: L("Kendiliğinden açılan (SFX) arşiv"), target: nil, action: nil)
    private let deleteBox = NSButton(checkboxWithTitle: P("Doğrulamadan sonra kaynakları Çöp Sepeti’ne taşı", "Move sources to Trash after verification"), target: nil, action: nil)
    private let volumeField = NSTextField()
    private let hintLabel = NSTextField(labelWithString: "")
    private let protectionBox = NSSwitch()
    private let advancedButton = NSButton()
    private var passwordGrid: NSGridView!
    private var advancedGrid: NSGridView!
    private var formStack: NSStackView!
    private var result: CompressOptions?
    private var options: CompressOptions

    init(options: CompressOptions, itemCount: Int, allowsDeletingSources: Bool = true) {
        self.options = options
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 370),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Arşiv Oluştur")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build(itemCount: itemCount, allowsDeletingSources: allowsDeletingSources)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(itemCount: Int, allowsDeletingSources: Bool) {
        guard let content = window?.contentView else { return }
        pathField.stringValue = options.archivePath
        pathField.placeholderString = L("/yol/arşiv.rar")
        pathField.usesSingleLineMode = true
        pathField.cell?.wraps = false
        pathField.cell?.isScrollable = true
        pathField.lineBreakMode = .byTruncatingMiddle
        let browse = NSButton(title: L("Gözat…"), target: self, action: #selector(browse))
        let pathRow = NSStackView(views: [pathField, browse])
        pathRow.orientation = .horizontal
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        formatPopup.addItems(withTitles: ArchiveFormat.allCases.map { $0.title })
        formatPopup.selectItem(at: options.format.rawValue)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        levelPopup.addItems(withTitles: [L("Depola (sıkıştırma yok)"), L("En hızlı"), L("Hızlı"), L("Normal"), L("İyi"), L("En iyi")])
        levelPopup.selectItem(at: options.level)
        pwField.placeholderString = L("Boş bırakılırsa şifrelenmez")
        pw2Field.placeholderString = L("Şifreyi tekrar girin")
        volumeField.placeholderString = L("örn. 100M, 1G, 700M  (boş = bölme)")
        for f in [volumeField, pwField, pw2Field] as [NSTextField] {
            f.usesSingleLineMode = true
            f.cell?.wraps = false
            f.cell?.isScrollable = true
        }
        encryptNamesBox.state = options.encryptNames ? .on : .off
        solidBox.state = options.solid ? .on : .off
        rrBox.state = options.recoveryRecord ? .on : .off
        sfxBox.state = options.sfx ? .on : .off
        deleteBox.state = options.deleteAfter ? .on : .off
        if !allowsDeletingSources { deleteBox.state = .off; deleteBox.isEnabled = false }
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.maximumNumberOfLines = 1
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hintLabel.widthAnchor.constraint(equalToConstant: 350).isActive = true

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let header = NSTextField(labelWithString: LF("%d öğe sıkıştırılacak", itemCount))
        header.font = .boldSystemFont(ofSize: 13)

        let formatCell = NSStackView(views: [formatPopup, hintLabel])
        formatCell.orientation = .vertical
        formatCell.alignment = .leading
        formatCell.spacing = 4

        profilePopup.addItems(withTitles: [P("Özel / son ayarlar", "Custom / last settings"), P("Hızlı ZIP", "Fast ZIP"), P("Yüksek sıkıştırma · 7z", "High compression · 7z"), P("Şifreli paylaşım · 7z", "Encrypted sharing · 7z")])
        profilePopup.target = self; profilePopup.action = #selector(profileChanged)
        let grid = NSGridView(views: [
            [label(L("Arşiv:")), pathRow],
            [label(L("Biçim:")), formatCell],
        ])
        passwordGrid = NSGridView(views: [
            [label(L("Şifre:")), pwField],
            [label(L("Şifre (tekrar):")), pw2Field],
            [NSGridCell.emptyContentView, encryptNamesBox],
        ])
        advancedGrid = NSGridView(views: [
            [label(P("Profil:", "Profile:")), profilePopup],
            [label(L("Sıkıştırma:")), levelPopup],
            [label(L("Parçalara böl:")), volumeField],
            [label(L("Seçenekler:")), solidBox],
            [NSGridCell.emptyContentView, rrBox],
            [NSGridCell.emptyContentView, sfxBox],
            [NSGridCell.emptyContentView, deleteBox],
        ])
        for form in [grid, passwordGrid!, advancedGrid!] {
            form.rowSpacing = 8; form.columnSpacing = 10
            form.column(at: 0).xPlacement = .trailing
            form.column(at: 0).width = 125
            form.column(at: 1).width = 360
        }
        protectionBox.target = self; protectionBox.action = #selector(toggleProtection)
        protectionBox.setAccessibilityLabel(P("Şifreyle koru", "Protect with password"))
        let protectionLabel = NSTextField(labelWithString: P("Şifreyle koru", "Protect with password"))
        let protectionRow = NSStackView(views: [protectionBox, protectionLabel])
        protectionRow.orientation = .horizontal; protectionRow.alignment = .centerY; protectionRow.spacing = 8
        protectionBox.state = options.password?.isEmpty == false ? .on : .off
        pwField.stringValue = options.password ?? ""; pw2Field.stringValue = options.password ?? ""
        passwordGrid.isHidden = protectionBox.state != .on
        advancedButton.title = P("Gelişmiş seçenekler", "Advanced options")
        advancedButton.setButtonType(.onOff)
        advancedButton.bezelStyle = .inline
        advancedButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        advancedButton.imagePosition = .imageLeft
        advancedButton.target = self; advancedButton.action = #selector(toggleAdvanced)
        let expanded = options.sfx || options.deleteAfter || options.solid || options.recoveryRecord || options.volumeSize?.isEmpty == false
        advancedButton.state = expanded ? .on : .off
        advancedGrid.isHidden = !expanded
        if expanded { advancedButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) }

        let ok = NSButton(title: L("Oluştur"), target: self, action: #selector(okPressed))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: L("İptal"), target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, ok])
        buttons.orientation = .horizontal

        let root = NSStackView(views: [header, grid, protectionRow, passwordGrid!, advancedButton, advancedGrid!, buttons])
        formStack = root
        root.detachesHiddenViews = true
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathRow.widthAnchor.constraint(equalToConstant: 360),
        ])
        window?.initialFirstResponder = pathField
        applyFormatRules()
        resizeForm()
    }

    private func resizeForm() {
        formStack.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: 560, height: formStack.fittingSize.height + 40))
    }

    @objc private func toggleAdvanced() {
        advancedGrid.isHidden = advancedButton.state != .on
        advancedButton.image = NSImage(systemSymbolName: advancedGrid.isHidden ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
        resizeForm()
    }

    @objc private func toggleProtection() {
        passwordGrid.isHidden = protectionBox.state != .on
        if passwordGrid.isHidden { pwField.stringValue = ""; pw2Field.stringValue = ""; encryptNamesBox.state = .off }
        resizeForm()
        if !passwordGrid.isHidden { window?.makeFirstResponder(pwField) }
    }

    private var selectedFormat: ArchiveFormat {
        ArchiveFormat(rawValue: formatPopup.indexOfSelectedItem) ?? .rar5
    }

    @objc private func profileChanged() {
        switch profilePopup.indexOfSelectedItem {
        case 1: formatPopup.selectItem(at: ArchiveFormat.zip.rawValue); levelPopup.selectItem(at: 1); encryptNamesBox.state = .off; solidBox.state = .off
        case 2: formatPopup.selectItem(at: ArchiveFormat.sevenZip.rawValue); levelPopup.selectItem(at: 5); solidBox.state = .on; encryptNamesBox.state = .off
        case 3: protectionBox.state = .on; toggleProtection(); formatPopup.selectItem(at: ArchiveFormat.sevenZip.rawValue); levelPopup.selectItem(at: 3); solidBox.state = .off; encryptNamesBox.state = .on; window?.makeFirstResponder(pwField)
        default: return
        }
        deleteBox.state = .off; sfxBox.state = .off; volumeField.stringValue = ""
        formatChanged()
    }

    @objc private func formatChanged() {
        let f = selectedFormat
        let p = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty { pathField.stringValue = f.replacingExtension(in: p) }
        applyFormatRules()
    }

    private func applyFormatRules() {
        let f = selectedFormat
        levelPopup.isEnabled = f.supportsLevel
        protectionBox.isEnabled = f.supportsPassword
        pwField.isEnabled = f.supportsPassword
        pw2Field.isEnabled = f.supportsPassword
        encryptNamesBox.isEnabled = f.supportsEncryptNames
        solidBox.isEnabled = f.supportsSolid
        rrBox.isEnabled = f.supportsRecovery
        sfxBox.isEnabled = f.supportsSFX
        volumeField.isEnabled = f.supportsVolumes
        switch f {
        case .rar5: hintLabel.stringValue = L("En iyi sıkıştırma ve kurtarma kaydı; WinRAR 5+ ile açılır.")
        case .sevenZip: hintLabel.stringValue = L("Ücretsiz, yüksek sıkıştırma; AES-256 şifre ve ad şifreleme destekler.")
        case .zip: hintLabel.stringValue = P("ZIP · AES-256. Türkçe/emojili şifre için 7z seçin.", "ZIP · AES-256. Use 7z for non-ASCII passwords.")
        case .tar: hintLabel.stringValue = L("Sıkıştırma yapmaz, yalnızca paketler.")
        case .tgz, .txz, .tbz2: hintLabel.stringValue = L("Unix/Linux için; şifre ve parçalara bölme desteklemez.")
        }
    }

    @objc private func browse() {
        let panel = NSSavePanel()
        panel.title = L("Arşivi Kaydet")
        panel.nameFieldStringValue = (pathField.stringValue as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: (pathField.stringValue as NSString).deletingLastPathComponent)
        if panel.runModal() == .OK, let u = panel.url { pathField.stringValue = u.path }
    }

    @objc private func okPressed() {
        var path = pathField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { NSSound.beep(); return }
        let f = selectedFormat
        if ArchiveFormat.detect(fromPath: path) != f { path = f.replacingExtension(in: path) }
        if f.supportsPassword, protectionBox.state == .on, pwField.stringValue.isEmpty {
            Dialogs.error(P("Şifre gerekli", "Password required"), P("Şifreyle korumak için bir şifre girin veya bu seçeneği kapatın.", "Enter a password or turn off password protection."))
            window?.makeFirstResponder(pwField)
            return
        }
        if f.supportsPassword, pwField.stringValue != pw2Field.stringValue {
            Dialogs.error(L("Şifreler eşleşmiyor"), L("Her iki şifre alanına aynı şifreyi girin."))
            return
        }
        var o = options
        o.archivePath = path
        o.format = f
        o.level = levelPopup.indexOfSelectedItem
        o.password = (f.supportsPassword && !pwField.stringValue.isEmpty) ? pwField.stringValue : nil
        do { try o.validatePassword() }
        catch { Dialogs.error(P("Şifre bu biçime uygun değil", "Password is not supported"), error.localizedDescription); return }
        o.encryptNames = f.supportsEncryptNames && encryptNamesBox.state == .on
        o.solid = f.supportsSolid && solidBox.state == .on
        o.recoveryRecord = f.supportsRecovery && rrBox.state == .on
        o.sfx = f.supportsSFX && sfxBox.state == .on
        o.deleteAfter = deleteBox.state == .on
        let v = volumeField.stringValue.trimmingCharacters(in: .whitespaces)
        o.volumeSize = (f.supportsVolumes && !v.isEmpty) ? v : nil
        if profilePopup.indexOfSelectedItem == 3, o.password == nil {
            Dialogs.error(P("Şifre gerekli", "Password required"), P("Şifreli paylaşım profili için bir şifre girin.", "Enter a password for the encrypted sharing profile.")); return
        }
        UserDefaults.standard.set(o.format.rawValue, forKey: "plus.compress.format")
        UserDefaults.standard.set(o.level, forKey: "plus.compress.level")
        UserDefaults.standard.set((path as NSString).deletingLastPathComponent, forKey: "plus.compress.destination")
        result = o
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelPressed() { NSApp.stopModal(withCode: .cancel) }

    func windowWillClose(_ notification: Notification) {
        if NSApp.modalWindow === window { NSApp.stopModal(withCode: .cancel) }
    }

    /// Modal gösterir; iptalde nil döner.
    func run() -> CompressOptions? {
        guard let w = window else { return nil }
        Dialogs.activate()
        // Pencereyi içeriğin gerektirdiği yüksekliğe getir (fazla boşluk satırlar arasına dağılmasın)
        if let content = w.contentView {
            content.layoutSubtreeIfNeeded()
            let fit = content.fittingSize
            w.setContentSize(NSSize(width: max(fit.width, 520), height: fit.height))
        }
        w.center()
        let code = NSApp.runModal(for: w)
        w.orderOut(nil)
        return code == .OK ? result : nil
    }
}
