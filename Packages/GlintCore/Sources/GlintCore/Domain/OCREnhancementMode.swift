import Foundation

public enum OCREnhancementMode: String, Sendable, Equatable, CaseIterable {
    case automatic
    case always
    case off
}

public enum OCREnhancementSelection {
    public static let defaultsKey = "ocr.enhancementMode"

    public static func selected(
        in defaults: UserDefaults = .standard
    ) -> OCREnhancementMode {
        guard let stored = defaults.string(forKey: defaultsKey),
              let mode = OCREnhancementMode(rawValue: stored) else {
            return .automatic
        }
        return mode
    }

    public static func select(
        _ mode: OCREnhancementMode,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}
