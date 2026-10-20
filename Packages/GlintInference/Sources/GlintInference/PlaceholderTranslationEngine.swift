import GlintCore

/// M1 selects the actual runtime (CTranslate2 / MLX) before this is implemented.
public struct PlaceholderTranslationEngine: TranslationEngine {
    public init() {}

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}
