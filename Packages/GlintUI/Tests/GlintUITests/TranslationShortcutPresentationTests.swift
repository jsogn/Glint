import AppKit
import GlintCore
import XCTest

@testable import GlintUI

final class TranslationShortcutPresentationTests: XCTestCase {
    func testPresetModifierSymbolNames() {
        XCTAssertEqual(
            TranslationInsertionShortcut.presets.map(
                \.modifierSymbolNames
            ),
            [
                ["option"],
                ["control"],
                ["command"],
                ["shift"],
                ["capslock"],
            ]
        )
    }

    @MainActor
    func testModifierSymbolsAreAvailableInSFAssets() {
        let shortcut = TranslationInsertionShortcut(
            modifiers: [
                .control,
                .option,
                .shift,
                .command,
                .capsLock,
            ]
        )

        XCTAssertEqual(
            shortcut.modifierSymbolNames,
            [
                "control",
                "option",
                "shift",
                "command",
                "capslock",
            ]
        )
        for symbolName in shortcut.modifierSymbolNames {
            XCTAssertNotNil(
                NSImage(
                    systemSymbolName: symbolName,
                    accessibilityDescription: nil
                ),
                symbolName
            )
        }
    }

    func testPresetDisplayTextUsesNativeModifierSymbols() {
        XCTAssertEqual(
            TranslationInsertionShortcut.presets.map(\.displayText),
            [
                "⌥",
                "⌃",
                "⌘",
                "⇧",
                "⇪",
            ]
        )
    }

    func testPresetAccessibilityLabels() {
        XCTAssertEqual(
            TranslationInsertionShortcut.presets.map(
                \.shortcutAccessibilityLabel
            ),
            [
                "Option + 1–N",
                "Control + 1–N",
                "Command + 1–N",
                "Shift + 1–N",
                "Caps Lock + 1–N",
            ]
        )
    }
}
