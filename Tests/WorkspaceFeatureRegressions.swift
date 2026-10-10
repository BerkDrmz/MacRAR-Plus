import Foundation

func runWorkspaceFeatureRegressions(root: URL) throws {
    let selectionEntries = [ArchiveEntry(name: "docs/sub/a.txt", isDirectory: false, size: 3, packedSize: 2),
                            ArchiveEntry(name: "docs-other/b.txt", isDirectory: false, size: 5),
                            ArchiveEntry(name: "docs/empty/", isDirectory: true),
                            ArchiveEntry(name: "literal*.txt", isDirectory: false, size: 7)]
    let selectionTree = Node.buildTree(selectionEntries)
    var selectionNodes: [Node] = []; selectionTree.flatten(into: &selectionNodes)
    let nodeByPath = Dictionary(uniqueKeysWithValues: selectionNodes.map { ($0.path, $0) })
    let selectedNodes = ["docs/sub/a.txt", "docs-other/b.txt", "docs/sub", "docs", "docs/empty", "literal*.txt"].map { nodeByPath[$0]! }
    check(Node.selectionRoots(selectedNodes).map(\.path) == ["docs-other/b.txt", "docs", "literal*.txt"], "Selection coverage preserves order, exact siblings and literal wildcard names")
    check(Node.selectionRoots([nodeByPath["docs/empty"]!]).map(\.path) == ["docs/empty"], "Selection coverage retains an empty folder")
    let leafSelection = selectionNodes.filter { !$0.isDir }
    check(Node.selectionRoots(leafSelection).map(\.path) == leafSelection.map(\.path), "Independent file selections remain unchanged")
    check(Node.selectionRoots([]).isEmpty, "Empty selection stays empty")
    let independentEntries = (0..<10_000).map { ArchiveEntry(name: "folder\($0)/a.txt", isDirectory: false) }
    let independentTree = Node.buildTree(independentEntries)
    var independentNodes: [Node] = []; independentTree.flatten(into: &independentNodes)
    let independentRoots = Node.selectionRoots(independentNodes)
    check(independentRoots.count == 10_000 && independentRoots.allSatisfy(\.isDir), "Large selection includes each selected folder once and excludes descendants")

    var summaryInfo = ArchiveInfo(path: root.appendingPathComponent("Design Kit.zip").path, kind: .other, details: "", entries: selectionEntries)
    let workspace = WorkspaceModel(); workspace.update(summaryInfo)
    check(workspace.archiveFileCount == summaryInfo.fileCount && workspace.archiveTotalSize == summaryInfo.totalSize, "Cached workspace totals match archive metadata")
    check(workspace.archiveStoredSize == summaryInfo.storedSize && !workspace.archiveEncrypted, "Cached disk size and encryption match listing")
    summaryInfo.entries[0].encrypted = true; summaryInfo.entries[0].size = 30
    workspace.update(summaryInfo)
    check(workspace.archiveEncrypted && workspace.archiveTotalSize == summaryInfo.totalSize, "Reload refreshes cached totals and entry encryption")
    summaryInfo.entries = []; summaryInfo.headersEncrypted = true; workspace.update(summaryInfo)
    check(workspace.archiveFileCount == 0 && workspace.archiveTotalSize == 0 && workspace.archiveEncrypted, "Empty encrypted-header archive has correct summary")
    workspace.update(nil)
    check(workspace.info == nil && workspace.archiveFileCount == 0 && workspace.archiveTotalSize == 0 && workspace.archiveStoredSize == 0 && !workspace.archiveEncrypted, "Clearing a listing resets cached summary")

    let selectionSource = root.appendingPathComponent("selection-source.zip")
    let fixture = RarRunner.run(.sevenZip, ["a", "-tzip", "--", selectionSource.path, root.appendingPathComponent("Design Kit").path])
    check(fixture.ok, "Selection compression fixture created")
    guard case .ok(let selectionInfo) = RarRunner.list(selectionSource.path, password: nil) else { fatalError("Selection fixture failed") }
    let sourceBytes = try Data(contentsOf: selectionSource)
    let unicodeName = "Design Kit/Documents/Başlangıç rehberi.md"
    let unicodeDestination = root.appendingPathComponent("unicode-selected-output")
    let unicodeOK = waitBool { done in
        Ops.extract(info: selectionInfo, names: [unicodeName], dest: unicodeDestination.path, password: nil, host: nil, quiet: true) { ok, _ in done(ok) }
    }
    check(unicodeOK, "Selected Unicode archive member extracts through the asynchronous preview path")
    check(try Data(contentsOf: unicodeDestination.appendingPathComponent(unicodeName)) == Data(contentsOf: root.appendingPathComponent(unicodeName)), "Selected Unicode member retains its exact bytes")
    guard case .ok(let unicodeTar) = RarRunner.list(root.appendingPathComponent("bundle.tar.gz").path, password: nil) else { fatalError("Unicode pipeline fixture failed") }
    let tarMember = unicodeTar.entries.first { $0.name.hasSuffix("rehberi.md") }!.name
    let tarOutput = root.appendingPathComponent("unicode-pipeline-output")
    let tarResult = RarRunner.runStages(Ops.extractStages(info: unicodeTar, names: [tarMember], dest: tarOutput.path, password: nil, mode: .overwrite))
    check(tarResult.ok, "Unicode argument bridge preserves piped TAR input")
    try ArchiveSafety.validateExtracted(tarOutput, entries: ArchiveSafety.selectedEntries(unicodeTar, names: [tarMember]))
    check(try Data(contentsOf: tarOutput.appendingPathComponent(tarMember)) == Data(contentsOf: root.appendingPathComponent(unicodeName)), "Unicode pipeline extracts only the requested member with exact bytes")
    let injectionName = "Şifreli \"; $(printf injected); ' literal.txt"
    let unicodeInputs = root.appendingPathComponent("unicode-process-inputs")
    try FileManager.default.createDirectory(at: unicodeInputs, withIntermediateDirectories: true)
    try Data("exact Unicode argument".utf8).write(to: unicodeInputs.appendingPathComponent(injectionName))
    let unicodeArchive = root.appendingPathComponent("unicode-argument.zip")
    let createUnicode = RarRunner.run(.sevenZip, ["a", "-tzip", "--", unicodeArchive.path, unicodeInputs.appendingPathComponent(injectionName).path])
    check(createUnicode.ok, "Unicode process bridge treats shell punctuation as literal input")
    guard case .ok(let unicodeInfo) = RarRunner.list(unicodeArchive.path, password: nil) else { fatalError("Unicode bridge fixture failed") }
    let archivedName = unicodeInfo.entries.first!.name
    check(archivedName == injectionName && unicodeInfo.entries.count == 1, "Unicode source archive contains only the literal requested filename")
    let exactOutput = root.appendingPathComponent("unicode-argument-output")
    let unicodeStages = Ops.extractStages(info: unicodeInfo, names: [archivedName], dest: exactOutput.path, password: nil, mode: .overwrite)
    let exactResult = RarRunner.runStages(unicodeStages)
    check(exactResult.ok && FileManager.default.fileExists(atPath: exactOutput.appendingPathComponent(injectionName).path), "Quoted Unicode member names cross the process boundary unchanged")
    try ArchiveSafety.validateExtracted(exactOutput, entries: unicodeInfo.entries)
    check(try Data(contentsOf: exactOutput.appendingPathComponent(injectionName)) == Data("exact Unicode argument".utf8), "Literal Unicode extraction passes complete path and content checks")
    let unicodePassword = "Şifre-çığ-🗝\n"
    let encryptedArchive = root.appendingPathComponent("unicode-password.7z")
    let encrypt = RarRunner.run(.sevenZip, ["a", "-t7z", "-p" + unicodePassword, "--", encryptedArchive.path, unicodeInputs.appendingPathComponent(injectionName).path])
    check(encrypt.ok, "Unicode password archive created without argument normalization")
    let passwordCheck = RarRunner.run(.sevenZip, ["t", "-p" + unicodePassword, "--", encryptedArchive.path])
    check(passwordCheck.ok, "Exact Unicode password including trailing newline opens the archive")
    check(rejects { try CompressOptions(archivePath: "output.zip", password: "Şifre").validatePassword() }, "Unsupported Unicode ZIP password is rejected before engine work")
    check(rejects { try CompressOptions(archivePath: "output.zip", password: "password\n").validatePassword() }, "Unsupported ZIP password controls are rejected before engine work")
    check(!rejects { try CompressOptions(archivePath: "output.zip", password: "ASCII 123 !@#$%^&*").validatePassword() }, "Printable ASCII ZIP passwords remain supported")
    check(!rejects { try CompressOptions(archivePath: "output.7z", format: .sevenZip, password: unicodePassword).validatePassword() }, "Unicode 7z passwords retain all original characters")
    check(rejects { try CompressOptions(archivePath: "output.7z", format: .sevenZip, password: "prefix\u{0}suffix").validatePassword() }, "Passwords cannot be silently truncated at NUL")
    let names = ["Design Kit/literal[1].txt", "Design Kit/Code/app.swift", "Design Kit/empty"]
    let beforeTemps = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("MacRARPlus-selection-") })
    for format in [ArchiveFormat.zip, .rar5] {
        let destination = root.appendingPathComponent("selected-result." + format.ext)
        var options = CompressOptions(archivePath: destination.path, format: format)
        options.deleteAfter = true // Selection flow must never delete original entries.
        let ok = waitBool { done in
            Ops.compressSelection(info: selectionInfo, names: names, options: options, password: nil, host: nil) { ok, _, _ in done(ok) }
        }
        check(ok, "Selected files recompressed into " + format.ext)
        guard case .ok(let result) = RarRunner.list(destination.path, password: nil) else { fatalError("Recompressed archive unreadable") }
        check(Set(result.entries.filter { !$0.isDirectory }.map(\.name)) == Set(names.prefix(2)), "Recompression preserves paths and excludes wildcard siblings in " + format.ext)
        check(result.entries.contains { $0.isDirectory && $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == names[2] }, "Recompression preserves selected empty folder in " + format.ext)
    }
    let failed = waitBool { done in
        Ops.compressSelection(info: selectionInfo, names: names, options: CompressOptions(archivePath: selectionSource.path), password: nil, host: nil) { ok, _, _ in done(ok) }
    }
    check(!failed, "Recompression rejects replacing its source archive")
    check(try Data(contentsOf: selectionSource) == sourceBytes, "Source archive stays byte-identical after recompression")
    let afterTemps = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("MacRARPlus-selection-") })
    check(afterTemps == beforeTemps, "Selection temporary folders cleaned after success and rejection")
    check(QuickActions.actions.contains { $0.flag == "--compress-dialog" && $0.name.contains("Sıkıştır") }, "Finder exposes configurable compression action")

    func matches(_ text: String, _ path: String, size: Int64 = 20, date: String = "2026-10-10", directory: Bool = false, encrypted: Bool = false) -> Bool {
        ArchiveQuery(text).matches(path: path, size: size, modified: date, directory: directory, encrypted: encrypted)
    }
    check(matches("\"annual report\"", "docs/Annual Report.pdf"), "Quoted search matches a contiguous phrase")
    check(!matches("\"annual report\"", "annual draft report.pdf"), "Quoted search rejects separated words")
    check(matches("annual report", "annual draft report.pdf"), "Legacy search still combines independent words")
    check(!matches("report -backup", "backup/report.pdf"), "Search exclusion applies to complete paths")
    check(matches("report -backup", "docs/report.pdf"), "Search exclusion retains unrelated paths")
    check(!matches("-\"old report\"", "docs/old report.pdf"), "Quoted exclusions group phrases")
    check(matches("\"-backup\"", "-backup.txt"), "Quoted leading dash stays literal")
    check(matches("\"ext:pdf\"", "ext:pdf.txt"), "Quoted filter syntax stays literal")
    check(matches("type:file encrypted:yes EXT:.PDF,TXT", "report.PDF", encrypted: true), "Type encryption and extension filters combine")
    check(!matches("encrypted:no", "report.pdf", encrypted: true), "Encryption filter excludes encrypted files")
    check(!matches("type:folder", "report.pdf"), "Folder filter excludes files")
    check(matches("TYPE:FOLDER", "docs", directory: true), "Folder filter supports case insensitive syntax")
    check(matches("report\t ext:pdf\nsize>10B", "report.pdf"), "Search handles tabs and line breaks")
    check(matches("literal*.txt", "literal*.txt"), "Search wildcard characters stay literal")
    check(!matches("literal*.txt", "literalABC.txt"), "Search wildcards never broaden results")
    check(matches("\"annual report", "annual report.pdf"), "Incomplete quote remains usable while typing")
    check(matches("literal\\\"quote.txt", "literal\"quote.txt"), "Escaped quote searches a real quote in a filename")
    check(matches("\"annual \\\"report\\\"\"", "annual \"report\".txt"), "Escaped quotes work inside a grouped phrase")
    check(matches("folder\\name", "folder\\name.txt"), "Backslashes outside quote escapes remain literal")
    check(!matches("size>NaN", "report.pdf"), "Invalid size syntax does not silently broaden search")
    check(!matches("after:2026-02-30", "report.pdf"), "Impossible dates do not silently broaden search")
    check(matches("AFTER:2024-02-29 BEFORE:2024-02-29", "report.pdf", date: "2024-02-29 12:00:00"), "Valid leap date and inclusive boundaries")
    check(!matches("after:2026-01-01", "report.pdf", date: ""), "Date filters exclude missing metadata")

    let entries = [ArchiveEntry(name: "docs/", isDirectory: true),
                   ArchiveEntry(name: "docs/a.txt", isDirectory: false, size: 12, packedSize: 7, mtime: "2026-10-10", crc: "123", encrypted: true),
                   ArchiveEntry(name: "docs/sub/b.txt", isDirectory: false),
                   ArchiveEntry(name: "docs-other/c.txt", isDirectory: false),
                   ArchiveEntry(name: "=2+3,\"quoted\"\nTürkçe.txt", isDirectory: false),
                   ArchiveEntry(name: "  @SUM(1).txt", isDirectory: false)]
    let folder = try ArchiveInventory.records(entries: entries, selection: ["docs", "docs/a.txt"])
    check(folder.count == 3, "Inventory includes selected folder descendants without duplicates")
    check(!folder.contains { $0.path.hasPrefix("docs-other") }, "Inventory folder scope requires a path boundary")
    check(try ArchiveInventory.records(entries: entries, selection: []).isEmpty, "Empty explicit export selection exports nothing")
    check(try ArchiveInventory.records(entries: entries, selection: ["docs/a.txt"]).count == 1, "Inventory exact file selection")
    check(try ArchiveInventory.records(entries: entries, query: ArchiveQuery("encrypted:yes")).count == 1, "Inventory can filter encrypted metadata")
    check(try ArchiveInventory.records(entries: entries, matchingPaths: ["docs/sub/b.txt"]).count == 1, "Inventory honors the exact visible filter scope")
    check(try ArchiveInventory.records(entries: entries, matchingPaths: []).isEmpty, "Empty search result exports no records")
    let records = try ArchiveInventory.records(entries: entries)
    let json = try ArchiveInventory.data(records, format: .json)
    let decoded = try JSONDecoder().decode([ArchiveInventory.Record].self, from: json)
    check(decoded.map(\.path) == entries.map(\.name), "JSON export preserves Unicode quotes newlines and formula-like names")
    check(decoded[1].size == 12 && decoded[1].packedSize == 7 && decoded[1].encrypted && decoded[1].crc == "123", "JSON export retains typed metadata")
    let csv = String(decoding: try ArchiveInventory.data(records, format: .csv), as: UTF8.self)
    check(csv.hasPrefix("path,directory,size_bytes,packed_bytes,modified,crc,encrypted\r\n"), "CSV has stable columns and CRLF records")
    check(csv.contains("\"'=2+3,\"\"quoted\"\"\nTürkçe.txt\""), "CSV escapes quotes commas newlines and formulas")
    check(csv.contains("\"'  @SUM(1).txt\""), "CSV protects formula-like names after whitespace")
    check(rejects { _ = try ArchiveInventory.records(entries: entries, cancelled: { true }) }, "Inventory preparation respects cancellation")
    check(rejects { _ = try ArchiveInventory.data(records, format: .json, cancelled: { true }) }, "JSON serialization respects cancellation")
    check(rejects { _ = try ArchiveInventory.data(records, format: .csv, cancelled: { true }) }, "CSV serialization respects cancellation")

    let directory = root.appendingPathComponent("inventory-export")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.zip")
    try Data("archive-original".utf8).write(to: source)
    let info = ArchiveInfo(path: source.path, kind: .other, details: "zip", entries: entries)
    check(rejects { try ArchiveInventory.write(json, to: source, protecting: info) }, "Inventory cannot overwrite its source archive")
    check(try Data(contentsOf: source) == Data("archive-original".utf8), "Rejected inventory save preserves archive bytes")
    let destination = directory.appendingPathComponent("files.json")
    try Data("previous-list".utf8).write(to: destination)
    check(rejects { try ArchiveInventory.write(json, to: destination, protecting: info, cancelled: { true }) }, "Cancelled inventory write preserves existing file")
    check(try Data(contentsOf: destination) == Data("previous-list".utf8), "Cancellation leaves prior export intact")
    try ArchiveInventory.write(json, to: destination, protecting: info)
    check(try Data(contentsOf: destination) == json, "Inventory writes a complete atomic replacement")
    let link = directory.appendingPathComponent("linked.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    check(rejects { try ArchiveInventory.write(json, to: link, protecting: info) }, "Inventory rejects linked destinations")
    try FileManager.default.removeItem(at: directory)

    let mapped = [ArchiveEntry(name: "folder", isDirectory: true, size: 1000),
                  ArchiveEntry(name: "a.PDF", isDirectory: false, size: 20, crc: "ab123456"),
                  ArchiveEntry(name: "copy.pdf", isDirectory: false, size: 20, crc: "AB123456"),
                  ArchiveEntry(name: "different-size.pdf", isDirectory: false, size: 30, crc: "AB123456"),
                  ArchiveEntry(name: "no-crc.bin", isDirectory: false, size: 50),
                  ArchiveEntry(name: "invalid-crc.bin", isDirectory: false, size: 50, crc: "not-crc!"),
                  ArchiveEntry(name: "empty1", isDirectory: false, crc: "00000000"),
                  ArchiveEntry(name: "empty2", isDirectory: false, crc: "00000000")]
    let map = try ArchiveMap.build(mapped)
    check(map.fileCount == 7 && map.emptyCount == 2 && map.totalSize == 170, "Archive map counts files and zero-byte files without counting directories")
    check(map.types.first?.ext == "bin" && map.types.first?.size == 100, "Archive map ranks types by uncompressed bytes")
    check(map.types.first { $0.ext == "pdf" }?.count == 3, "Archive map merges uppercase and lowercase extensions")
    check(map.types.first { $0.ext.isEmpty }?.count == 2, "Archive map includes files without an extension")
    check(map.largest.first?.size == 50 && map.largest.last?.size == 0, "Archive map ranks largest files deterministically")
    check(map.candidateGroupCount == 1 && map.candidates.first?.count == 2, "Duplicate candidates require a valid matching CRC32 and matching size")
    check(map.candidateAdditionalBytes == 20, "Candidate bytes count only additional members of metadata groups")
    check(map.candidates.first?.files.map(\.path) == ["a.PDF", "copy.pdf"], "Candidate member order is stable")
    check(rejects { _ = try ArchiveMap.build(mapped, cancelled: { true }) }, "Archive map supports cancellation")
    check(rejects { _ = try ArchiveMap.build([ArchiveEntry(name: "bad", isDirectory: false, size: -1)]) }, "Archive map rejects negative size metadata")
    check(rejects { _ = try ArchiveMap.build([ArchiveEntry(name: "huge", isDirectory: false, size: Int64.max), ArchiveEntry(name: "overflow", isDirectory: false, size: 1)]) }, "Archive map rejects aggregate overflow")
    let emptyMap = try ArchiveMap.build([])
    check(emptyMap.fileCount == 0 && emptyMap.types.isEmpty && emptyMap.candidates.isEmpty, "Empty archives produce a valid empty map")
    let many = (0..<120).map { ArchiveEntry(name: "file\($0).txt", isDirectory: false, size: Int64($0 + 1)) }
    let bounded = try ArchiveMap.build(many)
    check(bounded.largest.count == 50 && bounded.largest.first?.size == 120 && bounded.fileCount == 120, "Map bounds rendered file rows without truncating totals")
    let shared = (0..<100).map { ArchiveEntry(name: "repeat\($0).txt", isDirectory: false, size: 5, crc: "ABCD1234") }
    let sharedMap = try ArchiveMap.build(shared)
    check(sharedMap.candidates.first?.files.count == 20 && sharedMap.candidates.first?.count == 100 && sharedMap.candidateAdditionalBytes == 495, "Map bounds candidate previews while retaining complete counts")
    let sourcePart = root.appendingPathComponent("inventory-protected.part2.rar")
    try Data("part-original".utf8).write(to: sourcePart)
    let revision = ArchiveRevision(parts: [ArchiveRevision.Part(name: sourcePart.lastPathComponent, content: try ContentRevision.read(sourcePart))])
    let splitInfo = ArchiveInfo(path: root.appendingPathComponent("inventory-protected.part1.rar").path, kind: .rar, details: "volume", entries: [], revision: revision)
    check(rejects { try ArchiveInventory.write(json, to: sourcePart, protecting: splitInfo) }, "Inventory cannot overwrite another archive volume")
    check(try Data(contentsOf: sourcePart) == Data("part-original".utf8), "Protected volume retains original bytes")
    try FileManager.default.removeItem(at: sourcePart)
}
