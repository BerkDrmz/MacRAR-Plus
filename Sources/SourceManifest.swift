import Foundation
import CryptoKit

/// A manifest is only collected for the explicitly destructive source-to-Trash option.
struct SourceManifest {
    struct File: Equatable { let size: Int64; let modified: Date; let inode: UInt64; let digest: Data }
    let files: [String: File]
    let archiveSizes: [String: Int64]
    let archiveDigests: [String: Data]
    let directories: Set<String>

    static func collect(_ items: [String], cancelled: () -> Bool = { false }) throws -> SourceManifest {
        let fm = FileManager.default
        let roots = items.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let rootPaths = Set(roots)
        guard rootPaths.count == roots.count, !roots.contains(where: { path in
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path != "/" { if rootPaths.contains(parent.path) { return true }; parent.deleteLastPathComponent() }
            return rootPaths.contains("/") && path != "/"
        }) else {
            throw ArchiveSafetyError(message: P("Kaynak temizliği için iç içe veya yinelenen seçimleri kaldırın.", "Remove nested or duplicate selections before source cleanup."))
        }
        var files: [String: File] = [:], expected: [String: Int64] = [:]
        var digests: [String: Data] = [:]
        var directories = Set<String>()
        func add(_ url: URL, name: String) throws {
            if cancelled() { throw CocoaError(.userCancelled) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isSymbolicLink != true else { throw ArchiveSafetyError(message: P("Bağlantı içeren kaynaklar otomatik silinemez.", "Sources containing links cannot be deleted automatically.")) }
            if values.isDirectory == true { directories.insert(name); return }
            guard values.isRegularFile == true else { throw ArchiveSafetyError(message: P("Özel kaynak dosyaları otomatik silinemez.", "Special source files cannot be deleted automatically.")) }
            guard expected[name] == nil else { throw ArchiveSafetyError(message: P("Kaynaklarda aynı arşiv yolu var: ", "Sources have the same archive path: ") + name) }
            let revision = try FileRevision.read(url)
            let digest = try Self.digest(url, cancelled: cancelled)
            guard try FileRevision.read(url) == revision else { throw changedError() }
            let file = File(size: Int64(values.fileSize ?? 0), modified: revision.modified, inode: revision.inode, digest: digest)
            files[ArchiveSafety.normalizedSystemPath(url.path)] = file; expected[name] = file.size
            digests[name] = digest
        }
        for item in items {
            let requested = URL(fileURLWithPath: item).standardizedFileURL
            guard try requested.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ArchiveSafetyError(message: P("Kaynak bağlantılar otomatik silinemez.", "Source links cannot be deleted automatically."))
            }
            let source = requested.resolvingSymlinksInPath()
            if isDirectoryPath(source.path) {
                try add(source, name: source.lastPathComponent)
                var traversalError: Error?
                guard let iterator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in traversalError = error; return false }) else {
                    throw ArchiveSafetyError(message: P("Kaynak klasör okunamadı.", "Could not read the source folder."))
                }
                for case let child as URL in iterator {
                    let relative = String(ArchiveSafety.normalizedSystemPath(child.path).dropFirst(ArchiveSafety.normalizedSystemPath(source.path).count + 1))
                    try add(child, name: source.lastPathComponent + "/" + relative)
                }
                if let error = traversalError { throw error }
            } else { try add(source, name: source.lastPathComponent) }
        }
        return SourceManifest(files: files, archiveSizes: expected, archiveDigests: digests, directories: directories)
    }

    func verify(items: [String], archive: ArchiveInfo, cancelled: () -> Bool = { false }) throws {
        let current = try Self.collect(items, cancelled: cancelled)
        guard current.files == files, current.directories == directories else {
            throw ArchiveSafetyError(message: P("Sıkıştırma sırasında kaynaklar değişti; kaynaklar korunuyor.", "Sources changed during compression; source files are preserved."))
        }
        let stored = Dictionary(archive.entries.filter { !$0.isDirectory }.map { (ArchiveSafety.relativePath($0.name), $0.size) }, uniquingKeysWith: { _, newest in newest })
        let storedDirectories = Set(archive.entries.filter { $0.isDirectory }.map { ArchiveSafety.relativePath($0.name) })
        guard archiveSizes.allSatisfy({ stored[$0.key] == $0.value }), directories.isSubset(of: storedDirectories) else {
            throw ArchiveSafetyError(message: P("Bazı kaynaklar arşive eksiksiz girmedi; kaynaklar korunuyor.", "Some sources were not completely archived; source files are preserved."))
        }
    }

    private static func changedError() -> ArchiveSafetyError {
        ArchiveSafetyError(message: P("Kaynak içeriği değişti; kaynaklar korunuyor.", "Source content changed; source files are preserved."))
    }

    private static func digest(_ url: URL, cancelled: () -> Bool) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            if cancelled() { throw CocoaError(.userCancelled) }
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return Data(hash.finalize())
    }

    /// Check actual archived bytes, including formats without stored checksums.
    func verifyArchiveContents(_ archive: ArchiveInfo, password: String?, cancellation: TaskCancellation? = nil, cancelled: () -> Bool = { false }) throws {
        guard let revision = archive.revision, try ArchiveRevision.read(URL(fileURLWithPath: archive.path), cancelled: cancelled) == revision else { throw Self.changedError() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-source-check-\(UUID().uuidString)")
        try ArchiveSafety.validateEntries(archive.entries)
        try ArchiveSafety.validateDestination(folder.path, entries: archive.entries, cancelled: cancelled)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        if cancelled() { throw CocoaError(.userCancelled) }
        let result = RarRunner.runStages(Ops.extractStages(info: archive, names: nil, dest: folder.path, password: password, mode: .overwrite), cancellation: cancellation)
        if result.cancelled { throw CocoaError(.userCancelled) }
        guard result.ok else { throw ArchiveSafetyError(message: result.errorSummary) }
        try ArchiveSafety.validateExtracted(folder, entries: archive.entries)
        for (name, expected) in archiveDigests {
            guard try Self.digest(folder.appendingPathComponent(name), cancelled: cancelled) == expected else { throw Self.changedError() }
        }
        guard try ArchiveRevision.read(URL(fileURLWithPath: archive.path), cancelled: cancelled) == revision else { throw Self.changedError() }
    }

    /// First detach each source by a same-volume rename. Revalidate the detached
    /// bytes before Trash; a new file appearing at the old path is never touched.
    func moveVerifiedToTrash(items: [String], archive: ArchiveInfo, cancelled: () -> Bool = { false },
                             trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        try verify(items: items, archive: archive, cancelled: cancelled)
        let fm = FileManager.default
        for item in items {
            if cancelled() { throw CocoaError(.userCancelled) }
            if let revision = archive.revision {
                guard try ArchiveRevision.read(URL(fileURLWithPath: archive.path), cancelled: cancelled) == revision else { throw Self.changedError() }
            }
            let original = URL(fileURLWithPath: item).standardizedFileURL.resolvingSymlinksInPath()
            let scratch = original.deletingLastPathComponent().appendingPathComponent(".macrarplus-source-\(UUID().uuidString)")
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            let held = scratch.appendingPathComponent(original.lastPathComponent)
            defer {
                if (try? fm.contentsOfDirectory(atPath: scratch.path).isEmpty) == true { try? fm.removeItem(at: scratch) }
            }
            do {
                try fm.moveItem(at: original, to: held)
                let current = try Self.collect([held.path], cancelled: cancelled)
                let prefix = ArchiveSafety.normalizedSystemPath(original.path)
                let heldPrefix = ArchiveSafety.normalizedSystemPath(held.path)
                let relocated = Dictionary(uniqueKeysWithValues: current.files.map { (prefix + String($0.key.dropFirst(heldPrefix.count)), $0.value) })
                let expected = files.filter { $0.key == prefix || $0.key.hasPrefix(prefix + "/") }
                let top = original.lastPathComponent
                let expectedDirectories = directories.filter { $0 == top || $0.hasPrefix(top + "/") }
                guard relocated == expected, current.directories == expectedDirectories else { throw Self.changedError() }
                if cancelled() { throw CocoaError(.userCancelled) }
                try trash(held)
            } catch {
                if fm.fileExists(atPath: held.path) {
                    do {
                        let recovery = fm.fileExists(atPath: original.path) ? URL(fileURLWithPath: uniquePath(original.path)) : original
                        try fm.moveItem(at: held, to: recovery)
                    } catch {
                        throw ArchiveSafetyError(message: P("Kaynak korunuyor; kurtarma yolu: ", "Source preserved; recovery path: ") + held.path)
                    }
                }
                throw error
            }
        }
    }
}
