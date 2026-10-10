import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// New UI strings stay alongside the UI; the upstream translation table remains intact.
func P(_ tr: String, _ en: String) -> String { L10n.isTurkish ? tr : en }
func PlusText(_ key: String) -> String {
    L(key.replacingOccurrences(of: "MacRAR Plus", with: "MacRAR"))
        .replacingOccurrences(of: "MacRAR", with: "MacRAR Plus")
}

enum FileCategory: String, CaseIterable {
    case all, documents, images, media, code, encrypted
    var title: String {
        switch self {
        case .all: return P("Tüm dosyalar", "All files")
        case .documents: return P("Belgeler", "Documents")
        case .images: return P("Görseller", "Images")
        case .media: return P("Ses ve video", "Audio & video")
        case .code: return P("Kod ve veri", "Code & data")
        case .encrypted: return P("Şifreli öğeler", "Encrypted items")
        }
    }
    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .media: return "play.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .encrypted: return "lock"
        }
    }
    func matches(_ entry: ArchiveEntry) -> Bool {
        if self == .all { return true }
        if self == .encrypted { return entry.encrypted }
        if entry.isDirectory { return false }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch self {
        case .documents: return ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "md", "pages", "numbers", "key", "epub"].contains(ext)
        case .images: return ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff", "bmp", "avif", "psd", "raw"].contains(ext)
        case .media: return ["mp3", "mp4", "mov", "m4a", "wav", "flac", "aac", "mkv", "avi", "ogg", "aiff"].contains(ext)
        case .code: return ["swift", "js", "ts", "tsx", "jsx", "py", "rs", "go", "c", "cpp", "h", "html", "css", "json", "yaml", "yml", "xml", "sql", "csv", "toml", "sh"].contains(ext)
        default: return false
        }
    }
}

final class WorkspaceModel: ObservableObject {
    @Published var info: ArchiveInfo?
    @Published var category: FileCategory = .all
    private(set) var archiveFileCount = 0
    private(set) var archiveTotalSize: Int64 = 0
    private(set) var archiveStoredSize: Int64 = 0
    private(set) var archiveEncrypted = false
    @Published var selectedName = ""
    @Published var selectedPath = ""
    @Published var selectedSize: Int64 = 0
    @Published var selectedPacked: Int64 = 0
    @Published var selectedDate = ""
    @Published var selectedCRC = ""
    @Published var selectedEncrypted = false
    @Published var selectionCount = 0
    @Published var canPreview = false
    @Published var loading = false
    @Published var compressingSelection = false
    @Published var loadName = ""
    @Published var hasMatches = true
    var open: () -> Void = {}
    var create: () -> Void = {}
    var preview: () -> Void = {}
    var extractSelected: () -> Void = {}
    var compressSelected: () -> Void = {}
    var extractAll: () -> Void = {}
    var filter: (FileCategory) -> Void = { _ in }
    var openPath: (String) -> Void = { _ in }
    var dropped: ([String]) -> Void = { _ in }

    func update(_ info: ArchiveInfo?) {
        // Compute once per listing, before publishing it. Selection changes
        // must not rescan the archive or read its size from the filesystem.
        archiveFileCount = 0; archiveTotalSize = 0
        archiveEncrypted = info?.headersEncrypted ?? false
        for entry in info?.entries ?? [] {
            if !entry.isDirectory { archiveFileCount += 1 }
            archiveTotalSize += entry.size
            archiveEncrypted = archiveEncrypted || entry.encrypted
        }
        archiveStoredSize = info?.storedSize ?? 0
        self.info = info
    }
}

struct ArchiveHeader: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.info.map { ($0.path as NSString).lastPathComponent } ?? "MacRAR Plus")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if model.info != nil {
                    Text("\(model.archiveFileCount) " + P("dosya", "files") + " · " + Fmt.size(model.archiveTotalSize))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(FileCategory.allCases, id: \.self) { category in
                    Button { model.filter(category) } label: {
                        if model.category == category { Label(category.title, systemImage: "checkmark") }
                        else { Text(category.title) }
                    }
                }
            } label: { Label(model.category.title, systemImage: "line.3.horizontal.decrease") }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.loading || model.info == nil)
                .help(P("Dosyaları türüne göre göster", "Show files by type"))
        }.padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ArchiveActions: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.selectionCount > 0 ? "\(model.selectionCount) " + P("öğe seçili", "items selected") : P("Tüm dosyalar", "All files"))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.selectionCount > 0 ? Fmt.size(model.selectedSize) : P("Bir dosya seç veya tümünü çıkart", "Select a file or extract everything"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: model.preview) { Label(P("Önizle", "Preview"), systemImage: "eye") }
                .buttonStyle(.bordered).disabled(!model.canPreview).help(P("Tek dosya seç · Boşluk", "Select one file · Space"))
            Button { if model.selectionCount > 0 { model.compressSelected() } else { model.create() } } label: {
                Label(model.selectionCount > 0 ? P("Sıkıştır…", "Compress…") : P("Yeni arşiv…", "New archive…"), systemImage: "doc.zipper")
            }.buttonStyle(.bordered).disabled(model.compressingSelection)
            Button { if model.selectionCount > 0 { model.extractSelected() } else { model.extractAll() } } label: {
                Label(P("Çıkart…", "Extract…"), systemImage: "arrow.down.to.line")
            }.buttonStyle(.borderedProminent)
                .help(model.selectionCount > 0 ? P("Seçilenleri istediğin klasöre çıkart", "Extract selected items to a folder") : P("Tüm dosyaları istediğin klasöre çıkart", "Extract all files to a folder"))
        }.controlSize(.large).padding(.horizontal, 18).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor)).disabled(model.loading || model.info == nil)
    }
}

