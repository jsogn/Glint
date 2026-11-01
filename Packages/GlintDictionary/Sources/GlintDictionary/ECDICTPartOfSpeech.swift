import Foundation
import GlintCore

enum ECDICTPartOfSpeech {
    struct ParsedLine: Equatable {
        let body: String
        let partOfSpeech: PartOfSpeech?
    }

    static func parseLine(_ value: String) -> ParsedLine {
        let line = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let dot = line.firstIndex(of: ".") else {
            return ParsedLine(body: line, partOfSpeech: nil)
        }
        let prefix = line[..<dot]
        guard
            !prefix.isEmpty,
            prefix.allSatisfy({ $0.isLetter })
        else {
            return ParsedLine(body: line, partOfSpeech: nil)
        }
        let part = map(String(prefix).lowercased())
        let bodyStart = line.index(after: dot)
        let body = line[bodyStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedLine(body: body, partOfSpeech: part)
    }

    static func select(_ values: [PartOfSpeech]) -> [PartOfSpeech] {
        var unique: [PartOfSpeech] = []
        for value in values where !unique.contains(value) {
            unique.append(value)
            if unique.count == 2 {
                break
            }
        }
        return PartOfSpeech.normalized(unique)
    }

    static func encode(_ values: [PartOfSpeech]) -> String {
        select(values).map(\.rawValue).joined(separator: "/")
    }

    static func decode(_ value: String) -> [PartOfSpeech] {
        select(
            value.split(separator: "/").compactMap {
                PartOfSpeech(String($0))
            }
        )
    }

    static func englishKey(for value: String) -> String? {
        PartOfSpeech.singleEnglishWordKey(value)
    }

    private static func map(_ code: String) -> PartOfSpeech? {
        switch code {
        case "n": .noun
        case "v", "vt", "vi", "aux": .verb
        case "a", "adj": .adjective
        case "adv", "ad": .adverb
        case "prep": .preposition
        case "pron": .pronoun
        case "conj": .conjunction
        case "det": .determiner
        case "num": .numeral
        case "int", "interj": .interjection
        default: nil
        }
    }
}
