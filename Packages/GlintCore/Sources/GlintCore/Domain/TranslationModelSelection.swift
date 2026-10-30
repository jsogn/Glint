import Foundation

public enum TranslationModelSelection {
    public static let defaultsKey = "translation.modelID"
    public static let opusMTModelID = "mt-opus-zh-en"
    public static let defaultModelID =
        SystemTranslationModel.appleTranslationID
    private static let bundledModelMigrationKey =
        "translation.bundledModelMigration.v1"

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

    public static func migrateBundledModelSelection(
        in defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: bundledModelMigrationKey) else {
            return
        }
        let stored = defaults.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stored == opusMTModelID {
            select(defaultModelID, in: defaults)
        }
        defaults.set(true, forKey: bundledModelMigrationKey)
    }
}
