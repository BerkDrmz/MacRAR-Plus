import Foundation

// MARK: - Model

enum ArchiveKind {
    case rar        // unrar / rar
    case other      // 7zz (zip, 7z, tar, gz, xz, bz2, zst, iso, cab, ...)
}

struct ArchiveEntry {
    var name: String            // arşiv içindeki tam yol
    var isDirectory: Bool
    var size: Int64 = 0
    var packedSize: Int64 = 0
    var ratio: String = ""
    var mtime: String = ""
    var crc: String = ""
    var encrypted: Bool = false
    var attributes: String = ""
    var compression: String = ""
    var linkTarget: String? = nil

    var displayName: String { (name as NSString).lastPathComponent }
    var parentPath: String { (name as NSString).deletingLastPathComponent }
}

struct ArchiveInfo {
    var path: String
    var kind: ArchiveKind
    var details: String
    var entries: [ArchiveEntry]
    var headersEncrypted: Bool = false
    var revision: ArchiveRevision? = nil
    /// tar.gz / tar.xz gibi: dış katman 7zz ile açılıp iç tar'a aktarılır
    var tarCompressed: Bool { Formats.isTarCompressed(path) }

    var hasEncryptedFiles: Bool { headersEncrypted || entries.contains { $0.encrypted } }
    var isSolid: Bool { details.contains("solid") }
    var fileCount: Int { entries.filter { !$0.isDirectory }.count }
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var totalPacked: Int64 { entries.reduce(0) { $0 + $1.packedSize } }
    var storedSize: Int64 {
        guard let revision else { return archiveSize(path) }
        return revision.parts.reduce(Int64(0)) { total, part in
            let size = Int64(clamping: part.content.metadata.size)
            let sum = total.addingReportingOverflow(size)
            return sum.overflow ? Int64.max : sum.partialValue
        }
    }
    var topLevelNames: [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in entries {
            let top = e.name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? e.name
            if seen.insert(top).inserted { out.append(top) }
        }
        return out
    }
    /// Dosya ekleme / silme desteklenir mi?
    var supportsModification: Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !tarCompressed && ["rar", "7z", "zip", "tar"].contains(ext) && !details.contains("volume")
    }
}

struct RarResult {
    let code: Int32
    let output: String
    var cancelled: Bool = false
    var committedRevision: ArchiveRevision? = nil

    var ok: Bool { code == 0 && !cancelled }
    var warning: Bool { code == 1 && !cancelled }
    var wrongPassword: Bool {
        guard !ok, !cancelled else { return false }
        if code == 11 { return true }
        return output.components(separatedBy: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "Enter password:" || line.hasPrefix("Enter password (") { return true }
            guard line.hasPrefix("ERROR:") else { return false }
            return line.contains("Incorrect password") || line.contains("Wrong password")
                || line.contains("Cannot open encrypted archive") || line.contains("Can not open encrypted archive")
        }
    }
    var notArchive: Bool { !ok && (output.contains("is not RAR archive") || output.contains("Cannot open the file as archive")) }

    /// Kullanıcıya gösterilecek kısa hata metni
    var errorSummary: String {
        let lines = output.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{8}", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !$0.hasPrefix("UNRAR ") && !$0.hasPrefix("RAR ") && !$0.hasPrefix("Trial version") && !$0.hasPrefix("Evaluation copy") && !$0.hasPrefix("7-Zip") && !$0.hasPrefix("64-bit") }
        let interesting = lines.filter { l in
            l.contains("error") || l.contains("Error") || l.contains("ERROR") || l.contains("Incorrect") || l.contains("Wrong")
                || l.contains("failed") || l.contains("Failed") || l.contains("not RAR") || l.contains("Cannot") || l.contains("Can not")
                || l.contains("No files") || l.contains("Checksum") || l.contains("CRC") || l.contains("denied") || l.contains("Total errors")
                || l.contains("Unexpected end") || l.contains("Data Error") || l.contains("Unsupported")
        }
        let chosen = interesting.isEmpty ? Array(lines.suffix(6)) : Array(interesting.suffix(8))
        return chosen.joined(separator: "\n")
    }
}

