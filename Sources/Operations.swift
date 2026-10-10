import AppKit

/// Tüm arşiv işlemleri: hem pencereden hem de Finder hızlı eylemlerinden kullanılır.
enum Ops {

    /// Repack only selected entries. Sparse parent folders preserve archive paths.
    static func compressSelection(info: ArchiveInfo, names: [String], options: CompressOptions,
                                  password: String?, host: NSWindow?, completion: @escaping (Bool, String?, String?) -> Void) {
        var chosen = options
        chosen.deleteAfter = false // The source archive is never modified.
        if chosen.sfx { chosen.archivePath = (chosen.archivePath as NSString).deletingPathExtension + ".sfx" }
        let options = chosen
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-selection-" + UUID().uuidString)
        let finish: (Bool, String?, String?) -> Void = { ok, path, pw in
            try? FileManager.default.removeItem(at: temporary)
            completion(ok, path, pw)
        }
        TaskCenter.shared.work(title: P("Seçim hazırlanıyor", "Preparing selection"), host: host, body: { token in
            try token.check()
            try options.validatePassword()
            guard !names.isEmpty else { throw ArchiveSafetyError(message: P("Önce dosya seçin.", "Select files first.")) }
            try ArchiveSafety.validateSelection(info, names: names)
            let destination = URL(fileURLWithPath: options.archivePath).standardizedFileURL
            try ArchiveSafety.rejectLinks(in: destination)
            try ArchiveCreation.requireAvailable(destination)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }) { result in
            guard case .success = result else {
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    Dialogs.error(L("Sıkıştırma başarısız"), error.localizedDescription)
                }
                finish(false, nil, password); return
            }
            extract(info: info, names: names, dest: temporary.path, password: password, host: host, quiet: true) { ok, pw in
                guard ok else { finish(false, nil, pw); return }
                TaskCenter.shared.work(title: P("Seçilen dosyalar kontrol ediliyor", "Checking selected files"), host: host, body: { token -> [String] in
                    try token.check()
                    let items = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil).map(\.path).sorted()
                    guard !items.isEmpty else { throw ArchiveSafetyError(message: P("Seçim çıkartılamadı.", "Selection could not be extracted.")) }
                    try ArchiveSafety.validateInputs(items, cancelled: { token.cancelled })
                    if options.format == .rar5 { try ArchiveSafety.validateRARInputs(items) }
                    return items
                }) { prepared in
                    guard case .success(let items) = prepared else {
                        if case .failure(let error) = prepared, (error as? CocoaError)?.code != .userCancelled { Dialogs.error(L("Sıkıştırma başarısız"), error.localizedDescription) }
                        finish(false, nil, pw); return
                    }
                    // Require a fresh destination again at publication; never merge into an existing archive.
                    startCompression(items: items, options: options, manifest: nil, host: host) { ok, path in
                        finish(ok, ok ? path : nil, pw)
                    }
                }
            }
        }
    }

    // MARK: Ortak iş çalıştırıcı (ilerleme penceresiyle)

    static func runJob(title: String, stages: [Stage], cwd: String? = nil,
                       host: NSWindow?, totalFiles: Int?, stripPrefix: String? = nil,
                       completion: @escaping (RarResult) -> Void) {
        let panel = ProgressPanel(title: title)
        panel.stripPrefix = stripPrefix
        let job = RarJob()
        let taskID = TaskCenter.shared.begin { job.cancel() }
        var sawPercent = false
        var fileIndex = 0
        var lastName = ""
        job.onEvent = { ev in
            switch ev {
            case .file(let name):
                panel.setFile(name)
                if name != lastName {
                    lastName = name
                    fileIndex += 1
                    // Yüzde bilgisi gelmeyen boru hattı işlemlerinde dosya sayısına göre ilerle
                    if !sawPercent, let total = totalFiles, total > 0 {
                        panel.setFraction(Double(min(fileIndex, total)) / Double(total))
                    }
                }
            case .progress(let pct):
                // rar/unrar/7zz yüzdesi arşivin toplam ilerlemesidir
                sawPercent = true
                panel.setFraction(Double(pct) / 100.0)
            }
        }
        panel.onCancel = { job.cancel() }
        panel.show(on: host)
        job.start(stages: stages, cwd: cwd) { result in
            panel.onCancel = nil
            job.onEvent = nil
            panel.dismiss()
            TaskCenter.shared.finish(taskID)
            completion(result)
        }
    }

    static func runJob(title: String, tool: RarTool, args: [String], cwd: String? = nil,
                       host: NSWindow?, totalFiles: Int?, stripPrefix: String? = nil,
                       completion: @escaping (RarResult) -> Void) {
        runJob(title: title, stages: [(tool, args)], cwd: cwd, host: host, totalFiles: totalFiles, stripPrefix: stripPrefix, completion: completion)
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: Listeleme (şifre döngüsüyle)

    /// Arşivi listeler; gerekirse şifre sorar. İptalde nil döner.
    static func listInteractive(archive: String, password: inout String?) -> ArchiveInfo? {
        var wrong = false
        while true {
            switch RarRunner.list(archive, password: password) {
            case .ok(var info):
                do { try ArchiveSafety.validateEntries(info.entries) } catch { Dialogs.error(P("Arşiv güvenlik kontrolü", "Archive safety check"), error.localizedDescription); return nil }
                if wrong { info.headersEncrypted = true }   // şifre olmadan listelenemedi
                return info
            case .wrongPassword:
                guard let pw = Dialogs.askPassword(archiveName: name(archive), wrong: wrong) else { return nil }
                password = pw
                wrong = true
            case .error(let r):
                if r.notArchive {
                    Dialogs.error(L("Arşiv açılamadı"), LF("\"%@\" desteklenen bir arşiv değil.", name(archive)))
                } else {
                    Dialogs.error(L("Arşiv açılamadı"), r.errorSummary)
                }
                return nil
            }
        }
    }

    /// List in the background; password prompts and all UI updates remain on the main queue.
    @discardableResult
    static func listAsync(archive: String, password: String?, triedPassword: Bool = false,
                          cancellation: TaskCancellation = TaskCancellation(),
                          completion: @escaping (ArchiveInfo?, String?) -> Void) -> TaskCancellation {
        // Open through the application first so macOS file-access consent is
        // attributed to the app, before its bundled engine touches the archive.
        let accessID = TaskCenter.shared.begin { cancellation.cancel() }
        DispatchQueue.global(qos: .utility).async {
            let access = Result { () throws -> ArchiveRevision in
                try cancellation.check()
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: archive))
                defer { try? handle.close() }
                _ = try handle.read(upToCount: 1)
                try cancellation.check()
                return try ArchiveRevision.read(URL(fileURLWithPath: archive), cancelled: { cancellation.cancelled })
            }
            DispatchQueue.main.async {
                switch access {
                case .success(let revision):
                    listAccessibleAsync(archive: archive, password: password, triedPassword: triedPassword, revision: revision, cancellation: cancellation, completion: completion)
                case .failure(let error):
                    ArchiveLibrary.shared.record(P("Arşiv okuma", "Archive listing"), archive: archive, success: false, detail: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)
                    if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(L("Arşiv açılamadı"), error.localizedDescription) }
                    completion(nil, password)
                }
                TaskCenter.shared.finish(accessID)
            }
        }
        return cancellation
    }

    @discardableResult
    private static func listAccessibleAsync(archive: String, password: String?, triedPassword: Bool,
                                           revision: ArchiveRevision,
                                           cancellation: TaskCancellation,
                                           completion: @escaping (ArchiveInfo?, String?) -> Void) -> TaskCancellation {
        let job = RarJob(); job.capturesListing = true
        cancellation.onCancel { job.cancel() }
        let taskID = TaskCenter.shared.begin { cancellation.cancel() }
        job.start(stages: RarRunner.listStages(archive, password: password)) { result in
            cancellation.clearHandler()
            guard !cancellation.cancelled, !result.cancelled else {
                TaskCenter.shared.finish(taskID)
                ArchiveLibrary.shared.record(P("Arşiv okuma", "Archive listing"), archive: archive, success: false, detail: P("Okuma iptal edildi.", "Listing cancelled."), cancelled: true)
                completion(nil, password); return
            }
            if result.wrongPassword {
                TaskCenter.shared.finish(taskID)
                guard let pw = Dialogs.askPassword(archiveName: name(archive), wrong: triedPassword) else {
                    cancellation.cancel()
                    ArchiveLibrary.shared.record(P("Arşiv okuma", "Archive listing"), archive: archive, success: false, detail: P("Şifre girişi iptal edildi.", "Password entry cancelled."), cancelled: true)
                    completion(nil, password); return
                }
                listAsync(archive: archive, password: pw, triedPassword: true, cancellation: cancellation, completion: completion)
                return
            }
            guard result.ok else {
                TaskCenter.shared.finish(taskID)
                ArchiveLibrary.shared.record(P("Arşiv okuma", "Archive listing"), archive: archive, success: false, detail: result.errorSummary)
                Dialogs.error(L("Arşiv açılamadı"), result.errorSummary); completion(nil, password); return
            }
            DispatchQueue.global(qos: .utility).async {
                let parsed = Result { () throws -> ArchiveInfo in
                    try cancellation.check()
                    var info = Formats.kind(of: archive) == .rar ? RarRunner.parseRarListing(result.output, path: archive) : RarRunner.parse7zListing(result.output, path: archive)
                    guard try ArchiveRevision.read(URL(fileURLWithPath: archive), cancelled: { cancellation.cancelled }) == revision else {
                        throw ArchiveSafetyError(message: P("Arşiv okuma sırasında değişti; listeyi yeniden yükleyin.", "Archive changed while listing; reload it."))
                    }
                    info.revision = revision
                    try ArchiveSafety.validateEntries(info.entries)
                    try cancellation.check()
                    if triedPassword { info.headersEncrypted = true }
                    return info
                }
                DispatchQueue.main.async {
                    TaskCenter.shared.finish(taskID)
                    guard !cancellation.cancelled else { completion(nil, password); return }
                    switch parsed {
                    case .success(let info): completion(info, password)
                    case .failure(let error): Dialogs.error(P("Arşiv güvenlik kontrolü", "Archive safety check"), error.localizedDescription); completion(nil, password)
                    }
                }
            }
        }
        return cancellation
    }

    // MARK: Çıkartma

    /// Çıkartılacak öğeler arasında şifreli olan var mı? (names nil → tüm arşiv)
    static func needsPassword(info: ArchiveInfo, names: [String]?) -> Bool {
        if info.headersEncrypted { return true }
        guard let names else { return info.hasEncryptedFiles }
        return info.entries.contains { e in
            e.encrypted && names.contains { n in e.name == n || e.name.hasPrefix(n + "/") }
        }
    }

    enum OverwriteArg { case overwrite, rename, skip }

    static func extractStages(info: ArchiveInfo, names: [String]?, dest: String, password: String?, mode: OverwriteArg) -> [Stage] {
        let destSlash = dest.hasSuffix("/") ? dest : dest + "/"
        switch info.kind {
        case .rar:
            if info.entries.isEmpty {
                return [(.sevenZip, ["x", "-spd", "-y", "-o" + dest] + RarRunner.passwordArgs7z(password) + ["--", info.path])]
            }
            var args = ["x", "-y", mode == .overwrite ? "-o+" : "-or"] + RarRunner.passwordArgs(password) + ["--", info.path]
            if let names { args += names }
            args.append(destSlash)
            return [(.unrar, args)]
        case .other:
            let ow = mode == .overwrite ? "-aoa" : "-aou"
            if info.tarCompressed {
                var inner = ["x", "-spd", "-si", "-ttar", "-y", "-bb1", ow, "-o" + dest]
                if let names { inner += ["--"] + names }
                return [(.sevenZip, ["x", "-so"] + RarRunner.passwordArgs7z(password) + ["--", info.path]),
                        (.sevenZip, inner)]
            }
            var args = ["x", "-spd", "-y", "-bsp1", "-bb1", ow] + RarRunner.passwordArgs7z(password) + ["-o" + dest, "--", info.path]
            if let names { args += names }
            return [(.sevenZip, args)]
        }
    }

    /// names: nil ise tüm arşiv. completion(success, kullanılan şifre)
    static func extract(info: ArchiveInfo, names: [String]?, dest: String, password: String?,
                        host: NSWindow?, quiet: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        let lockKey = URL(fileURLWithPath: dest).standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        guard !extractionLocks.contains(where: { $0 == lockKey || $0.hasPrefix(lockKey + "/") || lockKey.hasPrefix($0 + "/") }) else {
            Dialogs.error(P("Hedef kullanımda", "Destination in use"), P("Bu hedefe başka bir çıkarma işlemi sürüyor.", "Another extraction is using this destination.")); completion(false, password); return
        }
        extractionLocks.insert(lockKey)
        let finished = completion
        let completion: (Bool, String?) -> Void = { ok, pw in extractionLocks.remove(lockKey); finished(ok, pw) }
        TaskCenter.shared.work(title: P("Hedef kontrol ediliyor", "Checking destination"), host: host, body: { token in
            if let revision = info.revision {
                guard try ArchiveRevision.read(URL(fileURLWithPath: info.path), cancelled: { token.cancelled }) == revision else { throw ArchiveSafetyError(message: P("Arşiv değişti. Listeyi yeniden yükleyin.", "Archive changed. Reload the listing.")) }
            }
            try ArchiveSafety.validateEntries(info.entries)
            try ArchiveSafety.validateSelection(info, names: names)
            let entries = ArchiveSafety.selectedEntries(info, names: names)
            try ArchiveSafety.validateDestination(dest, entries: entries, cancelled: { token.cancelled })
            return try ArchiveCollision.find(entries: entries, destination: dest)
        }) { result in
            switch result {
            case .failure(let error):
                ArchiveLibrary.shared.record(P("Çıkarma", "Extraction"), archive: info.path, success: false, detail: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)
                if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(P("Çıkarma engellendi", "Extraction blocked"), error.localizedDescription) }
                completion(false, password)
            case .success(let collisions):
                guard let policies = CollisionDialog.run(collisions) else {
                    ArchiveLibrary.shared.record(P("Çıkarma", "Extraction"), archive: info.path, success: false, detail: P("Çakışma kararı iptal edildi.", "Collision decision cancelled."), cancelled: true)
                    completion(false, password); return
                }
                extractAfterPreflight(info: info, names: names, dest: dest, password: password, host: host, quiet: quiet, policies: policies, completion: completion)
            }
        }
    }

    private static func extractAfterPreflight(info: ArchiveInfo, names: [String]?, dest: String, password: String?, host: NSWindow?, quiet: Bool, policies: [String: ArchiveSafety.Collision], completion: @escaping (Bool, String?) -> Void) {
        var pw = password
        if needsPassword(info: info, names: names), pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        let count = names == nil ? info.entries.count : nil
        runExtract(info: info, names: names, dest: dest, password: pw, mode: .overwrite, host: host, count: count, quiet: quiet, policies: policies, completion: completion)
    }

    private static func runExtract(info: ArchiveInfo, names: [String]?, dest: String, password: String?, mode: OverwriteArg,
                                   host: NSWindow?, count: Int?, quiet: Bool, policies: [String: ArchiveSafety.Collision] = [:], completion: @escaping (Bool, String?) -> Void) {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: dest)
        let staging = destination.appendingPathComponent(".macrarplus-stage-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { Dialogs.error(L("Çıkartma başarısız"), error.localizedDescription); completion(false, password); return }
        let stages = extractStages(info: info, names: names, dest: staging.path, password: password, mode: .overwrite)
        runJob(title: LF("Çıkartılıyor: %@", name(info.path)), stages: stages, host: host, totalFiles: count, stripPrefix: staging.path) { r in
            if r.cancelled {
                try? fm.removeItem(at: staging)
                ArchiveLibrary.shared.record(P("Çıkarma", "Extraction"), archive: info.path, success: false, detail: P("İşlem iptal edildi.", "Operation cancelled."), cancelled: true)
                completion(false, password); return
            }
            if r.wrongPassword {
                try? fm.removeItem(at: staging)
                guard let pw = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, password); return }
                runExtract(info: info, names: names, dest: dest, password: pw, mode: mode, host: host, count: count, quiet: quiet, policies: policies, completion: completion)
                return
            }
            guard r.ok else {
                try? fm.removeItem(at: staging)
                ArchiveLibrary.shared.record(P("Çıkarma başarısız", "Extraction failed"), archive: info.path, success: false, detail: r.errorSummary)
                Dialogs.error(L("Çıkartma başarısız"), r.errorSummary); completion(false, password); return
            }
            // File validation and moving may be expensive; keep it away from the UI thread.
            TaskCenter.shared.work(title: P("Dosyalar hedefe aktarılıyor", "Transferring files"), host: host, commitsChanges: true, body: { token in
                defer { try? fm.removeItem(at: staging) }
                if let revision = info.revision {
                    guard try ArchiveRevision.read(URL(fileURLWithPath: info.path), cancelled: { token.cancelled }) == revision else { throw ArchiveSafetyError(message: P("Arşiv çıkarma sırasında değişti; hedef korundu.", "Archive changed during extraction; destination preserved.")) }
                }
                try ArchiveSafety.validateExtracted(staging, entries: ArchiveSafety.selectedEntries(info, names: names))
                let canonicalPolicies = Dictionary(policies.map { (ArchiveSafety.relativePath($0.key), $0.value) }, uniquingKeysWith: { _, last in last })
                try ArchiveSafety.commit(staging: staging, destination: destination, rename: mode == .rename, skip: mode == .skip, policies: canonicalPolicies, requireCollisionDecision: true, cancelled: { token.cancelled })
            }) { result in
                switch result {
                case .success:
                    ArchiveLibrary.shared.record(P("Dosyalar çıkarıldı", "Files extracted"), archive: info.path, destination: dest, success: true)
                    completion(true, password)
                case .failure(let error):
                    try? fm.removeItem(at: staging)
                    ArchiveLibrary.shared.record(P("Çıkarma başarısız", "Extraction failed"), archive: info.path, success: false, detail: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)
                    if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(L("Çıkartma başarısız"), error.localizedDescription) }
                    completion(false, password)
                }
            }
        }
    }

    // MARK: Test

    static func test(info: ArchiveInfo, password: String?, host: NSWindow?, quiet: Bool = false, completion: @escaping (Bool, String?) -> Void) {
        var pw = password
        if info.hasEncryptedFiles, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        runTest(info: info, password: pw, host: host, quiet: quiet, completion: completion)
    }

    private static func runTest(info: ArchiveInfo, password: String?, host: NSWindow?, quiet: Bool, completion: @escaping (Bool, String?) -> Void) {
        let stages: [Stage]
        switch info.kind {
        case .rar:
            stages = info.entries.isEmpty
                ? [(.sevenZip, ["t", "-y"] + RarRunner.passwordArgs7z(password) + ["--", info.path])]
                : [(.unrar, ["t", "-y"] + RarRunner.passwordArgs(password) + ["--", info.path])]
        case .other:
            if info.tarCompressed {
                stages = [(.sevenZip, ["x", "-so"] + RarRunner.passwordArgs7z(password) + ["--", info.path]),
                          (.sevenZip, ["t", "-si", "-ttar", "-bb1"])]
            } else {
                stages = [(.sevenZip, ["t", "-bsp1", "-bb1"] + RarRunner.passwordArgs7z(password) + ["--", info.path])]
            }
        }
        runJob(title: LF("Test ediliyor: %@", name(info.path)), stages: stages, host: host, totalFiles: info.entries.count) { r in
            if r.cancelled {
                ArchiveLibrary.shared.record(P("Bütünlük testi", "Integrity test"), archive: info.path, success: false, detail: P("İşlem iptal edildi.", "Operation cancelled."), cancelled: true)
                completion(false, password); return
            }
            if r.wrongPassword {
                guard let pw = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, password); return }
                runTest(info: info, password: pw, host: host, quiet: quiet, completion: completion)
                return
            }
            ArchiveLibrary.shared.record(P("Bütünlük testi", "Integrity test"), archive: info.path, success: r.ok, detail: r.ok ? nil : r.errorSummary)
            if r.ok {
                if !quiet { Dialogs.info(L("Test başarılı"), LF("\"%@\" arşivinde hata bulunmadı.", name(info.path))) }
            } else {
                Dialogs.error(L("Test başarısız"), r.errorSummary)
            }
            completion(r.ok, password)
        }
    }

    // MARK: Sıkıştırma

    static func compress(items: [String], options: CompressOptions, host: NSWindow?, completion: @escaping (Bool, String) -> Void) {
        do { try options.validatePassword() }
        catch { Dialogs.error(P("Şifre bu biçime uygun değil", "Password is not supported"), error.localizedDescription); completion(false, options.archivePath); return }
        if options.format == .rar5 {
            do { try ArchiveSafety.validateRARInputs(items) }
            catch { Dialogs.error(P("Dosyalar korunuyor", "Files protected"), error.localizedDescription); completion(false, options.archivePath); return }
        }
        var normalized = options
        if normalized.sfx { normalized.archivePath = (normalized.archivePath as NSString).deletingPathExtension + ".sfx" }
        let fixed = normalized
        if FileManager.default.fileExists(atPath: fixed.archivePath), fixed.format.supportsAppend, !fixed.sfx {
            TaskCenter.shared.work(title: P("Mevcut arşiv kontrol ediliyor", "Checking existing archive"), host: host, body: { token in
                let listing = RarRunner.list(fixed.archivePath, password: nil)
                try token.check()
                switch listing { case .ok(let info): return info.hasEncryptedFiles; case .wrongPassword: return true; case .error: return false }
            }) { result in
                guard case .success(let encrypted) = result else { completion(false, fixed.archivePath); return }
                compressPrepared(items: items, options: fixed, existingEncrypted: encrypted, host: host, completion: completion)
            }
        } else { compressPrepared(items: items, options: fixed, existingEncrypted: false, host: host, completion: completion) }
    }

    private static func compressPrepared(items: [String], options: CompressOptions, existingEncrypted: Bool, host: NSWindow?, completion: @escaping (Bool, String) -> Void) {
        var o = options
        if items.contains(where: { item in
            let source = URL(fileURLWithPath: item).standardizedFileURL.resolvingSymlinksInPath().path
            let output = URL(fileURLWithPath: o.archivePath).standardizedFileURL.resolvingSymlinksInPath().path
            return output == source || (isDirectoryPath(source) && output.hasPrefix(source + "/"))
        }) {
            Dialogs.error(P("Kaynaklar korunuyor", "Source files protected"), P("Arşivi kaynak klasörün dışında kaydedin.", "Save the archive outside the source folder."))
            completion(false, o.archivePath); return
        }
        if o.deleteAfter, let volume = o.volumeSize, !volume.isEmpty {
            Dialogs.error(P("Seçenekler birlikte kullanılamaz", "Options cannot be combined"), P("Parçalı arşiv oluştururken kaynakları silme seçeneğini kapatın.", "Turn off source deletion when creating split archives."))
            completion(false, o.archivePath); return
        }
        if FileManager.default.fileExists(atPath: o.archivePath) {
            let alert = NSAlert()
            alert.messageText = LF("\"%@\" zaten var", name(o.archivePath))
            if o.format.supportsAppend, !o.sfx {
                if existingEncrypted {
                    alert.informativeText = L("Aynı adlı mevcut arşiv şifreli. Yeni, şifresiz bir arşiv oluşturulsun mu, yoksa dosyalar şifreli arşive mi eklensin?")
                    alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
                    alert.addButton(withTitle: L("Şifreli Arşive Ekle…"))
                    alert.addButton(withTitle: L("İptal"))
                    Dialogs.activate()
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        o.archivePath = uniquePath(o.archivePath)
                    case .alertSecondButtonReturn:
                        listAsync(archive: o.archivePath, password: o.password) { existing, pw in
                            guard let existing else { completion(false, o.archivePath); return }
                            add(info: existing, items: items, password: pw, host: host) { ok, _ in completion(ok, o.archivePath) }
                        }
                        return
                    default:
                        completion(false, o.archivePath); return
                    }
                } else {
                    alert.informativeText = L("Yeni bir arşiv oluşturulsun mu, yoksa dosyalar mevcut arşive mi eklensin?")
                    alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
                    alert.addButton(withTitle: L("Mevcut Arşive Ekle"))
                    alert.addButton(withTitle: L("İptal"))
                    Dialogs.activate()
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: o.archivePath = uniquePath(o.archivePath)
                    case .alertSecondButtonReturn:
                        listAsync(archive: o.archivePath, password: o.password) { existing, pw in
                            guard let existing else { completion(false, o.archivePath); return }
                            add(info: existing, items: items, password: pw, host: host) { ok, _ in completion(ok, o.archivePath) }
                        }
                        return
                    default: completion(false, o.archivePath); return
                    }
                }
            } else {
                alert.informativeText = L("Bu biçimde mevcut arşive ekleme yapılamaz. Yeni bir arşiv oluşturulsun mu?")
                alert.addButton(withTitle: L("Yeni Arşiv Oluştur"))
                alert.addButton(withTitle: L("İptal"))
                Dialogs.activate()
                if alert.runModal() == .alertFirstButtonReturn { o.archivePath = uniquePath(o.archivePath) } else { completion(false, o.archivePath); return }
            }
        }
        let prepared = o
        TaskCenter.shared.work(title: P("Kaynaklar kontrol ediliyor", "Checking source files"), host: host, body: { token -> SourceManifest? in
            try ArchiveSafety.validateInputs(items, cancelled: { token.cancelled })
            return prepared.deleteAfter ? try SourceManifest.collect(items, cancelled: { token.cancelled }) : nil
        }) { result in
            switch result {
            case .success(let manifest): startCompression(items: items, options: prepared, manifest: manifest, host: host, completion: completion)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(P("Kaynaklar korunuyor", "Source files protected"), error.localizedDescription) }
                completion(false, prepared.archivePath)
            }
        }
    }

    private static func startCompression(items: [String], options o: CompressOptions, manifest: SourceManifest?, host: NSWindow?, completion: @escaping (Bool, String) -> Void) {
        let lockKey = URL(fileURLWithPath: o.archivePath).standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping.lowercased()
        guard mutationLocks.insert(lockKey).inserted else {
            Dialogs.error(P("İşlem sürüyor", "Operation in progress"), P("Bu arşivde başka bir işlem sürüyor.", "Another operation is modifying this archive.")); completion(false, o.archivePath); return
        }
        TaskCenter.shared.work(title: P("Arşiv hedefi hazırlanıyor", "Preparing archive destination"), host: host, discardCancelledResult: { (creation: ArchiveCreation) in creation.cleanUp() }, body: { token in
            let creation = try ArchiveCreation(path: o.archivePath)
            do { try token.check(); return creation }
            catch { creation.cleanUp(); throw error }
        }) { preparation in
            guard case .success(let creation) = preparation else {
                mutationLocks.remove(lockKey)
                if case .failure(let error) = preparation, (error as? CocoaError)?.code != .userCancelled { Dialogs.error(L("Sıkıştırma başarısız"), error.localizedDescription) }
                completion(false, o.archivePath); return
            }
            var staged = o; staged.archivePath = creation.stagedPath
            let steps = staged.buildSteps(items: items)
            runSteps(steps, index: 0, archive: staged.archivePath, cwd: creation.staging.path, host: host) { result, _ in
                guard result.ok else {
                    creation.cleanUp(); mutationLocks.remove(lockKey)
                    ArchiveLibrary.shared.record(P("Arşiv oluşturma", "Archive creation"), archive: o.archivePath, success: false, detail: result.errorSummary, cancelled: result.cancelled)
                    completion(false, o.archivePath); return
                }
                TaskCenter.shared.work(title: P("Arşiv doğrulanıyor ve kaydediliyor", "Verifying and saving archive"), host: host, commitsChanges: true, body: { token in
                    defer { creation.cleanUp() }
                    let files = try creation.outputs(), first = try creation.firstOutput(files)
                    guard case .ok(let info) = RarRunner.list(first.path, password: o.password, cancellation: token) else { throw ArchiveSafetyError(message: P("Oluşturulan arşiv açılamadı.", "Could not open the created archive.")) }
                    try ArchiveSafety.validateEntries(info.entries)
                    try token.check()
                    return try creation.publish(files, cancelled: { token.cancelled })
                }) { published in
                    creation.cleanUp()
                    mutationLocks.remove(lockKey)
                    switch published {
                    case .failure(let error):
                        ArchiveLibrary.shared.record(P("Arşiv oluşturma", "Archive creation"), archive: o.archivePath, success: false, detail: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)
                        if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(L("Sıkıştırma başarısız"), error.localizedDescription) }
                        completion(false, o.archivePath)
                    case .success(let path):
                        ArchiveLibrary.shared.record(P("Arşiv oluşturma", "Archive creation"), archive: path, destination: path, success: true)
                        guard o.deleteAfter else { completion(true, path); return }
                        listAsync(archive: path, password: o.password) { info, pw in
                            guard let info else { completion(false, path); return }
                            TaskCenter.shared.work(title: P("Kaynaklar doğrulanıyor ve taşınıyor", "Verifying and moving sources"), host: host, commitsChanges: true, body: { token in
                                guard let manifest else { throw ArchiveSafetyError(message: "Missing source manifest") }
                                try manifest.verifyArchiveContents(info, password: pw, cancellation: token, cancelled: { token.cancelled })
                                try manifest.moveVerifiedToTrash(items: items, archive: info, cancelled: { token.cancelled })
                            }) { result in
                                switch result {
                                case .success: completion(true, path)
                                case .failure(let error):
                                    if (error as? CocoaError)?.code != .userCancelled { Dialogs.error(P("Kaynaklar taşınamadı", "Could not move source files to Trash"), error.localizedDescription) }
                                    completion(false, path)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func runSteps(_ steps: [CompressOptions.Step], index: Int, archive: String, cwd: String,
                                 host: NSWindow?, completion: @escaping (RarResult, String) -> Void) {
        guard index < steps.count else { completion(RarResult(code: 0, output: ""), archive); return }
        let step = steps[index]
        let suffix = steps.count > 1 ? " (\(index + 1)/\(steps.count))" : ""
        runJob(title: "\(L(step.title)): \(name(archive))\(suffix)", tool: step.tool, args: step.args, cwd: cwd, host: host, totalFiles: nil) { r in
            step.cleanup?()
            if r.cancelled {
                steps[(index + 1)...].forEach { $0.cleanup?() }
                completion(r, archive); return
            }
            if !r.ok {
                steps[(index + 1)...].forEach { $0.cleanup?() }
                Dialogs.error(L("Sıkıştırma başarısız"), r.errorSummary)
                completion(r, archive)
                return
            }
            runSteps(steps, index: index + 1, archive: archive, cwd: cwd, host: host, completion: completion)
        }
    }

    // MARK: Mevcut arşive dosya ekleme / silme

    static func add(info: ArchiveInfo, items: [String], password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        if info.kind == .rar {
            do { try ArchiveSafety.validateRARInputs(items) }
            catch { Dialogs.error(P("Dosyalar korunuyor", "Files protected"), error.localizedDescription); completion(false, password); return }
        }
        guard info.supportsModification else {
            Dialogs.error(L("Desteklenmiyor"), L("tar.gz / tar.xz türü arşivlere dosya eklenemez. Yeni bir arşiv oluşturun."))
            completion(false, password); return
        }
        var pw = password
        if info.hasEncryptedFiles, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        let stages: [Stage]
        switch info.kind {
        case .rar:
            stages = [(.rar, ["a", "-ep1", "-r", "-y"] + RarRunner.passwordArgs(pw, encryptHeaders: info.headersEncrypted) + ["--", info.path] + items)]
        case .other:
            var args = ["a", "-spd", "-y", "-bsp1", "-bb1"] + RarRunner.passwordArgs7z(pw)
            if info.headersEncrypted { args.append("-mhe=on") }
            stages = [(.sevenZip, args + ["--", info.path] + items)]
        }
        var incoming = [ArchiveEntry]()
        runMutation(title: LF("Ekleniyor: %@", name(info.path)), archive: info.path, stages: stages, host: host, password: pw, expectedRevision: info.revision, prepare: { token in
            try ArchiveSafety.validateEntries(info.entries)
            incoming = try ArchiveSafety.validateInputs(items, cancelled: { token.cancelled })
            let incomingNames = Set(incoming.map { ArchiveSafety.relativePath($0.name).lowercased() })
            try ArchiveSafety.validateEntries(info.entries.filter { !incomingNames.contains(ArchiveSafety.relativePath($0.name).lowercased()) } + incoming)
        }, verify: { temporary, token in
            guard case .ok(let after) = RarRunner.list(temporary, password: pw, cancellation: token) else { throw ArchiveSafetyError(message: P("Ekleme doğrulanamadı.", "Addition could not be verified.")) }
            let replacing = Set(incoming.map { ArchiveSafety.relativePath($0.name) })
            try ArchiveSafety.verifyUnchanged(info.entries.filter { !replacing.contains(ArchiveSafety.relativePath($0.name)) }, in: after.entries)
            let expected = Set(info.entries.map { ArchiveSafety.relativePath($0.name) }).union(replacing)
            guard Set(after.entries.map { ArchiveSafety.relativePath($0.name) }) == expected else { throw ArchiveSafetyError(message: P("Eklenen dosya yolları eşleşmiyor; asıl arşiv korundu.", "Added file paths do not match; original archive preserved.")) }
        }) { r in
            if r.cancelled { completion(false, pw); return }
            if r.wrongPassword {
                guard let p = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, pw); return }
                add(info: info, items: items, password: p, host: host, completion: completion)
                return
            }
            if !r.ok { Dialogs.error(L("Ekleme başarısız"), r.errorSummary) }
            completion(r.ok, pw)
        }
    }

    static func delete(info: ArchiveInfo, names: [String], password: String?, host: NSWindow?, completion: @escaping (Bool, String?) -> Void) {
        do { try ArchiveSafety.validateEntries(info.entries); try ArchiveSafety.validateSelection(info, names: names) }
        catch { Dialogs.error(L("Silme başarısız"), error.localizedDescription); completion(false, password); return }
        guard info.supportsModification else {
            Dialogs.error(L("Desteklenmiyor"), L("tar.gz / tar.xz türü arşivlerden dosya silinemez."))
            completion(false, password); return
        }
        if info.kind == .rar, names.contains(where: { $0.contains("*") || $0.contains("?") }) {
            Dialogs.error(P("Dosyalar korunuyor", "Files protected"), P("RAR motoru bu adları joker desen olarak yorumluyor. * veya ? içeren bir adı silmek için arşivi yeniden paketleyin.", "The RAR engine treats these names as patterns. Repack the archive to delete a name containing * or ?."))
            completion(false, password); return
        }
        var pw = password
        if info.headersEncrypted, pw == nil {
            guard let p = Dialogs.askPassword(archiveName: name(info.path)) else { completion(false, nil); return }
            pw = p
        }
        let stages: [Stage]
        switch info.kind {
        case .rar:
            stages = [(.rar, ["d", "-y"] + RarRunner.passwordArgs(pw) + ["--", info.path] + names)]
        case .other:
            stages = [(.sevenZip, ["d", "-spd", "-y", "-bsp1", "-bb1"] + RarRunner.passwordArgs7z(pw) + ["--", info.path] + names)]
        }
        runMutation(title: LF("Siliniyor: %@", name(info.path)), archive: info.path, stages: stages, host: host, password: pw, expectedRevision: info.revision, verify: { edited, token in
            let expected = info.entries.filter { e in !names.contains { e.name == $0 || e.name.hasPrefix($0 + "/") } }
            if info.kind == .rar, expected.isEmpty, !FileManager.default.fileExists(atPath: edited) {
                try RarRunner.writeEmptyRAR(at: edited, headerPassword: info.headersEncrypted ? pw : nil)
            }
            guard case .ok(let after) = RarRunner.list(edited, password: pw, cancellation: token) else { throw ArchiveSafetyError(message: P("Silinen arşiv doğrulanamadı; asıl arşiv korunuyor.", "Could not verify the edited archive; the original is preserved.")) }
            try ArchiveSafety.verifyUnchanged(expected, in: after.entries)
            guard Set(after.entries.map { $0.name }) == Set(expected.map { $0.name }) else { throw ArchiveSafetyError(message: P("Beklenmeyen dosyalar silindi; asıl arşiv korunuyor.", "Unexpected entries were deleted; the original is preserved.")) }
        }) { r in
            if r.cancelled { completion(false, pw); return }
            if r.wrongPassword {
                guard let p = Dialogs.askPassword(archiveName: name(info.path), wrong: true) else { completion(false, pw); return }
                delete(info: info, names: names, password: p, host: host, completion: completion)
                return
            }
            if !r.ok { Dialogs.error(L("Silme başarısız"), r.errorSummary) }
            completion(r.ok, pw)
        }
    }

    static func rename(info: ArchiveInfo, old: String, new: String, password: String?, host: NSWindow?, completion: @escaping (Bool) -> Void) {
        do {
            try ArchiveSafety.validateEntries(info.entries)
            try ArchiveSafety.validateSelection(info, names: [old])
            guard !new.hasPrefix(old + "/") else { throw ArchiveSafetyError(message: P("Bir klasörü kendi içine taşıyamazsınız.", "A folder cannot be moved into itself.")) }
            let renamed = info.entries.map { entry -> ArchiveEntry in
                var entry = entry
                entry.name = entry.name == old ? new : entry.name.hasPrefix(old + "/") ? new + String(entry.name.dropFirst(old.count)) : entry.name
                return entry
            }
            try ArchiveSafety.validateEntries(renamed)
            guard info.supportsModification, !new.isEmpty, !info.entries.contains(where: { $0.name == new }), ![old, new].contains(where: { $0.contains("*") || $0.contains("?") }) else { throw ArchiveSafetyError(message: P("Bu ad veya biçim yeniden adlandırmayı desteklemiyor.", "This name or format does not support renaming.")) }
            let tool: RarTool = info.kind == .rar ? .rar : .sevenZip
            let args = ["rn", "-y"] + (info.kind == .rar ? RarRunner.passwordArgs(password) : RarRunner.passwordArgs7z(password)) + ["--", info.path, old, new]
            runMutation(title: P("Yeniden adlandırılıyor", "Renaming"), archive: info.path, stages: [(tool, args)], host: host, password: password, expectedRevision: info.revision, verify: { temporary, token in
                guard case .ok(let after) = RarRunner.list(temporary, password: password, cancellation: token) else { throw ArchiveSafetyError(message: P("Arşiv doğrulanamadı.", "Archive could not be verified.")) }
                try ArchiveSafety.verifyUnchanged(renamed, in: after.entries)
                let expected = info.entries.map { $0.name == old ? new : $0.name.hasPrefix(old + "/") ? new + String($0.name.dropFirst(old.count)) : $0.name }
                guard Set(expected) == Set(after.entries.map { $0.name }) else { throw ArchiveSafetyError(message: P("Ad değişikliği doğrulanamadı; asıl arşiv korundu.", "Rename could not be verified; original archive preserved.")) }
            }) { result in
                if !result.ok, !result.cancelled { Dialogs.error(P("Ad değiştirilemedi", "Could not rename"), result.errorSummary) }
                completion(result.ok)
            }
        } catch { Dialogs.error(P("Ad değiştirilemedi", "Could not rename"), error.localizedDescription); completion(false) }
    }

    static func saveEdited(info: ArchiveInfo, relativePath: String, directory: String, password: String?, host: NSWindow?, expectedRevision: ArchiveRevision? = nil, sourceExpectedRevision: ContentRevision? = nil, didCommit: ((ArchiveRevision) -> Void)? = nil, completion: @escaping (Bool) -> Void) {
        guard info.supportsModification else { completion(false); return }
        let source = URL(fileURLWithPath: directory).appendingPathComponent(relativePath)
        var sourceRevision: ContentRevision?
        do {
            try ArchiveSafety.validateSelection(info, names: [relativePath])
            if info.kind == .rar { try ArchiveSafety.validateRARInputs([relativePath]) }
            try ArchiveSafety.rejectLinks(in: source)
        } catch { Dialogs.error(P("Dosya kaydedilemedi", "Could not save file"), error.localizedDescription); completion(false); return }
        let tool: RarTool = info.kind == .rar ? .rar : .sevenZip
        let switches = info.kind == .rar ? ["-r"] + RarRunner.passwordArgs(password, encryptHeaders: info.headersEncrypted) : ["-spd"] + RarRunner.passwordArgs7z(password) + (info.headersEncrypted ? ["-mhe=on"] : [])
        let args = ["a", "-y"] + switches + ["--", info.path, relativePath]
        guard let baseline = expectedRevision ?? info.revision else {
            Dialogs.error(P("Dosya kaydedilemedi", "Could not save file"), P("Başlangıç arşivi doğrulanamadı; arşivi yeniden açın.", "Cannot verify the original archive; reopen it.")); completion(false); return
        }
        runMutation(title: P("Düzenlenen dosya kaydediliyor", "Saving edited file"), archive: info.path, stages: [(tool, args)], host: host, cwd: directory, password: password, expectedRevision: baseline, prepare: { token in
            sourceRevision = try ContentRevision.read(source, cancelled: { token.cancelled })
            guard sourceExpectedRevision == nil || sourceExpectedRevision == sourceRevision else { throw ArchiveSafetyError(message: P("Editörde dosya yeniden değişti. Yeniden kaydedin.", "The editor changed the file again. Save again.")) }
        }, verify: { temporary, token in
            guard case .ok(let after) = RarRunner.list(temporary, password: password, cancellation: token), after.entries.contains(where: { $0.name == relativePath }), Set(after.entries.map { $0.name }) == Set(info.entries.map { $0.name }) else { throw ArchiveSafetyError(message: P("Dosya yolu doğrulanamadı; asıl arşiv korundu.", "File path could not be verified; original preserved.")) }
            let verification = FileManager.default.temporaryDirectory.appendingPathComponent("MacRARPlus-edit-check-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: verification, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: verification) }
            let extracted = RarRunner.runStages(extractStages(info: after, names: [relativePath], dest: verification.path, password: password, mode: .overwrite), cancellation: token)
            if extracted.cancelled { throw CocoaError(.userCancelled) }
            guard extracted.ok else { throw ArchiveSafetyError(message: extracted.errorSummary) }
            try ArchiveSafety.validateExtracted(verification, entries: ArchiveSafety.selectedEntries(after, names: [relativePath]))
            guard try ContentRevision.read(verification.appendingPathComponent(relativePath), cancelled: { token.cancelled }).digest == sourceRevision?.digest else { throw ArchiveSafetyError(message: P("Kaydedilen içerik editör kopyasıyla eşleşmiyor; asıl arşiv korundu.", "Saved contents do not match the editor copy; original archive preserved.")) }
            try ArchiveSafety.verifyUnchanged(info.entries.filter { $0.name != relativePath }, in: after.entries)
            guard try ContentRevision.read(source, cancelled: { token.cancelled }) == sourceRevision else { throw ArchiveSafetyError(message: P("Dış editörde dosya işlem sırasında değişti. Asıl arşiv korundu; yeniden kaydedin.", "The file changed in the external editor during processing. Original archive preserved; save again.")) }
        }) { result in
            if !result.ok, !result.cancelled { Dialogs.error(P("Dosya kaydedilemedi", "Could not save file"), result.errorSummary) }
            if result.ok, let revision = result.committedRevision { didCommit?(revision) }
            completion(result.ok)
        }
    }

    private static var mutationLocks = Set<String>()
    private static var extractionLocks = Set<String>()
    private static func runMutation(title: String, archive: String, stages: [Stage], host: NSWindow?, cwd: String? = nil, password: String? = nil, expectedRevision: ArchiveRevision? = nil, prepare: ((TaskCancellation) throws -> Void)? = nil, verify: ((String, TaskCancellation) throws -> Void)? = nil, completion: @escaping (RarResult) -> Void) {
        let original = URL(fileURLWithPath: archive).standardizedFileURL.resolvingSymlinksInPath()
        let lockKey = original.path.precomposedStringWithCanonicalMapping.lowercased()
        guard mutationLocks.insert(lockKey).inserted else {
            completion(RarResult(code: 2, output: P("Bu arşivde başka bir işlem sürüyor.", "Another operation is modifying this archive."))); return
        }
        let temporary = original.deletingLastPathComponent().appendingPathComponent(".macrarplus-edit-\(UUID().uuidString)." + original.pathExtension)
        TaskCenter.shared.work(title: P("Arşiv kopyası hazırlanıyor", "Preparing archive copy"), host: host, body: { token in
            try prepare?(token)
            let revision = try ArchiveRevision.read(original, cancelled: { token.cancelled })
            guard expectedRevision == nil || revision == expectedRevision else { throw ArchiveSafetyError(message: P("Arşiv düzenleme başladıktan sonra değişti; dışarıdaki değişiklikler korundu. Arşivi yeniden açın.", "Archive changed since editing began; external changes preserved. Reopen the archive.")) }
            try FileManager.default.copyItem(at: original, to: temporary)
            try token.check()
            guard try ContentRevision.read(temporary, cancelled: { token.cancelled }).digest == revision.parts.first?.content.digest else { throw ArchiveSafetyError(message: P("Arşiv kopyası kaynakla eşleşmiyor.", "Archive copy does not match its source.")) }
            guard try ArchiveRevision.read(original, cancelled: { token.cancelled }) == revision else { throw ArchiveSafetyError(message: P("Arşiv başka bir uygulamada değişti. Listeyi yeniden yükleyin.", "The archive changed in another application. Reload the listing.")) }
            return revision
        }) { preparation in
            if case .failure(let error) = preparation {
                try? FileManager.default.removeItem(at: temporary)
                mutationLocks.remove(lockKey)
                completion(RarResult(code: 2, output: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)); return
            }
            guard case .success(let revision) = preparation else { return }
            let safeStages = stages.map { (tool: $0.tool, args: $0.args.map { $0 == archive ? temporary.path : $0 }) }
            runJob(title: title, stages: safeStages, cwd: cwd, host: host, totalFiles: nil) { result in
                guard result.ok else {
                    try? FileManager.default.removeItem(at: temporary); mutationLocks.remove(lockKey)
                    ArchiveLibrary.shared.record(title, archive: archive, success: false, detail: result.errorSummary, cancelled: result.cancelled)
                    completion(result); return
                }
                TaskCenter.shared.work(title: P("Arşiv doğrulanıyor ve kaydediliyor", "Verifying and saving archive"), host: host, commitsChanges: true, body: { token in
                    try verify?(temporary.path, token); try token.check()
                    guard case .ok(let checked) = RarRunner.list(temporary.path, password: password, cancellation: token) else { throw ArchiveSafetyError(message: P("Değiştirilen arşiv açılamadı; asıl arşiv korundu.", "Cannot open the modified archive; original preserved.")) }
                    try ArchiveSafety.validateEntries(checked.entries)
                    let rar = checked.kind == .rar && !checked.entries.isEmpty
                    let integrity = RarRunner.runStages([(rar ? .unrar : .sevenZip, ["t", "-y"] + (rar ? RarRunner.passwordArgs(password) : RarRunner.passwordArgs7z(password)) + ["--", temporary.path])], cancellation: token)
                    if integrity.cancelled { throw CocoaError(.userCancelled) }
                    guard integrity.ok else { throw ArchiveSafetyError(message: integrity.errorSummary) }
                    try token.check()
                    guard try ArchiveRevision.read(original, cancelled: { token.cancelled }) == revision else { throw ArchiveSafetyError(message: P("Arşiv başka bir uygulamada değişti; dışarıdaki değişiklikler korundu. Listeyi yeniden yükleyin.", "The archive changed in another application; external changes were preserved. Reload the listing.")) }
                    let committed = try ArchiveRevision.read(temporary, cancelled: { token.cancelled })
                    _ = try FileManager.default.replaceItemAt(original, withItemAt: temporary, options: .usingNewMetadataOnly)
                    return committed
                }) { commit in
                    try? FileManager.default.removeItem(at: temporary); mutationLocks.remove(lockKey)
                    var final: RarResult
                    switch commit {
                    case .success(let revision): final = result; final.committedRevision = revision
                    case .failure(let error): final = RarResult(code: 2, output: error.localizedDescription, cancelled: (error as? CocoaError)?.code == .userCancelled)
                    }
                    ArchiveLibrary.shared.record(title, archive: archive, success: final.ok, detail: final.ok ? nil : final.errorSummary, cancelled: final.cancelled)
                    completion(final)
                }
            }
        }
    }


    // MARK: Hedef klasör yardımcıları

    static func folderNamedAfterArchive(_ archive: String) -> String {
        let ns = archive as NSString
        var base = (ns.deletingPathExtension as NSString).lastPathComponent
        // çok parçalı arşivlerde "ad.part1" → "ad", "ad.7z.001" → "ad"
        if let r = base.range(of: #"\.part\d+$"#, options: [.regularExpression, .caseInsensitive]) { base.removeSubrange(r) }
        if ns.pathExtension.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil {
            base = (base as NSString).deletingPathExtension
        }
        // ad.tar.gz → ad
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        return (ns.deletingLastPathComponent as NSString).appendingPathComponent(base)
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
