import SwiftUI
import AppKit

struct ActivityRecord: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    let title: String
    let archive: String
    let destination: String?
    let success: Bool
    var detail: String? = nil
    var cancelled: Bool? = nil
}

final class ArchiveLibrary: ObservableObject {
    static let shared = ArchiveLibrary()
    @Published private(set) var recent: [String] = []
    @Published private(set) var activity: [ActivityRecord] = []
    private let defaults = UserDefaults.standard
    init() {
        recent = defaults.stringArray(forKey: "plus.recent") ?? []
        if let data = defaults.data(forKey: "plus.activity"), let saved = try? JSONDecoder().decode([ActivityRecord].self, from: data) { activity = saved }
    }
    func opened(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(12))
        defaults.set(recent, forKey: "plus.recent")
    }
    func record(_ title: String, archive: String, destination: String? = nil, success: Bool, detail: String? = nil, cancelled: Bool = false) {
        activity.insert(ActivityRecord(title: title, archive: archive, destination: destination, success: success, detail: detail, cancelled: cancelled), at: 0)
        activity = Array(activity.prefix(100))
        if let data = try? JSONEncoder().encode(activity) { defaults.set(data, forKey: "plus.activity") }
    }
    func clear() { activity = []; defaults.removeObject(forKey: "plus.activity") }
}

struct ActivityView: View {
    @ObservedObject var library = ArchiveLibrary.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(P("İşlem geçmişi", "Activity history")).font(.title2.weight(.semibold))
                    Text(P("Son 100 işlem bu Mac’te saklanır.", "The last 100 operations are stored on this Mac.")).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(P("Temizle", "Clear")) { library.clear() }.disabled(library.activity.isEmpty)
            }.padding(24)
            Divider()
            if library.activity.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(P("Henüz işlem yapılmadı", "No operations yet")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(library.activity) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(record.success ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text((record.cancelled == true ? P("İptal · ", "Cancelled · ") : "") + record.title).font(.system(size: 12, weight: .semibold))
                            if let detail = record.detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled) }
                            Text((record.archive as NSString).lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack(spacing: 3) { Text(record.date, style: .date); Text("·"); Text(record.date, style: .time) }.font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let dest = record.destination, record.success {
                            Button(P("Finder’da göster", "Show in Finder")) { Ops.revealInFinder(dest) }
                        }
                    }.padding(.vertical, 7)
                }
            }
        }.frame(minWidth: 560, minHeight: 360)
    }
}