enum RarTool { case rar, unrar, sevenZip }

typealias Stage = (tool: RarTool, args: [String])

// MARK: - Biçim bilgisi

enum Formats {
    /// Uygulamanın açabildiği uzantılar
    static let openable: Set<String> = [
        "rar", "zip", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "tzst", "lz4", "lzma", "tlz", "z",
        "cab", "arj", "lzh", "lha", "cpio", "iso", "wim", "swm", "esd", "deb", "rpm", "jar", "war", "ear", "apk", "ipa",
        "xpi", "crx", "nupkg", "msi", "chm", "udf", "vhd", "vhdx", "vmdk", "qcow2", "squashfs", "cramfs", "ext", "ext2", "ext3", "ext4",
        "hfs", "hfsx", "dmg", "xar", "pkg", "ar", "a", "lib", "zipx", "br", "001", "lz", "uue", "bzip2", "gzip", "sfx",
    ]

    static func isArchive(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        if openable.contains(ext) || ext.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil { return true }
        return ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil
    }

    static func firstVolume(_ path: String) -> String {
        let ns = path as NSString
        var first = path
        if let range = path.range(of: #"(?<=\.part)\d+(?=\.(?:rar|sfx)$)"#, options: [.regularExpression, .caseInsensitive]) {
            let width = path[range].count
            first.replaceSubrange(range, with: String(repeating: "0", count: max(0, width - 1)) + "1")
        } else if ns.pathExtension.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil {
            first = ns.deletingPathExtension + ".001"
        } else if ns.pathExtension.range(of: #"^r\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            first = ns.deletingPathExtension + ".rar"
        }
        if FileManager.default.fileExists(atPath: first) { return first }
        if first != path, (first as NSString).pathExtension.lowercased() == "rar" {
            let sfx = (first as NSString).deletingPathExtension + ".sfx"
            if FileManager.default.fileExists(atPath: sfx) { return sfx }
        }
        return path
    }

    static func kind(of path: String) -> ArchiveKind {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "sfx" || ext == "rar" || ext.range(of: #"^r\d\d$"#, options: .regularExpression) != nil { return .rar }
        return .other
    }

    static func isTarCompressed(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        let ext = (lower as NSString).pathExtension
        if ["tgz", "tbz", "tbz2", "txz", "tzst", "tlz"].contains(ext) { return true }
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz4", ".tar.z", ".tar.lzma", ".tar.lz", ".tar.br"] {
            if lower.hasSuffix(suffix) { return true }
        }
        return false
    }
}

// MARK: - Runner

enum RarRunner {
    static let resourceDir: URL = {
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: r.appendingPathComponent("unrar").path) {
            return r
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    }()

    static func url(_ tool: RarTool) -> URL {
        switch tool {
        case .rar: return resourceDir.appendingPathComponent("rar")
        case .unrar: return resourceDir.appendingPathComponent("unrar")
        case .sevenZip: return resourceDir.appendingPathComponent("7zz")
        }
    }

    /// No switch means no password. Bare -p prompts; RAR's -p- is the literal password "-".
    static func passwordArgs(_ pw: String?, encryptHeaders: Bool = false) -> [String] {
        guard let pw, !pw.isEmpty else { return [] }
        return [(encryptHeaders ? "-hp" : "-p") + pw]
    }

    static func passwordArgs7z(_ pw: String?) -> [String] {
        guard let pw, !pw.isEmpty else { return [] }
        return ["-p" + pw]
    }

