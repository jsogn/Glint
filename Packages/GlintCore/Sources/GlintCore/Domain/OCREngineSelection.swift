import Foundation

public enum OCREngineSelection {
    public static let visionEngineID = "builtin.vision"
    public static let preferenceKey = "ocr.engineID"

    public static func selected(in defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: preferenceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return visionEngineID
        }
        return value
    }

    public static func select(
        _ engineID: String,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(engineID, forKey: preferenceKey)
    }
}
