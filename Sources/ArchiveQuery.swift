import Foundation

struct ArchiveQuery {
    let words: [String]
    let ext: String?
    let minimum: Int64?
    let maximum: Int64?
    let after: String?
    let before: String?
    let excludedWords: [String]
    let directoryFilter: Bool?
    let encryptedFilter: Bool?
    private let extensions: Set<String>?
    init(_ text: String) {
        var terms: [String] = [], extensionFilter: String?, minSize: Int64?, maxSize: Int64?, afterDate: String?, beforeDate: String?
        var excluded: [String] = [], directory: Bool?, encrypted: Bool?
        for (token, literal) in Self.tokens(text) {
            let lower = token.lowercased()
            if !literal, lower.hasPrefix("ext:"), token.count > 4 { extensionFilter = String(lower.dropFirst(4)) }
            else if !literal, lower.hasPrefix("size>"), let value = Self.bytes(String(token.dropFirst(5))) { minSize = value }
            else if !literal, lower.hasPrefix("size<"), let value = Self.bytes(String(token.dropFirst(5))) { maxSize = value }
            else if !literal, lower.hasPrefix("after:"), Self.validDate(String(token.dropFirst(6))) { afterDate = String(token.dropFirst(6)) }
            else if !literal, lower.hasPrefix("before:"), Self.validDate(String(token.dropFirst(7))) { beforeDate = String(token.dropFirst(7)) }
            else if !literal, lower == "type:file" { directory = false }
            else if !literal, lower == "type:folder" { directory = true }
            else if !literal, lower == "encrypted:yes" { encrypted = true }
            else if !literal, lower == "encrypted:no" { encrypted = false }
            else if !literal, token.hasPrefix("-"), token.count > 1 { excluded.append(String(token.dropFirst())) }
            else { terms.append(token) }
        }
        words = terms; ext = extensionFilter; minimum = minSize; maximum = maxSize; after = afterDate; before = beforeDate
        excludedWords = excluded; directoryFilter = directory; encryptedFilter = encrypted
        extensions = extensionFilter.map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }) }
    }

    /// Quotes group phrases. Only \" escapes a quote; other backslashes stay literal.
    private static func tokens(_ text: String) -> [(String, Bool)] {
        var result: [(String, Bool)] = [], token = "", quoted = false, literal = false
        let characters = Array(text)
        var skip = false
        for (index, character) in characters.enumerated() {
            if skip { skip = false; continue }
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "\"" {
                token.append("\""); skip = true; continue
            }
            if character == "\"" {
                if token.isEmpty && !quoted { literal = true }
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !token.isEmpty { result.append((token, literal)) }
                token = ""; literal = false
            } else { token.append(character) }
        }
        if !token.isEmpty { result.append((token, literal)) }
        return result
    }

    private static func validDate(_ text: String) -> Bool {
        let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]), year > 0 else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        return calendar.dateComponents([.year, .month, .day], from: date) == components
    }
    private static func bytes(_ value: String) -> Int64? {
        let upper = value.uppercased()
        let number = upper.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(number), value >= 0 else { return nil }
        let unit = String(upper.dropFirst(number.count))
        let units: [String: Double] = ["": 1, "B": 1, "K": 1024, "KB": 1024, "M": 1_048_576, "MB": 1_048_576, "G": 1_073_741_824, "GB": 1_073_741_824]
        guard let multiplier = units[unit], value * multiplier < Double(Int64.max) else { return nil }
        return Int64(value * multiplier)
    }
    func matches(path: String, size: Int64, modified: String, directory: Bool, encrypted: Bool = false) -> Bool {
        if let directoryFilter, directoryFilter != directory { return false }
        if let encryptedFilter, encryptedFilter != encrypted { return false }
        if let minimum, size <= minimum { return false }
        if let maximum, size >= maximum { return false }
        if let extensions {
            if directory || !extensions.contains((path as NSString).pathExtension.lowercased()) { return false }
        }
        if let after, modified.isEmpty || String(modified.prefix(10)) < after { return false }
        if let before, modified.isEmpty || String(modified.prefix(10)) > before { return false }
        guard words.allSatisfy({ path.localizedCaseInsensitiveContains($0) }) else { return false }
        guard !excludedWords.contains(where: { path.localizedCaseInsensitiveContains($0) }) else { return false }
        return true
    }
}
