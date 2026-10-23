public protocol DictionaryEngine: Sendable {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult?
}

public protocol TranslationEngine: Sendable {
    func translate(_ candidate: Candidate) async throws -> TranslationResult?
}

public enum GlintError: Error, Sendable, Equatable {
    case engineUnavailable
}
