import Foundation

public enum OCRRecognitionStrategy: String, Sendable, Equatable, CaseIterable {
    case automaticFallback
    case dualVerification
    case primaryOnly
}

public struct OCRRecognitionPreferences: Sendable, Equatable {
    public static let visionModelID = "builtin.vision"
    public static let defaultBackupModelID = "ocr-ppocrv6-small"

    public let primaryModelID: String
    public let backupModelID: String?
    public let strategy: OCRRecognitionStrategy

    public init(
        primaryModelID: String = Self.visionModelID,
        backupModelID: String? = Self.defaultBackupModelID,
        strategy: OCRRecognitionStrategy = .automaticFallback
    ) {
        self.primaryModelID = primaryModelID
        self.backupModelID = backupModelID == primaryModelID
            ? nil
            : backupModelID
        self.strategy = strategy
    }

    public static func load(
        from defaults: UserDefaults = .standard
    ) -> OCRRecognitionPreferences {
        let primary = normalizedModelID(
            defaults.string(forKey: Key.primaryModelID)
        ) ?? normalizedModelID(
            defaults.string(forKey: Key.legacyEngineID)
        ) ?? visionModelID
        let strategy = loadStrategy(from: defaults)
        let backup = loadBackup(
            primary: primary,
            strategy: strategy,
            from: defaults
        )
        return OCRRecognitionPreferences(
            primaryModelID: primary,
            backupModelID: backup,
            strategy: strategy
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(primaryModelID, forKey: Key.primaryModelID)
        defaults.set(primaryModelID, forKey: Key.legacyEngineID)
        defaults.set(backupModelID ?? "", forKey: Key.backupModelID)
        defaults.set(strategy.rawValue, forKey: Key.strategy)
        defaults.set(
            strategy.legacyEnhancementMode,
            forKey: Key.legacyEnhancementMode
        )
    }

    private static func loadBackup(
        primary: String,
        strategy: OCRRecognitionStrategy,
        from defaults: UserDefaults
    ) -> String? {
        if let stored = defaults.string(forKey: Key.backupModelID) {
            let normalized = normalizedModelID(stored)
            return normalized == primary ? nil : normalized
        }

        guard primary == visionModelID,
              strategy != .primaryOnly,
              defaults.string(forKey: Key.legacyEnhancementMode) != "off" else {
            return nil
        }
        return defaultBackupModelID
    }

    private static func loadStrategy(
        from defaults: UserDefaults
    ) -> OCRRecognitionStrategy {
        if let stored = defaults.string(forKey: Key.strategy),
           let strategy = OCRRecognitionStrategy(rawValue: stored) {
            return strategy
        }
        switch defaults.string(forKey: Key.legacyEnhancementMode) {
        case "always":
            return .dualVerification
        case "off":
            return .primaryOnly
        default:
            return .automaticFallback
        }
    }

    private static func normalizedModelID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }

    private enum Key {
        static let primaryModelID = "ocr.primaryModelID"
        static let backupModelID = "ocr.backupModelID"
        static let strategy = "ocr.strategy"
        static let legacyEngineID = "ocr.engineID"
        static let legacyEnhancementMode = "ocr.enhancementMode"
    }
}

private extension OCRRecognitionStrategy {
    var legacyEnhancementMode: String {
        switch self {
        case .automaticFallback:
            return "automatic"
        case .dualVerification:
            return "always"
        case .primaryOnly:
            return "off"
        }
    }
}
