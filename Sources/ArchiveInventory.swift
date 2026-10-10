import Foundation

/// Exports listing metadata only; no extraction, passwords, watchers or idle work.
enum ArchiveInventory {
    enum Format { case csv, json }
    struct Record: Codable {
        let path: String
        let directory: Bool
        let size: Int64
        let packedSize: Int64
        let modified: String
        let crc: String
        let encrypted: Bool
    }

    static func records(entries: [ArchiveEntry], selection: [String]? = nil,
                        query: ArchiveQuery? = nil, category: FileCategory = .all, matchingPaths: Set<String>? = nil,
                        cancelled: () -> Bool = { false }) throws -> [Record] {
        let selected = selection.map(Set.init)
        var result: [Record] = []
        for entry in entries {
            if cancelled() { throw CocoaError(.userCancelled) }
            let path = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            if let selected {
                var candidate = path
                var included = selected.contains(candidate)
                while !included, let slash = candidate.lastIndex(of: "/") {
                    candidate = String(candidate[..<slash]); included = selected.contains(candidate)
                }
                if !included { continue }
            } else {
                if let matchingPaths, !matchingPaths.contains(path) { continue }
                if !category.matches(entry) { continue }
                if let query, !query.matches(path: path, size: entry.size, modified: entry.mtime,
                                             directory: entry.isDirectory, encrypted: entry.encrypted) { continue }
            }
            result.append(Record(path: entry.name, directory: entry.isDirectory, size: entry.size,
                                 packedSize: entry.packedSize, modified: entry.mtime, crc: entry.crc, encrypted: entry.encrypted))
        }
        return result
    }

    static func data(_ records: [Record], format: Format, cancelled: () -> Bool = { false }) throws -> Data {
        if cancelled() { throw CocoaError(.userCancelled) }
        if format == .json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let output = try encoder.encode(records)
            if cancelled() { throw CocoaError(.userCancelled) }
            return output
        }
        var output = "path,directory,size_bytes,packed_bytes,modified,crc,encrypted\r\n"
        for record in records {
            if cancelled() { throw CocoaError(.userCancelled) }
            let values = [csvField(record.path), record.directory ? "true" : "false", String(record.size),
                          String(record.packedSize), csvField(record.modified), csvField(record.crc), record.encrypted ? "true" : "false"]
            output += values.joined(separator: ",") + "\r\n"
        }
        return Data(output.utf8)
    }

    /// Prevent names from becoming spreadsheet formulas; JSON preserves the exact text.
    private static func csvField(_ value: String) -> String {
        let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func write(_ data: Data, to destination: URL, protecting info: ArchiveInfo,
                      cancelled: () -> Bool = { false }) throws {
        try ArchiveSafety.rejectLinks(in: destination)
        let source = URL(fileURLWithPath: info.path)
        let parts = info.revision?.parts.map { part in
            part.name.isEmpty ? source : source.deletingLastPathComponent().appendingPathComponent(part.name)
        } ?? [source]
        let path = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard !parts.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL.path == path }) else {
            throw ArchiveSafetyError(message: P("Dosya listesi arşivin üzerine kaydedilemez.", "The file list cannot overwrite the archive."))
        }
        if cancelled() { throw CocoaError(.userCancelled) }
        try data.write(to: destination, options: .atomic)
    }
}
