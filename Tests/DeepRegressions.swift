import AppKit

func runDeepRegressions(root: URL) throws {
    let fm = FileManager.default
    let folder = root.appendingPathComponent("deep-regressions")
    let inputs = folder.appendingPathComponent("inputs")
    try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
    func read(_ url: URL, password: String? = nil) -> ArchiveInfo {
        guard case .ok(let info) = RarRunner.list(url.path, password: password) else { fatalError("Cannot list \(url)") }
        return info
    }
    func write(_ text: String, _ url: URL) throws { try text.write(to: url, atomically: true, encoding: .utf8) }
    let star = inputs.appendingPathComponent("literal*.txt"), question = inputs.appendingPathComponent("literal?.txt")
    let unrelated = inputs.appendingPathComponent("literalABC.txt"), seed = inputs.appendingPathComponent("seed.txt")
    try write("selected star", star); try write("selected question", question)
    try write("private unselected content", unrelated); try write("seed", seed)
    for format in ArchiveFormat.allCases where format != .rar5 {
        let output = folder.appendingPathComponent("literal." + format.ext)
        check(waitBool { done in Ops.compress(items: [star.path, question.path], options: CompressOptions(archivePath: output.path, format: format), host: nil) { ok, _ in done(ok) } }, "Literal creation: " + format.title)
        check(Set(read(output).entries.filter { !$0.isDirectory }.map { $0.name }) == Set([star.lastPathComponent, question.lastPathComponent]), "Only selected wildcard-named files archived: " + format.title)
    }
    let refused = folder.appendingPathComponent("refused.rar")
    check(!waitBool { done in Ops.compress(items: [star.path], options: CompressOptions(archivePath: refused.path, format: .rar5), host: nil) { ok, _ in done(ok) } }, "RAR literal wildcard creation is refused before engine work")
    check(!fm.fileExists(atPath: refused.path), "RAR refusal creates no archive")
    for ext in ["zip", "7z", "tar", "rar"] {
        let output = folder.appendingPathComponent("add." + ext)
        let tool: RarTool = ext == "rar" ? .rar : .sevenZip
        check(RarRunner.run(tool, ["a", "--", output.path, seed.path]).ok, "Create add regression: " + ext)
        let info = read(output), before = try Data(contentsOf: output)
        let added = waitBool { done in Ops.add(info: info, items: [star.path], password: nil, host: nil) { ok, _ in done(ok) } }
        if ext == "rar" {
            check(try !added && Data(contentsOf: output) == before, "RAR wildcard addition safely retains archive bytes")
        } else {
            check(added && Set(read(output).entries.map { $0.name }) == Set([seed.lastPathComponent, star.lastPathComponent]), "Literal addition excludes unselected files: " + ext)
        }
    }
    for name in ["Wrong password.txt", "Incorrect password.txt", "Enter password.txt", "Cannot open the file as archive.txt"] {
        let source = inputs.appendingPathComponent(name), output = folder.appendingPathComponent(UUID().uuidString + ".zip")
        try write("no password", source)
        check(RarRunner.run(.sevenZip, ["a", "-spd", "--", output.path, source.path]).ok, "Create password-phrase filename fixture")
        check(read(output).entries.first?.name == name, "Successful listing is not classified from filename: " + name)
        check(waitBool { done in Ops.listAsync(archive: output.path, password: nil) { info, _ in done(info?.entries.first?.name == name) } }, "Async listing accepts password-phrase filename")
        check(waitBool { done in Ops.extract(info: read(output), names: nil, dest: folder.appendingPathComponent(UUID().uuidString).path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Extraction accepts password-phrase filename")
    }
    check(RarResult(code: 11, output: "Incorrect password").wrongPassword, "Real password failure remains recognized")
    check(RarResult(code: 2, output: "ERROR: Wrong password : secret.txt").wrongPassword, "7zip password diagnostic remains recognized")
    check(RarResult(code: 255, output: "Enter password:\nBreak signaled").wrongPassword, "7zip password prompt without input remains recognized")
    check(!RarResult(code: 2, output: "Path = Wrong password.txt\nERROR: CRC Failed").wrongPassword, "Failed CRC with a password-phrase filename is not a password failure")
    for nested in [false, true] {
        let stage = folder.appendingPathComponent("rename-stage-\(nested)"), dest = folder.appendingPathComponent("rename-dest-\(nested)")
        let suffix = nested ? "nested" : ""
        let source = stage.appendingPathComponent(suffix), target = dest.appendingPathComponent(suffix)
        try fm.createDirectory(at: source, withIntermediateDirectories: true); try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try write("old target", target.appendingPathComponent("item"))
        try write("incoming A", source.appendingPathComponent("item")); try write("incoming B", source.appendingPathComponent("item 2"))
        try ArchiveSafety.commit(staging: stage, destination: dest, rename: false, policies: [nested ? "nested/item" : "item": .rename])
        check(try String(contentsOf: target.appendingPathComponent("item")) == "old target", "Rename retains existing file, nested=\(nested)")
        check(try String(contentsOf: target.appendingPathComponent("item 2")) == "incoming B", "Rename retains other incoming file, nested=\(nested)")
        check(try String(contentsOf: target.appendingPathComponent("item 3")) == "incoming A", "Rename reserves all incoming names, nested=\(nested)")
    }
    for name in ["plain.tar", "dot.tar", "dot.tar.gz"] {
        let archive = read(root.appendingPathComponent(name)), dest = folder.appendingPathComponent(name + "-out")
        check(waitBool { done in Ops.extract(info: archive, names: nil, dest: dest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Normal TAR root and empty link metadata: " + name)
        check(try String(contentsOf: dest.appendingPathComponent("a.txt")) == "tar data", "TAR normalized file content: " + name)
    }
    let dotInfo = read(root.appendingPathComponent("dot.tar"))
    check(waitBool { done in Ops.extract(info: dotInfo, names: ["./a.txt"], dest: folder.appendingPathComponent("dot-selected").path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Selected ./ TAR path extracts literally")
    check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "./../escape", isDirectory: false)]) }, "TAR canonicalization keeps traversal blocked")
    check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: ".", isDirectory: false)]) }, "Root alias cannot be a regular file")
    for encrypted in [false, true] {
        let output = folder.appendingPathComponent("last-\(encrypted).rar"), pw: String? = encrypted ? "last-secret" : nil
        let args = ["a", "-ep1", "-y"] + RarRunner.passwordArgs(pw, encryptHeaders: encrypted) + ["--", output.path, seed.path]
        check(RarRunner.run(.rar, args).ok, "Create last-entry RAR, encrypted=\(encrypted)")
        let before = read(output, password: pw)
        check(waitBool { done in Ops.delete(info: before, names: [seed.lastPathComponent], password: pw, host: nil) { ok, _ in done(ok) } }, "Delete last RAR entry, encrypted=\(encrypted)")
        let empty = read(output, password: pw)
        check(fm.fileExists(atPath: output.path) && empty.entries.isEmpty, "Last deletion leaves a valid empty RAR")
        if encrypted {
            if case .wrongPassword = RarRunner.list(output.path, password: nil) { check(true, "Empty RAR retains header encryption") }
            else { check(false, "Empty RAR retains header encryption") }
        }
        check(waitBool { done in Ops.test(info: empty, password: pw, host: nil, quiet: true) { ok, _ in done(ok) } }, "Integrity test accepts empty RAR")
        check(waitBool { done in Ops.add(info: empty, items: [seed.path], password: pw, host: nil) { ok, _ in done(ok) } }, "Empty RAR accepts future additions")
    }
    let source = inputs.appendingPathComponent("manifest.txt"), output = folder.appendingPathComponent("manifest.zip")
    let date = Date(timeIntervalSince1970: 1700000000)
    try write("original bytes", source); try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    let manifest = try SourceManifest.collect([source.path])
    check(RarRunner.run(.sevenZip, ["a", "--", output.path, source.path]).ok, "Create content-validation archive")
    let info = read(output)
    try manifest.verifyArchiveContents(info, password: nil)
    check(true, "Source digest matches actual archived bytes")
    let handle = try FileHandle(forWritingTo: source)
    try handle.write(contentsOf: Data("replaced bytes".utf8)); try handle.close()
    try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    check(rejects { try manifest.verify(items: [source.path], archive: info) }, "Same inode, size and mtime with changed bytes cannot pass cleanup")
    var trashCalled = false
    check(rejects { try manifest.moveVerifiedToTrash(items: [source.path], archive: info, trash: { _ in trashCalled = true }) }, "Changed source is refused before any Trash call")
    check(try !trashCalled && String(contentsOf: source) == "replaced bytes", "Unarchived source remains in place")
    let changedManifest = try SourceManifest.collect([source.path])
    check(rejects { try changedManifest.verifyArchiveContents(info, password: nil) }, "Equal-size archive content mismatch is detected")
    try write("original bytes", source); try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
    let cleanupManifest = try SourceManifest.collect([source.path])
    check(rejects { try cleanupManifest.moveVerifiedToTrash(items: [source.path], archive: info, trash: { _ in throw CocoaError(.fileWriteNoPermission) }) }, "Trash failure propagates")
    check(try String(contentsOf: source) == "original bytes", "Trash failure restores detached source")
    let fakeTrash = folder.appendingPathComponent("simulated-trash.txt")
    try cleanupManifest.moveVerifiedToTrash(items: [source.path], archive: info, trash: { held in
        try write("new file at original path", source)
        try fm.moveItem(at: held, to: fakeTrash)
    })
    check(try String(contentsOf: fakeTrash) == "original bytes", "Verified source is transferred to simulated Trash")
    check(try String(contentsOf: source) == "new file at original path", "Cleanup leaves new files at the original path untouched")
    check(rejects { _ = try SourceManifest.collect([inputs.path, source.path]) }, "Overlapping sources are refused for cleanup")
    let moving = inputs.appendingPathComponent("moving.txt")
    try write("original bytes", moving)
    let movingManifest = try SourceManifest.collect([moving.path])
    let movingInfo = ArchiveInfo(path: "test.zip", kind: .other, details: "zip", entries: [ArchiveEntry(name: moving.lastPathComponent, isDirectory: false, size: 14)])
    let writer = try FileHandle(forWritingTo: moving)
    var changedAfterDetach = false, movingTrashCalled = false
    check(rejects {
        try movingManifest.moveVerifiedToTrash(items: [moving.path], archive: movingInfo, cancelled: {
            if !fm.fileExists(atPath: moving.path), !changedAfterDetach {
                changedAfterDetach = true
                try! writer.write(contentsOf: Data("replaced bytes".utf8))
            }
            return false
        }, trash: { _ in movingTrashCalled = true })
    }, "An open writer changing the detached source prevents Trash")
    try writer.close()
    check(try changedAfterDetach && !movingTrashCalled && String(contentsOf: moving) == "replaced bytes", "Detached source changes are restored intact")
    let tree = inputs.appendingPathComponent("cleanup-tree")
    try fm.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
    try write("nested bytes", tree.appendingPathComponent("file.txt"))
    let treeManifest = try SourceManifest.collect([tree.path])
    let treeInfo = ArchiveInfo(path: "tree.zip", kind: .other, details: "zip", entries: [
        ArchiveEntry(name: "cleanup-tree", isDirectory: true), ArchiveEntry(name: "cleanup-tree/empty", isDirectory: true),
        ArchiveEntry(name: "cleanup-tree/file.txt", isDirectory: false, size: 12)])
    let heldTree = folder.appendingPathComponent("simulated-trash-tree")
    try treeManifest.moveVerifiedToTrash(items: [tree.path], archive: treeInfo, trash: { try fm.moveItem(at: $0, to: heldTree) })
    check(try !fm.fileExists(atPath: tree.path) && String(contentsOf: heldTree.appendingPathComponent("file.txt")) == "nested bytes", "Directory cleanup preserves nested data in simulated Trash")
    check(fm.fileExists(atPath: heldTree.appendingPathComponent("empty").path), "Directory cleanup preserves empty directories")
    let cleanupSource = inputs.appendingPathComponent("production-cleanup-\(UUID().uuidString).txt")
    let cleanupArchive = folder.appendingPathComponent("production-cleanup.zip")
    try write("test-only cleanup bytes", cleanupSource)
    check(waitBool { done in Ops.compress(items: [cleanupSource.path], options: CompressOptions(archivePath: cleanupArchive.path, deleteAfter: true), host: nil) { ok, _ in done(ok) } }, "Production create, content verification and source-to-Trash pipeline")
    check(!fm.fileExists(atPath: cleanupSource.path) && read(cleanupArchive).fileCount == 1, "Production cleanup leaves the complete archive")
    check(!(try fm.contentsOfDirectory(atPath: inputs.path)).contains { $0.hasPrefix(".macrarplus-source-") }, "Source cleanup removes empty quarantine directories")
    let stoppedVerification = TaskCancellation(); stoppedVerification.cancel()
    check(RarRunner.runStages([(.sevenZip, ["b"])], cancellation: stoppedVerification).cancelled, "Pre-cancelled verification never starts an engine")
    // Both before-save changes and consecutive app-owned saves are covered.
    let editArchive = folder.appendingPathComponent("stale-editor.zip"), editor = folder.appendingPathComponent("editor")
    try fm.createDirectory(at: editor, withIntermediateDirectories: true)
    check(RarRunner.run(.sevenZip, ["a", "--", editArchive.path, seed.path]).ok, "Create stale-editor archive")
    let initial = read(editArchive)
    try write("local editor edit", editor.appendingPathComponent(seed.lastPathComponent))
    try write("external newer change", seed)
    check(RarRunner.run(.sevenZip, ["a", "--", editArchive.path, seed.path]).ok, "Externally update archive before save")
    let externalBytes = try Data(contentsOf: editArchive)
    check(!waitBool { done in Ops.saveEdited(info: initial, relativePath: seed.lastPathComponent, directory: editor.path, password: nil, host: nil, completion: done) }, "Before-save external archive change rejects old editor baseline")
    check(try Data(contentsOf: editArchive) == externalBytes, "Before-save conflict preserves exact external archive bytes")
    let fresh = read(editArchive)
    var committed: ArchiveRevision?
    check(waitBool { done in Ops.saveEdited(info: fresh, relativePath: seed.lastPathComponent, directory: editor.path, password: nil, host: nil, didCommit: { committed = $0 }, completion: done) }, "Fresh edit commits with a new baseline")
    check(committed == (try ArchiveRevision.read(editArchive)), "Committed revision matches archive after replacement")
    try write("second app-owned edit", editor.appendingPathComponent(seed.lastPathComponent))
    check(waitBool { done in Ops.saveEdited(info: fresh, relativePath: seed.lastPathComponent, directory: editor.path, password: nil, host: nil, expectedRevision: committed, completion: done) }, "Consecutive edits advance baseline after app-owned commit")
    // Closing the real modal window must end runModal, rather than leaving it hidden.
    let dialog = CompressDialog(options: CompressOptions(archivePath: folder.appendingPathComponent("modal.zip").path), itemCount: 1)
    var timeoutTriggered = false
    let watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in timeoutTriggered = true; NSApp.abortModal() }
    RunLoop.main.add(watchdog, forMode: .modalPanel)
    let close = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in dialog.window?.performClose(nil) }
    RunLoop.main.add(close, forMode: .modalPanel)
    let result = dialog.run()
    watchdog.invalidate(); close.invalidate()
    check(result == nil && !timeoutTriggered && NSApp.modalWindow == nil, "Red close button ends the creation modal immediately")
}
