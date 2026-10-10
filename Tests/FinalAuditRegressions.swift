import AppKit

func runFinalAuditRegressions(root: URL) throws {
    let fm = FileManager.default, folder = root.appendingPathComponent("final-audit")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    func inPlace(_ text: String, _ url: URL) throws {
        let date = try FileRevision.read(url).modified
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Data(text.utf8)); try handle.close()
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
    let extreme = RarRunner.parse7zListing("Type = zip\n\n----------\nPath = a\nSize = 1\nPacked Size = 9223372036854775807\n\n", path: "numeric.zip")
    check(extreme.entries.count == 1 && extreme.entries[0].ratio.isEmpty, "Extreme packed ratio cannot crash the listing parser")
    check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "a", isDirectory: false, size: 1, packedSize: Int64.max), ArchiveEntry(name: "b", isDirectory: false, size: 1, packedSize: 1)]) }, "Packed aggregate overflow is rejected before tree or inspector construction")
    let normal = RarRunner.parse7zListing("Type = zip\n\n----------\nPath = a\nSize = 100\nPacked Size = 75\n\n", path: "numeric.zip")
    check(normal.entries.first?.ratio == "75%", "Ordinary compression ratio remains accurate")
    check(ArchiveQuery("size>9223372036854775807GB").minimum == nil && ArchiveQuery("size>9223372036854775807").minimum == nil, "Oversized numeric search filters are rejected safely")
    var discarded = false
    check(!waitBool { done in
        TaskCenter.shared.work(title: "Late preparation cancellation", host: nil, discardCancelledResult: { (value: Int) in discarded = value == 42 }, body: { token in
            token.cancel(); return 42
        }) { result in if case .success = result { done(true) } else { done(false) } }
    }, "Cancellation just after preparation stops the next operation stage")
    check(discarded, "Cancelled preparation disposes its owned resources")
    check(waitBool { done in
        TaskCenter.shared.work(title: "Late committed cancellation", host: nil, commitsChanges: true, body: { token in
            token.cancel(); return 42
        }) { result in if case .success(let value) = result { done(value == 42) } else { done(false) } }
    }, "Cancellation after completed commit keeps the successful result")
    // Queue the cancellation while main is occupied. A finished engine must not
    // hand an outdated success snapshot to the next stage when main resumes.
    let lateJob = RarJob()
    check(waitResult { done in
        lateJob.start(.sevenZip, ["i"], completion: done)
        DispatchQueue.main.async { lateJob.cancel() }
        Thread.sleep(forTimeInterval: 0.2)
    }.cancelled, "Late engine cancellation remains visible at main-thread completion")
    let failedJob = RarJob()
    check(waitResult { done in
        DispatchQueue.main.async { failedJob.cancel() }
        failedJob.start(.sevenZip, ["i"], cwd: folder.appendingPathComponent("missing-working-directory").path, completion: done)
    }.cancelled, "Startup-failure completion retains a queued cancellation")
    for mode in ["overwrite", "new-file", "folder-edit", "folder-add"] {
        let stage = folder.appendingPathComponent(mode + "-stage"), target = folder.appendingPathComponent(mode + "-out")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let names = ["a", "b"]
        let directories = mode.hasPrefix("folder")
        for name in names {
            if directories {
                try fm.createDirectory(at: stage.appendingPathComponent(name), withIntermediateDirectories: true)
                try write("incoming", stage.appendingPathComponent(name + "/child.txt"))
            } else {
                try write("incoming", stage.appendingPathComponent(name))
                if mode == "overwrite" { try write("original", target.appendingPathComponent(name)) }
            }
        }
        var changed: URL?, injected = false
        var errorText = ""
        do {
            try ArchiveSafety.commit(staging: stage, destination: target, rename: false, cancelled: {
                guard let name = names.first(where: { !fm.fileExists(atPath: stage.appendingPathComponent($0).path) }) else { return false }
                if !injected {
                    injected = true
                    if mode == "folder-add" {
                        changed = target.appendingPathComponent(name + "/external-empty")
                        try! fm.createDirectory(at: changed!, withIntermediateDirectories: false)
                    } else {
                        changed = target.appendingPathComponent(name + (directories ? "/child.txt" : ""))
                        // Same bytes count, inode and mtime: only the digest reveals this edit.
                        try! inPlace("external", changed!)
                    }
                }
                return true
            })
        } catch { errorText = error.localizedDescription }
        check(injected && !errorText.isEmpty, "Concurrent rollback conflict is reported: " + mode)
        check(try changed != nil && (mode == "folder-add" ? isDirectoryPath(changed!.path) : String(contentsOf: changed!) == "external"), "Rollback retains the exact external change: " + mode)
        let recovery = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".macrarplus-rollback-") }
        check(recovery != nil && errorText.contains(recovery!.path), "Recovery path is retained and included in the error: " + mode)
        check(fm.fileExists(atPath: recovery!.appendingPathComponent("Recovery.txt").path), "Recovery copies include destination mapping: " + mode)
        if mode == "overwrite" {
            let backups = try fm.contentsOfDirectory(at: recovery!, includingPropertiesForKeys: nil).filter { Int($0.lastPathComponent) != nil }
            check(try backups.count == 2 && backups.allSatisfy { try String(contentsOf: $0) == "original" }, "Both pre-extraction originals remain recoverable after external editing")
        }
        check(names.filter { fm.fileExists(atPath: stage.appendingPathComponent($0).path) }.count == 1, "Cancelled transaction leaves its other input staged: " + mode)
    }

    // A target modified after its backup must not be overwritten by incoming data.
    let stage = folder.appendingPathComponent("backup-stage"), target = folder.appendingPathComponent("backup-out")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true); try fm.createDirectory(at: target, withIntermediateDirectories: true)
    try write("incoming", stage.appendingPathComponent("file.txt")); try write("original", target.appendingPathComponent("file.txt"))
    var changedAfterBackup = false
    check(rejects {
        try ArchiveSafety.commit(staging: stage, destination: target, rename: false, cancelled: {
            if !changedAfterBackup, let recovery = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix(".macrarplus-rollback-") }), fm.fileExists(atPath: recovery.appendingPathComponent("0").path) {
                changedAfterBackup = true; try! inPlace("external", target.appendingPathComponent("file.txt"))
            }
            return false
        })
    }, "Changing an approved overwrite after backup aborts commit")
    check(try changedAfterBackup && String(contentsOf: target.appendingPathComponent("file.txt")) == "external" && String(contentsOf: stage.appendingPathComponent("file.txt")) == "incoming", "Late backup conflict preserves external destination and incoming source")
    check(!(try fm.contentsOfDirectory(atPath: target.path)).contains { $0.hasPrefix(".macrarplus-") }, "Pre-commit conflict cleans unused recovery copies")

    for mode in ["replace", "in-place", "removed"] {
        let creation = try ArchiveCreation(path: folder.appendingPathComponent("publish-" + mode + ".zip").path)
        let base = creation.destination.lastPathComponent
        for suffix in [".001", ".002"] { try write("incoming", creation.staging.appendingPathComponent(base + suffix)) }
        let first = folder.appendingPathComponent(base + ".001")
        var injected = false, errorText = ""
        do {
            _ = try creation.publish(try creation.outputs(), cancelled: {
                if !injected, fm.fileExists(atPath: first.path) {
                    injected = true
                    if mode == "removed" { try! fm.removeItem(at: first) }
                    else if mode == "in-place" { try! inPlace("external", first) }
                    else { try! write("external", first) }
                    return true
                }
                return false
            })
        } catch { errorText = error.localizedDescription }
        creation.cleanUp(); creation.cleanUp()
        check(injected && errorText.contains(creation.staging.path), "Split rollback conflict reports recovery directory: " + mode)
        check(mode == "removed" ? !fm.fileExists(atPath: first.path) : (try String(contentsOf: first)) == "external", "Split rollback respects external change: " + mode)
        check(try String(contentsOf: creation.staging.appendingPathComponent(base + ".002")) == "incoming", "Cleanup cannot delete retained split recovery volumes: " + mode)
        check(!fm.fileExists(atPath: folder.appendingPathComponent(base + ".002").path), "Interrupted split publication does not publish the next volume: " + mode)
    }

    // Actual engines, through production APIs: -- must preserve literal @ names.
    let source = folder.appendingPathComponent("@note.txt")
    try write("literal at sign", source)
    for format in [ArchiveFormat.rar5, .sevenZip, .zip, .tar] {
        let archive = folder.appendingPathComponent("literal." + format.ext)
        check(waitBool { done in Ops.compress(items: [source.path], options: CompressOptions(archivePath: archive.path, format: format), host: nil) { ok, _ in done(ok) } }, "Literal @ filename creation: " + format.title)
        guard case .ok(let info) = RarRunner.list(archive.path, password: nil) else { fatalError("Literal fixture listing failed") }
        let dest = folder.appendingPathComponent("literal-" + format.ext)
        check(waitBool { done in Ops.extract(info: info, names: ["@note.txt"], dest: dest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Selected literal @ filename extraction: " + format.title)
        check(try String(contentsOf: dest.appendingPathComponent("@note.txt")) == "literal at sign", "Literal @ entry contents survive: " + format.title)
        check(waitBool { done in Ops.rename(info: info, old: "@note.txt", new: "@renamed.txt", password: nil, host: nil, completion: done) }, "Literal @ entry rename: " + format.title)
        guard case .ok(let renamed) = RarRunner.list(archive.path, password: nil) else { fatalError("Renamed fixture listing failed") }
        check(waitBool { done in Ops.delete(info: renamed, names: ["@renamed.txt"], password: nil, host: nil) { ok, _ in done(ok) } }, "Literal @ entry delete: " + format.title)
    }
}
