import Foundation
import GlintCore
import XCTest
@testable import GlintUI

final class DisplayPreferencesTests: XCTestCase {
    func testOnlyEnglishEnablesEnglishOnlyDisplayCapabilities() {
        for target in TranslationTarget.allCases {
            XCTAssertEqual(
                target.supportsPartsOfSpeech,
                target == .english
            )
            XCTAssertEqual(
                target.supportsMultipleMeanings,
                target == .english
            )
        }
    }

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
    func testDisplayPositionDefaultsToAutomaticAndPersists() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(first.position, .automatic)

        first.position = .above

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.position, .above)
        XCTAssertEqual(
            HUDPosition.allCases.map(\.title),
            ["自动", "候选栏上方"]
        )
        XCTAssertEqual(
            HUDPosition.automatic.explanation,
            "根据候选栏和输入位置选择上下位置，并避开输入文字。"
        )
        XCTAssertEqual(
            HUDPosition.above.explanation,
            "与候选栏左侧对齐，不避让输入文字；空间不足时自动调整。"
        )
    }

    @MainActor
    func testAutomaticFlipProtectionDefaultsOffAndPersists() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(preferences.hidesHUDOnAutomaticFlip)

        preferences.hidesHUDOnAutomaticFlip = true

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hidesHUDOnAutomaticFlip)
    }

    @MainActor
    func testLegacyBelowDisplayPositionFallsBackToAutomatic() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("below", forKey: "display.position")

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.position, .automatic)
    }

    @MainActor
    func testResettingAppearanceDoesNotChangeDisplayPosition() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.position = .above

        preferences.resetHUDAppearance()

        XCTAssertEqual(preferences.position, .above)
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

        preferences.hudBackgroundStyle = .solid
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
    func testShowsPartsOfSpeechDefaultsTruePersistsAndNotifies() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        XCTAssertTrue(preferences.showsPartsOfSpeech)

        var observed: [Bool] = []
        preferences.showsPartsOfSpeechDidChange = {
            observed.append($0)
        }
        preferences.showsPartsOfSpeech = false

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.showsPartsOfSpeech)
        XCTAssertEqual(observed, [false])
        XCTAssertEqual(
            defaults.object(
                forKey: "display.showsPartsOfSpeech"
            ) as? Bool,
            false
        )
    }

    @MainActor
    func testHUDPreviewTranslationsMatchSelectedCandidate() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DisplayPreferences(defaults: defaults)
        let preview = HUDPreview(preferences: preferences)

        XCTAssertEqual(preview.selectedCandidateText, "你好")
        XCTAssertEqual(
            preview.previewItems.map(\.text),
            ["Hello", "hi", "greetings", "how do you do"]
        )
        XCTAssertEqual(
            preview.previewItems.map(\.partsOfSpeech),
            [
                [.noun, .interjection],
                [.interjection],
                [.noun],
                [],
            ]
        )

        preferences.showsPartsOfSpeech = false
        XCTAssertEqual(
            preview.previewItems.map(\.text),
            ["Hello", "hi", "greetings", "how do you do"]
        )
        XCTAssertTrue(
            preview.previewItems.allSatisfy {
                $0.partsOfSpeech.isEmpty
            }
        )
    }

    @MainActor
    func testHUDPreviewUsesLanguageSpecificSample() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DisplayPreferences(defaults: defaults)
        let expected: [TranslationTarget: String] = [
            .english: "Hello",
            .japanese: "こんにちは",
            .spanish: "Hola",
            .french: "Bonjour",
            .german: "Hallo",
            .russian: "Здравствуйте",
        ]

        for (target, text) in expected {
            let preview = HUDPreview(
                preferences: preferences,
                target: target
            )
            XCTAssertEqual(preview.previewItems.first?.text, text)
            XCTAssertTrue(
                preview.previewItems.allSatisfy {
                    $0.partsOfSpeech.isEmpty
                        || target.supportsPartsOfSpeech
                }
            )
        }
    }

    @MainActor
    func testHUDAppearanceDefaultsUseFrostedGlass() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(preferences.hudBackgroundStyle, .frostedGlass)
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

}
