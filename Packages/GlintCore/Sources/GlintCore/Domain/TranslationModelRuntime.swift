import Foundation

public enum TranslationPromptProfile: String, Codable, Sendable {
    case qwenGeneral = "qwen-general"
    case hyMT2 = "hy-mt2"
    case indexTranslate = "index-translate"
    case generic = "generic"

    public static func inferred(from modelID: String) -> Self {
        if modelID.hasPrefix("mt-hy-mt2-") {
            return .hyMT2
        }
        if modelID.hasPrefix("mt-index-translate-") {
            return .indexTranslate
        }
        if modelID.hasPrefix("llm-qwen3-") {
            return .qwenGeneral
        }
        return .generic
    }
}

public enum TranslationAdapterMode: String, Codable, Sendable {
    case directSource = "direct-source"
    case translationInstruction = "translation-instruction"
    case systemInstruction = "system-instruction"
}

public struct ResolvedTranslationModel:
    Sendable, Equatable
{
    public enum Storage: Sendable, Equatable {
        case mlx(
            directory: URL,
            promptProfile: TranslationPromptProfile
        )
        case ctranslate2(directory: URL)
    }

    public let modelID: String
    public let storage: Storage
    public let supportedDirections: Set<TranslationDirection>

    public init(
        modelID: String,
        storage: Storage,
        supportedDirections: Set<TranslationDirection>
    ) {
        self.modelID = modelID
        self.storage = storage
        self.supportedDirections = supportedDirections
    }
}
