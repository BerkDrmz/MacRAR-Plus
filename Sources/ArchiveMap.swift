import AppKit
import SwiftUI

/// One metadata pass, requested explicitly. CRC groups are candidates, never proof of identical contents.
struct ArchiveMap {
    struct File: Identifiable {
        let path: String
        let size: Int64
        var id: String { path }
    }
    struct FileType: Identifiable {
        let ext: String
        let count: Int
        let size: Int64
        var id: String { ext }
    }
    struct Candidates: Identifiable {
        let crc: String
        let size: Int64
        let count: Int
        let additionalBytes: Int64
        let files: [File]
        var id: String { "\(crc):\(size)" }
    }
    let fileCount: Int
    let emptyCount: Int
    let totalSize: Int64
    let largest: [File]
    let types: [FileType]
    let candidates: [Candidates]
    let candidateGroupCount: Int
    let candidateAdditionalBytes: Int64

    private struct Key: Hashable { let crc: String; let size: Int64 }

    static func build(_ entries: [ArchiveEntry], cancelled: () -> Bool = { false }) throws -> ArchiveMap {
        var files: [File] = [], empty = 0, total: Int64 = 0
        var types: [String: (count: Int, size: Int64)] = [:]
        var groups: [Key: [File]] = [:]
        func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
            let result = lhs.addingReportingOverflow(rhs)
            guard rhs >= 0, !result.overflow else { throw ArchiveSafetyError(message: P("Arşiv boyut bilgisi geçersiz.", "Invalid archive size metadata.")) }
            return result.partialValue
        }
        for entry in entries {
            if cancelled() { throw CocoaError(.userCancelled) }
            if entry.isDirectory { continue }
            total = try add(total, entry.size)
            if entry.size == 0 { empty += 1 }
            let file = File(path: entry.name, size: entry.size); files.append(file)
            let ext = (entry.name as NSString).pathExtension.lowercased()
            let previous = types[ext] ?? (0, 0)
            types[ext] = (previous.count + 1, try add(previous.size, entry.size))
            let crc = entry.crc.uppercased()
            if entry.size > 0, crc.count == 8, crc.allSatisfy({ "0123456789ABCDEF".contains($0) }) {
                groups[Key(crc: crc, size: entry.size), default: []].append(file)
            }
        }
        func ordered(_ a: File, _ b: File) -> Bool {
            a.size != b.size ? a.size > b.size : a.path < b.path
        }
        let largest = Array(files.sorted(by: ordered).prefix(50))
        let fileTypes = types.map { FileType(ext: $0.key, count: $0.value.count, size: $0.value.size) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.ext < $1.ext }
        var candidates: [Candidates] = [], candidateBytes: Int64 = 0
        for (key, members) in groups where members.count > 1 {
            if cancelled() { throw CocoaError(.userCancelled) }
            let product = key.size.multipliedReportingOverflow(by: Int64(members.count - 1))
            guard !product.overflow else { throw ArchiveSafetyError(message: P("Arşiv boyut bilgisi geçersiz.", "Invalid archive size metadata.")) }
            candidateBytes = try add(candidateBytes, product.partialValue)
            candidates.append(Candidates(crc: key.crc, size: key.size, count: members.count,
                                         additionalBytes: product.partialValue, files: Array(members.sorted(by: ordered).prefix(20))))
        }
        candidates.sort { $0.additionalBytes != $1.additionalBytes ? $0.additionalBytes > $1.additionalBytes : $0.id < $1.id }
        if cancelled() { throw CocoaError(.userCancelled) }
        return ArchiveMap(fileCount: files.count, emptyCount: empty, totalSize: total, largest: largest,
                          types: Array(fileTypes.prefix(50)), candidates: Array(candidates.prefix(50)),
                          candidateGroupCount: candidates.count, candidateAdditionalBytes: candidateBytes)
    }
}

