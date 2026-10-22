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
        mode: TranslationMode = .dictionaryFirst
    ) async throws -> TranslationResult? {
        guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        switch mode {
        case .dictionaryFirst:
            if let dictionaryResult = try? await dictionary.lookup(candidate) {
                return dictionaryResult
            }
            return try await translation.translate(candidate)
        case .modelFirst:
            if let modelResult = try? await translation.translate(candidate),
               !modelResult.options.isEmpty {
                guard candidate.kind != .sentence,
                      let dictionaryResult = try? await dictionary.lookup(
                          candidate
                      ),
                      !dictionaryResult.options.isEmpty else {
                    return modelResult
                }
                return Self.modelFirstMerged(
                    model: modelResult,
                    dictionary: dictionaryResult
                )
            }
            return try await dictionary.lookup(candidate)
        }
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
            options: model.options + dictionaryOptions,
            source: .translation,
            confidence: model.confidence
        )
    }
}