    static func makeProcess(_ tool: RarTool, _ args: [String], cwd: String?) -> Process {
        let p = Process()
        p.executableURL = url(tool)
        let isHeavy = ["a", "x", "e", "t", "d", "rn"].contains(args.first ?? "")
        var budget = isHeavy ? [tool == .sevenZip ? "-mmt=\(EnergyPolicy.threads)" : "-mt\(EnergyPolicy.threads)"] : []
        if args.first == "a", let dictionary = EnergyPolicy.dictionaryMiB {
            if tool == .rar { budget.append("-md\(dictionary)m") }
            else if tool == .sevenZip {
                let archive = args.firstIndex(of: "--").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
                if args.contains("-t7z") || (archive as NSString?)?.pathExtension.lowercased() == "7z" { budget.append("-m0=LZMA2:d=\(dictionary)m") }
            }
        }
        var arguments: [String] = tool == .sevenZip ? Array(args.prefix(1)) : [args[0], "-cfg-", "-@"]
        arguments.append(contentsOf: budget)
        arguments.append(contentsOf: args.dropFirst())
        p.arguments = arguments
        // Foundation converts process arguments to decomposed filesystem text
        // on macOS. Archive member names and passwords need their exact UTF-8.
        // ASCII values take the direct path. Other values cross Foundation as
        // base64 and are decoded by a fixed, quoted shell script before exec.
        // Values are never evaluated as shell code; the suffix retains newlines.
        let values = [url(tool).path] + arguments
        if values.contains(where: { $0.unicodeScalars.contains { !$0.isASCII } }) {
            var script: [String] = [], payload: [String] = [], references: [String] = []
            for (index, value) in values.enumerated() {
                let position = index + 1
                if value.unicodeScalars.contains(where: { !$0.isASCII }) {
                    payload.append(Data(value.utf8).base64EncodedString())
                    script.append("v\(index)=$(printf '%s' \"${\(position)}\" | /usr/bin/base64 -D && printf '.'); test $? -eq 0 || exit 127; v\(index)=${v\(index)%.}")
                    references.append("\"$v\(index)\"")
                } else {
                    payload.append(value)
                    references.append("\"${\(position)}\"")
                }
            }
            script.append("exec " + references.joined(separator: " "))
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script.joined(separator: "\n"), "MacRARPlus-engine"] + payload
        }
        p.qualityOfService = EnergyPolicy.mode == .fast && !EnergyPolicy.constrained ? .userInitiated : .utility
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Eşzamanlı çalıştırır, tüm çıktıyı toplar.
    static func run(_ tool: RarTool, _ args: [String], cwd: String? = nil) -> RarResult {
        runStages([(tool, args)], cwd: cwd)
    }

