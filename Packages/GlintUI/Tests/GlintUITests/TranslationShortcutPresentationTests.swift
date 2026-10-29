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

    @MainActor
    func testRecorderReleasesFocusAfterSuccessfulRecording() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let button = ShortcutRecorderNSButton(
            frame: NSRect(x: 20, y: 20, width: 128, height: 26),
            shortcut: .defaultTrigger
        )
        window.contentView = button

        button.startRecording()
        XCTAssertTrue(window.firstResponder === button)

        button.flagsChanged(
            with: try modifierEvent(
                flags: .option,
                windowNumber: window.windowNumber
            )
        )
        button.flagsChanged(
            with: try modifierEvent(
                flags: [],
                windowNumber: window.windowNumber
            )
        )

        XCTAssertFalse(button.isRecordingShortcut)
        XCTAssertFalse(window.firstResponder === button)
    }

    private func modifierEvent(
        flags: NSEvent.ModifierFlags,
        windowNumber: Int
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 58
            )
        )
    }
}