struct ArchiveInspector: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(P("Dosya bilgileri", "File details")).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                if let info = model.info {
                    Image(systemName: model.selectionCount > 0 ? (model.canPreview ? "doc.text" : "folder") : "shippingbox")
                        .font(.system(size: 44, weight: .light)).foregroundStyle(Color.accentColor).frame(maxWidth: .infinity).padding(.vertical, 12)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.selectionCount > 0 ? model.selectedName : (info.path as NSString).lastPathComponent)
                            .font(.system(size: 15, weight: .semibold)).lineLimit(3)
                        Text(model.selectionCount > 0 ? model.selectedPath : P("Arşiv özeti", "Archive overview"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                    Divider()
                    VStack(spacing: 13) {
                        detail(P("Boyut", "Size"), Fmt.size(model.selectionCount > 0 ? model.selectedSize : model.archiveTotalSize))
                        detail(P("Paketli", "Packed"), Fmt.size(model.selectionCount > 0 ? model.selectedPacked : model.archiveStoredSize))
                        detail(P("Şifreleme", "Encryption"), (model.selectionCount > 0 ? model.selectedEncrypted : model.archiveEncrypted) ? P("Şifreli", "Encrypted") : P("Şifresiz", "None"))
                        if model.selectionCount == 1 {
                            if !model.selectedDate.isEmpty { detail(P("Değiştirilme", "Modified"), model.selectedDate) }
                            if !model.selectedCRC.isEmpty { detail("CRC32", model.selectedCRC) }
                        } else { detail(P("Dosyalar", "Files"), "\(model.archiveFileCount)") }
                    }
                    if model.selectionCount == 0, model.archiveTotalSize > 0 {
                        let saved = max(0, 1 - Double(model.archiveStoredSize) / Double(model.archiveTotalSize))
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: saved).tint(.accentColor)
                            Text(String(format: P("%%%.0f daha az yer", "%.0f%% space saved"), saved * 100)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(P("Bir arşiv açtığında dosya ayrıntıları burada görünür.", "Open an archive to inspect its files here.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(21).id(model.selectionCount > 0 ? model.selectedPath : "archive")
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .medium)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

func archiveSize(_ path: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
}

struct WelcomeView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var library: ArchiveLibrary = .shared
    @State private var targeted = false
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 40)
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).padding(.bottom, 5)
                VStack(spacing: 9) {
                    Text(model.loading ? P("Arşiv okunuyor", "Reading archive") : P("Ne yapmak istersin?", "What would you like to do?"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(model.loading ? model.loadName : P("Bir arşivi aç veya dosyalarını sıkıştır.", "Open an archive or compress your files."))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if model.loading { ProgressView().padding(20) }
                else {
                    HStack(spacing: 12) {
                        Button(action: model.open) { Label(P("Arşiv aç", "Open archive"), systemImage: "folder").padding(.horizontal, 12) }.buttonStyle(.borderedProminent)
                        Button(action: model.create) { Label(P("Yeni arşiv", "New archive"), systemImage: "plus").padding(.horizontal, 12) }.buttonStyle(.bordered)
                    }.controlSize(.large)
                    Text(P("veya dosyaları bu pencereye bırak", "or drop files onto this window")).font(.system(size: 11)).foregroundStyle(.secondary)
                    if !library.recent.isEmpty {
                        VStack(alignment: .leading, spacing: 11) {
                            Text(P("Son açılanlar", "Recent archives")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(Array(library.recent.prefix(4)), id: \.self) { path in
                                Button { model.openPath(path) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "doc.zipper").foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text((path as NSString).lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.padding(.vertical, 7).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(20).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12)).frame(maxWidth: 430).padding(.top, 12)
                    }
                }
                HStack(spacing: 16) {
                    Text("RAR · ZIP · 7z · TAR")
                    Text(P("Tamamen yerel", "Entirely local"))
                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.top, 10)
                Spacer(minLength: 35)
            }.frame(maxWidth: .infinity).padding(.horizontal, 24)
        }.background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(15))
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
            let group = DispatchGroup(); let lock = NSLock(); var paths: [String] = []
            for provider in providers {
                group.enter()
                provider.loadObject(ofClass: NSURL.self) { item, _ in
                    defer { group.leave() }
                    let url = item as? URL
                    if let url { lock.lock(); paths.append(url.path); lock.unlock() }
                }
            }
            group.notify(queue: .main) { model.dropped(paths) }
            return true
        }
    }
}
