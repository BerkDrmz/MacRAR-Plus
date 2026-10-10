import AppKit
import Quartz

final class ArchiveOutlineView: NSOutlineView {
    var onPreview: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onPreview?()
        } else { super.keyDown(with: event) }
    }
}

final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private let temporaryFolder: String?
    var navigate: ((Int) -> Void)?
    private let previous = NSButton(title: "←", target: nil, action: nil)
    private let next = NSButton(title: "→", target: nil, action: nil)
    private var quickLook: QLPreviewView?
    init(url: URL, temporaryFolder: String?) {
        self.temporaryFolder = temporaryFolder
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = url.lastPathComponent; w.isReleasedWhenClosed = false; w.delegate = self; w.center()
        let controls = NSStackView(views: [previous, next]); controls.orientation = .horizontal
        controls.frame = NSRect(x: 12, y: 8, width: 120, height: 30); controls.autoresizingMask = [.maxYMargin]
        previous.target = self; previous.action = #selector(goPrevious); previous.toolTip = P("Önceki dosya", "Previous file")
        next.target = self; next.action = #selector(goNext); next.toolTip = P("Sonraki dosya", "Next file")
        w.contentView?.addSubview(controls)
        var frame = w.contentView!.bounds; frame.origin.y = 45; frame.size.height -= 45
        let preview = QLPreviewView(frame: frame, style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = url as NSURL
        w.contentView?.addSubview(preview); quickLook = preview
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func goPrevious() { navigate?(-1) }
    @objc private func goNext() { navigate?(1) }
    func update(url: URL, canPrevious: Bool, canNext: Bool) {
        window?.title = url.lastPathComponent; quickLook?.previewItem = url as NSURL
        previous.isEnabled = canPrevious; next.isEnabled = canNext
    }
    func windowWillClose(_ notification: Notification) {
        quickLook?.close(); quickLook = nil
        if let temporaryFolder { try? FileManager.default.removeItem(atPath: temporaryFolder) }
    }
}
