import Foundation
import GlintCore
import XCTest

@testable import GlintUI

final class GeneralPreferencesTests: XCTestCase {
    @MainActor
    func testInsertionIsEnabledByDefaultAndPersists() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = GeneralPreferences(defaults: defaults)
        XCTAssertTrue(first.insertionEnabled)
        var observed: [Bool] = []
        first.insertionEnabledDidChange = {
            observed.append($0)
        }

        first.setInsertionEnabled(false)

        XCTAssertFalse(first.insertionEnabled)
        XCTAssertEqual(observed, [false])
        XCTAssertFalse(GeneralPreferences(defaults: defaults).insertionEnabled)
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

        let shortcut = TranslationInsertionShortcut.presets[1]
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
            modifiers: [.control, .option]
        )

        XCTAssertNil(preferences.setInsertionShortcut(shortcut))
        XCTAssertEqual(preferences.insertionShortcut, shortcut)

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
        let custom = TranslationInsertionShortcut.presets[2]
        _ = preferences.setInsertionShortcut(custom)
        var observed: [TranslationInsertionShortcut] = []
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
    func testResetAllInsertionSettingsRestoresEnabledDefault() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = GeneralPreferences(defaults: defaults)
        XCTAssertNil(
            preferences.setInsertionShortcut(
                TranslationInsertionShortcut(
                    modifiers: [.control, .option]
                )
            )
        )
        preferences.setInsertionEnabled(false)
        var observedEnabled: [Bool] = []
        preferences.insertionEnabledDidChange = {
            observedEnabled.append($0)
        }

        preferences.resetInsertionSettings()

        XCTAssertEqual(
            preferences.insertionShortcut,
            TranslationInsertionShortcut.defaultTrigger
        )
        XCTAssertTrue(preferences.insertionEnabled)
        XCTAssertEqual(observedEnabled, [true])
    }
}
