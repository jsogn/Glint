import Foundation
import GlintCore
import XCTest
@testable import GlintUI

final class DisplayPreferencesTests: XCTestCase {
    @MainActor
    func testPreferencesPersistAcrossInstances() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DisplayPreferences(defaults: defaults)
        first.candidateDwellDuration = 0.24
        first.candidateSpacing = 14
        first.hudBackgroundStyle = .solid
        first.hudOpacity = 0.72
        first.setHUDTextColor(HUDColor(red: 1, green: 0.8, blue: 0.2))
        first.hudBackgroundColor = HUDColor(
            red: 0.08,
            green: 0.12,
            blue: 0.2
        )
        first.hudFontSize = 17
        first.hudDensity = .spacious
        first.translationScope = .row

        let second = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(second.candidateDwellDuration, 0.24)
        XCTAssertEqual(second.candidateSpacing, 14)
        XCTAssertEqual(second.hudOpacity, 0.72)
        XCTAssertEqual(second.hudBackgroundStyle, .solid)
        XCTAssertTrue(second.hudUsesCustomTextColor)
        XCTAssertEqual(
            second.hudTextColor,
            HUDColor(red: 1, green: 0.8, blue: 0.2)
        )
        XCTAssertEqual(
            second.hudBackgroundColor,
            HUDColor(red: 0.08, green: 0.12, blue: 0.2)
        )
        XCTAssertEqual(second.hudFontSize, 17)
        XCTAssertEqual(second.hudDensity, .spacious)
        XCTAssertEqual(second.translationScope, .row)
        XCTAssertEqual(
            defaults.object(
                forKey: "display.candidateDwellDuration"
            ) as? Double,
            0.24
        )
    }

    @MainActor
    func testCandidateDwellDurationIsClamped() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.candidateDwellDuration = 2
        XCTAssertEqual(preferences.candidateDwellDuration, 0.3)
        preferences.candidateDwellDuration = 0
        XCTAssertEqual(preferences.candidateDwellDuration, 0.05)
        preferences.candidateDwellDuration = 0.049
        XCTAssertEqual(preferences.candidateDwellDuration, 0.05)
        preferences.candidateDwellDuration = 0.08
        XCTAssertEqual(preferences.candidateDwellDuration, 0.08)
        preferences.candidateDwellDuration = .nan
        XCTAssertEqual(preferences.candidateDwellDuration, 0.10)

        preferences.candidateSpacing = 30
        XCTAssertEqual(preferences.candidateSpacing, 24)
        preferences.candidateSpacing = -1
        XCTAssertEqual(preferences.candidateSpacing, 0)
        preferences.candidateSpacing = .nan
        XCTAssertEqual(preferences.candidateSpacing, 6)

        preferences.hudOpacity = 2
        XCTAssertEqual(preferences.hudOpacity, 1)
        preferences.hudOpacity = 0
        XCTAssertEqual(preferences.hudOpacity, 0.4)

        preferences.hudFontSize = 30
        XCTAssertEqual(preferences.hudFontSize, 18)
        preferences.hudFontSize = 8
        XCTAssertEqual(preferences.hudFontSize, 12)
        preferences.hudFontSize = .nan
        XCTAssertEqual(preferences.hudFontSize, 14)
    }

    @MainActor
    func testStoredCandidateDwellDurationIsClampedOnLoad() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.01, forKey: "display.candidateDwellDuration")

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.candidateDwellDuration, 0.05)
        XCTAssertEqual(
            defaults.object(
                forKey: "display.candidateDwellDuration"
            ) as? Double,
            0.05
        )
    }

    @MainActor
    func testStoredLegacyDefaultDwellDurationIsPreserved() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(0.12, forKey: "display.candidateDwellDuration")

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.candidateDwellDuration, 0.12)
    }

    @MainActor
    func testCandidateDwellDurationChangeNotifiesObserver() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(
            preferences.candidateDwellDuration,
            0.10,
            accuracy: 0.001
        )

        var observed: [Double] = []
        preferences.candidateDwellDurationDidChange = {
            observed.append($0)
        }
        preferences.candidateDwellDuration = 2

        XCTAssertEqual(observed, [0.3])
    }

    @MainActor
    func testTranslationScopeDefaultsToSelectedAndNotifiesChanges() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(preferences.translationScope, .selected)

        var observed: [CandidateTranslationScope] = []
        preferences.translationScopeDidChange = {
            observed.append($0)
        }
        preferences.translationScope = .row

        XCTAssertEqual(observed, [.row])
    }

    @MainActor
    func testHUDAppearanceDefaultsUseDarkGlass() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.hudBackgroundStyle, .darkGlass)
        XCTAssertFalse(preferences.hudUsesCustomTextColor)
        XCTAssertEqual(preferences.hudOpacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(preferences.hudFontSize, 14)
        XCTAssertEqual(preferences.hudDensity, .standard)
        XCTAssertEqual(preferences.maximumTranslationCount, 4)
        XCTAssertEqual(
            preferences.hudSelectedTranslationSpacing,
            14
        )
        XCTAssertEqual(preferences.hudAppearance, .default)
    }

    @MainActor
    func testCandidateSpacingDefaultsToSixPoints() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.candidateSpacing, 6, accuracy: 0.001)
    }

    @MainActor
    func testResetHUDAppearanceRestoresDefaults() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.hudBackgroundStyle = .solid
        preferences.setHUDTextColor(HUDColor(red: 1, green: 0, blue: 0))
        preferences.hudBackgroundColor = HUDColor(
            red: 0,
            green: 0,
            blue: 1
        )
        preferences.hudFontSize = 18
        preferences.hudDensity = .spacious
        preferences.hudSelectedTranslationSpacing = 22
        preferences.candidateSpacing = 18

        preferences.resetHUDAppearance()

        XCTAssertEqual(preferences.hudAppearance, .default)
        XCTAssertEqual(
            preferences.candidateSpacing,
            6,
            accuracy: 0.001
        )
        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(
            reloaded.candidateSpacing,
            6,
            accuracy: 0.001
        )
    }

    @MainActor
    func testSelectedTranslationSpacingPersistsAndClamps() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.hudSelectedTranslationSpacing = 20

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.hudSelectedTranslationSpacing, 20)

        reloaded.hudSelectedTranslationSpacing = 30
        XCTAssertEqual(reloaded.hudSelectedTranslationSpacing, 24)

        reloaded.hudSelectedTranslationSpacing = 2
        XCTAssertEqual(reloaded.hudSelectedTranslationSpacing, 8)
    }

    @MainActor
    func testMaximumTranslationCountPersistsClampsAndNotifies() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        var observed: [Int] = []
        preferences.maximumTranslationCountDidChange = {
            observed.append($0)
        }
        preferences.maximumTranslationCount = 6

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.maximumTranslationCount, 6)

        reloaded.maximumTranslationCount = 12
        XCTAssertEqual(reloaded.maximumTranslationCount, 9)
        reloaded.maximumTranslationCount = 0
        XCTAssertEqual(reloaded.maximumTranslationCount, 1)
        XCTAssertEqual(observed, [6])
    }

    @MainActor
    func testGlassAndSolidOpacityAreStoredSeparately() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.hudGlassOpacity = 0.76
        preferences.hudBackgroundStyle = .solid
        preferences.hudSolidOpacity = 0.64

        preferences.hudBackgroundStyle = .darkGlass
        XCTAssertEqual(preferences.hudOpacity, 0.76, accuracy: 0.001)
        preferences.hudBackgroundStyle = .solid
        XCTAssertEqual(preferences.hudOpacity, 0.64, accuracy: 0.001)
    }

}
