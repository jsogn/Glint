import GlintCore

public struct SystemTranslationEngine: TranslationEngine {
    private let coordinator: SystemTranslationCoordinator

    public init(coordinator: SystemTranslationCoordinator) {
        self.coordinator = coordinator
    }

    public func translate(
        _ candidate: Candidate
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        let output = try await coordinator.translate(candidate.text)
        try Task.checkCancellation()
        return output.isEmpty ? nil : TranslationResult(text: output)
    }
}
