import Foundation
import GlintCore

public final class ECDICTDictionary: DictionaryEngine, @unchecked Sendable {
    private let ranker: ECDICTRanker?

    public init(databaseURL: URL? = nil) {
        self.ranker = ECDICTRanker(databaseURL: databaseURL)
    }

    public init(ranker: ECDICTRanker?) {
        self.ranker = ranker
    }

    public func lookup(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        let text = request.candidate.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty,
            !DictionaryPolicy.blockedTerms.contains(text)
        else {
            return nil
        }
        guard
            let rankings = ranker?.fallbackRankings(
                term: text,
                maxFrequency: 100_000,
                limit: 3
            ), !rankings.isEmpty
        else {
            return nil
        }
        let options = rankings.enumerated().map { index, ranking in
            TranslationOption(
                text: ranking.english,
                score: 0.70 - Double(index) * 0.05
            )
        }
        return TranslationResult(options: options)
    }
}
