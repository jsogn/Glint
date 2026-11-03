import Foundation

@MainActor
public final class TranslationSelectionStore {
    public static let defaultModelID =
        SystemTranslationModel.appleTranslationID

    private enum Key {
        static let legacyModelID = "translation.modelID"
        static let target = "translation.targetLanguage"
        static let modelEnglish = "translation.modelID.en"
        static let modelJapanese = "translation.modelID.ja"
        static let migration = "translation.multilingualMigration.v1"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var selectedTarget: TranslationTarget {
        get {
            defaults.string(forKey: Key.target)
                .flatMap(TranslationTarget.init(rawValue:))
                ?? .english
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.target)
        }
    }

    public func selectedModelID(
        for target: TranslationTarget
    ) -> String {
        let value = defaults.string(forKey: modelKey(for: target))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return Self.defaultModelID
        }
        return value
    }

    public func selectModel(
        _ modelID: String,
        for target: TranslationTarget
    ) {
        let trimmed = modelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        defaults.set(
            trimmed.isEmpty ? Self.defaultModelID : trimmed,
            forKey: modelKey(for: target)
        )
    }

    public func migrateIfNeeded() {
        guard !defaults.bool(forKey: Key.migration) else { return }

        let legacy = defaults.string(forKey: Key.legacyModelID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let migratedEnglishModel =
            legacy == TranslationModelSelection.opusMTModelID
            ? Self.defaultModelID
            : legacy

        if defaults.object(forKey: Key.modelEnglish) == nil {
            selectModel(
                migratedEnglishModel ?? Self.defaultModelID,
                for: .english
            )
        }
        if defaults.object(forKey: Key.modelJapanese) == nil {
            selectModel(Self.defaultModelID, for: .japanese)
        }
        if defaults.object(forKey: Key.target) == nil {
            selectedTarget = .english
        }
        defaults.set(true, forKey: Key.migration)
    }

    private func modelKey(
        for target: TranslationTarget
    ) -> String {
        switch target {
        case .english: Key.modelEnglish
        case .japanese: Key.modelJapanese
        }
    }
}
