import Foundation

public enum TranslationModeSelection {
    public static let defaultsKey = "translation.mode"

    public static func selected(in defaults: UserDefaults = .standard) -> TranslationMode {
        guard let stored = defaults.string(forKey: defaultsKey),
              let mode = TranslationMode(rawValue: stored) else {
            return .dictionaryFirst
        }
        return mode
    }

    public static func select(
        _ mode: TranslationMode,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}
