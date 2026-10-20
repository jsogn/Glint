import Foundation

public enum TranslationModelSelection {
    public static let defaultsKey = "translation.modelID"
    public static let defaultModelID = "mt-opus-zh-en"
    public static let openAICompatibleModelID = "external-openai-compatible"
    public static let openAICompatibleModelPrefix =
        "external-openai-compatible:"
    public static let mlxModelPrefix = "llm-qwen3-"
    public static let mlxModelPrefixes = [
        mlxModelPrefix,
        "mt-hy-mt2-",
        "mt-index-translate-",
    ]

    public static func selected(in defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stored?.isEmpty == false ? stored! : defaultModelID
    }

    public static func select(
        _ modelID: String,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(modelID, forKey: defaultsKey)
    }

    public static func usesMLX(_ modelID: String) -> Bool {
        mlxModelPrefixes.contains { modelID.hasPrefix($0) }
    }

    public static func openAICompatibleSelectionID(
        for providerID: String
    ) -> String {
        openAICompatibleModelPrefix + providerID
    }

    public static func openAIProviderID(fromSelectionID modelID: String) -> String? {
        guard modelID.hasPrefix(openAICompatibleModelPrefix) else {
            return nil
        }
        return String(modelID.dropFirst(openAICompatibleModelPrefix.count))
    }
}
