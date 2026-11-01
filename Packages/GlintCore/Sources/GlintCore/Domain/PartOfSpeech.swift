import Foundation

public enum PartOfSpeech:
    String, CaseIterable, Sendable, Equatable, Hashable
{
    case noun
    case verb
    case adjective
    case adverb
    case preposition
    case pronoun
    case conjunction
    case determiner
    case numeral
    case interjection

    public var abbreviation: String {
        switch self {
        case .noun: "n."
        case .verb: "v."
        case .adjective: "adj."
        case .adverb: "adv."
        case .preposition: "prep."
        case .pronoun: "pron."
        case .conjunction: "conj."
        case .determiner: "det."
        case .numeral: "num."
        case .interjection: "interj."
        }
    }

    public var accessibilityName: String {
        rawValue
    }

    public init?(_ token: String) {
        let value =
            token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "n", "n.", "noun": self = .noun
        case "v", "v.", "verb": self = .verb
        case "adj", "adj.", "adjective": self = .adjective
        case "adv", "adv.", "adverb": self = .adverb
        case "prep", "prep.", "preposition": self = .preposition
        case "pron", "pron.", "pronoun": self = .pronoun
        case "conj", "conj.", "conjunction": self = .conjunction
        case "det", "det.", "determiner": self = .determiner
        case "num", "num.", "numeral": self = .numeral
        case "interj", "interj.", "interjection": self = .interjection
        default: return nil
        }
    }

    public static func normalized(
        _ values: [PartOfSpeech],
        limit: Int = 2
    ) -> [PartOfSpeech] {
        Array(
            allCases
                .filter(values.contains)
                .prefix(max(0, limit))
        )
    }

    public static func singleEnglishWordKey(_ text: String) -> String? {
        let value = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
            !value.contains(where: \.isWhitespace)
        else {
            return nil
        }
        let hasLatinLetter = value.contains {
            $0.isASCII && $0.isLetter
        }
        let hasHan = value.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
        }
        guard hasLatinLetter, !hasHan else { return nil }
        return value
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