    /// Birbirine borulanmış aşamaları eşzamanlı çalıştırır; son aşamanın çıktısı ve çıkış kodu döner.
    static func runStages(_ stages: [Stage], cwd: String? = nil, cancellation: TaskCancellation? = nil) -> RarResult {
        var processes: [Process] = []
        var pipes: [Pipe] = []
        for (i, stage) in stages.enumerated() {
            let p = makeProcess(stage.tool, stage.args, cwd: cwd)
            if i > 0 { p.standardInput = pipes[i - 1].fileHandleForReading }
            if i < stages.count - 1 {
                let pipe = Pipe(); pipes.append(pipe)
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            }
            processes.append(p)
        }
        guard let last = processes.last else { return RarResult(code: -1, output: "No processing stages") }
        let launched = processes
        cancellation?.onCancel { for p in launched where p.isRunning { p.terminate() } }
        defer { cancellation?.clearHandler() }
        let output = Pipe(); last.standardOutput = output; last.standardError = output
        do {
            for p in processes {
                try cancellation?.check()
                try p.run()
                if cancellation?.cancelled == true, p.isRunning { p.terminate() }
            }
        } catch {
            let running = processes.filter { $0.isRunning }
            running.forEach { $0.terminate() }
            running.forEach { $0.waitUntilExit() }
            pipes.forEach { try? $0.fileHandleForReading.close(); try? $0.fileHandleForWriting.close() }
            return RarResult(code: -1, output: error.localizedDescription, cancelled: cancellation?.cancelled == true)
        }
        // Close parent copies so downstream readers observe EOF even when upstream fails.
        pipes.forEach { try? $0.fileHandleForReading.close(); try? $0.fileHandleForWriting.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        processes.forEach { $0.waitUntilExit() }
        let failure = processes.first { $0.terminationStatus > 1 || $0.terminationStatus < 0 }
        let code = failure?.terminationStatus ?? processes.map { $0.terminationStatus }.max() ?? 0
        var text = String(decoding: data, as: UTF8.self)
        if let failure, failure !== last { text += "\nUpstream archive processing failed (\(failure.terminationStatus))." }
        return RarResult(code: code, output: text, cancelled: cancellation?.cancelled == true)
    }

    enum ListOutcome {
        case ok(ArchiveInfo)
        case wrongPassword
        case error(RarResult)
    }

    static func listStages(_ path: String, password: String?) -> [Stage] {
        switch Formats.kind(of: path) {
        case .rar:
            return [(.unrar, ["lt", "-y"] + passwordArgs(password) + ["--", path])]
        case .other:
            if Formats.isTarCompressed(path) {
                return [(.sevenZip, ["x", "-so"] + passwordArgs7z(password) + ["--", path]),
                        (.sevenZip, ["l", "-si", "-ttar", "-slt"])]
            }
            return [(.sevenZip, ["l", "-slt"] + passwordArgs7z(password) + ["--", path])]
        }
    }

    static func list(_ path: String, password: String?, cancellation: TaskCancellation? = nil) -> ListOutcome {
        let kind = Formats.kind(of: path)
        let before = try? ArchiveRevision.read(URL(fileURLWithPath: path), cancelled: { cancellation?.cancelled == true })
        let r = runStages(listStages(path, password: password), cancellation: cancellation)
        if r.cancelled { return .error(r) }
        if r.wrongPassword { return .wrongPassword }
        guard before != nil, before == (try? ArchiveRevision.read(URL(fileURLWithPath: path), cancelled: { cancellation?.cancelled == true })) else {
            return .error(RarResult(code: 2, output: P("Arşiv okuma sırasında değişti; listeyi yeniden yükleyin.", "Archive changed while listing; reload it.")))
        }
        switch kind {
        case .rar:
            guard r.output.contains("Details:") else { return .error(r) }
            if !r.ok { return .error(r) }
            var info = parseRarListing(r.output, path: path); info.revision = before
            return .ok(info)
        case .other:
            if r.notArchive || !r.ok { return .error(r) }
            guard r.output.contains("----------") || r.output.contains("Type = ") else { return .error(r) }
            var info = parse7zListing(r.output, path: path); info.revision = before
            return .ok(info)
        }
    }

    // MARK: unrar lt ayrıştırma

    static func parseRarListing(_ out: String, path: String) -> ArchiveInfo {
        var details = ""
        var entries: [ArchiveEntry] = []
        var block: [String: String] = [:]

        func flush() {
            defer { block = [:] }
            guard let name = block["Name"], let type = block["Type"], type != "Service" else { return }
            var e = ArchiveEntry(name: name, isDirectory: type == "Directory")
            e.size = Int64(block["Size"] ?? "") ?? 0
            e.packedSize = Int64(block["Packed size"] ?? "") ?? 0
            e.ratio = block["Ratio"] ?? ""
            if let m = block["mtime"] { e.mtime = String(m.prefix(19)) }
            e.crc = block["CRC32"] ?? block["CRC32 MAC"] ?? ""
            e.encrypted = (block["Flags"] ?? "").contains("encrypted")
            e.attributes = block["Attributes"] ?? ""
            e.compression = block["Compression"] ?? ""
            e.linkTarget = block["Target"] ?? block["Link target"]
            if type.lowercased().contains("link") { e.linkTarget = e.linkTarget ?? "link" }
            entries.append(e)
        }

        var inEntries = false
        for raw in out.components(separatedBy: "\n") {
            let line = String(raw.drop(while: { $0 == " " || $0 == "\t" }))
            if !inEntries {
                if line.hasPrefix("Details:") {
                    details = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    inEntries = true
                }
                continue
            }
            if line.isEmpty { flush(); continue }
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let payload = String(line[line.index(after: idx)...])
            let value = key == "Name" ? (payload.hasPrefix(" ") ? String(payload.dropFirst()) : payload) : payload.trimmingCharacters(in: .whitespaces)
            if key == "Name", block["Name"] != nil { flush() }
            block[key] = value
        }
        flush()
        var info = ArchiveInfo(path: path, kind: .rar, details: details, entries: entries)
        info.headersEncrypted = details.contains("encrypted headers")
        // Pure parser: operation boundaries attach a verified revision.
        return info
    }

    // MARK: 7zz l -slt ayrıştırma

    static func parse7zListing(_ out: String, path: String) -> ArchiveInfo {
        let lines = out.components(separatedBy: "\n")
        // Son "----------" satırından sonrası girdiler; öncesi arşiv başlık blokları
        let sepIndex = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces) == "----------" }
        let headerLines = sepIndex.map { Array(lines[..<$0]) } ?? lines
        let entryLines = sepIndex.map { Array(lines[($0 + 1)...]) } ?? []

