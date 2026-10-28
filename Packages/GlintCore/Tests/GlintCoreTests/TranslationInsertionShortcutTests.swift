import XCTest

@testable import GlintCore

final class TranslationInsertionShortcutTests: XCTestCase {
    func testDefaultTriggerIsOption() {
        let shortcut = TranslationInsertionShortcut.defaultTrigger

        XCTAssertEqual(shortcut.displayText, "⌥")
        XCTAssertEqual(shortcut.modifiers, [.option])
    }

    func testPresetsAreValidAndDistinct() {
        let presets = TranslationInsertionShortcut.presets

        XCTAssertEqual(
            presets.map(\.displayText),
            [
                "⌥",
                "⌃",
                "⌘",
                "⇧",
                "⇪",
            ]
        )
        XCTAssertTrue(presets.allSatisfy(\.isValid))
        XCTAssertEqual(
            Set(
                presets.map {
                    $0.modifiers.rawValue
                }
            ).count,
            presets.count
        )
    }

    func testShortcutIsModifierWhitelist() {
        XCTAssertFalse(
            TranslationInsertionShortcut(modifiers: []).isValid
        )
        XCTAssertTrue(
            TranslationInsertionShortcut(
                modifiers: [.control, .option, .shift, .command]
            ).isValid
        )
        XCTAssertFalse(
            TranslationInsertionShortcut(
                modifiers: TranslationInsertionModifiers(
                    rawValue: 1 << 12
                )
            ).isValid
        )
        XCTAssertTrue(
            TranslationInsertionShortcut(
                modifiers: [.capsLock]
            ).isValid
        )
    }

    func testShortcutRoundTripsThroughJSON() throws {
        let shortcut = TranslationInsertionShortcut(
            modifiers: [.control, .option, .capsLock]
        )

        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(
            TranslationInsertionShortcut.self,
            from: data
        )

        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(decoded.displayText, "⌃ ⌥ ⇪")
    }
}
