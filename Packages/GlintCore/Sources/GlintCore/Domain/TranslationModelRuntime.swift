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

public enum ResolvedTranslationModel: Sendable, Equatable {
    case mlx(
        modelID: String,
        directory: URL,
        promptProfile: TranslationPromptProfile
    )
    case ctranslate2(modelID: String, directory: URL)

    public var modelID: String {
        switch self {
        case let .mlx(modelID, _, _):
            modelID
        case let .ctranslate2(modelID, _):
            modelID
        }
    }
}
