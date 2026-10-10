import SwiftUI
import AppKit

struct BatchItem: Identifiable {
    let id = UUID()
    let path: String
    var status = P("Bekliyor", "Waiting")
    var finished = false
    var success: Bool?
    var destination: String?
    var detail: String?
    var cancelled = false
}

final class BatchModel: ObservableObject {
    @Published var items: [BatchItem] = []
    @Published var testing = false
    @Published var destination = NSHomeDirectory() + "/Downloads"
    @Published var running = false
    @Published var stopRequested = false
    weak var host: NSWindow?
    var finishedCount: Int { items.filter { $0.finished }.count }
    func add(_ paths: [String]) {
        guard !running else { return }
        let normalized = AppDelegate.dedupeVolumes(paths.filter { Formats.isArchive($0) }.map(AppDelegate.resolved))
        for path in normalized where !items.contains(where: { $0.path == path }) { items.append(BatchItem(path: path)) }
    }
    func choose() { add(Dialogs.chooseFiles(title: P("Toplu işlem için arşiv seç", "Choose archives for batch processing"), prompt: L("Ekle"), archivesOnly: true)) }
    func chooseDestination() {
        if let path = Dialogs.chooseFolder(title: L("Nereye çıkartılsın?"), prompt: L("Seç"), initial: destination) { destination = path }
    }
    private var pendingIndices: [Int] = []
    private var currentStarted = Date.distantPast
    func retryFailed() { start(onlyFailed: true) }
    func start(onlyFailed: Bool = false) {
        guard !running, !items.isEmpty else { return }
        pendingIndices = items.indices.filter { !onlyFailed || items[$0].success != true }
        guard !pendingIndices.isEmpty else { return }
        running = true; stopRequested = false
        for i in pendingIndices { items[i].finished = false; items[i].success = nil; items[i].detail = nil; items[i].cancelled = false; items[i].status = P("Bekliyor", "Waiting") }
        next(0)
    }
    func next(_ position: Int) {
        guard position < pendingIndices.count, !stopRequested else {
            running = false
            if stopRequested {
                for i in items.indices where !items[i].finished { items[i].status = P("Durduruldu", "Stopped") }
            }
            return
        }
        let index = pendingIndices[position]
        currentStarted = Date()
        items[index].status = P("Okunuyor…", "Reading…")
        let path = items[index].path
        Ops.listAsync(archive: path, password: nil) { [self] info, password in
            guard let info else { finish(index, position: position, ok: false, dest: nil); return }
            guard !stopRequested else { running = false; items[index].status = P("Durduruldu", "Stopped"); return }
            items[index].status = testing ? P("Test ediliyor…", "Testing…") : P("Çıkartılıyor…", "Extracting…")
            if testing {
                Ops.test(info: info, password: password, host: host, quiet: true) { [self] ok, _ in finish(index, position: position, ok: ok, dest: nil) }
            } else {
                // Every archive gets a fresh folder; an existing folder is never merged silently.
                let folderName = (Ops.folderNamedAfterArchive(path) as NSString).lastPathComponent
                let dest = uniquePath((destination as NSString).appendingPathComponent(folderName))
                Ops.extract(info: info, names: nil, dest: dest, password: password, host: host, quiet: true) { [self] ok, _ in finish(index, position: position, ok: ok, dest: dest) }
            }
        }
    }
    private func finish(_ index: Int, position: Int, ok: Bool, dest: String?) {
        items[index].finished = true; items[index].success = ok; items[index].destination = dest
        let latest = ArchiveLibrary.shared.activity.first { $0.archive == items[index].path && $0.date >= currentStarted }
        items[index].cancelled = !ok && latest?.cancelled == true
        items[index].detail = !ok ? latest?.detail ?? P("Arşiv okunamadı veya işlem iptal edildi.", "The archive could not be read or the operation was cancelled.") : nil
        items[index].status = ok ? P("Tamamlandı", "Completed") : items[index].cancelled ? P("İptal edildi", "Cancelled") : P("Başarısız", "Failed")
        next(position + 1)
    }
}

struct BatchView: View {
    @ObservedObject var model: BatchModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 32)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(P("Toplu işlemler", "Batch operations")).font(.title2.weight(.semibold))
                    Text(P("Arşivleri sırayla işle. Her arşiv ayrı klasöre çıkarılır.", "Process archives in order. Each archive gets its own folder.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            VStack(alignment: .leading, spacing: 14) {
                Picker(P("İşlem", "Operation"), selection: $model.testing) {
                    Text(P("Çıkart", "Extract")).tag(false)
                    Text(P("Bütünlük testi", "Integrity test")).tag(true)
                }.pickerStyle(.segmented).frame(width: 300)
                if !model.testing {
                    HStack {
                        Label(model.destination.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "folder").font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(P("Hedef değiştir…", "Change destination…")) { model.chooseDestination() }
                    }
                }
            }.padding(.horizontal, 24).padding(.bottom, 18).disabled(model.running)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text(P("İşlenecek arşivleri ekle", "Add archives to your queue")).foregroundStyle(.secondary)
                    Button(P("Arşiv ekle…", "Add archives…")) { model.choose() }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.success == true ? "checkmark.circle.fill" : item.success == false ? "exclamationmark.circle" : "doc.zipper")
                                .foregroundStyle(item.success == true ? Color.green : item.success == false ? Color.orange : Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text((item.path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(item.status).font(.system(size: 11)).foregroundStyle(.secondary)
                                if let detail = item.detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).help(detail) }
                            }
                            Spacer()
                            if let dest = item.destination, item.success == true {
                                Button { Ops.revealInFinder(dest) } label: { Image(systemName: "folder") }.help(P("Finder’da göster", "Show in Finder"))
                            }
                            if !model.running {
                                Button { model.items.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(P("Kuyruktan kaldır", "Remove from queue"))
                            }
                        }.padding(.vertical, 7)
                    }
                }
            }
            Divider()
            HStack(spacing: 12) {
                Button(P("Arşiv ekle…", "Add archives…")) { model.choose() }.disabled(model.running)
                Text("\(model.finishedCount) / \(model.items.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button(model.stopRequested ? P("Duracak…", "Stopping…") : P("Bu işlemden sonra dur", "Stop after this operation")) { model.stopRequested = true }.disabled(model.stopRequested)
                } else {
                    if model.items.contains(where: { $0.success == false }) { Button(P("Başarısızları yeniden dene", "Retry failed")) { model.retryFailed() } }
                    Button(P("Başlat", "Start")) { model.start() }.buttonStyle(.borderedProminent).disabled(model.items.isEmpty)
                }
            }.padding(20)
        }.frame(minWidth: 640, minHeight: 440)
    }
}

final class BatchWindowController: NSWindowController, NSWindowDelegate {
    let model = BatchModel()
    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: w)
        w.title = P("Toplu işlemler", "Batch operations") + " — MacRAR Plus"
        w.contentView = NSHostingView(rootView: BatchView(model: model))
        w.minSize = NSSize(width: 660, height: 480); w.isReleasedWhenClosed = false; w.delegate = self; w.center()
        model.host = w
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.running }
}
