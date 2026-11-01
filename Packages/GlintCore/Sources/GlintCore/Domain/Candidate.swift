import Foundation

public enum CandidateKind: String, Sendable, Equatable {
    case word
    case phrase
    case sentence
    case unknown
}

public struct Candidate: Sendable, Equatable {
    public let text: String
    public let kind: CandidateKind

    public init(text: String, kind: CandidateKind = .unknown) {
        self.text = text
        self.kind = kind
    }
}

public struct TranslationOption: Sendable, Equatable {
    public let text: String
    public let score: Double
    public let partsOfSpeech: [PartOfSpeech]

    public init(
        text: String,
        score: Double,
        partsOfSpeech: [PartOfSpeech] = []
    ) {
        self.text = text
        self.score = score.isFinite ? score : 0
        self.partsOfSpeech = PartOfSpeech.normalized(partsOfSpeech)
    }
}

public struct TranslationResult: Sendable, Equatable {
    public let options: [TranslationOption]

    public init(text: String) {
        self.options = [TranslationOption(text: text, score: 1)]
    }

    public init(options: [TranslationOption]) {
        let sorted =
            options
            .filter { !$0.text.isEmpty }
            .sorted {
                if $0.score == $1.score {
                    return $0.text < $1.text
                }
                return $0.score > $1.score
            }
        var indexes: [String: Int] = [:]
        var merged: [TranslationOption] = []
        for option in sorted {
            let key = Self.dedupeKey(option.text)
            if let index = indexes[key] {
                let existing = merged[index]
                merged[index] = TranslationOption(
                    text: existing.text,
                    score: existing.score,
                    partsOfSpeech:
                        existing.partsOfSpeech + option.partsOfSpeech
                )
            } else {
                indexes[key] = merged.count
                merged.append(option)
            }
        }
        self.options = merged
    }

    public var text: String {
        options.first?.text ?? ""
    }

    public var displayText: String {
        var selected: [String] = []
        var length = 0
        for option in options.prefix(3) {
            let separatorLength = selected.isEmpty ? 0 : 3
            let proposedLength = length + separatorLength + option.text.count
            if !selected.isEmpty, proposedLength > 48 {
                break
            }
            selected.append(option.text)
            length = proposedLength
        }
        return selected.joined(separator: " · ")
    }

    public var primaryOnly: TranslationResult {
        guard options.count > 1 else { return self }
        return TranslationResult(options: Array(options.prefix(1)))
    }

    private static func dedupeKey(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(
            text.lowercased().unicodeScalars.filter { allowed.contains($0) }
        )
    }
}

public enum TranslationMode: String, Sendable, Equatable, CaseIterable {
    case smartFusion = "smart-fusion"
    case dictionaryFirst
    case modelFirst
}

public enum CandidateTranslationScope: String, Sendable, Equatable, CaseIterable {
    case selected
    case row
}
