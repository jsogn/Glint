import Foundation

public enum CandidateKind: String, Sendable, Equatable, CaseIterable {
    case word
    case phrase
    case sentence
    case unknown
}

public struct Candidate: Sendable, Equatable {
    public let text: String
    public let kind: CandidateKind
    public let confidence: Double

    public init(text: String, kind: CandidateKind = .unknown, confidence: Double = 1.0) {
        self.text = text
        self.kind = kind
        self.confidence = confidence
    }
}

public enum ResultSource: String, Sendable, Equatable {
    case dictionary
    case translation
}

public struct TranslationOption: Sendable, Equatable {
    public let text: String
    public let score: Double

    public init(text: String, score: Double) {
        self.text = text
        self.score = score
    }
}

public struct TranslationResult: Sendable, Equatable {
    public let options: [TranslationOption]
    public let source: ResultSource
    public let confidence: Double

    public init(text: String, source: ResultSource, confidence: Double) {
        self.options = [TranslationOption(text: text, score: confidence)]
        self.source = source
        self.confidence = confidence
    }

    public init(
        options: [TranslationOption],
        source: ResultSource,
        confidence: Double
    ) {
        var seen: Set<String> = []
        self.options = options
            .filter { !$0.text.isEmpty }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.text < rhs.text
                }
                return lhs.score > rhs.score
            }
            .filter { seen.insert(Self.dedupeKey($0.text)).inserted }
        self.source = source
        self.confidence = confidence
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
        return TranslationResult(
            options: Array(options.prefix(1)),
            source: source,
            confidence: confidence
        )
    }

    private static func dedupeKey(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(
            text.lowercased().unicodeScalars.filter { allowed.contains($0) }
        )
    }
}

public enum TranslationMode: String, Sendable, Equatable, CaseIterable {
    case dictionaryFirst
    case modelFirst
}

public enum CandidateTranslationScope: String, Sendable, Equatable, CaseIterable {
    case selected
    case row
}
