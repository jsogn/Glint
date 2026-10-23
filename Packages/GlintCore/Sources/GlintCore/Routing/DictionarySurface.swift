import Foundation

public enum DictionarySurface {
    public static func split(_ text: String) -> [String] {
        text.split(separator: ";")
            .compactMap { normalize(String($0)) }
    }

    public static func normalize(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let opening = value.firstIndex(of: "(") {
            guard let closing = value[opening...].firstIndex(of: ")") else {
                value = String(value[..<opening])
                break
            }
            value.removeSubrange(opening...closing)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        value = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for prefix in ["to ", "the ", "a ", "an ", "be ", "of "] {
            if value.lowercased().hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        value = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        guard !value.isEmpty,
              !containsHan(value),
              !isMetadata(value) else {
            return nil
        }
        return value
    }

    public static func penalty(for text: String) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace)
        var penalty = min(
            0.20,
            max(0, Double(words.count - 3)) * 0.04
        )
        penalty += min(
            0.12,
            max(0, Double(text.count - 28)) * 0.005
        )
        if text.lowercased().hasPrefix("surname ") {
            penalty += 0.25
        }
        return penalty
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
        }
    }

    private static func isMetadata(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.hasPrefix("see ")
            || value.hasPrefix("variant of ")
            || value.hasPrefix("old variant ")
            || value.hasPrefix("abbr. for ")
            || value.hasPrefix("taiwan pr.")
    }
}
