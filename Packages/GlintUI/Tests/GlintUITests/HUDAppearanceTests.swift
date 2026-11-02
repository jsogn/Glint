import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import GlintUI

final class HUDAppearanceTests: XCTestCase {
    @MainActor
    func testHUDPanelUsesSystemAppearance() throws {
        let hud = HUDController()
        let panel = try XCTUnwrap(
            NSApp.windows.first {
                $0.level == .popUpMenu
                    && $0.styleMask.contains(.borderless)
                    && $0.styleMask.contains(.nonactivatingPanel)
            }
        )

        XCTAssertNil(panel.appearance)
        XCTAssertNil(panel.contentView?.appearance)
        _ = hud
    }

    @MainActor
    func testHUDNativeMaterialUsesSystemAppearance() throws {
        let hostingView = NSHostingView(
            rootView: HUDNativeMaterialBackground()
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 200,
            height: 40
        )
        hostingView.layoutSubtreeIfNeeded()

        let materialView = try XCTUnwrap(
            hostingView.descendants.first {
                $0 is NSVisualEffectView
            } as? NSVisualEffectView
        )
        XCTAssertNil(materialView.appearance)
    }

    @MainActor
    func testSystemGlassUsesLiquidGlassOnMacOS26() throws {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("System glass uses Liquid Glass on macOS 26+")
        }

        let hostingView = NSHostingView(
            rootView: HUDView(
                text: "hello",
                appearance: HUDAppearance(
                    backgroundStyle: .darkGlass
                )
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 200,
            height: 40
        )
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            hostingView.descendants.contains {
                $0 is NSVisualEffectView
            }
        )
    }

    @MainActor
    func testFrostedGlassUsesStableDarkPopoverMaterial() throws {
        let hostingView = NSHostingView(
            rootView: HUDView(
                text: "hello",
                appearance: HUDAppearance(
                    backgroundStyle: .frostedGlass
                )
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 200,
            height: 40
        )
        hostingView.layoutSubtreeIfNeeded()

        let materialView = try XCTUnwrap(
            hostingView.descendants.first {
                $0 is NSVisualEffectView
            } as? NSVisualEffectView
        )
        XCTAssertEqual(materialView.material, .popover)
        XCTAssertEqual(materialView.blendingMode, .behindWindow)
        XCTAssertEqual(materialView.appearance?.name, .darkAqua)
        XCTAssertEqual(materialView.state, .active)
    }

    @MainActor
    func testFrostedGlassIgnoresConfiguredBackgroundOpacity() throws {
        let hostingView = NSHostingView(
            rootView: HUDView(
                text: "hello",
                appearance: HUDAppearance(
                    backgroundStyle: .frostedGlass
                ),
                backgroundOpacity: 0.88
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 200,
            height: 40
        )
        hostingView.layoutSubtreeIfNeeded()

        let materialView = try XCTUnwrap(
            hostingView.descendants.first {
                $0 is NSVisualEffectView
            } as? NSVisualEffectView
        )
        XCTAssertEqual(materialView.alphaValue, 1, accuracy: 0.001)
    }

    func testSelectedTranslationSpacingIsClamped() {
        XCTAssertEqual(
            HUDAppearance(selectedTranslationSpacing: 2)
                .selectedTranslationSpacing,
            8
        )
        XCTAssertEqual(
            HUDAppearance(selectedTranslationSpacing: 30)
                .selectedTranslationSpacing,
            24
        )
    }

    func testBackgroundStyleTitlesStaySimple() {
        XCTAssertEqual(
            HUDBackgroundStyle.allCases.map(\.title),
            ["磨砂玻璃", "系统玻璃", "纯色"]
        )
    }

    func testColorComponentsAreClampedToValidRange() {
        let color = HUDColor(
            red: -1,
            green: 2,
            blue: .nan
        )

        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 1)
        XCTAssertEqual(color.blue, 0)
    }

    func testDecodedColorComponentsAreClamped() throws {
        let data = Data(
            #"{"red":2,"green":-1,"blue":0.5}"#.utf8
        )

        let color = try JSONDecoder().decode(HUDColor.self, from: data)

        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0.5)
    }

    func testAutomaticTextColorUsesDefaultTextColor() {
        let appearance = HUDAppearance()

        XCTAssertEqual(
            appearance.effectiveTextColor,
            HUDAppearance.defaultTextColor
        )
    }

    func testFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(HUDAppearance(fontSize: 8).fontSize, 12)
        XCTAssertEqual(HUDAppearance(fontSize: 30).fontSize, 18)
    }
}

private extension NSView {
    var descendants: [NSView] {
        subviews + subviews.flatMap(\.descendants)
    }
}
