import Foundation

public enum TranslationModelSelection {
    public static let defaultsKey = "translation.modelID"
    public static let defaultModelID = "mt-opus-zh-en"

    public static func selected(in defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return defaultModelID }
        return stored
    }

    public static func select(
        _ modelID: String,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(modelID, forKey: defaultsKey)
    }

    public static func isSystemTranslation(_ modelID: String) -> Bool {
        modelID == SystemTranslationModel.appleTranslationID
    }
}
