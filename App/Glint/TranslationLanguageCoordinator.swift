import GlintCore
import GlintInference
import GlintMac

extension SystemTranslationCoordinator:
    @retroactive SystemTranslationLanguageProviding {}

@MainActor
final class TranslationLanguageRuntimeAdapter:
    TranslationLanguageRuntimeProviding
{
    private let runtime: TranslationRuntime

    init(runtime: TranslationRuntime) {
        self.runtime = runtime
    }

    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        await runtime.prepare(
            modelID: modelID,
            direction: direction
        )
    }

    func releaseResources(for modelID: String) async {
        await runtime.releaseResources(for: modelID)
    }
}

