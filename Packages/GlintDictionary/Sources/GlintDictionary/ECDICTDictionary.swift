import Foundation
import GlintCore

public final class ECDICTDictionary: DictionaryEngine, @unchecked Sendable {
    private let ranker: ECDICTRanker?
    private let blocked: Set<String> = ["打", "尼", "你号"]

    public init(databaseURL: URL? = nil) {
        self.ranker = ECDICTRanker(databaseURL: databaseURL)
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        guard !candidate.text.isEmpty, !blocked.contains(candidate.text) else {
            return nil
        }
        guard let values = ranker?.fallbackCandidates(
            term: candidate.text,
            maxFrequency: 100_000,
            limit: 3
        ), !values.isEmpty else {
            return nil
        }
        let options = values.enumerated().map { index, value in
            TranslationOption(
                text: value,
                score: 0.70 - Double(index) * 0.05
            )
        }
        return TranslationResult(
            options: options,
            source: .dictionary,
            confidence: 0.70
        )
    }
}
