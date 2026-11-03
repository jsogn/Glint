import GlintCore

public struct SystemTranslationEngine: TranslationEngine {
    private let coordinator: SystemTranslationCoordinator

    public init(coordinator: SystemTranslationCoordinator) {
        self.coordinator = coordinator
    }

    public func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        direction.source == .simplifiedChinese
    }

    public func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        let output = try await coordinator.translate(
            request.candidate.text,
            direction: request.direction
        )
        try Task.checkCancellation()
        return output.isEmpty ? nil : TranslationResult(text: output)
    }
}
