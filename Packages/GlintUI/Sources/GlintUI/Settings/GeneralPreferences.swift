import Foundation
import GlintCore
import Observation

public enum TranslationSpeechAccent: String, CaseIterable, Sendable {
    case system
    case american
    case british

    public var title: String {
        switch self {
        case .system: return "系统默认"
        case .american: return "美式英语"
        case .british: return "英式英语"
        }
    }

    public func languageCode(
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        switch self {
        case .system:
            return preferredLanguages.first {
                $0.hasPrefix("en")
            } ?? "en-US"
        case .american: return "en-US"
        case .british: return "en-GB"
        }
    }
}

public enum TranslationSpeechRate: String, CaseIterable, Sendable {
    case slower
    case standard
    case faster

    public var title: String {
        switch self {
        case .slower: return "较慢"
        case .standard: return "标准"
        case .faster: return "较快"
        }
    }
}

@MainActor
@Observable
public final class GeneralPreferences {
    public static let defaultSpeechShortcut =
        TranslationInsertionShortcut(
            modifiers: [.command]
        )
    public static let autoSpeechDelayRange = 0.5...3.0
    public static let defaultAutoSpeechDelay = 1.2

    private static let legacyCombinedSpeechDefault =
        TranslationInsertionShortcut(
            modifiers: [.control, .option]
        )
    private static let legacyReservedSpeechDefault =
        TranslationInsertionShortcut(
            modifiers: [.control]
        )

    private enum Key {
        static let insertionShortcut =
            "general.translationInsertionShortcut"
        static let insertionEnabled =
            "general.translationInsertionEnabled"
        static let speechShortcut =
            "general.translationSpeechShortcut"
        static let manualSpeechEnabled =
            "general.translationSpeechEnabled"
        static let speechAccent =
            "general.translationSpeechAccent"
        static let speechVoicePrefix =
            "general.translationSpeechVoice."
        static let speechRate =
            "general.translationSpeechRate"
        static let autoSpeechEnabled =
            "general.translationAutoSpeechEnabled"
        static let autoSpeechDelay =
            "general.translationAutoSpeechDelay"
    }

    public private(set) var insertionShortcut: TranslationInsertionShortcut?
    public private(set) var speechShortcut: TranslationInsertionShortcut?
    public private(set) var speechAccent: TranslationSpeechAccent
    public private(set) var speechVoiceIdentifiers:
        [TranslationTarget: String]
    public private(set) var speechRate: TranslationSpeechRate
    public private(set) var autoSpeechEnabled: Bool
    public private(set) var autoSpeechDelay: Double

    public var insertionEnabled: Bool {
        insertionShortcut != nil
    }