        // Başlık: son "Type =" değeri asıl arşiv türüdür (split/gzip gibi dış katmanlar önce gelir)
        var type = ""
        var solid = false
        var volumes = 0
        var outerTypes: [String] = []
        for raw in headerLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let r = line.range(of: " = ") else { continue }
            let key = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...])
            switch key {
            case "Type": if !type.isEmpty { outerTypes.append(type) }; type = value
            case "Solid": solid = (value == "+")
            case "Volumes": volumes = Int(value) ?? 0
            default: break
            }
        }
        if Formats.isTarCompressed(path), type.isEmpty { type = "tar" }

        var entries: [ArchiveEntry] = []
        var block: [String: String] = [:]
        func flush() {
            defer { block = [:] }
            guard let name = block["Path"], !name.isEmpty else { return }
            let attrs = block["Attributes"] ?? ""
            let isDir = block["Folder"] == "+" || attrs.hasPrefix("D")
            var e = ArchiveEntry(name: name.hasSuffix("/") ? String(name.dropLast()) : name, isDirectory: isDir)
            e.size = Int64(block["Size"] ?? "") ?? 0
            e.packedSize = Int64(block["Packed Size"] ?? "") ?? 0
            if e.size > 0, e.packedSize > 0 {
                let percent = Double(e.packedSize) * 100 / Double(e.size)
                if percent.isFinite, percent < Double(Int.max) { e.ratio = "\(Int(percent))%" }
            }
            if let m = block["Modified"] { e.mtime = String(m.prefix(19)) }
            e.crc = block["CRC"] ?? ""
            e.encrypted = block["Encrypted"] == "+"
            e.attributes = attrs
            e.compression = block["Method"] ?? ""
            e.linkTarget = [block["Symbolic Link"], block["Hard Link"]].compactMap { $0 }.first { !$0.isEmpty }
            if let mode = block["Mode"], mode.hasPrefix("l") { e.linkTarget = e.linkTarget ?? "link" }
            entries.append(e)
        }
        for raw in entryLines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            guard let r = line.range(of: " = ") else {
                if line.hasSuffix(" =") { block[String(line.dropLast(2))] = "" }
                continue
            }
            let key = String(line[..<r.lowerBound])
            let value = String(line[r.upperBound...])
            if key == "Path", block["Path"] != nil { flush() }
            block[key] = value
        }
        flush()

        var parts: [String] = [type.isEmpty ? L("arşiv") : type]
        if Formats.isTarCompressed(path) {
            let outerExt = (path as NSString).pathExtension.lowercased()
            parts = ["tar + \(outerExt)"]
        }
        if solid { parts.append("solid") }
        if volumes > 1 { parts.append("\(volumes) volume") }
        var info = ArchiveInfo(path: path, kind: .other, details: parts.joined(separator: ", "), entries: entries)
        info.headersEncrypted = false
        // Pure parser: operation boundaries attach a verified revision.
        return info
    }

    /// RAR removes its file after deleting the last entry. Keep a valid empty RAR 5
    /// (signature, main header, end header, with CRC32s per rarlab.com/technote.htm).
    static func writeEmptyRAR(at path: String, headerPassword: String?) throws {
        let bytes: [UInt8] = [0x52,0x61,0x72,0x21,0x1a,0x07,0x01,0x00,
                             0xc5,0x1a,0x33,0x32,0x03,0x01,0x00,0x00,
                             0x19,0xb2,0x3a,0x35,0x03,0x05,0x00,0x00]
        try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
        if let password = headerPassword {
            let result = run(.rar, ["ch", "-y"] + passwordArgs(password, encryptHeaders: true) + ["--", path])
            guard result.ok else { throw ArchiveSafetyError(message: result.errorSummary) }
        }
    }
}

