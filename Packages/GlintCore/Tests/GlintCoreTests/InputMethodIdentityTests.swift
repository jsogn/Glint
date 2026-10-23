import GlintCore
import XCTest

final class InputMethodIdentityTests: XCTestCase {
    func testUsesSystemLocalizedNameWhenAvailable() {
        let identity = InputMethodIdentity(
            bundleIdentifier:
                InputMethodIdentifier.weTypeBundle,
            inputSourceIdentifier:
                InputMethodIdentifier.weTypePinyinMode,
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: "微信输入法"
        )

        XCTAssertEqual(identity.displayName, "微信输入法")
    }

    func testKnownBundleProvidesStableDisplayFallback() {
        let identity = InputMethodIdentity(
            bundleIdentifier:
                InputMethodIdentifier.weTypeBundle,
            inputSourceIdentifier:
                InputMethodIdentifier.weTypePinyinMode,
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: " "
        )

        XCTAssertEqual(identity.displayName, "微信输入法")
    }

    func testApplePinyinUsesLocalizedChineseDisplayName() {
        let identity = InputMethodIdentity(
            bundleIdentifier:
                InputMethodIdentifier.appleInputMethodBundle,
            inputSourceIdentifier:
                InputMethodIdentifier.applePinyinInputMode,
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: "Pinyin – Simplified"
        )

        XCTAssertEqual(identity.displayName, "简体拼音")
    }

    func testUnknownInputMethodDoesNotExposeInternalIdentifier() {
        let identity = InputMethodIdentity(
            bundleIdentifier: "com.example.inputmethod",
            inputSourceIdentifier:
                "com.example.inputmethod.pinyin",
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: nil
        )

        XCTAssertEqual(identity.displayName, "输入法")
    }
}
