import Foundation

enum EnglishWordNormalizer {
    static func normalize(_ text: String) -> String {
        var value = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["to ", "the ", "a ", "an ", "be ", "of "] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        value = String(
            value.unicodeScalars.filter { allowed.contains($0) }
        )
        if value.count > 3, value.hasSuffix("s") {
            value = String(value.dropLast())
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}
