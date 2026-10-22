import CoreGraphics
import AppKit
import SwiftUI
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

    @MainActor
    func testHUDMinimumWidthReservesSlotForEveryItem() {
        let sixItems = HUDItemRow.minimumPanelWidth(for: 6)
        let nineItems = HUDItemRow.minimumPanelWidth(for: 9)
        let sixMinimum =
            HUDLayoutMetrics.multiItemHorizontalPadding * 2
                + 6 * HUDItemRow.minimumItemWidth
                + 5 * HUDLayoutMetrics.itemSpacing
        let nineMinimum =
            HUDLayoutMetrics.multiItemHorizontalPadding * 2
                + 9 * HUDItemRow.minimumItemWidth
                + 8 * HUDLayoutMetrics.itemSpacing

        XCTAssertGreaterThanOrEqual(
            sixItems,
            sixMinimum
        )
        XCTAssertGreaterThanOrEqual(
            nineItems,
            nineMinimum
        )
    }

    @MainActor
    func testHUDUsesCompactOuterInsetMatchingCandidateBar() {
        XCTAssertEqual(
            HUDLayoutMetrics.multiItemHorizontalPadding,
            3
        )
    }

    @MainActor
    func testHUDUsesAvailableScreenWidthBeforeTruncating() {
        let items = (0..<6).map { index in
            HUDItem(
                id: index,
                number: index + 1,
                text: String(
                    repeating: "a complete sentence for candidate ",
                    count: 4
                )
            )
        }

        let size = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400
        )

        XCTAssertGreaterThan(size.width, 1_000)
        XCTAssertLessThanOrEqual(size.width, 1_400)
    }

    @MainActor
    func testHUDWidthAccountsForMinimumSlotsBeforeCompression() {
        let items = [
            HUDItem(id: 0, number: 1, text: "Eat", isSelected: true),
            HUDItem(id: 1, number: 2, text: "🍚"),
            HUDItem(id: 2, number: 3, text: "Go for dinner"),
            HUDItem(id: 3, number: 4, text: "Chefan"),
            HUDItem(id: 4, number: 5, text: "Wing rice"),
            HUDItem(id: 5, number: 6, text: "Red rice"),
        ]
        let textFont = NSFont.systemFont(
            ofSize: HUDLayoutMetrics.textFontSize,
            weight: .medium
        )
        let numberFont = NSFont.systemFont(
            ofSize: HUDLayoutMetrics.numberFontSize,
            weight: .medium
        )
        let expectedItemWidths = items.map { item -> CGFloat in
            var width = ceil(
                (item.text as NSString).size(
                    withAttributes: [.font: textFont]
                ).width
            )
            if let number = item.number {
                width += ceil(
                    ("\(number)" as NSString).size(
                        withAttributes: [.font: numberFont]
                    ).width
                ) + HUDLayoutMetrics.numberSpacing
            }
            width += HUDLayoutMetrics.itemHorizontalPadding * 2
            return max(width, HUDLayoutMetrics.minimumItemWidth)
        }
        let expectedWidth = ceil(
            HUDLayoutMetrics.multiItemHorizontalPadding * 2
                + expectedItemWidths.reduce(0, +)
                + CGFloat(items.count - 1)
                    * HUDLayoutMetrics.itemSpacing
        )

        let size = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400
        )

        XCTAssertEqual(size.width, expectedWidth, accuracy: 0.001)
    }

    @MainActor
    func testHUDNaturalWidthCoversHostingViewFittingSize() {
        let items = [
            HUDItem(id: 0, number: 1, text: "Eat", isSelected: true),
            HUDItem(id: 1, number: 2, text: "🍚"),
            HUDItem(id: 2, number: 3, text: "Go for dinner"),
            HUDItem(id: 3, number: 4, text: "Chefan"),
            HUDItem(id: 4, number: 5, text: "Wing rice"),
            HUDItem(id: 5, number: 6, text: "Red rice"),
        ]
        let hostingView = NSHostingView(
            rootView: HUDView(items: items)
        )
        hostingView.layoutSubtreeIfNeeded()
        let fittingWidth = hostingView.fittingSize.width

        XCTAssertGreaterThan(fittingWidth, 400)
        XCTAssertGreaterThanOrEqual(
            HUDItemRow.naturalPanelWidth(for: items),
            fittingWidth
        )
    }

    @MainActor
    func testHUDUsesSelectedOnlyWhenFullRowExceedsScreen() {
        let items = (0..<6).map { index in
            HUDItem(
                id: index,
                number: index + 1,
                text: String(repeating: "complete sentence ", count: 2),
                isSelected: index == 0
            )
        }

        XCTAssertTrue(
            HUDItemRow.requiresSelectedOnly(
                for: items,
                maximumWidth: 600
            )
        )
        let size = HUDController.panelSize(
            for: items,
            maximumWidth: 600,
            selectedOnly: true
        )
        let widestSingleItem = items.map {
            HUDItemRow.naturalPanelWidth(for: [$0])
        }.max() ?? 120

        XCTAssertGreaterThanOrEqual(size.width, widestSingleItem)
        XCTAssertLessThanOrEqual(size.width, 600)
    }

    @MainActor
    func testHUDVisibleWidthDoesNotShrinkDuringComposition() {
        let current = NSSize(width: 500, height: 36)
        let shorter = NSSize(width: 320, height: 36)
        let wider = NSSize(width: 620, height: 36)

        XCTAssertEqual(
            HUDController.resolvedPanelSize(
                current: current,
                proposed: shorter,
                isVisible: true
            ).width,
            500
        )
        XCTAssertEqual(
            HUDController.resolvedPanelSize(
                current: current,
                proposed: wider,
                isVisible: true
            ).width,
            620
        )
        XCTAssertEqual(
            HUDController.resolvedPanelSize(
                current: current,
                proposed: shorter,
                isVisible: false
            ).width,
            320
        )
    }

    @MainActor
    func testSameRevisionUsesInPlaceContentPatch() {
        XCTAssertEqual(
            HUDController.contentUpdate(
                displayedRevision: 42,
                incomingRevision: 42,
                isVisible: true
            ),
            .patch
        )
    }

    @MainActor
    func testChangedRevisionUsesTransition() {
        XCTAssertEqual(
            HUDController.contentUpdate(
                displayedRevision: 42,
                incomingRevision: 43,
                isVisible: true
            ),
            .transition
        )
    }

    @MainActor
    func testHiddenHUDUsesEntryRegardlessOfRevision() {
        XCTAssertEqual(
            HUDController.contentUpdate(
                displayedRevision: nil,
                incomingRevision: 42,
                isVisible: false
            ),
            .entry
        )
    }

}
