import CoreGraphics
import XCTest
@testable import GlintUI

final class HUDLayoutTests: XCTestCase {
    private let visibleFrame = CGRect(
        x: 0,
        y: 0,
        width: 1_440,
        height: 900
    )
    private let panelSize = CGSize(width: 440, height: 36)
    private let candidateRect = CGRect(
        x: 300,
        y: 400,
        width: 180,
        height: 32
    )

    func testAboveAndBelowUseTheSameConfiguredSpacing() {
        let above = HUDLayout.placement(
            near: candidateRect,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .above,
            spacing: 7
        )
        let below = HUDLayout.placement(
            near: candidateRect,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .below,
            spacing: 7
        )

        XCTAssertEqual(
            above.frame.minY - candidateRect.maxY,
            7,
            accuracy: 0.001
        )
        XCTAssertEqual(
            candidateRect.minY - below.frame.maxY,
            7,
            accuracy: 0.001
        )
        XCTAssertFalse(above.placesBelow)
        XCTAssertTrue(below.placesBelow)
    }

    func testAutomaticPlacementUsesAboveOnlyWhenBelowDoesNotFit() {
        let normal = HUDLayout.placement(
            near: candidateRect,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7
        )
        let nearBottom = HUDLayout.placement(
            near: CGRect(x: 300, y: 20, width: 180, height: 32),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7
        )

        XCTAssertTrue(normal.placesBelow)
        XCTAssertFalse(nearBottom.placesBelow)
    }

    func testHorizontalPlacementClampsInsideVisibleFrame() {
        let placement = HUDLayout.placement(
            near: CGRect(x: 1_400, y: 400, width: 30, height: 32),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .above,
            spacing: 7
        )

        XCTAssertEqual(
            placement.frame.maxX,
            visibleFrame.maxX - HUDLayout.screenEdgeInset,
            accuracy: 0.001
        )
    }
}