    public var manualSpeechEnabled: Bool {
        speechShortcut != nil
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    public var insertionShortcutDidChange: (@MainActor (TranslationInsertionShortcut?) -> Void)?
    @ObservationIgnored
    public var speechShortcutDidChange: (@MainActor (TranslationInsertionShortcut?) -> Void)?
    @ObservationIgnored
    public var speechAccentDidChange: (@MainActor (TranslationSpeechAccent) -> Void)?
    @ObservationIgnored
    public var speechVoiceDidChange: (@MainActor () -> Void)?
    @ObservationIgnored
    public var speechRateDidChange: (@MainActor (TranslationSpeechRate) -> Void)?
    @ObservationIgnored
    public var autoSpeechEnabledDidChange: (@MainActor (Bool) -> Void)?
    @ObservationIgnored
    public var autoSpeechDelayDidChange: (@MainActor (Double) -> Void)?
    @ObservationIgnored
    public var shortcutAvailabilityCheck: @MainActor (TranslationInsertionShortcut) -> Bool = { _ in true }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let insertionWasEnabled =
            defaults.object(forKey: Key.insertionEnabled) as? Bool
            ?? true
        let stored = defaults.data(forKey: Key.insertionShortcut)
        let decoded = stored.flatMap {
            try? JSONDecoder().decode(
                TranslationInsertionShortcut.self,
                from: $0
            )
        }
        let resolvedInsertionShortcut =
            if let decoded, decoded.isValid {
                decoded
            } else {
                TranslationInsertionShortcut.defaultTrigger
            }
        let activeInsertionShortcut =
            insertionWasEnabled ? resolvedInsertionShortcut : nil
        insertionShortcut = activeInsertionShortcut

        let manualSpeechWasEnabled =
            defaults.object(forKey: Key.manualSpeechEnabled) as? Bool
            ?? true
        let storedSpeechShortcut = defaults.data(
            forKey: Key.speechShortcut
        ).flatMap {
            try? JSONDecoder().decode(
                TranslationInsertionShortcut.self,
                from: $0
            )
        }
        if let storedSpeechShortcut,
            storedSpeechShortcut.isValid,
            storedSpeechShortcut.modifiers
                != activeInsertionShortcut?.modifiers,
            storedSpeechShortcut != Self.legacyCombinedSpeechDefault,
            storedSpeechShortcut != Self.legacyReservedSpeechDefault
        {
            speechShortcut = storedSpeechShortcut
        } else {
            speechShortcut = Self.defaultSpeechShortcut(
                avoiding: activeInsertionShortcut?.modifiers
            )
        }
        if !manualSpeechWasEnabled {
            speechShortcut = nil
        }
        speechAccent =
            defaults.string(forKey: Key.speechAccent).flatMap(
                TranslationSpeechAccent.init(rawValue:)
            ) ?? .system
        speechVoiceIdentifiers = Self.loadSpeechVoiceIdentifiers(
            from: defaults
        )
        speechRate =
            defaults.string(forKey: Key.speechRate).flatMap(
                TranslationSpeechRate.init(rawValue:)
            ) ?? .standard
        autoSpeechEnabled =
            defaults.object(forKey: Key.autoSpeechEnabled) as? Bool
            ?? false
        let storedAutoSpeechDelay =
            defaults.object(forKey: Key.autoSpeechDelay) as? Double
        let resolvedAutoSpeechDelay = Self.clampedAutoSpeechDelay(
            storedAutoSpeechDelay ?? Self.defaultAutoSpeechDelay
        )
        autoSpeechDelay = resolvedAutoSpeechDelay
        if let speechShortcut,
            storedSpeechShortcut != speechShortcut
        {
            persist(speechShortcut, forKey: Key.speechShortcut)
        }
        if storedAutoSpeechDelay != resolvedAutoSpeechDelay {
            defaults.set(
                resolvedAutoSpeechDelay,
                forKey: Key.autoSpeechDelay
            )
        }
    }

    public func setInsertionShortcut(
        _ shortcut: TranslationInsertionShortcut?
    ) -> String? {
        guard insertionShortcut != shortcut else { return nil }
        if let shortcut {
            guard shortcut.isValid else {
                return "请选择一个触发修饰键"
            }
            if let speechShortcut,
                shortcut.modifiers == speechShortcut.modifiers
            {
                return "释义插入触发键不能与朗读相同"
            }
            guard shortcutAvailabilityCheck(shortcut) else {
                return "该快捷键组合已被系统或其他应用占用"
            }
            insertionShortcut = shortcut
            persist(shortcut)
            defaults.set(true, forKey: Key.insertionEnabled)
        } else {
            insertionShortcut = nil
            defaults.set(false, forKey: Key.insertionEnabled)
        }
        insertionShortcutDidChange?(shortcut)
        return nil
    }

    public func setSpeechShortcut(
        _ shortcut: TranslationInsertionShortcut?
    ) -> String? {
        guard speechShortcut != shortcut else { return nil }
        if let shortcut {
            guard shortcut.isValid else {
                return "请选择一个触发修饰键"
            }
            if let insertionShortcut,
                shortcut.modifiers == insertionShortcut.modifiers
            {
                return "朗读触发键不能与释义插入相同"
            }
            guard shortcutAvailabilityCheck(shortcut) else {
                return "该快捷键组合已被系统或其他应用占用"
            }
            speechShortcut = shortcut
            persist(shortcut, forKey: Key.speechShortcut)
            defaults.set(true, forKey: Key.manualSpeechEnabled)
        } else {
            speechShortcut = nil
            defaults.set(false, forKey: Key.manualSpeechEnabled)
        }
        speechShortcutDidChange?(shortcut)
        return nil
    }

    public func setSpeechAccent(_ accent: TranslationSpeechAccent) {
        guard speechAccent != accent else { return }
        speechAccent = accent
        defaults.set(accent.rawValue, forKey: Key.speechAccent)
        speechAccentDidChange?(accent)
    }

    public func speechVoiceIdentifier(
        for target: TranslationTarget
    ) -> String? {
        speechVoiceIdentifiers[target]
    }

    public func setSpeechVoiceIdentifier(
        _ identifier: String?,
        for target: TranslationTarget
    ) {
        let normalized =
            identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        guard speechVoiceIdentifiers[target] != normalized else {
            return
        }
        if let normalized {
            speechVoiceIdentifiers[target] = normalized
            defaults.set(
                normalized,
                forKey: Self.speechVoiceKey(for: target)
            )
        } else {
            speechVoiceIdentifiers.removeValue(forKey: target)
            defaults.removeObject(
                forKey: Self.speechVoiceKey(for: target)
            )
        }
        speechVoiceDidChange?()
    }

