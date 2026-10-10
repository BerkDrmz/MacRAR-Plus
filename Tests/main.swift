import AppKit
import Foundation

setbuf(stdout, nil)
setenv("MACRAR_DEBUG_NONINTERACTIVE", "1", 1)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var checks = 0
func check(_ condition: Bool, _ name: String) {
    guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1; print("PASS: \(name)")
}
func list(_ name: String, password: String? = nil) -> ArchiveInfo {
    switch RarRunner.list(root.appendingPathComponent(name).path, password: password) {
    case .ok(let info): return info
    default: fputs("FAIL: listing \(name)\n", stderr); exit(1)
    }
}
func rejects(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
func waitResult(_ start: (@escaping (RarResult) -> Void) -> Void) -> RarResult {
    var result: RarResult?
    start { result = $0 }
    let deadline = Date().addingTimeInterval(20)
    while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    guard let result else { fputs("FAIL: async operation timed out\n",stderr); exit(1) }
    return result
}
func waitBool(_ start: (@escaping (Bool) -> Void) -> Void) -> Bool {
    var result: Bool?
    start { result = $0 }
    let deadline = Date().addingTimeInterval(20)
    while result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    guard let result else { fputs("FAIL: operation timed out\n",stderr); exit(1) }
    return result
}
var zip = list("Design Kit.zip")
check(zip.fileCount == 8, "ZIP file count including Unicode and hidden files")
check(zip.entries.contains { $0.name.contains("Başlangıç") }, "Unicode filenames survive listing")
check(zip.entries.contains { $0.name.hasSuffix("empty") && $0.isDirectory }, "Empty directory survives listing")
check(FileCategory.documents.matches(ArchiveEntry(name: "nested/a.PDF", isDirectory: false)), "Document category is case insensitive")
check(FileCategory.images.matches(ArchiveEntry(name: "a.heic", isDirectory: false)), "HEIC image category")
check(!FileCategory.code.matches(ArchiveEntry(name: "folder.json", isDirectory: true)), "Category excludes directories")
check(rejects { try ArchiveSafety.validateEntries(list("traversal.zip").entries) }, "Traversal archive is rejected")
check(rejects { try ArchiveSafety.validateEntries(list("absolute.zip").entries) }, "Absolute archive path is rejected")
check(rejects { try ArchiveSafety.validateEntries(list("link.zip").entries) }, "ZIP symbolic link is rejected")
check(rejects { try ArchiveSafety.validateEntries(list("links.tar").entries) }, "TAR symbolic link is rejected")
check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "C:\\bad.txt", isDirectory: false)]) }, "Windows drive path is rejected")
check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "a/../../escape", isDirectory: false)]) }, "Nested traversal is rejected")
check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "file", isDirectory: false, size: -1)]) }, "Negative size is rejected")
check(rejects { try ArchiveSafety.validateEntries([ArchiveEntry(name: "a", isDirectory: false, size: Int64.max), ArchiveEntry(name: "b", isDirectory: false, size: 1)]) }, "Size overflow is rejected")
if case .error = RarRunner.list(root.appendingPathComponent("broken.zip").path, password: nil) { check(true, "Corrupt ZIP fails listing") } else { check(false, "Corrupt ZIP fails listing") }
let tar = list("bundle.tar.gz")
check(tar.fileCount == zip.fileCount, "Two-stage TAR.GZ listing")
let failedPipeline = RarRunner.runStages(RarRunner.listStages(root.appendingPathComponent("broken.tar.gz").path, password: nil))
check(!failedPipeline.ok, "Upstream decompression failure is propagated")
let asyncFail = waitResult { done in RarJob().start(stages: RarRunner.listStages(root.appendingPathComponent("broken.tar.gz").path, password: nil), completion: done) }
check(!asyncFail.ok, "Async pipeline propagates upstream failure")
let selected = root.appendingPathComponent("selected")
try fm.createDirectory(at: selected, withIntermediateDirectories: true)
let selectedResult = RarRunner.runStages(Ops.extractStages(info: zip, names: ["Design Kit/literal[1].txt"], dest: selected.path, password: nil, mode: .overwrite))
check(selectedResult.ok, "Selected extraction succeeds")
check(fm.fileExists(atPath: selected.appendingPathComponent("Design Kit/literal[1].txt").path), "Literal wildcard filename extracts")
check(!fm.fileExists(atPath: selected.appendingPathComponent("Design Kit/literal1.txt").path), "Wildcard does not select unrelated file")
let dest = root.appendingPathComponent("safe-output")
let fullExtract = waitBool { done in Ops.extract(info: zip, names: nil, dest: dest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }
check(fullExtract, "Production staged extraction succeeds")
let sourceBytes = try Data(contentsOf: root.appendingPathComponent("Design Kit/Documents/Başlangıç rehberi.md"))
let outputBytes = try Data(contentsOf: dest.appendingPathComponent("Design Kit/Documents/Başlangıç rehberi.md"))
check(sourceBytes == outputBytes, "Extracted Unicode file contents match source")
check(!(try fm.contentsOfDirectory(atPath: dest.path)).contains { $0.hasPrefix(".macrarplus-stage") }, "Staging cleaned up after extraction")
let outside = root.appendingPathComponent("outside")
try fm.createDirectory(at: outside, withIntermediateDirectories: true)
let linked = root.appendingPathComponent("linked-destination")
try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
check(rejects { try ArchiveSafety.validateDestination(linked.path, entries: zip.entries) }, "Destination symlink is rejected")
let merge = root.appendingPathComponent("merge")
let stage = root.appendingPathComponent("stage")
try fm.createDirectory(at: merge, withIntermediateDirectories: true)
try fm.createDirectory(at: stage, withIntermediateDirectories: true)
try "old".write(to: merge.appendingPathComponent("item.txt"), atomically: true, encoding: .utf8)
try "new".write(to: stage.appendingPathComponent("item.txt"), atomically: true, encoding: .utf8)
try ArchiveSafety.commit(staging: stage, destination: merge, rename: false)
check(try String(contentsOf: merge.appendingPathComponent("item.txt"), encoding: .utf8) == "new", "Overwrite replaces only colliding file")
try "renamed".write(to: stage.appendingPathComponent("item.txt"), atomically: true, encoding: .utf8)
try ArchiveSafety.commit(staging: stage, destination: merge, rename: true)
check(try String(contentsOf: merge.appendingPathComponent("item 2.txt"), encoding: .utf8) == "renamed", "Rename preserves both files")
check(try String(contentsOf: merge.appendingPathComponent("item.txt"), encoding: .utf8) == "new", "Original retained in rename mode")
try fm.createSymbolicLink(at: stage.appendingPathComponent("link"), withDestinationURL: outside)
check(rejects { try ArchiveSafety.validateStaging(stage) }, "Unexpected engine-created symlink is rejected")
let encrypted = root.appendingPathComponent("secret.7z")
let secretArgs = ["a", "-t7z", "-mhe=on", "-ptest-secret", "--", encrypted.path, "Design Kit"]
check(RarRunner.run(.sevenZip, secretArgs, cwd: root.path).ok, "Create encrypted 7z with encrypted headers")
if case .wrongPassword = RarRunner.list(encrypted.path, password: nil) { check(true, "Encrypted headers require password") } else { check(false, "Encrypted headers require password") }
check(list("secret.7z", password: "test-secret").fileCount == 8, "Encrypted 7z opens with correct password")
let rar = root.appendingPathComponent("test.rar")
check(RarRunner.run(.rar, ["a", "-ep1", "-r", "--", rar.path, root.appendingPathComponent("Design Kit").path]).ok, "Create RAR")
check(list("test.rar").fileCount == 8, "RAR listing parity")
check(!list("test.rar").hasEncryptedFiles, "Passwordless RAR stays unencrypted")
let rarOutput = root.appendingPathComponent("rar-output")
check(waitBool { done in Ops.extract(info: list("test.rar"), names: nil, dest: rarOutput.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Production RAR staged extraction")
let seven = root.appendingPathComponent("split.7z")
check(RarRunner.run(.sevenZip, ["a", "-t7z", "-v1k", "--", seven.path, "Design Kit"], cwd: root.path).ok, "Create split 7z")
check(list("split.7z.001").fileCount == 8, "Split 7z listing")
check(AppDelegate.dedupeVolumes(["/a/x.part02.rar", "/a/x.part01.rar", "/a/y.7z.002", "/a/y.7z.001"]).count == 2, "Multi-volume batch deduplication")
check(Formats.firstVolume(root.appendingPathComponent("split.7z.002").path).hasSuffix(".001"), "Later split volume resolves to the first volume")
check(AppDelegate.dedupeVolumes(["/a/x.7z.001", "/a/x.zip.001"]).count == 2, "Different split formats never collapse into one queue item")
let extra = root.appendingPathComponent("added.txt")
try "added".write(to: extra, atomically: true, encoding: .utf8)
check(waitBool { done in Ops.add(info: zip, items: [extra.path], password: nil, host: nil) { ok, _ in done(ok) } }, "Transactional ZIP add")
check(list("Design Kit.zip").entries.contains { $0.name.hasSuffix("added.txt") }, "Added entry is present")
check(waitBool { done in Ops.delete(info: list("Design Kit.zip"), names: ["added.txt"], password: nil, host: nil) { ok, _ in done(ok) } }, "Transactional ZIP delete")
check(!list("Design Kit.zip").entries.contains { $0.name.hasSuffix("added.txt") }, "Deleted entry is absent")
zip = list("Design Kit.zip")
let cancelledJob = RarJob()
let cancelResult = waitResult { done in
    cancelledJob.start(.sevenZip, ["b", "-mmt1"], completion: done)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { cancelledJob.cancel() }
}
check(cancelResult.cancelled, "Running process cancellation completes")
let options = CompressOptions(archivePath: "/tmp/test.tar.gz", format: .tgz, deleteAfter: true)
check(!options.buildSteps(items: ["/tmp/input"]).flatMap { $0.args }.contains("-sdel"), "Sources cannot be deleted before final compression succeeds")
check(CompressOptions(archivePath: "test.zip").format == .zip, "Free ZIP is the default creation format")
// Exercise every offered creation format through the production path.
for format in ArchiveFormat.allCases {
    let path = root.appendingPathComponent("created." + format.ext).path
    let opts = CompressOptions(archivePath: path, format: format)
    check(waitBool { done in Ops.compress(items: [root.appendingPathComponent("Design Kit").path], options: opts, host: nil) { ok, _ in done(ok) } }, "Production creation: " + format.title)
    check(list("created." + format.ext).fileCount == 8, "Created archive contents: " + format.title)
}
let previewDest = FileManager.default.temporaryDirectory.appendingPathComponent("macrarplus-test-\(UUID().uuidString)")
do { try ArchiveSafety.validateDestination(previewDest.path, entries: zip.entries); check(true, "macOS system /var alias is accepted") } catch { print(error.localizedDescription); check(false, "macOS system /var alias is accepted") }
check(waitBool { done in Ops.extract(info: zip, names: ["Design Kit/Documents/Product brief.txt"], dest: previewDest.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Production extraction into macOS preview cache")
try? fm.removeItem(at: previewDest)
let encryptedZIP = root.appendingPathComponent("encrypted.zip")
let zipOptions = CompressOptions(archivePath: encryptedZIP.path, format: .zip, password: "test-secret")
check(waitBool { done in Ops.compress(items: [root.appendingPathComponent("Design Kit").path], options: zipOptions, host: nil) { ok, _ in done(ok) } }, "Production AES ZIP creation")
let encryptedZipInfo = list("encrypted.zip", password: "test-secret")
check(encryptedZipInfo.hasEncryptedFiles, "ZIP encryption metadata is present")
check(waitBool { done in Ops.extract(info: encryptedZipInfo, names: nil, dest: root.appendingPathComponent("encrypted-output").path, password: "test-secret", host: nil, quiet: true) { ok, _ in done(ok) } }, "Production encrypted ZIP extraction")
let batch = BatchModel()
batch.destination = root.appendingPathComponent("batch-output").path
batch.add([root.appendingPathComponent("Design Kit.zip").path, root.appendingPathComponent("test.rar").path])
check(waitBool { done in
    batch.start()
    let observer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        if !batch.running { timer.invalidate(); done(batch.items.allSatisfy { $0.success == true }) }
    }
    RunLoop.main.add(observer, forMode: .common)
}, "Batch extracts ZIP and RAR sequentially")
check(batch.finishedCount == 2, "Batch completion count")
check(batch.items[0].destination != batch.items[1].destination, "Batch destinations are separate folders")
batch.testing = true
check(waitBool { done in
    batch.start()
    let observer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        if !batch.running { timer.invalidate(); done(batch.items.allSatisfy { $0.success == true }) }
    }
    RunLoop.main.add(observer, forMode: .common)
}, "Batch tests integrity without success dialogs")
let stopped = BatchModel(); stopped.add([root.appendingPathComponent("Design Kit.zip").path])
check(waitBool { done in
    stopped.start(); stopped.stopRequested = true
    let observer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        if !stopped.running { timer.invalidate(); done(stopped.finishedCount == 0) }
    }
    RunLoop.main.add(observer, forMode: .common)
}, "Stopping queue prevents pending extraction")
// Regressions found by the detailed archive audit.
let edge = root.appendingPathComponent("edge")
try fm.createDirectory(at: edge, withIntermediateDirectories: true)
let spaceFile = edge.appendingPathComponent("trailing.txt ")
try "space".write(to: spaceFile, atomically: true, encoding: .utf8)
let spaceZIP = edge.appendingPathComponent("spaces.zip")
check(RarRunner.run(.sevenZip, ["a", "-tzip", "--", spaceZIP.path, spaceFile.path]).ok, "Create trailing-space fixture")
guard case .ok(let spaceInfo) = RarRunner.list(spaceZIP.path, password: nil) else { fatalError() }
check(spaceInfo.entries.first?.name == "trailing.txt ", "Listing preserves trailing-space ZIP name")
check(waitBool { done in Ops.extract(info: spaceInfo, names: ["trailing.txt "], dest: edge.appendingPathComponent("space-out").path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Selected trailing-space extraction succeeds")
check(fm.fileExists(atPath: edge.appendingPathComponent("space-out/trailing.txt ").path), "Selected extraction creates the actual trailing-space file")
let unreadable = edge.appendingPathComponent("unreadable.txt")
try "protected".write(to: unreadable, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
check(!waitBool { done in Ops.compress(items: [spaceFile.path, unreadable.path], options: CompressOptions(archivePath: edge.appendingPathComponent("incomplete.zip").path), host: nil) { ok, _ in done(ok) } }, "Compression warning is never classified as complete success")
try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
check(fm.fileExists(atPath: unreadable.path), "Incomplete compression retains source files")
let wildFile = edge.appendingPathComponent("literal*.txt")
let unrelated = edge.appendingPathComponent("literalABC.txt")
try "selected".write(to: wildFile, atomically: true, encoding: .utf8)
try "retain".write(to: unrelated, atomically: true, encoding: .utf8)
let wildRAR = edge.appendingPathComponent("wild.rar")
check(RarRunner.run(.rar, ["a", "-ep1", "--", wildRAR.path, wildFile.path, unrelated.path]).ok, "Create wildcard RAR fixture")
guard case .ok(let wildInfo) = RarRunner.list(wildRAR.path, password: nil) else { fatalError() }
let originalRARBytes = try Data(contentsOf: wildRAR)
check(!waitBool { done in Ops.delete(info: wildInfo, names: ["literal*.txt"], password: nil, host: nil) { ok, _ in done(ok) } }, "RAR wildcard deletion is safely refused")
check(try Data(contentsOf: wildRAR) == originalRARBytes, "RAR wildcard refusal preserves original bytes")
let missing = edge.appendingPathComponent("missing")
let oldDestination = edge.appendingPathComponent("old.txt")
try "old contents".write(to: oldDestination, atomically: true, encoding: .utf8)
check(rejects { try ArchiveSafety.place(source: missing, destination: oldDestination) }, "Missing replacement source fails")
check(try String(contentsOf: oldDestination) == "old contents", "Failed replacement retains destination content")
let newExecutable = edge.appendingPathComponent("new.sh")
try "#!/bin/sh\necho new".write(to: newExecutable, atomically: true, encoding: .utf8)
try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: newExecutable.path)
try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: oldDestination.path)
try ArchiveSafety.place(source: newExecutable, destination: oldDestination)
check((try fm.attributesOfItem(atPath: oldDestination.path))[.posixPermissions] as? NSNumber == 0o755, "Extraction replacement uses new executable permissions")
let manifest = try SourceManifest.collect([spaceFile.path])
try manifest.verify(items: [spaceFile.path], archive: spaceInfo)
check(true, "Source manifest verifies complete matching archive")
try "changed".write(to: spaceFile, atomically: true, encoding: .utf8)
check(rejects { try manifest.verify(items: [spaceFile.path], archive: spaceInfo) }, "Changed source prevents automatic deletion")
let emptyInfo = ArchiveInfo(path: spaceZIP.path, kind: .other, details: "zip", entries: [])
check(rejects { try manifest.verify(items: [spaceFile.path], archive: emptyInfo) }, "Missing archive entries prevent source deletion")
// SFX needs its module adjacent to the standalone test runner, just like the bundle.
try? fm.removeItem(at: RarRunner.resourceDir.appendingPathComponent("default.sfx"))
try fm.copyItem(at: root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/default.sfx"), to: RarRunner.resourceDir.appendingPathComponent("default.sfx"))
let sfxPath = edge.appendingPathComponent("created-sfx.rar").path
check(waitBool { done in Ops.compress(items: [unreadable.path], options: CompressOptions(archivePath: sfxPath, format: .rar5, sfx: true), host: nil) { ok, actual in check(actual.hasSuffix(".sfx"), "SFX completion reports actual output path"); done(ok) } }, "SFX creation uses bundled module")
check(Formats.isArchive(edge.appendingPathComponent("created-sfx.sfx").path), "SFX is recognized as an archive")
check({ if case .ok = RarRunner.list(edge.appendingPathComponent("created-sfx.sfx").path, password: nil) { return true }; return false }(), "SFX can be listed without executing it")
let query = ArchiveQuery("brief ext:txt size>10B size<1MB after:2026-01-01")
check(query.matches(path: "docs/brief.txt", size: 20, modified: "2026-10-09 12:00:00", directory: false), "Advanced search combines path type size and date")
check(!query.matches(path: "docs/brief.pdf", size: 20, modified: "2026-10-09", directory: false), "Advanced search excludes a different extension")
let skipStage = edge.appendingPathComponent("skip-stage"), skipDest = edge.appendingPathComponent("skip-dest")
try fm.createDirectory(at: skipStage, withIntermediateDirectories: true)
try fm.createDirectory(at: skipDest, withIntermediateDirectories: true)
try "old".write(to: skipDest.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try "new".write(to: skipStage.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
try "add".write(to: skipStage.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
try ArchiveSafety.commit(staging: skipStage, destination: skipDest, rename: false, policies: ["a.txt": .skip])
check(try String(contentsOf: skipDest.appendingPathComponent("a.txt")) == "old", "Per-file skip retains original")
check(try String(contentsOf: skipDest.appendingPathComponent("b.txt")) == "add", "Per-file skip still extracts noncolliding files")
let editZIP = edge.appendingPathComponent("edit.zip")
try fm.copyItem(at: root.appendingPathComponent("Design Kit.zip"), to: editZIP)
guard case .ok(let editInfo) = RarRunner.list(editZIP.path, password: nil) else { fatalError() }
let relative = "Design Kit/Documents/Product brief.txt"
let editRoot = edge.appendingPathComponent("edit-root")
check(waitBool { done in Ops.extract(info: editInfo, names: [relative], dest: editRoot.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Prepare external edit preserving nested path")
let editedContent = "Edited content at original nested path"
try editedContent.write(to: editRoot.appendingPathComponent(relative), atomically: true, encoding: .utf8)
check(waitBool { done in Ops.saveEdited(info: editInfo, relativePath: relative, directory: editRoot.path, password: nil, host: nil, completion: done) }, "Save edited file to original nested archive path")
guard case .ok(let afterEdit) = RarRunner.list(editZIP.path, password: nil) else { fatalError() }
let updated = edge.appendingPathComponent("verify-edit")
check(waitBool { done in Ops.extract(info: afterEdit, names: [relative], dest: updated.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) } }, "Re-extract edited file")
check(try String(contentsOf: updated.appendingPathComponent(relative)) == editedContent, "Archived edited content matches external edit")
let newName = "Design Kit/Documents/Renamed brief.txt"
check(waitBool { done in Ops.rename(info: afterEdit, old: relative, new: newName, password: nil, host: nil, completion: done) }, "Transactional ZIP rename")
guard case .ok(let renamed) = RarRunner.list(editZIP.path, password: nil) else { fatalError() }
check(renamed.entries.contains { $0.name == newName } && !renamed.entries.contains { $0.name == relative }, "Rename changes only selected archive path")
let beforeRetry = batch.items[0].destination
batch.items[1].success = false
check(waitBool { done in
    batch.retryFailed()
    let observer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
        if !batch.running { timer.invalidate(); done(batch.items.allSatisfy { $0.success == true }) }
    }
    RunLoop.main.add(observer, forMode: .common)
}, "Batch retries only failed entries")
check(batch.items[0].destination == beforeRetry, "Batch retry retains successful entry result")
let savedEnergy = EnergyPolicy.mode; EnergyPolicy.mode = .economy
check(EnergyPolicy.threads == 1, "Energy saver caps engine threads at one")
check(RarRunner.makeProcess(.sevenZip, ["a", "-t7z", "--", "/tmp/out.7z", "/tmp/input"], cwd: nil).arguments?.contains("-mmt=1") == true, "7zip process uses energy thread limit")
check(RarRunner.makeProcess(.rar, ["a", "--", "/tmp/out.rar", "/tmp/input"], cwd: nil).arguments?.contains("-mt1") == true, "RAR process uses energy thread limit")
EnergyPolicy.mode = savedEnergy
check(rejects { try ArchiveSafety.validateSelection(zip, names: ["does-not-exist.txt"]) }, "Missing selected paths are rejected before extraction")
check(rejects { try ArchiveSafety.validateSelection(zip, names: []) }, "Empty selection does not falsely report success")
let rootLink = edge.appendingPathComponent("source-link")
try fm.createSymbolicLink(at: rootLink, withDestinationURL: edge.appendingPathComponent("sources"))
check(rejects { _ = try SourceManifest.collect([rootLink.path]) }, "Source root symlink is refused for automatic deletion")
let preCancelled = RarJob(); preCancelled.cancel()
check(waitResult { done in preCancelled.start(.sevenZip, ["b"], completion: done) }.cancelled, "Pre-cancelled engine job never starts")
let cancelledListing = TaskCancellation(); cancelledListing.cancel()
check(waitBool { done in Ops.listAsync(archive: zip.path, password: nil, cancellation: cancelledListing) { info, _ in done(info == nil) } }, "Pre-cancelled listing returns without launching")
let revisionURL = edge.appendingPathComponent("revision.txt")
try "first".write(to: revisionURL, atomically: true, encoding: .utf8)
let revision = try FileRevision.read(revisionURL)
try "second value".write(to: revisionURL, atomically: true, encoding: .utf8)
check(try FileRevision.read(revisionURL) != revision, "File revision detects external modification")
let aliasSource = fm.temporaryDirectory.appendingPathComponent("macrarplus-manifest-\(UUID().uuidString)")
try fm.createDirectory(at: aliasSource.appendingPathComponent("empty"), withIntermediateDirectories: true)
try "bytes".write(to: aliasSource.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
let aliasManifest = try SourceManifest.collect([aliasSource.path])
check(aliasManifest.archiveSizes[aliasSource.lastPathComponent + "/a.txt"] == 5, "Source manifest preserves paths through macOS temporary aliases")
let aliasEntries = [ArchiveEntry(name: aliasSource.lastPathComponent, isDirectory: true), ArchiveEntry(name: aliasSource.lastPathComponent + "/empty", isDirectory: true), ArchiveEntry(name: aliasSource.lastPathComponent + "/a.txt", isDirectory: false, size: 5)]
let aliasInfo = ArchiveInfo(path: "/tmp/alias.zip", kind: .other, details: "zip", entries: aliasEntries)
try aliasManifest.verify(items: [aliasSource.path], archive: aliasInfo)
check(true, "Source manifest verifies empty directories as well as files")
let missingDirectory = ArchiveInfo(path: "/tmp/alias.zip", kind: .other, details: "zip", entries: Array(aliasEntries.suffix(1)))
check(rejects { try aliasManifest.verify(items: [aliasSource.path], archive: missingDirectory) }, "Missing archived empty directory prevents source deletion")
try fm.removeItem(at: aliasSource)
let externalZIP = edge.appendingPathComponent("external-change.zip")
try fm.copyItem(at: URL(fileURLWithPath: zip.path), to: externalZIP)
guard case .ok(let externalInfo) = RarRunner.list(externalZIP.path, password: nil) else { fatalError() }
let noise = edge.appendingPathComponent("noise.bin")
var noiseData = Data(count: 32 * 1024 * 1024)
noiseData.withUnsafeMutableBytes { bytes in arc4random_buf(bytes.baseAddress!, bytes.count) }
try noiseData.write(to: noise); noiseData = Data()
let externalBytes = try Data(contentsOf: externalZIP) + Data("External change must survive".utf8)
check(!waitBool { done in
    Ops.add(info: externalInfo, items: [noise.path], password: nil, host: nil) { ok, _ in done(ok) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { try! externalBytes.write(to: externalZIP, options: .atomic) }
}, "External archive modification prevents committing the stale copy")
check(try Data(contentsOf: externalZIP) == externalBytes, "External archive bytes survive rejected commit")
let concurrentZIP = edge.appendingPathComponent("concurrent-edit.zip")
try fm.copyItem(at: URL(fileURLWithPath: zip.path), to: concurrentZIP)
guard case .ok(let concurrentInfo) = RarRunner.list(concurrentZIP.path, password: nil) else { fatalError() }
let originalConcurrent = try Data(contentsOf: concurrentZIP)
let concurrentRoot = edge.appendingPathComponent("concurrent-editor")
let concurrentFile = concurrentRoot.appendingPathComponent(relative)
try fm.createDirectory(at: concurrentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
try fm.copyItem(at: noise, to: concurrentFile)
check(!waitBool { done in
    Ops.saveEdited(info: concurrentInfo, relativePath: relative, directory: concurrentRoot.path, password: nil, host: nil, completion: done)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { try! "New external edit".write(to: concurrentFile, atomically: true, encoding: .utf8) }
}, "External editor modification during save rejects stale archive commit")
check(try Data(contentsOf: concurrentZIP) == originalConcurrent, "Concurrent editor save preserves original archive")
try fm.removeItem(at: noise)
EnergyPolicy.mode = .economy
check(RarRunner.makeProcess(.sevenZip, ["a", "-t7z", "--", "/tmp/out.7z"], cwd: nil).arguments?.contains("-m0=LZMA2:d=16m") == true, "Energy saver limits 7z compression dictionary")
check(RarRunner.makeProcess(.rar, ["a", "--", "/tmp/out.rar"], cwd: nil).arguments?.contains("-md16m") == true, "Energy saver limits RAR compression dictionary")
EnergyPolicy.mode = savedEnergy
try runDeepRegressions(root: root)
try runConsolidatedRegressions(root: root)
try runFinalAuditRegressions(root: root)
try runWorkspaceFeatureRegressions(root: root)
check(!TaskCenter.shared.hasActiveTasks, "No processing tasks remain after completion")
print("\n\(checks) checks passed")
