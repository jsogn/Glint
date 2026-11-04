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

        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: CGRect(
                x: screen.visibleFrame.minX + 300,
                y: screen.frame.maxY - 62,
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
                && abs(panel.frame.minY - (62 + 7)) < 0.5
        }

        XCTAssertEqual(
            panel.frame.minY,
            62 + 7,
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
            near: CGRect(
                x: screen.visibleFrame.minX + 300,
                y: screen.frame.maxY - 52,
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

        let candidateX = screen.visibleFrame.minX + 300
        hud.show(
            items: [HUDItem(id: 0, number: 1, text: "Dinner")],
            near: CGRect(
                x: candidateX,
                y: screen.frame.maxY - 52,
                width: 180,
                height: 32
            ),
            inputCaretRect: CGRect(
                x: candidateX + 50,
                y: screen.frame.maxY - 84,
                width: 0,
                height: 24
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

        let candidateX = screen.visibleFrame.minX + 300
        let safeCandidate = CGRect(
            x: candidateX,
            y: screen.frame.maxY - 432,
            width: 180,
            height: 32
        )
        let safeCaret = CGRect(
            x: candidateX + 50,
            y: screen.frame.maxY - 324,
            width: 0,
            height: 24
        )
        let flippedCandidate = CGRect(
            x: candidateX,
            y: screen.frame.maxY - 52,
            width: 180,
            height: 32
        )
        let flippedCaret = CGRect(
            x: candidateX + 50,
            y: screen.frame.maxY - 84,
            width: 0,
            height: 24
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