// MARK: - Streaming job (ilerleme takibi)

final class RarJob {
    enum Event {
        case file(String)       // yeni dosya işleniyor
        case progress(Int)      // yüzde (toplam)
    }

    private var processes: [Process] = []
    private var monitoredTool: RarTool = .unrar
    private let queue = DispatchQueue(label: "macrar.job", qos: .utility)
    private var buffer = Data()
    private var output = ""
    var capturesListing = false
    private var outputBytes = 0
    private var lastEventTime: TimeInterval = 0
    private var pendingFile: String?
    private var pendingPercent: Int?
    private var wasCancelled = false
    private let stateLock = NSLock()
    var cancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wasCancelled
    }
    var onEvent: ((Event) -> Void)?   // ana kuyrukta çağrılır

    private static let verbs = ["Extracting", "Adding", "Testing", "Updating", "Creating", "Deleting", "Compressing", "Fresh", "Calculating"]
    private static let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3})%"#)
    private static let percentHeadRegex = try! NSRegularExpression(pattern: #"^\s*(\d{1,3})%"#)
    private static let tailRegex = try! NSRegularExpression(pattern: #"\s*(\d{1,3}%|OK|Failed|CRC failed)\s*$"#)
    private static let sevenNameRegex = try! NSRegularExpression(pattern: #"(?:^|\s)([-+TU])\s(\S.*)$"#)

    func start(_ tool: RarTool, _ args: [String], cwd: String? = nil, completion: @escaping (RarResult) -> Void) {
        start(stages: [(tool, args)], cwd: cwd, completion: completion)
    }

    /// Aşamalar birbirine borulanır; yalnızca son aşamanın çıktısı izlenir.
    func start(stages: [Stage], cwd: String? = nil, completion: @escaping (RarResult) -> Void) {
        guard !cancelled else { completion(RarResult(code: 2, output: "Cancelled", cancelled: true)); return }
        guard let lastStage = stages.last else { completion(RarResult(code: -1, output: "No processing stages")); return }
        monitoredTool = lastStage.tool
        var pipes: [Pipe] = []
        for (i, stage) in stages.enumerated() {
            let p = RarRunner.makeProcess(stage.tool, stage.args, cwd: cwd)
            if i > 0 { p.standardInput = pipes[i - 1].fileHandleForReading }
            if i < stages.count - 1 {
                let pipe = Pipe(); pipes.append(pipe)
                p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            }
            processes.append(p)
        }
        let outputPipe = Pipe()
        processes.last?.standardOutput = outputPipe; processes.last?.standardError = outputPipe
        var launched = [Process]()
        do {
            for p in processes { try p.run(); launched.append(p) }
        } catch {
            launched.filter { $0.isRunning }.forEach { $0.terminate() }
            pipes.forEach { try? $0.fileHandleForReading.close(); try? $0.fileHandleForWriting.close() }
            try? outputPipe.fileHandleForWriting.close()
            queue.async {
                _ = outputPipe.fileHandleForReading.readDataToEndOfFile()
                launched.forEach { $0.waitUntilExit() }
                try? outputPipe.fileHandleForReading.close()
                DispatchQueue.main.async { completion(RarResult(code: -1, output: error.localizedDescription, cancelled: self.cancelled)) }
            }
            return
        }
        pipes.forEach { try? $0.fileHandleForReading.close(); try? $0.fileHandleForWriting.close() }
        queue.async { [self] in
            while true {
                let data = outputPipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                consume(data)
            }
            flushPartial()
            processes.forEach { $0.waitUntilExit() }
            let failure = processes.first { $0.terminationStatus > 1 || $0.terminationStatus < 0 }
            let code = failure?.terminationStatus ?? processes.map { $0.terminationStatus }.max() ?? 0
            if let failure, failure !== processes.last { output += "\nUpstream archive processing failed (\(failure.terminationStatus))." }
            let result = RarResult(code: code, output: output, cancelled: cancelled)
            DispatchQueue.main.async {
                var delivered = result
                delivered.cancelled = self.cancelled
                completion(delivered)
            }
        }
    }

    func cancel() {
        stateLock.lock(); wasCancelled = true; stateLock.unlock()
        processes.forEach { if $0.isRunning { $0.terminate() } }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            if !capturesListing, outputBytes > 1_048_576 { output = String(output.suffix(524_288)); outputBytes = output.utf8.count }
            let clean = line.replacingOccurrences(of: "\u{8}", with: "") + "\n"
            output += clean; outputBytes += clean.utf8.count
            if !capturesListing { parse(line) }
        }
        if !capturesListing, !buffer.isEmpty, buffer.count < 4096 {
            parse(String(decoding: buffer, as: UTF8.self))
        }
    }

    private func flushPartial() {
        if !buffer.isEmpty {
            output += String(decoding: buffer, as: UTF8.self).replacingOccurrences(of: "\u{8}", with: "")
            buffer.removeAll()
        }
    }

    private func parse(_ raw: String) {
        let line = raw.replacingOccurrences(of: "\u{8}", with: "").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        var pct: Int? = nil
        var fileName: String? = nil

        if monitoredTool == .sevenZip {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = Self.percentHeadRegex.firstMatch(in: line, range: full) {
                pct = Int(ns.substring(with: m.range(at: 1)))
            }
            if line.contains("ERROR") || line.hasSuffix("--") || line.contains(" Open ") {
                // hata satırları ve "Open --" gibi bilgi satırları dosya değil
            } else if let m = Self.sevenNameRegex.firstMatch(in: line, range: full) {
                var name = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                if name.hasSuffix("/") { name.removeLast() }
                if !name.isEmpty, !name.hasPrefix("Everything") { fileName = name }
            }
        } else {
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = Self.percentRegex.matches(in: line, range: full).last {
                pct = Int(ns.substring(with: m.range(at: 1)))
            }
            var candidate: String? = nil
            if line.hasPrefix("... ") {
                candidate = String(line.dropFirst(4))        // parça değişiminden sonra devam eden dosya
            } else {
                for verb in Self.verbs where line.hasPrefix(verb + " ") {
                    let rest = String(line.dropFirst(verb.count)).trimmingCharacters(in: .whitespaces)
                    if rest.hasPrefix("from ") || rest.hasPrefix("archive ") { break }
                    candidate = rest
                    break
                }
            }
            if let c = candidate {
                var name = c.trimmingCharacters(in: .whitespaces)
                while let m = Self.tailRegex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) {
                    name = (name as NSString).substring(to: m.range.location)
                }
                fileName = name.trimmingCharacters(in: .whitespaces)
            }
        }

        if let fileName { pendingFile = fileName }
        if let pct { pendingPercent = pct }
        let now = ProcessInfo.processInfo.systemUptime
        guard let onEvent, now - lastEventTime >= 0.2 || pct == 100 else { return }
        lastEventTime = now
        let file = pendingFile, progress = pendingPercent
        pendingFile = nil; pendingPercent = nil
        DispatchQueue.main.async {
            if let f = file, !f.isEmpty { onEvent(.file(f)) }
            if let p = progress { onEvent(.progress(p)) }
        }
    }
}

// MARK: - Yardımcılar

enum Fmt {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }
}

func isDirectoryPath(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
}

func uniquePath(_ path: String) -> String {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return path }
    let ns = path as NSString
    let dir = ns.deletingLastPathComponent
    let ext = ns.pathExtension
    let base = (ns.deletingPathExtension as NSString).lastPathComponent
    var i = 2
    while true {
        let candidate = (dir as NSString).appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
        if !fm.fileExists(atPath: candidate) { return candidate }
        i += 1
    }
}
