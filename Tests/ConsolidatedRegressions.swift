import AppKit

func runConsolidatedRegressions(root: URL) throws {
    let fm = FileManager.default, folder = root.appendingPathComponent("consolidated")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    func read(_ url: URL, password: String? = nil) -> ArchiveInfo {
        guard case .ok(let info) = RarRunner.list(url.path, password: password) else { fatalError("Cannot list \(url.path)") }
        return info
    }
    let input = folder.appendingPathComponent("inputs"), a = input.appendingPathComponent("A/report.txt"), b = input.appendingPathComponent("B/report.txt")
    try fm.createDirectory(at: a.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write("source A", a); try write("source B", b)
    for format in ArchiveFormat.allCases {
        let output = folder.appendingPathComponent("duplicates." + format.ext)
        check(!waitBool { done in Ops.compress(items: [a.path, b.path], options: CompressOptions(archivePath: output.path, format: format), host: nil) { ok, _ in done(ok) } }, "Duplicate input paths refused before creation: " + format.title)
        check(try !fm.fileExists(atPath: output.path) && String(contentsOf: a) == "source A" && String(contentsOf: b) == "source B", "Duplicate refusal retains both sources and no public output: " + format.title)
    }
    let duplicateRAR = folder.appendingPathComponent("external-duplicate.rar")
    check(RarRunner.run(.rar, ["a", "-ep1", "--", duplicateRAR.path, a.path, b.path]).ok, "Create external duplicate-name RAR fixture")
    let duplicateInfo = read(duplicateRAR), duplicateDest = folder.appendingPathComponent("duplicate-out")
    check(duplicateInfo.fileCount == 2, "External RAR has two same-name entries")
    check(!waitBool { done in Ops.extract(info: duplicateInfo, names: nil, dest: duplicateDest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Duplicate archive extraction cannot silently collapse files")
    check(!fm.fileExists(atPath: duplicateDest.path), "Ambiguous extraction leaves destination untouched")
    check(!waitBool { done in Ops.listAsync(archive: duplicateRAR.path, password: nil) { info, _ in done(info != nil) } }, "Async opening rejects duplicate archive paths")
    for pair in [["a.txt", "./a.txt"], ["A.txt", "a.txt"], ["café.txt", "cafe\u{301}.txt"], ["a", "a/child"]] {
        check(rejects { try ArchiveSafety.validateEntries(pair.map { ArchiveEntry(name: $0, isDirectory: false) }) }, "Canonical or file-directory alias refused: " + pair.joined(separator: ", "))
    }
    check(rejects { try ArchiveSafety.validateInputs([input.path, a.path]) }, "Overlapping root selections refused for ordinary creation")
    check(Formats.isArchive("archive.7z.002") && Formats.isArchive("archive.7z.1000"), "Later numbered volumes are recognized as archives")
    let legacy = folder.appendingPathComponent("legacy.r00")
    try write("existing legacy volume", legacy)
    check(rejects { _ = try ArchiveCreation(path: folder.appendingPathComponent("legacy.rar").path) }, "Existing legacy RAR volume reserves the whole archive name")
    check(try String(contentsOf: legacy) == "existing legacy volume", "Legacy volume collision retains its contents")
    let inside = input.appendingPathComponent("self.zip")
    check(!waitBool { done in Ops.compress(items: [input.path], options: CompressOptions(archivePath: inside.path), host: nil) { ok, _ in done(ok) } }, "Output inside its own input is refused")
    check(!fm.fileExists(atPath: inside.path), "Self-inclusion creates no output")

    let noise = input.appendingPathComponent("noise.bin")
    var bytes = Data(count: 128 * 1024)
    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try bytes.write(to: noise)
    for format in [ArchiveFormat.rar5, .sevenZip, .zip] {
        let oldBase = folder.appendingPathComponent("existing." + format.ext)
        let oldFirst = folder.appendingPathComponent(format == .rar5 ? "existing.part01.rar" : "existing." + format.ext + ".001")
        for step in CompressOptions(archivePath: oldBase.path, format: format, volumeSize: "10k").buildSteps(items: [noise.path]) {
            check(RarRunner.run(step.tool, step.args).ok, "Seed existing split archive: " + format.title); step.cleanup?()
        }
        let names = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("existing.") }
        let originals = try Dictionary(uniqueKeysWithValues: names.map { ($0.path, try Data(contentsOf: $0)) })
        check(read(oldFirst).fileCount == 1, "Existing split archive is valid: " + format.title)
        check(!waitBool { done in Ops.compress(items: [a.path], options: CompressOptions(archivePath: oldBase.path, format: format, volumeSize: "10k"), host: nil) { ok, _ in done(ok) } }, "Existing split family cannot be overwritten: " + format.title)
        check(try originals.allSatisfy { try Data(contentsOf: URL(fileURLWithPath: $0.key)) == $0.value }, "Every pre-existing split volume retains exact bytes: " + format.title)
        for url in names { try fm.removeItem(at: url) }
        let fresh = folder.appendingPathComponent("fresh." + format.ext)
        var actual = ""
        check(waitBool { done in Ops.compress(items: [noise.path], options: CompressOptions(archivePath: fresh.path, format: format, volumeSize: "10k"), host: nil) { ok, path in actual = path; done(ok) } }, "Create split archive through production flow: " + format.title)
        check(fm.fileExists(atPath: actual) && actual != fresh.path, "Split completion returns the existing first volume: " + format.title)
        for volume in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where volume.lastPathComponent.hasPrefix("fresh.") {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1700000000)], ofItemAtPath: volume.path)
        }
        let splitInfo = read(URL(fileURLWithPath: actual)), dest = folder.appendingPathComponent("fresh-out-" + format.ext)
        let diskSize = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("fresh.") }.reduce(Int64(0)) { try $0 + Int64(Data(contentsOf: $1).count) }
        check(splitInfo.storedSize == diskSize && diskSize > 10 * 1024, "Archive summary counts every split volume: " + format.title)
        check(waitBool { done in Ops.extract(info: splitInfo, names: nil, dest: dest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Split archive opens and extracts: " + format.title)
        check(try Data(contentsOf: dest.appendingPathComponent(noise.lastPathComponent)) == bytes, "Split output content matches source: " + format.title)
        let family = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("fresh.") && !$0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let later = family.last!, before = try FileRevision.read(later), original = try Data(contentsOf: later)
        var changed = original; changed[changed.count - 1] ^= 1
        let handle = try FileHandle(forWritingTo: later); try handle.write(contentsOf: changed); try handle.close()
        try fm.setAttributes([.modificationDate: before.modified], ofItemAtPath: later.path)
        check(try FileRevision.read(later) == before, "Later volume edit preserves cheap metadata: " + format.title)
        check(try ArchiveRevision.read(URL(fileURLWithPath: actual)) != splitInfo.revision, "Strong revision detects changed later volume: " + format.title)
        check(!waitBool { done in Ops.extract(info: splitInfo, names: nil, dest: folder.appendingPathComponent("stale-split-" + format.ext).path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Stale split listing cannot be extracted: " + format.title)
        for url in family { try fm.removeItem(at: url) }
    }

    // Reproduce valid, equal-length replacement with unchanged inode and mtime.
    let old = input.appendingPathComponent("old/document.txt"), new = input.appendingPathComponent("new/document.txt")
    try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
    try write("original bytes", old); try write("replaced bytes", new)
    let date = Date(timeIntervalSince1970: 1700000000)
    for url in [old, new] { try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
    let archive = folder.appendingPathComponent("revision.zip"), replacement = folder.appendingPathComponent("replacement.zip")
    for (output, source) in [(archive, old), (replacement, new)] { check(RarRunner.run(.sevenZip, ["a", "-tzip", "-mx=0", "--", output.path, source.path]).ok, "Create equal-size stored ZIP revision fixture") }
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: archive.path)
    let baseline = read(archive), cheap = try FileRevision.read(archive), replacementBytes = try Data(contentsOf: replacement)
    check(replacementBytes.count == (try Data(contentsOf: archive)).count, "Replacement archive has identical byte length")
    let handle = try FileHandle(forWritingTo: archive); try handle.write(contentsOf: replacementBytes); try handle.close()
    try fm.setAttributes([.modificationDate: cheap.modified], ofItemAtPath: archive.path)
    check(try FileRevision.read(archive) == cheap && read(archive).fileCount == 1, "In-place replacement is valid and retains inode, size and mtime")
    let editor = folder.appendingPathComponent("editor")
    try fm.createDirectory(at: editor, withIntermediateDirectories: true); try write("local edit", editor.appendingPathComponent("document.txt"))
    check(!waitBool { done in Ops.saveEdited(info: baseline, relativePath: "document.txt", directory: editor.path, password: nil, host: nil, completion: done) }, "Metadata-preserving external edit rejects stale save")
    check(try Data(contentsOf: archive) == replacementBytes, "External ZIP bytes are preserved exactly")
    check(!waitBool { done in Ops.delete(info: baseline, names: ["document.txt"], password: nil, host: nil) { ok, _ in done(ok) } }, "Metadata-preserving external edit also rejects stale delete")
    check(try Data(contentsOf: archive) == replacementBytes, "Stale deletion preserves external ZIP bytes")

    for encrypted in [false, true] {
        let empty = folder.appendingPathComponent("empty-\(encrypted).rar"), password = encrypted ? "empty-secret" : nil
        try RarRunner.writeEmptyRAR(at: empty.path, headerPassword: password)
        let info = read(empty, password: password), dest = folder.appendingPathComponent("empty-out-\(encrypted)")
        check(waitBool { done in Ops.extract(info: info, names: nil, dest: dest.path, password: password, host: nil, quiet: true) { ok, _ in done(ok) } }, "Empty RAR extraction succeeds, encrypted=\(encrypted)")
        check(try fm.contentsOfDirectory(atPath: dest.path).isEmpty, "Empty extraction creates only the empty target folder")
        check(!waitBool { done in Ops.extract(info: info, names: ["missing.txt"], dest: folder.appendingPathComponent("missing-empty-\(encrypted)").path, password: password, host: nil, quiet: true) { ok, _ in done(ok) } }, "Missing selection in empty RAR still fails")
    }

    // Force cancellation after the first overwrite, and a late new target collision.
    let stage = folder.appendingPathComponent("rollback-stage"), target = folder.appendingPathComponent("rollback-out")
    try fm.createDirectory(at: stage, withIntermediateDirectories: true); try fm.createDirectory(at: target, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt"] { try write("new " + name, stage.appendingPathComponent(name)); try write("old " + name, target.appendingPathComponent(name)) }
    var interrupted = false
    check(rejects {
        try ArchiveSafety.commit(staging: stage, destination: target, rename: false, cancelled: {
            if ["a.txt", "b.txt"].contains(where: { !fm.fileExists(atPath: stage.appendingPathComponent($0).path) }) { interrupted = true; return true }
            return false
        })
    }, "Multi-file transfer cancellation propagates")
    check(try interrupted && String(contentsOf: target.appendingPathComponent("a.txt")) == "old a.txt" && String(contentsOf: target.appendingPathComponent("b.txt")) == "old b.txt", "Cancellation rolls back every completed overwrite")
    check(!(try fm.contentsOfDirectory(atPath: target.path)).contains { $0.hasPrefix(".macrarplus-") }, "Successful rollback removes its recovery folder")
    let lateStage = folder.appendingPathComponent("late-stage"), lateTarget = folder.appendingPathComponent("late-out")
    try fm.createDirectory(at: lateStage, withIntermediateDirectories: true); try fm.createDirectory(at: lateTarget, withIntermediateDirectories: true)
    for name in ["a.txt", "b.txt"] { try write("new " + name, lateStage.appendingPathComponent(name)) }
    var appeared: String?
    check(rejects {
        try ArchiveSafety.commit(staging: lateStage, destination: lateTarget, rename: false, cancelled: {
            if appeared == nil, ["a.txt", "b.txt"].contains(where: { !fm.fileExists(atPath: lateStage.appendingPathComponent($0).path) }) {
                appeared = ["a.txt", "b.txt"].first { fm.fileExists(atPath: lateStage.appendingPathComponent($0).path) }
                try! write("external late file", lateTarget.appendingPathComponent(appeared!))
            }
            return false
        })
    }, "Late transfer collision aborts instead of overwriting")
    check(try appeared != nil && String(contentsOf: lateTarget.appendingPathComponent(appeared!)) == "external late file" && fm.contentsOfDirectory(atPath: lateTarget.path).count == 1, "Late collision preserves new external file and rolls back earlier placement")
    let decisionStage = folder.appendingPathComponent("decision-stage"), decisionTarget = folder.appendingPathComponent("decision-out")
    try fm.createDirectory(at: decisionStage, withIntermediateDirectories: true); try fm.createDirectory(at: decisionTarget, withIntermediateDirectories: true)
    try write("incoming", decisionStage.appendingPathComponent("new.txt")); try write("appeared after preflight", decisionTarget.appendingPathComponent("new.txt"))
    check(rejects { try ArchiveSafety.commit(staging: decisionStage, destination: decisionTarget, rename: false, requireCollisionDecision: true) }, "An unapproved pre-commit collision cannot be overwritten")
    check(try String(contentsOf: decisionTarget.appendingPathComponent("new.txt")) == "appeared after preflight", "Missing collision decision preserves exact target content")
    let placeSource = folder.appendingPathComponent("transfer-source"), placeDest = folder.appendingPathComponent("transfer-folder")
    try write("retain failed source", placeSource); try fm.createDirectory(at: placeDest, withIntermediateDirectories: true)
    check(rejects { try ArchiveSafety.place(source: placeSource, destination: placeDest) }, "Invalid folder replacement fails safely")
    check(try String(contentsOf: placeSource) == "retain failed source" && isDirectoryPath(placeDest.path), "Failed transfer preserves both source and target")

    // Public output appearing after private preparation must survive publication.
    let late = folder.appendingPathComponent("late.zip"), creation = try ArchiveCreation(path: folder.appendingPathComponent("late-base.zip").path)
    try write("private archive", URL(fileURLWithPath: creation.stagedPath))
    try write("external archive", creation.destination)
    check(rejects { _ = try creation.publish(try creation.outputs()) }, "Late creation collision is refused")
    check(try String(contentsOf: creation.destination) == "external archive", "Late creation collision retains external output")
    creation.cleanUp()
    let rollbackCreation = try ArchiveCreation(path: late.path)
    for name in ["late.zip.001", "late.zip.002"] { try write("private volume", rollbackCreation.staging.appendingPathComponent(name)) }
    check(rejects { _ = try rollbackCreation.publish(try rollbackCreation.outputs(), cancelled: { fm.fileExists(atPath: folder.appendingPathComponent("late.zip.001").path) }) }, "Split publication cancellation fails")
    check(!fm.fileExists(atPath: folder.appendingPathComponent("late.zip.001").path) && !fm.fileExists(atPath: folder.appendingPathComponent("late.zip.002").path), "Split publication rollback leaves no partial public archive")
    rollbackCreation.cleanUp()

    for format in [ArchiveFormat.rar5, .sevenZip, .zip, .tar] {
        let output = folder.appendingPathComponent("matrix." + format.ext), source = input.appendingPathComponent("mutable.txt")
        let password: String? = format == .tar ? nil : "matrix-secret"
        try write("first mutable contents", source)
        check(waitBool { done in Ops.compress(items: [source.path, a.path], options: CompressOptions(archivePath: output.path, format: format, password: password, encryptNames: format.supportsEncryptNames), host: nil) { ok, _ in done(ok) } }, "Mutation matrix creation: " + format.title)
        var info = read(output, password: password)
        try write("updated mutable contents", source)
        check(waitBool { done in Ops.add(info: info, items: [source.path], password: password, host: nil) { ok, _ in done(ok) } }, "Replace selected archive entry: " + format.title)
        info = read(output, password: password)
        let before = try Data(contentsOf: output)
        check(!waitBool { done in Ops.add(info: info, items: [a.path, b.path], password: password, host: nil) { ok, _ in done(ok) } }, "Ambiguous addition refused: " + format.title)
        check(try Data(contentsOf: output) == before, "Rejected addition preserves all archive bytes: " + format.title)
        check(!waitBool { done in Ops.rename(info: info, old: source.lastPathComponent, new: "report.txt", password: password, host: nil, completion: done) }, "Rename collision refused: " + format.title)
        check(try Data(contentsOf: output) == before, "Rejected rename retains original bytes: " + format.title)
        check(waitBool { done in Ops.rename(info: info, old: source.lastPathComponent, new: "renamed.txt", password: password, host: nil, completion: done) }, "Valid rename with unselected entry: " + format.title)
        info = read(output, password: password)
        let contents = folder.appendingPathComponent("matrix-out-" + format.ext)
        check(waitBool { done in Ops.extract(info: info, names: nil, dest: contents.path, password: password, host: nil, quiet: true) { ok, _ in done(ok) } }, "Modified archive extracts with correct password: " + format.title)
        check(try String(contentsOf: contents.appendingPathComponent("renamed.txt")) == "updated mutable contents" && String(contentsOf: contents.appendingPathComponent("report.txt")) == "source A", "Replacement and rename retain both intended contents: " + format.title)
        check(waitBool { done in Ops.delete(info: info, names: ["renamed.txt"], password: password, host: nil) { ok, _ in done(ok) } }, "Selected deletion after rename: " + format.title)
        check(read(output, password: password).entries.filter { !$0.isDirectory }.map { $0.name } == ["report.txt"], "Deletion leaves unselected archive entry: " + format.title)
    }
    let sfx = folder.appendingPathComponent("split-sfx.rar")
    var actualSFX = ""
    check(waitBool { done in Ops.compress(items: [noise.path], options: CompressOptions(archivePath: sfx.path, format: .rar5, volumeSize: "10k", sfx: true), host: nil) { ok, path in actualSFX = path; done(ok) } }, "Split SFX creation completes")
    check(fm.fileExists(atPath: actualSFX) && actualSFX.hasSuffix(".sfx"), "Split SFX reports its real first executable volume")
    let sfxParts = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("split-sfx.part") }
    check(sfxParts.count > 10 && sfxParts.allSatisfy { Formats.firstVolume($0.path) == actualSFX }, "Later split SFX volumes resolve to the first SFX")
    check(AppDelegate.dedupeVolumes(sfxParts.map { $0.path }).count == 1, "Split SFX appears only once in a batch")
    let sfxInfo = read(URL(fileURLWithPath: actualSFX)), sfxDest = folder.appendingPathComponent("sfx-output")
    check(waitBool { done in Ops.extract(info: sfxInfo, names: nil, dest: sfxDest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Split SFX extracts without executing its module")
    check(try Data(contentsOf: sfxDest.appendingPathComponent(noise.lastPathComponent)) == bytes, "Split SFX contents match source")
    let concurrentOutput = folder.appendingPathComponent("concurrent.zip")
    var creations = [Bool]()
    check(waitBool { done in
        for _ in 0..<2 {
            Ops.compress(items: [noise.path], options: CompressOptions(archivePath: concurrentOutput.path), host: nil) { ok, _ in
                creations.append(ok); if creations.count == 2 { done(creations.filter { $0 }.count == 1) }
            }
        }
    }, "Exactly one concurrent creation can publish the same path")
    check(read(concurrentOutput).fileCount == 1, "Concurrent creation retains one complete archive")
    let concurrentInfo = read(concurrentOutput), concurrentDestination = folder.appendingPathComponent("concurrent-output")
    var extractions = [Bool]()
    check(waitBool { done in
        for _ in 0..<2 {
            Ops.extract(info: concurrentInfo, names: nil, dest: concurrentDestination.path, password: nil, host: nil, quiet: true) { ok, _ in
                extractions.append(ok); if extractions.count == 2 { done(extractions.filter { $0 }.count == 1) }
            }
        }
    }, "Same-destination concurrent extraction is refused")
    check(try Data(contentsOf: concurrentDestination.appendingPathComponent(noise.lastPathComponent)) == bytes, "Concurrent extraction retains correct content")
    let cancelledSource = input.appendingPathComponent("cancel.bin"), cancelledArchive = folder.appendingPathComponent("cancel.rar")
    var large = Data(count: 16 * 1024 * 1024); large.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
    try large.write(to: cancelledSource)
    var cancelledDuringEngine = false
    check(!waitBool { done in
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
            if (try? fm.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".macrarplus-create-") }) == true {
                cancelledDuringEngine = true; timer?.invalidate(); TaskCenter.shared.cancelAll()
            }
        }
        Ops.compress(items: [cancelledSource.path], options: CompressOptions(archivePath: cancelledArchive.path, format: .rar5), host: nil) { ok, _ in timer?.invalidate(); done(ok) }
    }, "Cancelling production creation stops the engine")
    check(cancelledDuringEngine && !fm.fileExists(atPath: cancelledArchive.path), "Cancelled creation never publishes a partial archive")
    check(try Data(contentsOf: cancelledSource) == large, "Cancelled creation retains every source byte")
    let sourceSnapshot = try ContentRevision.read(editor.appendingPathComponent("document.txt")), freshBaseline = read(archive)
    try write("new external editor contents", editor.appendingPathComponent("document.txt"))
    check(!waitBool { done in Ops.saveEdited(info: freshBaseline, relativePath: "document.txt", directory: editor.path, password: nil, host: nil, sourceExpectedRevision: sourceSnapshot, completion: done) }, "Editor change between confirmation and engine preparation is refused")
    check(try Data(contentsOf: archive) == replacementBytes, "Late editor change preserves the existing archive")
    check(!(try fm.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".macrarplus-") }, "Consolidated operations leave no private transaction folders")
}
