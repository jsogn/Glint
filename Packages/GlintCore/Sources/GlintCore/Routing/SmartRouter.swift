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
            if let modelResult = try? await translation.translate(candidate) {
                return modelResult
            }
            return try await dictionary.lookup(candidate)
        }
    }
}
