import Foundation
import GlintCore
import XCTest

@testable import GlintUI

final class GeneralPreferencesTests: XCTestCase {
    @MainActor
    func testInsertionShortcutCanBeClearedAndPersists() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = GeneralPreferences(defaults: defaults)
        XCTAssertTrue(first.insertionEnabled)
        var observed: [TranslationInsertionShortcut?] = []
        first.insertionShortcutDidChange = {
            observed.append($0)
        }

        XCTAssertNil(first.setInsertionShortcut(nil))

        XCTAssertFalse(first.insertionEnabled)
        XCTAssertNil(first.insertionShortcut)
        XCTAssertEqual(observed.count, 1)
        XCTAssertNil(observed.first ?? nil)
        XCTAssertFalse(GeneralPreferences(defaults: defaults).insertionEnabled)
    }

    @MainActor
    func testSpeechSettingsDefaultAndPersist() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = GeneralPreferences(defaults: defaults)
        XCTAssertTrue(first.manualSpeechEnabled)
        XCTAssertEqual(first.speechAccent, .system)
        XCTAssertEqual(first.speechRate, .standard)
        XCTAssertEqual(
            first.speechShortcut?.modifiers,
            [.command]
        )
        XCTAssertFalse(first.autoSpeechEnabled)
        XCTAssertEqual(
            first.autoSpeechDelay,
            GeneralPreferences.defaultAutoSpeechDelay
        )

        XCTAssertNil(first.setSpeechShortcut(nil))
        first.setSpeechAccent(.british)
        first.setSpeechRate(.slower)
        first.setAutoSpeechEnabled(true)
        first.setAutoSpeechDelay(1.8)

        let reloaded = GeneralPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.manualSpeechEnabled)
        XCTAssertEqual(reloaded.speechAccent, .british)
        XCTAssertEqual(reloaded.speechRate, .slower)
        XCTAssertNil(reloaded.speechShortcut)
        XCTAssertTrue(reloaded.autoSpeechEnabled)
        XCTAssertEqual(reloaded.autoSpeechDelay, 1.8)
    }

    @MainActor
    func testSpeechShortcutPersistsWhenSet() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let shortcut = TranslationInsertionShortcut(
            modifiers: [.command, .option]
        )

        XCTAssertNil(preferences.setSpeechShortcut(shortcut))

        let reloaded = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.speechShortcut, shortcut)
        XCTAssertTrue(reloaded.manualSpeechEnabled)
    }

    @MainActor
    func testSpeechVoicesPersistPerTargetAndClear() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        var observedChangeCount = 0
        preferences.speechVoiceDidChange = {
            observedChangeCount += 1
        }

        XCTAssertNil(
            preferences.speechVoiceIdentifier(for: .japanese)
        )
        preferences.setSpeechVoiceIdentifier(
            "  com.apple.voice.compact.ja-JP.Kyoko  ",
            for: .japanese
        )
        preferences.setSpeechVoiceIdentifier(
            "com.apple.voice.compact.es-ES.Mónica",
            for: .spanish
        )

        XCTAssertEqual(
            preferences.speechVoiceIdentifier(for: .japanese),
            "com.apple.voice.compact.ja-JP.Kyoko"
        )
        XCTAssertEqual(
            GeneralPreferences(defaults: defaults)
                .speechVoiceIdentifier(for: .japanese),
            "com.apple.voice.compact.ja-JP.Kyoko"
        )
        XCTAssertEqual(
            GeneralPreferences(defaults: defaults)
                .speechVoiceIdentifier(for: .spanish),
            "com.apple.voice.compact.es-ES.Mónica"
        )

        preferences.setSpeechVoiceIdentifier(nil, for: .japanese)

        XCTAssertNil(
            GeneralPreferences(defaults: defaults)
                .speechVoiceIdentifier(for: .japanese)
        )
        XCTAssertEqual(
            GeneralPreferences(defaults: defaults)
                .speechVoiceIdentifier(for: .spanish),
            "com.apple.voice.compact.es-ES.Mónica"
        )
        XCTAssertEqual(observedChangeCount, 3)
    }

    @MainActor
    func testLegacyDisabledFlagsMigrateToEmptyShortcuts() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "general.translationInsertionEnabled")
        defaults.set(false, forKey: "general.translationSpeechEnabled")
        defaults.set(
            try JSONEncoder().encode(
                TranslationInsertionShortcut.defaultTrigger
            ),
            forKey: "general.translationInsertionShortcut"
        )
        defaults.set(
            try JSONEncoder().encode(
                GeneralPreferences.defaultSpeechShortcut
            ),
            forKey: "general.translationSpeechShortcut"
        )

        let preferences = GeneralPreferences(defaults: defaults)

        XCTAssertNil(preferences.insertionShortcut)
        XCTAssertNil(preferences.speechShortcut)
        XCTAssertFalse(preferences.insertionEnabled)
        XCTAssertFalse(preferences.manualSpeechEnabled)
    }

    @MainActor
    func testLegacyCombinedSpeechDefaultMigratesToCommand() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacyDefault = TranslationInsertionShortcut(
            modifiers: [.control, .option]
        )
        defaults.set(
            try JSONEncoder().encode(legacyDefault),
            forKey: "general.translationSpeechShortcut"
        )

        let preferences = GeneralPreferences(defaults: defaults)

        XCTAssertEqual(
            try XCTUnwrap(preferences.speechShortcut).modifiers,
            [.command]
        )
        XCTAssertEqual(
            try XCTUnwrap(
                GeneralPreferences(defaults: defaults).speechShortcut
            ).modifiers,
            [.command]
        )
    }

    @MainActor
    func testReservedControlSpeechDefaultMigratesToCommand() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(
                TranslationInsertionShortcut(modifiers: [.control])
            ),
            forKey: "general.translationSpeechShortcut"
        )

        let preferences = GeneralPreferences(defaults: defaults)

        XCTAssertEqual(
            try XCTUnwrap(preferences.speechShortcut).modifiers,
            [.command]
        )
    }

    @MainActor
    func testSpeechSettingsNotifyObservers() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        var observedShortcuts: [TranslationInsertionShortcut?] = []
        var observedAccents: [TranslationSpeechAccent] = []
        var observedSpeechVoiceChangeCount = 0
        var observedRates: [TranslationSpeechRate] = []
        var observedAutoEnabled: [Bool] = []
        var observedAutoDelays: [Double] = []
        preferences.speechShortcutDidChange = {
            observedShortcuts.append($0)
        }
        preferences.speechAccentDidChange = {
            observedAccents.append($0)
        }
        preferences.speechVoiceDidChange = {
            observedSpeechVoiceChangeCount += 1
        }
        preferences.speechRateDidChange = {
            observedRates.append($0)
        }
        preferences.autoSpeechEnabledDidChange = {
            observedAutoEnabled.append($0)
        }
        preferences.autoSpeechDelayDidChange = {
            observedAutoDelays.append($0)
        }
        let shortcut = TranslationInsertionShortcut(
            modifiers: [.command, .option]
        )

        XCTAssertNil(preferences.setSpeechShortcut(shortcut))
        XCTAssertNil(preferences.setSpeechShortcut(nil))
        preferences.setSpeechAccent(.british)
        preferences.setSpeechVoiceIdentifier("ja.voice", for: .japanese)
        preferences.setSpeechVoiceIdentifier("es.voice", for: .spanish)
        preferences.setSpeechRate(.faster)
        preferences.setAutoSpeechEnabled(true)
        preferences.setAutoSpeechDelay(2.1)

        XCTAssertEqual(observedShortcuts, [shortcut, nil])
        XCTAssertEqual(observedAccents, [.british])
        XCTAssertEqual(observedSpeechVoiceChangeCount, 2)
        XCTAssertEqual(observedRates, [.faster])
        XCTAssertEqual(observedAutoEnabled, [true])
        XCTAssertEqual(observedAutoDelays, [2.1])
    }

    @MainActor
    func testAutoSpeechDelayIsClampedAndPersisted() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)

        preferences.setAutoSpeechDelay(0.1)
        XCTAssertEqual(
            preferences.autoSpeechDelay,
            GeneralPreferences.autoSpeechDelayRange.lowerBound
        )

        preferences.setAutoSpeechDelay(8)
        XCTAssertEqual(
            preferences.autoSpeechDelay,
            GeneralPreferences.autoSpeechDelayRange.upperBound
        )

        preferences.setAutoSpeechDelay(.infinity)
        XCTAssertEqual(
            preferences.autoSpeechDelay,
            GeneralPreferences.defaultAutoSpeechDelay
        )
        XCTAssertEqual(
            GeneralPreferences(defaults: defaults).autoSpeechDelay,
            GeneralPreferences.defaultAutoSpeechDelay
        )
    }

    @MainActor
    func testInvalidStoredSpeechAccentFallsBackToSystem() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "unsupported",
            forKey: "general.translationSpeechAccent"
        )

        let preferences = GeneralPreferences(defaults: defaults)

        XCTAssertEqual(preferences.speechAccent, .system)
    }

    @MainActor
    func testInvalidStoredSpeechRateFallsBackToStandard() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "unsupported",
            forKey: "general.translationSpeechRate"
        )

        let preferences = GeneralPreferences(defaults: defaults)

        XCTAssertEqual(preferences.speechRate, .standard)
    }

    @MainActor
    func testUnavailableShortcutIsRejectedBeforeSaving() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let originalInsertion = preferences.insertionShortcut
        let originalSpeech = preferences.speechShortcut
        preferences.shortcutAvailabilityCheck = { _ in false }

        let insertionError = preferences.setInsertionShortcut(
            TranslationInsertionShortcut(
                modifiers: [.option, .shift]
            )
        )
        let speechError = preferences.setSpeechShortcut(
            TranslationInsertionShortcut(
                modifiers: [.command, .shift]
            )
        )

        XCTAssertEqual(
            insertionError,
            "该快捷键组合已被系统或其他应用占用"
        )
        XCTAssertEqual(
            speechError,
            "该快捷键组合已被系统或其他应用占用"
        )
        XCTAssertEqual(preferences.insertionShortcut, originalInsertion)
        XCTAssertEqual(preferences.speechShortcut, originalSpeech)
    }

    @MainActor
    func testSpeechShortcutRejectsCollisionWithInsertion() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let original = preferences.speechShortcut

        XCTAssertNotNil(
            preferences.setSpeechShortcut(
                try XCTUnwrap(preferences.insertionShortcut)
            )
        )

        XCTAssertEqual(preferences.speechShortcut, original)
    }

    @MainActor
    func testInsertionShortcutRejectsCollisionWithSpeech() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let original = preferences.insertionShortcut

        XCTAssertNotNil(
            preferences.setInsertionShortcut(
                try XCTUnwrap(preferences.speechShortcut)
            )
        )

        XCTAssertEqual(preferences.insertionShortcut, original)
    }

    @MainActor
    func testClearingShortcutFreesModifierForTheOtherAction() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let freedShortcut = try XCTUnwrap(preferences.insertionShortcut)

        XCTAssertNil(preferences.setInsertionShortcut(nil))
        XCTAssertNil(preferences.setSpeechShortcut(freedShortcut))

        XCTAssertEqual(preferences.speechShortcut, freedShortcut)
    }

    @MainActor
    func testStoredSpeechShortcutCannotCollideWithInsertion() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let insertion = GeneralPreferences.defaultSpeechShortcut
        defaults.set(
            try JSONEncoder().encode(insertion),
            forKey: "general.translationInsertionShortcut"
        )
        defaults.set(
            try JSONEncoder().encode(insertion),
            forKey: "general.translationSpeechShortcut"
        )

        let preferences = GeneralPreferences(defaults: defaults)
        let resolvedSpeechShortcut = preferences.speechShortcut

        XCTAssertNotEqual(
            preferences.speechShortcut?.modifiers,
            preferences.insertionShortcut?.modifiers
        )
        XCTAssertNil(
            preferences.setInsertionShortcut(
                TranslationInsertionShortcut.defaultTrigger
            )
        )

        let reloaded = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(
            reloaded.speechShortcut,
            resolvedSpeechShortcut
        )
    }

    @MainActor
    func testInsertionShortcutDefaultsAndPersists() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(
            first.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )

        let shortcut = TranslationInsertionShortcut.presets[3]
        XCTAssertNil(first.setInsertionShortcut(shortcut))

        let second = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(second.insertionShortcut, shortcut)
    }

    @MainActor
    func testRecordedCustomShortcutIsAcceptedAndPersisted() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let shortcut = TranslationInsertionShortcut(
            modifiers: [.control, .command]
        )

        XCTAssertNil(preferences.setInsertionShortcut(shortcut))
        XCTAssertEqual(preferences.insertionShortcut, shortcut)

        let reloaded = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.insertionShortcut, shortcut)
    }

    @MainActor
    func testThreeModifierShortcutIsAcceptedAndPersisted() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let shortcut = TranslationInsertionShortcut(
            modifiers: [.control, .option, .shift]
        )

        XCTAssertNil(preferences.setInsertionShortcut(shortcut))

        let reloaded = GeneralPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.insertionShortcut, shortcut)
    }

    @MainActor
    func testInvalidShortcutIsRejectedAndStoredInvalidFallsBack() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let original = preferences.insertionShortcut
        let invalid = TranslationInsertionShortcut(
            modifiers: []
        )

        XCTAssertNotNil(
            preferences.setInsertionShortcut(invalid)
        )
        XCTAssertEqual(preferences.insertionShortcut, original)

        defaults.set(
            try JSONEncoder().encode(invalid),
            forKey: "general.translationInsertionShortcut"
        )

        let reloaded = GeneralPreferences(defaults: defaults)

        XCTAssertEqual(
            reloaded.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )
    }

    @MainActor
    func testResetRestoresDefaultAndNotifies() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        let custom = TranslationInsertionShortcut.presets[1]
        _ = preferences.setInsertionShortcut(custom)
        var observed: [TranslationInsertionShortcut?] = []
        preferences.insertionShortcutDidChange = {
            observed.append($0)
        }

        preferences.resetInsertionShortcut()

        XCTAssertEqual(
            preferences.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )
        XCTAssertEqual(
            observed,
            [TranslationInsertionShortcut.defaultTrigger]
        )
    }

    @MainActor
    func testResetInsertionSettingsRestoresShortcut() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        XCTAssertNil(
            preferences.setInsertionShortcut(
                TranslationInsertionShortcut(
                    modifiers: [.control, .command]
                )
            )
        )
        XCTAssertNil(preferences.setInsertionShortcut(nil))
        var observedShortcuts: [TranslationInsertionShortcut?] = []
        preferences.insertionShortcutDidChange = {
            observedShortcuts.append($0)
        }

        preferences.resetInsertionSettings()

        XCTAssertEqual(
            preferences.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )
        XCTAssertTrue(preferences.insertionEnabled)
        XCTAssertEqual(
            observedShortcuts,
            [TranslationInsertionShortcut.defaultTrigger]
        )
    }

    @MainActor
    func testResetInsertionAndSpeechSettingsAreIndependent() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        _ = preferences.setSpeechShortcut(
            TranslationInsertionShortcut(
                modifiers: [.command, .option]
            )
        )
        XCTAssertNil(preferences.setSpeechShortcut(nil))
        preferences.setSpeechAccent(.british)
        preferences.setSpeechVoiceIdentifier("fr.voice", for: .french)
        preferences.setSpeechRate(.faster)
        preferences.setAutoSpeechEnabled(true)
        preferences.setAutoSpeechDelay(2.5)

        preferences.resetSpeechSettings()

        XCTAssertEqual(
            preferences.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )
        XCTAssertEqual(
            preferences.speechShortcut,
            GeneralPreferences.defaultSpeechShortcut
        )
        XCTAssertTrue(preferences.insertionEnabled)
        XCTAssertTrue(preferences.manualSpeechEnabled)
        XCTAssertEqual(preferences.speechAccent, .system)
        XCTAssertNil(preferences.speechVoiceIdentifier(for: .french))
        XCTAssertEqual(preferences.speechRate, .standard)
        XCTAssertFalse(preferences.autoSpeechEnabled)
        XCTAssertEqual(
            preferences.autoSpeechDelay,
            GeneralPreferences.defaultAutoSpeechDelay
        )
    }

    @MainActor
    func testResetInsertionAvoidsSpeechKeyWithoutChangingSpeech() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        XCTAssertNil(
            preferences.setInsertionShortcut(
                TranslationInsertionShortcut(modifiers: [.shift])
            )
        )
        XCTAssertNil(
            preferences.setSpeechShortcut(
                TranslationInsertionShortcut(modifiers: [.option])
            )
        )
        XCTAssertNil(preferences.setInsertionShortcut(nil))

        preferences.resetInsertionSettings()

        XCTAssertEqual(
            preferences.insertionShortcut?.modifiers,
            [.command]
        )
        XCTAssertEqual(
            preferences.speechShortcut?.modifiers,
            [.option]
        )
        XCTAssertTrue(preferences.insertionEnabled)
    }
}