    public func setSpeechRate(_ rate: TranslationSpeechRate) {
        guard speechRate != rate else { return }
        speechRate = rate
        defaults.set(rate.rawValue, forKey: Key.speechRate)
        speechRateDidChange?(rate)
    }

    public func setAutoSpeechEnabled(_ enabled: Bool) {
        guard autoSpeechEnabled != enabled else { return }
        autoSpeechEnabled = enabled
        defaults.set(enabled, forKey: Key.autoSpeechEnabled)
        autoSpeechEnabledDidChange?(enabled)
    }

    public func setAutoSpeechDelay(_ delay: Double) {
        let clamped = Self.clampedAutoSpeechDelay(delay)
        guard autoSpeechDelay != clamped else { return }
        autoSpeechDelay = clamped
        defaults.set(clamped, forKey: Key.autoSpeechDelay)
        autoSpeechDelayDidChange?(clamped)
    }

    public func resetInsertionShortcut() {
        _ = setInsertionShortcut(
            Self.defaultInsertionShortcut(
                avoiding: speechShortcut?.modifiers
            )
        )
    }

    public func resetInsertionSettings() {
        _ = setInsertionShortcut(
            Self.defaultInsertionShortcut(
                avoiding: speechShortcut?.modifiers
            )
        )
    }

    public func resetSpeechSettings() {
        _ = setSpeechShortcut(
            Self.defaultSpeechShortcut(
                avoiding: insertionShortcut?.modifiers
            )
        )
        setSpeechAccent(.system)
        clearSpeechVoiceIdentifiers()
        setSpeechRate(.standard)
        setAutoSpeechEnabled(false)
        setAutoSpeechDelay(Self.defaultAutoSpeechDelay)
    }

    private func persist(
        _ shortcut: TranslationInsertionShortcut
    ) {
        persist(shortcut, forKey: Key.insertionShortcut)
    }

    private func persist(
        _ shortcut: TranslationInsertionShortcut,
        forKey key: String
    ) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func clearSpeechVoiceIdentifiers() {
        guard !speechVoiceIdentifiers.isEmpty else { return }
        for target in TranslationTarget.allCases {
            defaults.removeObject(forKey: Self.speechVoiceKey(for: target))
        }
        speechVoiceIdentifiers.removeAll()
        speechVoiceDidChange?()
    }

    private static func loadSpeechVoiceIdentifiers(
        from defaults: UserDefaults
    ) -> [TranslationTarget: String] {
        var voices: [TranslationTarget: String] = [:]
        for target in TranslationTarget.allCases {
            if let voice = defaults.string(
                forKey: speechVoiceKey(for: target)
            )?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty
            {
                voices[target] = voice
            }
        }
        return voices
    }

    private static func speechVoiceKey(
        for target: TranslationTarget
    ) -> String {
        Key.speechVoicePrefix + target.rawValue
    }

    private static func defaultSpeechShortcut(
        avoiding modifiers: TranslationInsertionModifiers?
    ) -> TranslationInsertionShortcut {
        guard let modifiers else {
            return Self.defaultSpeechShortcut
        }
        if Self.defaultSpeechShortcut.modifiers != modifiers {
            return Self.defaultSpeechShortcut
        }
        let candidates: [TranslationInsertionModifiers] = [
            [.command],
            [.shift],
            [.capsLock],
        ]
        return TranslationInsertionShortcut(
            modifiers: candidates.first { $0 != modifiers }
                ?? [.control]
        )
    }

    private static func defaultInsertionShortcut(
        avoiding modifiers: TranslationInsertionModifiers?
    ) -> TranslationInsertionShortcut {
        guard let modifiers else {
            return TranslationInsertionShortcut.defaultTrigger
        }
        if TranslationInsertionShortcut.defaultTrigger.modifiers
            != modifiers
        {
            return TranslationInsertionShortcut.defaultTrigger
        }
        let candidates: [TranslationInsertionModifiers] = [
            [.command],
            [.shift],
            [.capsLock],
        ]
        return TranslationInsertionShortcut(
            modifiers: candidates.first { $0 != modifiers }
                ?? [.command]
        )
    }

    private static func clampedAutoSpeechDelay(_ value: Double) -> Double {
        guard value.isFinite else {
            return Self.defaultAutoSpeechDelay
        }
        return min(
            max(value, Self.autoSpeechDelayRange.lowerBound),
            Self.autoSpeechDelayRange.upperBound
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
