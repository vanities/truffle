import Foundation

/// Names as Siri hears them: "Play the Halloween mix" has to find "Halloween Mix", "Ana Rios" has to
/// find "Ana Ríos", and "Halloween 2026" has to find "🎃 Halloween 2026".
enum MediaText {
    /// Lowercased, accents and punctuation (and emoji) gone, one space between words, without a leading
    /// "the" or "my".
    static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "&", with: " and ")
        let words = folded.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .map(String.init)
        var trimmed = words[...]
        while let first = trimmed.first, ["the", "my"].contains(first), trimmed.count > 1 { trimmed = trimmed.dropFirst() }
        return trimmed.joined(separator: " ")
    }

    /// How well `candidate` answers `asked`, from 0 (not at all) to 3 (the same name).
    static func score(_ candidate: String, asked: String) -> Int {
        let wanted = key(asked), name = key(candidate)
        guard !wanted.isEmpty, !name.isEmpty else { return 0 }
        if name == wanted { return 3 }
        if name.hasPrefix(wanted + " ") || wanted.hasPrefix(name + " ") { return 2 }
        let words = Set(wanted.split(separator: " ")), have = Set(name.split(separator: " "))
        return words.isSubset(of: have) || have.isSubset(of: words) ? 1 : 0
    }
}
