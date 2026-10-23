import Foundation

public struct SmartRouter: Sendable {
    private let dictionary: any DictionaryEngine
    private let translation: any TranslationEngine

    public init(dictionary: any DictionaryEngine, translation: any TranslationEngine) {
        self.dictionary = dictionary
        self.translation = translation
    }

    public func route(
        _ candidate: Candidate,
        mode: TranslationMode = .dictionaryFirst,
        includesAlternatives: Bool = true,
        dictionaryPrefetch: Task<TranslationResult?, Never>? = nil
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        switch mode {
        case .dictionaryFirst:
            if let dictionaryResult = await dictionaryResult(
                for: candidate,
                prefetch: dictionaryPrefetch
            ) {
                return dictionaryResult
            }
            try Task.checkCancellation()
            return try await translation.translate(candidate)
        case .modelFirst:
            if let modelResult = try? await translation.translate(candidate),
                !modelResult.options.isEmpty
            {
                guard includesAlternatives,
                    candidate.kind != .sentence,
                    let dictionaryResult = await dictionaryResult(
                        for: candidate,
                        prefetch: dictionaryPrefetch
                    ),
                    !dictionaryResult.options.isEmpty
                else {
                    return modelResult
                }
                return Self.modelFirstMerged(
                    model: modelResult,
                    dictionary: dictionaryResult
                )
            }
            try Task.checkCancellation()
            return await dictionaryResult(
                for: candidate,
                prefetch: dictionaryPrefetch
            )
        }
    }

    public func prefetchDictionary(
        _ candidate: Candidate
    ) async -> TranslationResult? {
        guard !Task.isCancelled else {
            return nil
        }
        let result = try? await dictionary.lookup(candidate)
        return Task.isCancelled ? nil : result
    }

    private func dictionaryResult(
        for candidate: Candidate,
        prefetch: Task<TranslationResult?, Never>?
    ) async -> TranslationResult? {
        if let prefetch {
            return await prefetch.value
        }
        return try? await dictionary.lookup(candidate)
    }

    private static func modelFirstMerged(
        model: TranslationResult,
        dictionary: TranslationResult
    ) -> TranslationResult {
        guard let lastModelScore = model.options.last?.score else {
            return dictionary
        }
        let firstDictionaryScore = lastModelScore - 0.0001
        let dictionaryOptions = dictionary.options.enumerated().map {
            index, option in
            TranslationOption(
                text: option.text,
                score: firstDictionaryScore - Double(index) * 0.000001
            )
        }
        return TranslationResult(
            options: model.options + dictionaryOptions
        )
    }
}
