import AppKit
import GlintCore
import XCTest
@testable import GlintUI

final class HUDControllerTests: XCTestCase {
    @MainActor
    func testHUDShowsWithoutCaretGeometryWhenCandidateHasRoomBelow()
        async throws
    {
        let (hud, panel, screen) = try makeHUDFixture()
        defer { hud.hide(animated: false) }

        let expectedPanelMinY = screen.visibleFrame.minY + 30 + 32 + 7
        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: quartzRect(
                screen: screen,
                minY: screen.visibleFrame.minY + 30,
                width: 180,
                height: 32
            ),
            inputCaretRect: nil,
            position: .automatic,
            spacing: 7,
            revision: 1,
            hidesOnAutomaticFlip: true
        )
        await waitUntil {
            panel.isVisible
                && abs(panel.frame.minY - expectedPanelMinY) < 0.5
        }

        XCTAssertEqual(
            panel.frame.minY,
            expectedPanelMinY,
            accuracy: 0.5
        )
    }

    @MainActor
    func testHUDHidesWithoutCaretGeometryWhenCandidateHasNoRoomBelow()
        async throws
    {
        let (hud, panel, screen) = try makeHUDFixture()
        defer { hud.hide(animated: false) }

        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: quartzRect(
                screen: screen,
                minY: screen.visibleFrame.minY + 20,
                width: 180,
                height: 32
            ),
            inputCaretRect: nil,
            position: .automatic,
            spacing: 7,
            revision: 1,
            hidesOnAutomaticFlip: true
        )
        await waitUntil { !panel.isVisible }

        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testHUDDoesNotEnterWhenInitialPlacementNeedsProtection()
        async throws
    {
        let (hud, panel, screen) = try makeHUDFixture()
        defer { hud.hide(animated: false) }

        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: quartzRect(
                screen: screen,
                minY: screen.visibleFrame.minY + 20,
                width: 180,
                height: 32
            ),
            inputCaretRect: quartzRect(
                screen: screen,
                minY: screen.visibleFrame.minY + 60,
                width: 0,
                height: 24,
                xOffset: 350
            ),
            position: .automatic,
            spacing: 7,
            revision: 1,
            hidesOnAutomaticFlip: true
        )
        await waitUntil { !panel.isVisible }

        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testHUDHidesAndRestoresOnAutomaticFlipProtection() async throws {
        let (hud, panel, screen) = try makeHUDFixture()
        defer { hud.hide(animated: false) }

        let safeCandidate = quartzRect(
            screen: screen,
            minY: screen.visibleFrame.minY + 400,
            width: 180,
            height: 32
        )
        let safeCaret = quartzRect(
            screen: screen,
            minY: screen.visibleFrame.minY + 300,
            width: 0,
            height: 24,
            xOffset: 350
        )
        let flippedCandidate = quartzRect(
            screen: screen,
            minY: screen.visibleFrame.minY + 20,
            width: 180,
            height: 32
        )
        let flippedCaret = quartzRect(
            screen: screen,
            minY: screen.visibleFrame.minY + 60,
            width: 0,
            height: 24,
            xOffset: 350
        )

        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: safeCandidate,
            inputCaretRect: safeCaret,
            position: .automatic,
            spacing: 7,
            revision: 1,
            hidesOnAutomaticFlip: true
        )
        await waitUntil { panel.isVisible }
        XCTAssertTrue(panel.isVisible)

        hud.updateLayout(
            screenRect: flippedCandidate,
            inputCaretRect: flippedCaret
        )
        await waitUntil { !panel.isVisible }
        XCTAssertFalse(panel.isVisible)

        hud.updateLayout(
            screenRect: safeCandidate,
            inputCaretRect: safeCaret
        )
        await waitUntil { panel.isVisible }
        XCTAssertTrue(panel.isVisible)
    }

    private func quartzRect(
        screen: NSScreen,
        minY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        xOffset: CGFloat = 300
    ) -> CGRect {
        CGRect(
            x: screen.visibleFrame.minX + xOffset,
            y: screen.frame.maxY - minY - height,
            width: width,
            height: height
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for HUD state")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func makeHUDFixture() throws
        -> (HUDController, NSWindow, NSScreen)
    {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(
            NSScreen.screens.first(where: {
                $0.frame.origin == .zero
            }) ?? NSScreen.main
        )
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let hud = HUDController()
        let panel = try XCTUnwrap(
            NSApp.windows.first {
                !existingWindows.contains(ObjectIdentifier($0))
                    && $0.level == .popUpMenu
                    && $0.styleMask.contains(.borderless)
                    && $0.styleMask.contains(.nonactivatingPanel)
            }
        )
        return (hud, panel, screen)
    }
}