struct ArchiveMapView: View {
    let map: ArchiveMap
    let name: String
    let locate: (String) -> Void
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(P("Arşiv haritası", "Archive map")).font(.title2.weight(.semibold))
                Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 32) {
                statistic(P("Dosya", "Files"), "\(map.fileCount)")
                statistic(P("Açılmış boyut", "Uncompressed size"), Fmt.size(map.totalSize))
                statistic(P("Boş dosya", "Empty files"), "\(map.emptyCount)")
                Spacer(minLength: 0)
            }
            Picker(P("Analiz bölümü", "Analysis section"), selection: $tab) {
                Text(P("Büyük dosyalar", "Largest files")).tag(0)
                Text(P("Dosya türleri", "File types")).tag(1)
                Text(P("Tekrar adayları", "Duplicate candidates")).tag(2)
            }.pickerStyle(.segmented)
            if tab == 0 {
                Text(P("En büyük 50 dosya. Listede bul ile dosyaya geç.", "The 50 largest files. Locate jumps to the file in the archive.")).font(.callout).foregroundStyle(.secondary)
                List(map.largest) { file in fileRow(file) }
                if map.fileCount == 0 { Text(P("Bu arşivde dosya yok.", "This archive contains no files.")).foregroundStyle(.secondary) }
            } else if tab == 1 {
                Text(P("En çok alan kaplayan 50 tür; boyutlar açılmış içerik boyutudur.", "The 50 largest types by uncompressed content size.")).font(.callout).foregroundStyle(.secondary)
                List(map.types) { type in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(type.ext.isEmpty ? P("Uzantısız", "No extension") : "." + type.ext).fontWeight(.medium)
                            Spacer()
                            Text("\(type.count) " + P("dosya", "files")).foregroundStyle(.secondary)
                            Text(Fmt.size(type.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                        ProgressView(value: map.totalSize == 0 ? 0 : Double(type.size) / Double(map.totalSize))
                            .accessibilityLabel((type.ext.isEmpty ? P("Uzantısız", "No extension") : type.ext) + " · " + Fmt.size(type.size))
                    }.padding(.vertical, 6)
                }
            } else {
                Text(P("Aynı boyut ve CRC32, aynı içeriği garanti etmez. Dosyalar otomatik silinmez. CRC’si olmayan ve boş dosyalar karşılaştırmaya alınmaz.", "Matching size and CRC32 do not guarantee identical contents. Files are never deleted automatically. Empty files and files without CRC are excluded.")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("\(map.candidateGroupCount) " + P("aday grubu", "candidate groups") + " · " + Fmt.size(map.candidateAdditionalBytes) + " " + P("ek açılmış boyut", "additional uncompressed bytes")).fontWeight(.medium)
                List {
                    ForEach(map.candidates) { group in
                        Section(header: Text("CRC32 \(group.crc) · \(group.count) " + P("dosya", "files") + " · " + Fmt.size(group.size) + P(" / dosya", " / file"))) {
                            ForEach(group.files) { file in fileRow(file) }
                            if group.count > group.files.count {
                                Text(P("Bu grupta ilk 20 dosya gösteriliyor.", "Showing the first 20 files in this group.")).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if map.candidateGroupCount == 0 { Text(P("Metadata’da tekrar adayı bulunmadı.", "No duplicate candidates found in metadata.")).foregroundStyle(.secondary) }
            }
            Text(P("Arşiv çıkarılmadan hazırlanır. İlk 50 grup/tür gösterilir. Değişikliklerden sonra haritayı yeniden aç.", "Prepared without extraction. Shows the first 50 groups/types. Reopen after archive changes.")).font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 560, minHeight: 440)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private func fileRow(_ file: ArchiveMap.File) -> some View {
        HStack(spacing: 12) {
            Text(file.path).lineLimit(1).truncationMode(.middle).help(file.path).textSelection(.enabled)
            Spacer(minLength: 8)
            Text(Fmt.size(file.size)).monospacedDigit().frame(width: 90, alignment: .trailing)
            Button(P("Listede bul", "Locate")) { locate(file.path) }
                .buttonStyle(.bordered)
                .accessibilityLabel(P("Arşivde bul: ", "Locate in archive: ") + file.path)
        }.padding(.vertical, 5).accessibilityElement(children: .contain)
    }
}
