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

    func testAutomaticPlacementUsesScreenCenterDirection() {
        let upper = HUDLayout.placement(
            near: CGRect(x: 300, y: 600, width: 180, height: 32),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7
        )
        let lower = HUDLayout.placement(
            near: CGRect(x: 300, y: 100, width: 180, height: 32),
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7
        )

        XCTAssertTrue(upper.placesBelow)
        XCTAssertFalse(lower.placesBelow)
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

    func testExplicitHorizontalOriginKeepsPlacementStable() {
        let first = HUDLayout.placement(
            near: CGRect(x: 320, y: 400, width: 500, height: 32),
            panelSize: CGSize(width: 440, height: 36),
            visibleFrame: visibleFrame,
            position: .above,
            spacing: 7,
            horizontalOrigin: 300
        )
        let second = HUDLayout.placement(
            near: CGRect(x: 270, y: 400, width: 600, height: 32),
            panelSize: CGSize(width: 520, height: 36),
            visibleFrame: visibleFrame,
            position: .above,
            spacing: 7,
            horizontalOrigin: 300
        )

        XCTAssertEqual(first.frame.minX, 300, accuracy: 0.001)
        XCTAssertEqual(second.frame.minX, 300, accuracy: 0.001)
    }

    func testHUDHorizontalAnchorIgnoresSmallJitter() {
        let anchor = HUDHorizontalAnchor.initial(
            screenFrame: visibleFrame,
            hudOriginX: 300,
            candidateOriginX: 320
        )

        XCTAssertEqual(
            anchor.resolvedHUDOriginX(candidateOriginX: 323),
            300,
            accuracy: 0.001
        )
        XCTAssertEqual(
            anchor.following(candidateOriginX: 323),
            anchor
        )
    }

    func testHUDHorizontalAnchorFollowsMeaningfulCandidateMovement() {
        let anchor = HUDHorizontalAnchor.initial(
            screenFrame: visibleFrame,
            hudOriginX: 300,
            candidateOriginX: 320
        )
        let moved = anchor.following(candidateOriginX: 370)

        XCTAssertEqual(
            moved.resolvedHUDOriginX(candidateOriginX: 370),
            350,
            accuracy: 0.001
        )
        XCTAssertEqual(moved.candidateOriginX, 370)
    }

    func testAutomaticPlacementKeepsPreferredSideNearCenter() {
        let centeredCandidate = CGRect(
            x: 300,
            y: 434,
            width: 180,
            height: 32
        )
        let above = HUDLayout.placement(
            near: centeredCandidate,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: false
        )
        let below = HUDLayout.placement(
            near: centeredCandidate,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: true
        )

        XCTAssertFalse(above.placesBelow)
        XCTAssertTrue(below.placesBelow)
    }

    func testAutomaticPlacementKeepsPreferredBelowInsideCenterBand() {
        let candidate = CGRect(
            x: 300,
            y: 418,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: candidate,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: true
        )

        XCTAssertTrue(placement.placesBelow)
    }

    func testAutomaticPlacementFlipsBelowPreferenceAfterCrossingCenter() {
        let candidate = CGRect(
            x: 300,
            y: 300,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: candidate,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: true
        )

        XCTAssertFalse(placement.placesBelow)
    }

    func testAutomaticPlacementFlipsAbovePreferenceAfterCrossingCenter() {
        let candidate = CGRect(
            x: 300,
            y: 600,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: candidate,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: false
        )

        XCTAssertTrue(placement.placesBelow)
    }

    func testAutomaticPlacementStillFlipsWhenPreferredSideDoesNotFit() {
        let nearBottom = CGRect(
            x: 300,
            y: 20,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: nearBottom,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .automatic,
            spacing: 7,
            preferredPlacesBelow: true
        )

        XCTAssertFalse(placement.placesBelow)
    }

    func testExplicitBelowFlipsAboveWhenBottomHasNoRoom() {
        let nearBottom = CGRect(
            x: 300,
            y: 20,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: nearBottom,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .below,
            spacing: 7
        )

        XCTAssertFalse(placement.placesBelow)
        XCTAssertEqual(
            placement.frame.minY - nearBottom.maxY,
            7,
            accuracy: 0.001
        )
    }

    func testExplicitAboveFlipsBelowWhenTopHasNoRoom() {
        let nearTop = CGRect(
            x: 300,
            y: 860,
            width: 180,
            height: 32
        )
        let placement = HUDLayout.placement(
            near: nearTop,
            panelSize: panelSize,
            visibleFrame: visibleFrame,
            position: .above,
            spacing: 7
        )

        XCTAssertTrue(placement.placesBelow)
        XCTAssertEqual(
            nearTop.minY - placement.frame.maxY,
            7,
            accuracy: 0.001
        )
    }

    @MainActor
    func testAnchoredPanelWidthIsLimitedToRemainingScreenSpace() {
        XCTAssertEqual(
            HUDController.maximumPanelWidth(
                in: visibleFrame,
                fixedOriginX: 1_000
            ),
            432,
            accuracy: 0.001
        )
        XCTAssertEqual(
            HUDController.maximumPanelWidth(
                in: visibleFrame,
                fixedOriginX: nil
            ),
            1_424,
            accuracy: 0.001
        )
    }

    @MainActor
    func testHUDMinimumWidthReservesSlotForEveryItem() {
        let metrics = HUDLayoutMetrics()
        let sixItems = HUDItemRow.minimumPanelWidth(for: 6)
        let nineItems = HUDItemRow.minimumPanelWidth(for: 9)
        let sixMinimum =
            metrics.multiItemHorizontalPadding * 2
            + 6 * metrics.minimumItemWidth
            + 5 * metrics.itemSpacing
        let nineMinimum =
            metrics.multiItemHorizontalPadding * 2
            + 9 * metrics.minimumItemWidth
            + 8 * metrics.itemSpacing

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
            HUDLayoutMetrics().multiItemHorizontalPadding,
            3
        )
    }

    @MainActor
    func testDefaultAppearanceUsesCompactHUDGeometry() {
        let metrics = HUDLayoutMetrics(appearance: .default)

        XCTAssertEqual(metrics.textFontSize, 14)
        XCTAssertEqual(metrics.numberFontSize, 10)
        XCTAssertEqual(metrics.minimumItemWidth, 44)
        XCTAssertEqual(metrics.itemSpacing, 4)
        XCTAssertEqual(metrics.selectedHorizontalPadding, 10)
        XCTAssertEqual(metrics.multiItemHorizontalPadding, 3)
        XCTAssertEqual(metrics.singleItemHorizontalPadding, 12)
        XCTAssertEqual(metrics.itemHorizontalPadding, 5)
        XCTAssertEqual(metrics.numberSpacing, 2)
        XCTAssertEqual(metrics.singleItemHeight, 29)
        XCTAssertEqual(metrics.multiItemHeight, 27)
    }

    @MainActor
    func testSelectedTranslationLayoutUsesConfiguredSpacing() {
        let metrics = HUDLayoutMetrics()
        let items = [
            HUDItem(id: 0, number: 1, text: "Hello"),
            HUDItem(id: 1, number: 2, text: "hi"),
            HUDItem(id: 2, number: 3, text: "ciao"),
            HUDItem(id: 3, number: 4, text: "hiya"),
            HUDItem(id: 4, number: 5, text: "Bonjour"),
        ]

        XCTAssertEqual(
            metrics.minimumItemWidth(for: .selectedTranslations),
            0
        )
        XCTAssertEqual(
            metrics.itemSpacing(for: .selectedTranslations),
            14
        )
        XCTAssertEqual(
            metrics.itemHorizontalPadding(for: .selectedTranslations),
            0
        )
        XCTAssertEqual(
            metrics.horizontalPadding(
                for: .selectedTranslations,
                itemCount: items.count
            ),
            11.5
        )

        let defaultSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            layoutStyle: .selectedTranslations
        )
        let wideSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            layoutStyle: .selectedTranslations,
            appearance: HUDAppearance(
                selectedTranslationSpacing: 24
            )
        )

        XCTAssertGreaterThan(wideSize.width, defaultSize.width)
    }

    @MainActor
    func testSelectedHUDHostingViewFitsConfiguredNaturalWidth() {
        let items = [
            HUDItem(id: 0, number: 1, text: "Hello"),
            HUDItem(id: 1, number: 2, text: "hi"),
            HUDItem(id: 2, number: 3, text: "ciao"),
            HUDItem(id: 3, number: 4, text: "hiya"),
            HUDItem(id: 4, number: 5, text: "Bonjour"),
        ]
        let hostingView = NSHostingView(
            rootView: HUDView(
                items: items,
                layoutStyle: .selectedTranslations
            )
        )
        hostingView.layoutSubtreeIfNeeded()
        let naturalWidth = HUDItemRow.naturalPanelWidth(
            for: items,
            layoutStyle: .selectedTranslations
        )
        let panelSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            layoutStyle: .selectedTranslations
        )

        XCTAssertGreaterThanOrEqual(
            naturalWidth,
            hostingView.fittingSize.width
        )
        XCTAssertLessThanOrEqual(
            naturalWidth - hostingView.fittingSize.width,
            HUDLayoutMetrics().measurementSafetyPadding
        )
        XCTAssertEqual(
            panelSize.width,
            naturalWidth,
            accuracy: 0.001
        )
    }

    @MainActor
    func testAppearanceUpdatesHUDHeightAndTextMeasurementWidth() {
        let items = [
            HUDItem(id: 0, text: "a complete sentence for measurement")
        ]
        let standard = HUDAppearance()
        let enlarged = HUDAppearance(
            fontSize: 18,
            density: .spacious
        )

        let standardSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            appearance: standard
        )
        let enlargedSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            appearance: enlarged
        )

        XCTAssertGreaterThan(enlargedSize.height, standardSize.height)
        XCTAssertGreaterThan(enlargedSize.width, standardSize.width)
    }

    @MainActor
    func testCompactDensityUsesLessVerticalSpace() {
        let compact = HUDLayoutMetrics(
            appearance: HUDAppearance(density: .compact)
        )
        let standard = HUDLayoutMetrics(
            appearance: HUDAppearance(density: .standard)
        )
        let spacious = HUDLayoutMetrics(
            appearance: HUDAppearance(density: .spacious)
        )

        XCTAssertLessThan(
            compact.singleItemHeight,
            standard.singleItemHeight
        )
        XCTAssertLessThan(
            standard.singleItemHeight,
            spacious.singleItemHeight
        )
    }

    @MainActor
    func testCompactFifteenPointHUDStaysLaptopFriendly() {
        let metrics = HUDLayoutMetrics(
            appearance: HUDAppearance(
                fontSize: 15,
                density: .compact
            )
        )

        XCTAssertEqual(metrics.singleItemHeight, 28)
        XCTAssertEqual(metrics.multiItemHeight, 24)
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
        let metrics = HUDLayoutMetrics()
        let textFont = NSFont.systemFont(
            ofSize: metrics.textFontSize,
            weight: .medium
        )
        let numberFont = NSFont.systemFont(
            ofSize: metrics.numberFontSize,
            weight: .medium
        )
        let expectedItemWidths = items.map { item -> CGFloat in
            var width = ceil(
                (item.text as NSString).size(
                    withAttributes: [.font: textFont]
                ).width
            )
            if let number = item.number {
                width +=
                    ceil(
                        ("\(number)" as NSString).size(
                            withAttributes: [.font: numberFont]
                        ).width
                    ) + metrics.numberSpacing
            }
            width += metrics.itemHorizontalPadding * 2
            return max(width, metrics.minimumItemWidth)
        }
        let expectedWidth = ceil(
            metrics.multiItemHorizontalPadding * 2
                + expectedItemWidths.reduce(0, +)
                + CGFloat(items.count - 1)
                * metrics.itemSpacing
                + metrics.measurementSafetyPadding
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
    func testHUDMeasurementMarginAcrossAppearanceMatrix() {
        let items = [
            HUDItem(id: 0, number: 1, text: "hello", isSelected: true),
            HUDItem(id: 1, number: 2, text: "how are you?"),
            HUDItem(id: 2, number: 3, text: "you"),
        ]

        for fontSize in stride(from: 12.0, through: 18.0, by: 1) {
            for density in HUDDensity.allCases {
                let appearance = HUDAppearance(
                    fontSize: fontSize,
                    density: density
                )
                let hostingView = NSHostingView(
                    rootView: HUDView(
                        items: items,
                        appearance: appearance
                    )
                )
                hostingView.layoutSubtreeIfNeeded()
                let natural = HUDItemRow.naturalPanelWidth(
                    for: items,
                    appearance: appearance
                )
                let panelSize = HUDController.panelSize(
                    for: items,
                    maximumWidth: 1_400,
                    appearance: appearance
                )
                XCTAssertGreaterThanOrEqual(
                    natural,
                    hostingView.fittingSize.width,
                    "\(fontSize)pt \(density.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    panelSize.width,
                    hostingView.fittingSize.width,
                    "\(fontSize)pt \(density.rawValue)"
                )
                XCTAssertEqual(
                    panelSize.height,
                    hostingView.fittingSize.height,
                    accuracy: 0.001,
                    "\(fontSize)pt \(density.rawValue)"
                )
            }
        }
    }

    @MainActor
    func testHUDHostingViewDoesNotResizePanelAfterDisplay() {
        let items = [
            HUDItem(
                id: 0,
                text: "a complete translation",
                isSelected: true
            )
        ]
        let appearance = HUDAppearance(
            fontSize: 15,
            density: .standard
        )
        let panelSize = HUDController.panelSize(
            for: items,
            maximumWidth: 1_400,
            appearance: appearance
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.alphaValue = 0
        let hostingView = NSHostingView(
            rootView: HUDView(
                items: items,
                appearance: appearance
            )
        )
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        defer {
            panel.orderOut(nil)
            panel.close()
        }

        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(panel.frame.size.width, panelSize.width)
        XCTAssertEqual(panel.frame.size.height, panelSize.height)
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
        let widestSingleItem =
            items.map {
                HUDItemRow.naturalPanelWidth(for: [$0])
            }.max() ?? 120

        XCTAssertGreaterThanOrEqual(size.width, widestSingleItem)
        XCTAssertLessThanOrEqual(size.width, 600)
    }

    @MainActor
    func testUnhighlightedMeaningsDoNotCollapseToSingleItem() {
        let items = (0..<4).map { index in
            HUDItem(
                id: index,
                number: index + 1,
                text: String(repeating: "meaning ", count: 12)
            )
        }

        XCTAssertFalse(
            HUDItemRow.requiresSelectedOnly(
                for: items,
                maximumWidth: 300
            )
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
