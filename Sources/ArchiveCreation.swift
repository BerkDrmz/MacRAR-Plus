import Foundation

/// Engines may create a whole family of volumes. Keep all of them private until complete.
final class ArchiveCreation {
    let destination: URL
    let staging: URL
    private var preserveStaging = false
    var stagedPath: String { staging.appendingPathComponent(destination.lastPathComponent).path }

    init(path: String) throws {
        destination = URL(fileURLWithPath: path).standardizedFileURL
        try ArchiveSafety.rejectLinks(in: destination)
        try Self.requireAvailable(destination)
        staging = destination.deletingLastPathComponent().appendingPathComponent(".macrarplus-create-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    private static func belongs(_ name: String, to destination: URL) -> Bool {
        let base = NSRegularExpression.escapedPattern(for: destination.lastPathComponent)
        let stem = NSRegularExpression.escapedPattern(for: destination.deletingPathExtension().lastPathComponent)
        let legacy = ["rar", "sfx"].contains(destination.pathExtension.lowercased()) ? "|" + stem + #"\.r\d\d"# : ""
        let pattern = "^(?:" + base + #"(?:\.\d{3,})?|"# + stem + #"\.part\d+\.(?:rar|sfx)"# + legacy + ")$"
        return name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func requireAvailable(_ destination: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
        guard !names.contains(where: { belongs($0, to: destination) }) else {
            throw ArchiveSafetyError(message: P("Bu arşiv adı veya parçalarından biri zaten var. Başka bir ad seçin; mevcut dosyalar korundu.", "This archive name or one of its volumes already exists. Choose another name; existing files were preserved."))
        }
    }

    func outputs() throws -> [URL] {
        try ArchiveSafety.validateStaging(staging)
        let files = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isRegularFileKey])
        guard !files.isEmpty, try files.allSatisfy({ try Self.belongs($0.lastPathComponent, to: destination) && $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }) else {
            throw ArchiveSafetyError(message: P("Arşiv çıktıları doğrulanamadı; mevcut dosyalar korundu.", "Archive outputs could not be verified; existing files were preserved."))
        }
        return files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func firstOutput(_ files: [URL]) throws -> URL {
        if let base = files.first(where: { $0.lastPathComponent == destination.lastPathComponent }) { return base }
        guard let first = files.first, first.lastPathComponent.range(of: #"(?:\.part0*1\.(?:rar|sfx)|\.001)$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            throw ArchiveSafetyError(message: P("Arşivin ilk parçası bulunamadı.", "The first archive volume was not found."))
        }
        return first
    }

    /// No replacement is permitted, including files that appear during the engine operation.
    func publish(_ files: [URL], cancelled: () -> Bool = { false }) throws -> String {
        let fm = FileManager.default, first = try firstOutput(files)
        try Self.requireAvailable(destination)
        var moved: [(source: URL, target: URL, revision: TransferRevision?)] = []
        do {
            for source in files {
                if cancelled() { throw CocoaError(.userCancelled) }
                let target = destination.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent)
                try ArchiveSafety.rejectLinks(in: target)
                let receipt = files.count > 1 ? try TransferRevision.read(source, cancelled: cancelled) : nil
                try fm.moveItem(at: source, to: target)
                moved.append((source, target, receipt))
            }
        } catch {
            var recoveryFailed = false
            for item in moved.reversed() {
                do {
                    guard let receipt = item.revision else { throw CocoaError(.fileReadUnknown) }
                    try receipt.reclaim(item.target, to: item.source)
                }
                catch { recoveryFailed = true }
            }
            if recoveryFailed {
                preserveStaging = true
                throw ArchiveSafetyError(message: P("Hedefteki değişiklikler korundu; kalan arşiv parçaları: ", "Destination changes were preserved; remaining archive volumes: ") + staging.path)
            }
            throw error
        }
        return destination.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent).path
    }

    func cleanUp() { if !preserveStaging { try? FileManager.default.removeItem(at: staging) } }
}
