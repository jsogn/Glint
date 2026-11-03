import Foundation

public enum ManagedTranslationModelIDs {
    public static let opusMT = "mt-opus-zh-en"
}

@MainActor
public final class TranslationSelectionStore {
    public nonisolated static let defaultModelID =
        SystemTranslationModel.appleTranslationID

    private enum Key {
        static let legacyModelID = "translation.modelID"
        static let target = "translation.targetLanguage"
        static let modelPrefix = "translation.modelID."
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
            legacy == ManagedTranslationModelIDs.opusMT
            ? Self.defaultModelID
            : legacy

        for target in TranslationTarget.allCases {
            guard defaults.object(forKey: modelKey(for: target)) == nil
            else {
                continue
            }
            let modelID =
                target == .english
                ? migratedEnglishModel ?? Self.defaultModelID
                : Self.defaultModelID
            selectModel(modelID, for: target)
        }
        if defaults.object(forKey: Key.target) == nil {
            selectedTarget = .english
        }
        defaults.set(true, forKey: Key.migration)
    }

    private func modelKey(
        for target: TranslationTarget
    ) -> String {
        Key.modelPrefix + target.rawValue
    }
}
