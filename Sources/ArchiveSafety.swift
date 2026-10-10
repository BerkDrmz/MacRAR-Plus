import Foundation

struct ArchiveSafetyError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The engine writes only into a fresh staging folder. Links are deliberately refused.
enum ArchiveSafety {
    static func relativePath(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
            .filter { $0 != "." }.joined(separator: "/")
    }

    static func validateRARInputs(_ items: [String]) throws {
        guard !items.contains(where: { $0.contains("*") || $0.contains("?") }) else {
            throw ArchiveSafetyError(message: P("RAR motoru * veya ? içeren yolları tam ad olarak seçemiyor. Bu dosyalar için ZIP veya 7z kullanın; hiçbir dosya değiştirilmedi.", "RAR cannot select paths containing * or ? literally. Use ZIP or 7z for these files; no files were changed."))
        }
    }
    static func normalizedSystemPath(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"] where path.hasPrefix("/private" + alias + "/") { return String(path.dropFirst("/private".count)) }
        return path
    }
    static func validateEntries(_ entries: [ArchiveEntry]) throws {
        var total: Int64 = 0, packedTotal: Int64 = 0
        var paths = [String: Bool]()
        for e in entries {
            let path = e.name.replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            let bad = path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") ||
                path.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil ||
                components.contains("..") || components.count > 128 ||
                path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
            guard !bad else { throw ArchiveSafetyError(message: P("Güvenli olmayan arşiv yolu: ", "Unsafe archive path: ") + e.name) }
            guard !relativePath(e.name).isEmpty || e.isDirectory else {
                throw ArchiveSafetyError(message: P("Güvenli olmayan arşiv yolu: ", "Unsafe archive path: ") + e.name)
            }
            guard e.linkTarget == nil, !e.attributes.contains("lrwx"), !e.attributes.hasPrefix("l") else {
                throw ArchiveSafetyError(message: P("Bağlantı içeren arşivler güvenli çıkarma modunda desteklenmiyor: ", "Archives containing links are not supported in safe extraction mode: ") + e.name)
            }
            guard e.size >= 0, e.packedSize >= 0, !total.addingReportingOverflow(e.size).overflow, !packedTotal.addingReportingOverflow(e.packedSize).overflow else {
                throw ArchiveSafetyError(message: P("Arşiv boyutu bilgisi geçersiz.", "The archive contains invalid size metadata."))
            }
            total += e.size
            packedTotal += e.packedSize
            let key = relativePath(e.name).precomposedStringWithCanonicalMapping.lowercased()
            if !key.isEmpty {
                guard paths[key] == nil else { throw ArchiveSafetyError(message: P("Aynı hedefe yazan arşiv yolları var: ", "Archive paths would overwrite the same destination: ") + e.name) }
                paths[key] = e.isDirectory
            }
        }
        for key in paths.keys {
            var parts = key.split(separator: "/")
            while parts.count > 1 {
                parts.removeLast()
                guard paths[parts.joined(separator: "/")] != false else { throw ArchiveSafetyError(message: P("Dosya ve klasör yolları çakışıyor: ", "File and folder paths conflict: ") + key) }
            }
        }
    }

