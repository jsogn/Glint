import Foundation
import GlintCore
import Observation

@MainActor
@Observable
public final class GeneralPreferences {
    private enum Key {
        static let insertionShortcut =
            "general.translationInsertionShortcut"
        static let insertionEnabled =
            "general.translationInsertionEnabled"
    }

    public private(set) var insertionShortcut:
        TranslationInsertionShortcut
    public private(set) var insertionEnabled: Bool

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    public var insertionShortcutDidChange:
        (@MainActor (TranslationInsertionShortcut) -> Void)?
    @ObservationIgnored
    public var insertionEnabledDidChange:
        (@MainActor (Bool) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        insertionEnabled =
            defaults.object(forKey: Key.insertionEnabled) as? Bool
            ?? true
        let stored = defaults.data(forKey: Key.insertionShortcut)
        let decoded = stored.flatMap {
            try? JSONDecoder().decode(
                TranslationInsertionShortcut.self,
                from: $0
            )
        }
        if let decoded, decoded.isValid {
            insertionShortcut = decoded
        } else {
            insertionShortcut =
                TranslationInsertionShortcut.defaultTrigger
        }
    }

    public func setInsertionShortcut(
        _ shortcut: TranslationInsertionShortcut
    ) -> String? {
        guard shortcut.isValid else {
            return "请选择一个触发修饰键"
        }
        insertionShortcut = shortcut
        persist(shortcut)
        insertionShortcutDidChange?(shortcut)
        return nil
    }

    public func setInsertionEnabled(_ enabled: Bool) {
        guard insertionEnabled != enabled else { return }
        insertionEnabled = enabled
        defaults.set(enabled, forKey: Key.insertionEnabled)
        insertionEnabledDidChange?(enabled)
    }

    public func resetInsertionShortcut() {
        insertionShortcut =
            TranslationInsertionShortcut.defaultTrigger
        persist(insertionShortcut)
        insertionShortcutDidChange?(insertionShortcut)
    }

    public func resetInsertionSettings() {
        _ = setInsertionShortcut(
            TranslationInsertionShortcut.defaultTrigger
        )
        setInsertionEnabled(true)
    }

    private func persist(
        _ shortcut: TranslationInsertionShortcut
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: Key.insertionShortcut)
    }
}
