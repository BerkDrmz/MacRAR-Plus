import Foundation
import CryptoKit

/// Cheap snapshots for detecting changes without watchers or background polling.
struct FileRevision: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    static func read(_ url: URL) throws -> FileRevision {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileRevision(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                            modified: attrs[.modificationDate] as? Date ?? .distantPast,
                            inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

/// Strong checks run only at operation boundaries, in the utility queue.
struct ContentRevision: Equatable {
    let metadata: FileRevision
    let digest: Data

    static func read(_ url: URL, cancelled: () -> Bool = { false }) throws -> ContentRevision {
        try ArchiveSafety.rejectLinks(in: url)
        let before = try FileRevision.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            if cancelled() { throw CocoaError(.userCancelled) }
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        guard try FileRevision.read(url) == before else {
            throw ArchiveSafetyError(message: P("Dosya okuma sırasında değişti. Yeniden deneyin.", "File changed while reading. Try again."))
        }
        return ContentRevision(metadata: before, digest: Data(hash.finalize()))
    }
}

/// Receipts for rollback only. Include descendants so an edit inside a moved folder
/// cannot be mistaken for an untouched output. No watchers or idle hashing are used.
struct TransferRevision: Equatable {
    struct Node: Equatable {
        let inode: UInt64
        let device: UInt64
        let content: ContentRevision?
    }
    let nodes: [String: Node]

    static func read(_ root: URL, cancelled: () -> Bool = { false }) throws -> TransferRevision {
        let fm = FileManager.default
        try ArchiveSafety.rejectLinks(in: root)
        var nodes = [String: Node]()
        func append(_ url: URL, name: String) throws -> Bool {
            if cancelled() { throw CocoaError(.userCancelled) }
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == .typeDirectory || type == .typeRegular else {
                throw ArchiveSafetyError(message: P("Aktarılan dosya değişti; korundu: ", "Transferred item changed; it was preserved: ") + url.path)
            }
            nodes[name] = Node(inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                               device: (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
                               content: type == .typeRegular ? try ContentRevision.read(url, cancelled: cancelled) : nil)
            return type == .typeDirectory
        }
        if try append(root, name: "") {
            var failure: Error?
            guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
            for case let child as URL in iterator {
                _ = try append(child, name: String(child.path.dropFirst(root.path.count + 1)))
            }
            if let failure { throw failure }
        }
        return TransferRevision(nodes: nodes)
    }

    /// Detach without replacing anything, then recheck inside the private folder.
    /// A concurrent replacement must stay at its public path or in recovery.
    func reclaim(_ target: URL, to held: URL) throws {
        let fm = FileManager.default
        guard try Self.read(target) == self else {
            throw ArchiveSafetyError(message: P("Hedef başka bir uygulama tarafından değiştirildi; korundu: ", "Another application changed the destination; it was preserved: ") + target.path)
        }
        try ArchiveSafety.rejectLinks(in: held)
        try fm.moveItem(at: target, to: held)
        do {
            guard try Self.read(held) == self else { throw CocoaError(.fileReadUnknown) }
        } catch {
            // moveItem refuses to overwrite a newer public item. If restoring fails,
            // the caller retains the private recovery folder, including this item.
            try? fm.moveItem(at: held, to: target)
            throw error
        }
    }
}

/// Include every part: changing a later volume must invalidate an old listing too.
struct ArchiveRevision: Equatable {
    struct Part: Equatable { let name: String; let content: ContentRevision }
    let parts: [Part]

    static func read(_ url: URL, cancelled: () -> Bool = { false }) throws -> ArchiveRevision {
        let parent = url.deletingLastPathComponent(), name = url.lastPathComponent
        var pattern: String?
        if let range = name.range(of: #"\.part\d+\.(rar|sfx)$"#, options: [.regularExpression, .caseInsensitive]) {
            pattern = "^" + NSRegularExpression.escapedPattern(for: String(name[..<range.lowerBound])) + #"\.part\d+\.(rar|sfx)$"#
        } else if let range = name.range(of: #"\.\d{3,}$"#, options: .regularExpression) {
            pattern = "^" + NSRegularExpression.escapedPattern(for: String(name[..<range.lowerBound])) + #"\.\d{3,}$"#
        } else if ["rar", "sfx"].contains(url.pathExtension.lowercased()) || url.pathExtension.range(of: #"^r\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let stem = NSRegularExpression.escapedPattern(for: url.deletingPathExtension().lastPathComponent)
            let legacy = "^" + stem + #"\.r\d\d$"#
            if try FileManager.default.contentsOfDirectory(atPath: parent.path).contains(where: { $0.range(of: legacy, options: [.regularExpression, .caseInsensitive]) != nil }) {
                pattern = "^" + stem + #"\.(?:rar|sfx|r\d\d)$"#
            }
        }
        func paths() throws -> [URL] {
            guard let pattern else { return [url] }
            return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let files = try paths()
        guard files.contains(where: { $0.lastPathComponent == name }) else { throw CocoaError(.fileReadNoSuchFile) }
        let parts = try files.map { Part(name: pattern == nil ? "" : $0.lastPathComponent, content: try ContentRevision.read($0, cancelled: cancelled)) }
        guard try paths() == files else { throw ArchiveSafetyError(message: P("Arşiv parçaları okuma sırasında değişti.", "Archive volumes changed while reading.")) }
        return ArchiveRevision(parts: parts)
    }
}
