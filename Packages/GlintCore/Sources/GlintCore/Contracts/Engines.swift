public protocol DictionaryEngine: Sendable {
    func lookup(
        _ request: TranslationRequest
    ) async throws -> TranslationResult?
}

public protocol TranslationEngine: Sendable {
    func supports(
        _ direction: TranslationDirection
    ) async -> Bool
    func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult?
}

public protocol PartOfSpeechProviding: Sendable {
    func partsOfSpeech(forEnglish word: String) async -> [PartOfSpeech]
}

public enum GlintError: Error, Sendable, Equatable {
    case engineUnavailable
}
