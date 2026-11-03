import GlintCore

extension DictionaryEngine {
    func lookup(
        _ candidate: Candidate
    ) async throws -> TranslationResult? {
        try await lookup(
            TranslationRequest(
                candidate: candidate,
                direction: .simplifiedChineseToEnglish
            )
        )
    }
}

extension DictionaryRouter {
    func lookup(_ candidate: Candidate) async -> TranslationResult? {
        await lookup(
            TranslationRequest(
                candidate: candidate,
                direction: .simplifiedChineseToEnglish
            )
        )
    }
}

extension SmartRouter {
    func route(
        _ candidate: Candidate,
        mode: TranslationMode = .dictionaryFirst,
        includesAlternatives: Bool = true,
        dictionaryPrefetch: Task<TranslationResult?, Never>? = nil
    ) async throws -> TranslationResult? {
        try await route(
            TranslationRequest(
                candidate: candidate,
                direction: .simplifiedChineseToEnglish
            ),
            mode: mode,
            includesAlternatives: includesAlternatives,
            dictionaryPrefetch: dictionaryPrefetch
        )
    }
}