    /// Engines flatten selected root names; detect collisions before they can lose an input.
    @discardableResult
    static func validateInputs(_ items: [String], cancelled: () -> Bool = { false }) throws -> [ArchiveEntry] {
        guard !items.isEmpty else { throw ArchiveSafetyError(message: P("En az bir kaynak seçin.", "Select at least one source.")) }
        let roots = items.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
        let rootPaths = Set(roots.map { $0.path })
        guard rootPaths.count == roots.count, !roots.contains(where: { root in
            var parent = root.deletingLastPathComponent()
            while parent.path != "/" { if rootPaths.contains(parent.path) { return true }; parent.deleteLastPathComponent() }
            return rootPaths.contains("/") && root.path != "/"
        }) else { throw ArchiveSafetyError(message: P("İç içe veya yinelenen kaynak seçimlerini kaldırın.", "Remove nested or duplicate source selections.")) }
        var entries = [ArchiveEntry](), checkedPaths = Set<String>()
        func checkLinks(_ url: URL) throws {
            var current = url
            while current.path != "/", !checkedPaths.contains(current.path) {
                try rejectSingleLink(current); checkedPaths.insert(current.path); current.deleteLastPathComponent()
            }
        }
        func append(_ url: URL, name: String) throws {
            if cancelled() { throw CocoaError(.userCancelled) }
            try checkLinks(url)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isDirectory == true || values.isRegularFile == true else { throw ArchiveSafetyError(message: P("Özel kaynak dosyası desteklenmiyor: ", "Special source files are not supported: ") + url.path) }
            entries.append(ArchiveEntry(name: name, isDirectory: values.isDirectory == true, size: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0)))
        }
        for (index, root) in roots.enumerated() {
            try rejectLinks(in: URL(fileURLWithPath: items[index]).standardizedFileURL)
            try append(root, name: root.lastPathComponent)
            if isDirectoryPath(root.path) {
                var failure: Error?
                guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
                for case let child as URL in iterator {
                    let relative = String(child.path.dropFirst(root.path.count + 1))
                    try append(child, name: root.lastPathComponent + "/" + relative)
                }
                if let failure { throw failure }
            }
        }
        try validateEntries(entries)
        return entries
    }

    static func verifyUnchanged(_ expected: [ArchiveEntry], in actual: [ArchiveEntry]) throws {
        try validateEntries(actual)
        let stored = Dictionary(uniqueKeysWithValues: actual.map { ($0.name, $0) })
        guard expected.allSatisfy({ before in
            guard let after = stored[before.name] else { return false }
            return before.isDirectory == after.isDirectory && before.size == after.size && before.crc == after.crc && before.encrypted == after.encrypted
        }) else { throw ArchiveSafetyError(message: P("Seçilmemiş arşiv içeriği değişti; asıl arşiv korundu.", "Unselected archive contents changed; original archive preserved.")) }
    }

    static func selectedEntries(_ info: ArchiveInfo, names: [String]?) -> [ArchiveEntry] {
        guard let names else { return info.entries }
        return info.entries.filter { entry in names.contains { entry.name == $0 || entry.name.hasPrefix($0 + "/") } }
    }

    static func validateSelection(_ info: ArchiveInfo, names: [String]?) throws {
        guard let names else { return }
        guard !names.isEmpty, names.allSatisfy({ name in
            info.entries.contains { $0.name == name || $0.name.hasPrefix(name + "/") }
        }) else { throw ArchiveSafetyError(message: P("Seçilen yol arşivde bulunamadı. Listeyi yeniden yükleyin.", "The selected path was not found in the archive. Reload the listing.")) }
    }

    static func validateDestination(_ destination: String, entries: [ArchiveEntry], cancelled: () -> Bool = { false }) throws {
        let base = URL(fileURLWithPath: destination).standardizedFileURL
        var checked = Set<String>()
        func check(_ url: URL) throws {
            var current = url
            while current.path != "/", !checked.contains(current.path) {
                try rejectSingleLink(current)
                checked.insert(current.path); current.deleteLastPathComponent()
            }
        }
        try check(base)
        for e in entries {
            if cancelled() { throw CocoaError(.userCancelled) }
            let relative = relativePath(e.name)
            if relative.isEmpty, e.isDirectory { continue }
            let target = base.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(base.path + "/") else {
                throw ArchiveSafetyError(message: P("Hedef klasörün dışına yazma engellendi.", "Writing outside the destination was blocked."))
            }
            try check(target)
        }
        var existing = base
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" { existing.deleteLastPathComponent() }
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: existing.path)
        let available = (attrs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let required = entries.reduce(Int64(0)) { $0 + $1.size }
        guard available >= required && available - required >= min(required, 16 * 1024 * 1024) else {
            throw ArchiveSafetyError(message: P("Hedef diskte yeterli boş alan yok. Gereken: ", "Not enough free space on the destination disk. Required: ") + Fmt.size(required))
        }
    }

    private static func rejectSingleLink(_ url: URL) throws {
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        if let target = systemAliases[url.path], let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path), actual == target || actual == String(target.dropFirst()) { return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ArchiveSafetyError(message: P("Hedefteki sembolik bağlantıya yazma engellendi: ", "Writing through a destination symlink was blocked: ") + url.path)
        }
    }
    static func rejectLinks(in url: URL) throws {
        var current = url
        while current.path != "/" { try rejectSingleLink(current); current.deleteLastPathComponent() }
    }

    static func validateExtracted(_ folder: URL, entries: [ArchiveEntry]) throws {
        try validateEntries(entries)
        try validateStaging(folder)
        let expected = Set(entries.filter { !$0.isDirectory }.map { relativePath($0.name) })
        var actual = Set<String>()
        let canonical = folder.resolvingSymlinksInPath()
        let basePath = normalizedSystemPath(canonical.path)
        var traversalError: Error?
        if let iterator = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { _, error in traversalError = error; return false }) {
            for case let file as URL in iterator where (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
                let filePath = normalizedSystemPath(file.path)
                guard filePath.hasPrefix(basePath + "/") else { throw ArchiveSafetyError(message: P("Geçici dosya yolu doğrulanamadı.", "Could not verify the temporary file path.")) }
                actual.insert(String(filePath.dropFirst(basePath.count + 1)))
            }
        }
        if let traversalError { throw traversalError }
        guard expected == actual else { throw ArchiveSafetyError(message: P("Çıkarılan dosyalar seçilen listeyle eşleşmiyor; hedef korunuyor.", "Extracted files do not match the selection; destination is preserved.")) }
        for entry in entries where !entry.isDirectory {
            let attrs = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(entry.name).path)
            guard (attrs[.size] as? NSNumber)?.int64Value == entry.size else { throw ArchiveSafetyError(message: P("Çıkarılan dosya boyutu eşleşmiyor: ", "Extracted file size mismatch: ") + entry.name) }
        }
    }

    enum Collision { case overwrite, rename, skip, exclusive }

    /// Prepare on the destination volume before replacing anything. Also used by Finder promises.
    static func place(source: URL, destination: URL, collision: Collision = .overwrite) throws {
        let fm = FileManager.default
        try validateStagingItem(source)
        try rejectLinks(in: destination)
        var target = destination
        if fm.fileExists(atPath: target.path) {
            switch collision {
            case .skip: return
            case .rename: target = URL(fileURLWithPath: uniquePath(target.path))
            case .overwrite: break
            case .exclusive: throw CocoaError(.fileWriteFileExists)
            }
        }
        let parent = target.deletingLastPathComponent()
        let scratch = parent.appendingPathComponent(".macrarplus-transfer-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        var preserveScratch = false
        defer { if !preserveScratch { try? fm.removeItem(at: scratch) } }
        let prepared = scratch.appendingPathComponent(source.lastPathComponent)
        let sourceDevice = (try fm.attributesOfItem(atPath: source.path))[.systemNumber] as? NSNumber
        let targetDevice = (try fm.attributesOfItem(atPath: parent.path))[.systemNumber] as? NSNumber
        let moved = sourceDevice == targetDevice
        do {
            if moved { try fm.moveItem(at: source, to: prepared) }
            else { try fm.copyItem(at: source, to: prepared) }
            try rejectLinks(in: target)
            if fm.fileExists(atPath: target.path) {
                guard collision != .exclusive, collision != .rename else { throw CocoaError(.fileWriteFileExists) }
                if collision == .skip {
                    if moved { try fm.moveItem(at: prepared, to: source) }
                    return
                }
                guard !isDirectoryPath(target.path), !isDirectoryPath(prepared.path) else { throw ArchiveSafetyError(message: P("Mevcut klasör bir dosyayla değiştirilemez.", "An existing folder cannot be replaced with a file.")) }
                _ = try fm.replaceItemAt(target, withItemAt: prepared, options: .usingNewMetadataOnly)
            } else { try fm.moveItem(at: prepared, to: target) }
        } catch {
            if moved, fm.fileExists(atPath: prepared.path) {
                do { try fm.moveItem(at: prepared, to: source) }
                catch { preserveScratch = true; throw ArchiveSafetyError(message: P("Aktarılamayan kaynak korunuyor: ", "Untransferred source preserved: ") + prepared.path) }
            }
            throw error
        }
    }
    private static func validateStagingItem(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw ArchiveSafetyError(message: P("Dosya veya klasör doğrulanamadı.", "File or folder could not be validated.")) }
        if values.isDirectory == true { try validateStaging(url) }
    }

    static func validateStaging(_ folder: URL) throws {
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: [], errorHandler: { _, error in traversalError = error; return false }) else {
            throw ArchiveSafetyError(message: P("Geçici klasör okunamadı.", "Could not read the staging folder."))
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw ArchiveSafetyError(message: P("Çıkarılan bağlantı veya özel dosya engellendi: ", "An extracted link or special file was blocked: ") + url.lastPathComponent)
            }
        }
        if let traversalError { throw traversalError }
    }

    /// Merge regular files only after the complete engine operation and validation succeed.
    static func commit(staging: URL, destination: URL, rename: Bool, skip: Bool = false, policies: [String: Collision] = [:], requireCollisionDecision: Bool = false, cancelled: () -> Bool = { false }) throws {
        let fm = FileManager.default
        try validateStaging(staging)
        // Reserve every incoming path before choosing any new name. Otherwise
        // item -> item 2 can be overwritten by the next incoming item 2.
        var reserved = Set<String>()
        func key(_ url: URL) -> String { url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased() }
        func reserve(_ src: URL, _ dest: URL) throws {
            if cancelled() { throw CocoaError(.userCancelled) }
            reserved.insert(key(dest))
            if isDirectoryPath(src.path) {
                for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) {
                    try reserve(child, dest.appendingPathComponent(child.lastPathComponent))
                }
            }
        }
        let children = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        for child in children { try reserve(child, destination.appendingPathComponent(child.lastPathComponent)) }
        var plan: [(source: URL, target: URL, existed: Bool)] = []
        func prepare(_ src: URL, _ dest: URL) throws {
            if cancelled() { throw CocoaError(.userCancelled) }
            try rejectLinks(in: dest)
            let attrs = try fm.attributesOfItem(atPath: src.path)
            let isDir = attrs[.type] as? FileAttributeType == .typeDirectory
            let relative = String(dest.path.dropFirst(destination.path.count + 1))
            let policy = policies[relative] ?? (skip ? .skip : rename ? .rename : .overwrite)
            if policy == .skip, fm.fileExists(atPath: dest.path) { return }
            if isDir, isDirectoryPath(dest.path), policy != .rename {
                for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) { try prepare(child, dest.appendingPathComponent(child.lastPathComponent)) }
            } else {
                if requireCollisionDecision, policy == .overwrite, fm.fileExists(atPath: dest.path), policies[relative] == nil {
                    throw ArchiveSafetyError(message: P("Hedefte işlem sırasında yeni bir dosya oluştu; dosya korundu. Yeniden deneyin.", "A new destination file appeared during processing; it was preserved. Try again."))
                }
                var target = dest
                if policy == .rename, fm.fileExists(atPath: dest.path) {
                    let ext = dest.pathExtension
                    let stem = ext.isEmpty ? dest.lastPathComponent : dest.deletingPathExtension().lastPathComponent
                    var index = 2
                    repeat {
                        target = dest.deletingLastPathComponent().appendingPathComponent(stem + " \(index)" + (ext.isEmpty ? "" : "." + ext))
                        index += 1
                    } while fm.fileExists(atPath: target.path) || reserved.contains(key(target))
                    try reserve(src, target)
                }
                let existed = fm.fileExists(atPath: target.path)
                guard !existed || (!isDir && !isDirectoryPath(target.path)) else { throw ArchiveSafetyError(message: P("Dosya ve klasör hedefleri çakışıyor: ", "File and folder destinations conflict: ") + target.path) }
                plan.append((src, target, existed))
            }
        }
        for child in children { try prepare(child, destination.appendingPathComponent(child.lastPathComponent)) }
        guard !plan.isEmpty else { return }
        let recovery = destination.appendingPathComponent(".macrarplus-rollback-" + UUID().uuidString)
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var preserveRecovery = false
        defer { if !preserveRecovery { try? fm.removeItem(at: recovery) } }
        var backups = [String: (url: URL, revision: ContentRevision)]()
        for (index, item) in plan.enumerated() where item.existed {
            if cancelled() { throw CocoaError(.userCancelled) }
            let backup = recovery.appendingPathComponent(String(index))
            let revision = try ContentRevision.read(item.target, cancelled: cancelled)
            try fm.copyItem(at: item.target, to: backup)
            guard try ContentRevision.read(backup, cancelled: cancelled).digest == revision.digest else {
                throw ArchiveSafetyError(message: P("Hedef yedeklenirken değişti; işlem durduruldu.", "Destination changed while being backed up; the operation stopped."))
            }
            backups[item.target.path] = (backup, revision)
        }
        var completed = [(source: URL, target: URL, existed: Bool, revision: TransferRevision?)]()
        do {
            for item in plan {
                if cancelled() { throw CocoaError(.userCancelled) }
                let receipt = plan.count > 1 ? try TransferRevision.read(item.source, cancelled: cancelled) : nil
                if let backup = backups[item.target.path], try ContentRevision.read(item.target, cancelled: cancelled) != backup.revision {
                    throw ArchiveSafetyError(message: P("Hedef işlem sırasında değişti; dosya korundu: ", "Destination changed during processing; the file was preserved: ") + item.target.path)
                }
                try place(source: item.source, destination: item.target, collision: item.existed ? .overwrite : .exclusive)
                completed.append((item.source, item.target, item.existed, receipt))
            }
        } catch {
            for (index, item) in completed.reversed().enumerated() {
                do {
                    guard let receipt = item.revision else { throw CocoaError(.fileReadUnknown) }
                    let held = recovery.appendingPathComponent("placed-\(index)")
                    try receipt.reclaim(item.target, to: held)
                    if let backup = backups[item.target.path] {
                        try rejectLinks(in: item.target)
                        try fm.moveItem(at: backup.url, to: item.target)
                    } else { try fm.moveItem(at: held, to: item.source) }
                } catch { preserveRecovery = true }
            }
            if preserveRecovery {
                let mapping = plan.enumerated().map { index, item in
                    "\(index): \(item.target.path)"
                }.joined(separator: "\n")
                try? (P("Numaralı dosyalar işlem öncesindeki hedef kopyalarıdır. placed-* dosyaları geri alınan çıktılardır.\n", "Numbered files are copies of the destinations before processing. placed-* files are reclaimed outputs.\n") + mapping + "\n").write(to: recovery.appendingPathComponent("Recovery.txt"), atomically: true, encoding: .utf8)
                throw ArchiveSafetyError(message: P("İşlem tamamlanamadı; kurtarma kopyaları: ", "Operation could not complete; recovery copies: ") + recovery.path)
            }
            throw error
        }
    }
}
