import Foundation
import GlintCore

public final class ECDICTDictionary: DictionaryEngine, @unchecked Sendable {
    private let ranker: ECDICTRanker?

    public init(databaseURL: URL? = nil) {
        self.ranker = ECDICTRanker(databaseURL: databaseURL)
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !DictionaryPolicy.blockedTerms.contains(text) else {
            return nil
        }
        guard let values = ranker?.fallbackCandidates(
            term: text,
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
        return TranslationResult(options: options)
    }
}
