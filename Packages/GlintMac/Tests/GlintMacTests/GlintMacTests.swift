import CoreGraphics
import XCTest
@testable import GlintMac

final class GlintMacTests: XCTestCase {
    func testCandidateRegionConvertsToCGRect() {
        let region = CandidateRegion(x: 10, y: 20, width: 300, height: 120)
        XCTAssertEqual(region.cgRect.origin.x, 10)
        XCTAssertEqual(region.cgRect.size.width, 300)
    }

    func testAXCandidateFrameBecomesDisplayRegion() {
        let frame = CGRect(x: 120, y: 240, width: 96, height: 28)

        XCTAssertEqual(
            MonitoringController.candidateRegion(for: frame),
            CandidateRegion(x: 120, y: 240, width: 96, height: 28)
        )
    }

    func testEmptyAXCandidateFrameIsRejected() {
        XCTAssertNil(
            MonitoringController.candidateRegion(
                for: CGRect(x: 120, y: 240, width: 0, height: 28)
            )
        )
    }

    func testRowModeUsesStableCandidateBarFrame() throws {
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 180, y: 80, width: 50, height: 28),
                options: [
                    AXCandidateOption(
                        text: "你好",
                        frame: CGRect(x: 20, y: 80, width: 50, height: 28),
                        isSelected: false
                    ),
                    AXCandidateOption(
                        text: "你好吗",
                        frame: CGRect(x: 80, y: 80, width: 70, height: 28),
                        isSelected: true
                    ),
                ],
                listFrame: CGRect(x: 10, y: 80, width: 360, height: 28)
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 10, y: 80, width: 360, height: 28)
        )
    }

    func testRowModeAnchorsToVisibleRowInsideCandidateWindow() throws {
        let expandedWindow = CGRect(x: 10, y: 20, width: 540, height: 260)
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 40, y: 170, width: 50, height: 28),
                options: [
                    AXCandidateOption(
                        text: "逆",
                        frame: CGRect(x: 40, y: 170, width: 50, height: 28),
                        isSelected: true
                    ),
                ],
                windowFrame: expandedWindow,
                listFrame: CGRect(x: 20, y: 30, width: 500, height: 220)
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 10, y: 170, width: 540, height: 28)
        )
    }

    func testSelectedModeKeepsSelectedCandidateFrame() {
        let selected = CGRect(x: 180, y: 80, width: 50, height: 28)

        XCTAssertEqual(
            MonitoringController.candidateDisplayFrame(
                scope: .selected,
                selectedFrame: selected,
                options: [],
                listFrame: CGRect(x: 10, y: 80, width: 360, height: 28)
            ),
            selected
        )
    }

    func testRowTrackingIgnoresSelectionMovementWithinSameRow() {
        let rowFrame = CGRect(x: 10, y: 80, width: 360, height: 28)
        let first = CandidateTrackingIdentity.make(
            scope: .row,
            selectedText: "翻译",
            selectedFrame: CGRect(x: 20, y: 80, width: 50, height: 28),
            rowTexts: ["翻译", "翻译了"],
            rowFrame: rowFrame
        )
        let second = CandidateTrackingIdentity.make(
            scope: .row,
            selectedText: "翻译了",
            selectedFrame: CGRect(x: 90, y: 80, width: 60, height: 28),
            rowTexts: ["翻译", "翻译了"],
            rowFrame: rowFrame
        )

        XCTAssertEqual(first, second)
    }

    func testSelectedTrackingChangesWhenCandidateChanges() {
        let first = CandidateTrackingIdentity.make(
            scope: .selected,
            selectedText: "翻译",
            selectedFrame: CGRect(x: 20, y: 80, width: 50, height: 28),
            rowTexts: ["翻译"],
            rowFrame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let second = CandidateTrackingIdentity.make(
            scope: .selected,
            selectedText: "翻译了",
            selectedFrame: CGRect(x: 90, y: 80, width: 60, height: 28),
            rowTexts: ["翻译了"],
            rowFrame: CGRect(x: 90, y: 80, width: 60, height: 28)
        )

        XCTAssertNotEqual(first, second)
    }

    func testTextSelectionExcludesMarkedCompositionRange() {
        XCTAssertFalse(
            FocusMonitor.isTextSelection(nil, markedRange: nil)
        )
        XCTAssertFalse(
            FocusMonitor.isTextSelection(
                NSRange(location: 12, length: 0),
                markedRange: nil
            )
        )
        XCTAssertTrue(
            FocusMonitor.isTextSelection(
                NSRange(location: 1, length: 6),
                markedRange: NSRange(location: 7, length: 6)
            )
        )
        XCTAssertFalse(
            FocusMonitor.isTextSelection(
                NSRange(location: 6, length: 5),
                markedRange: NSRange(location: 6, length: 5)
            )
        )
    }

    func testCompositionStateUsesMarkedRange() {
        XCTAssertEqual(
            FocusMonitor.compositionState(for: nil),
            .unknown
        )
        XCTAssertEqual(
            FocusMonitor.compositionState(
                for: NSRange(location: 4, length: 3)
            ),
            .composing
        )
        XCTAssertEqual(
            FocusMonitor.compositionState(
                for: NSRange(location: 7, length: 0)
            ),
            .inactive
        )
    }

    func testComposingStateAlwaysAllowsCandidateScanning() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .composing,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testInactiveCompositionFallsBackToTextInputEvidence() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: true,
                hasCaret: false
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: false,
                hasCaret: true
            )
        )
        XCTAssertFalse(
            CandidateScanGate.allowsScanning(
                compositionState: .inactive,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testUnknownCompositionFallsBackToTextInputEvidence() {
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: true,
                hasCaret: true
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: false,
                hasCaret: true
            )
        )
        XCTAssertTrue(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: true,
                hasCaret: false
            )
        )
        XCTAssertFalse(
            CandidateScanGate.allowsScanning(
                compositionState: .unknown,
                isEditableTextInput: false,
                hasCaret: false
            )
        )
    }

    func testEditableTextInputRecognizesTextRolesAndEditableAttribute() {
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXTextFieldRole as String,
                editable: false
            )
        )
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXTextAreaRole as String,
                editable: false
            )
        )
        XCTAssertTrue(
            FocusMonitor.isEditableTextInput(
                role: kAXGroupRole as String,
                editable: true
            )
        )
        XCTAssertFalse(
            FocusMonitor.isEditableTextInput(
                role: kAXMenuItemRole as String,
                editable: false
            )
        )
    }

    func testAXCandidateIdentityDeduplicatesEquivalentFrame() {
        let frame = CGRect(x: 120, y: 80, width: 48, height: 28)
        let first = AXCandidateItem(text: "吃", frame: frame)
        let second = AXCandidateItem(text: "吃", frame: frame)

        XCTAssertEqual(first.identity, second.identity)
    }

    func testAXVisibleRowUsesVisibleCandidatesAndSelectedIndex() throws {
        let visible = (0..<6).reversed().map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 60),
                    y: 80,
                    width: 50,
                    height: 28
                )
            )
        }
        let selected = AXCandidateItem(
            text: "candidate2",
            frame: CGRect(x: 999, y: 999, width: 50, height: 28)
        )

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(
            row.items.map(\.text),
            (0..<6).map { "candidate\($0)" }
        )
        XCTAssertEqual(row.selectedIndex, 2)
    }

    func testAXVisibleRowFallsBackToSelectedWhenAbsent() throws {
        let selected = AXCandidateItem(
            text: "selected",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            AXCandidateItem(
                text: "other",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
        ]

        XCTAssertEqual(
            try XCTUnwrap(
                AXCandidateVisibleRowSelector.select(
                    selected: selected,
                    visible: visible
                )
            ),
            AXCandidateVisibleRow(
                items: [selected],
                selectedIndex: 0
            )
        )
    }

    func testAXVisibleRowRejectsExpandedVisibleRows() {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "candidate1",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
            AXCandidateItem(
                text: "candidate2",
                frame: CGRect(x: 20, y: 110, width: 50, height: 28)
            ),
        ]

        XCTAssertNil(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )
    }

    func testAXVisibleRowRejectsBulkVisibleChildren() {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 0, y: 80, width: 50, height: 28)
        )
        let visible = (0..<30).map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 60),
                    y: 80,
                    width: 50,
                    height: 28
                )
            )
        }

        XCTAssertNil(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )
    }

    func testAXVisibleRowSupportsNineCandidates() throws {
        let visible = (0..<9).map { index in
            AXCandidateItem(
                text: "candidate\(index)",
                frame: CGRect(
                    x: CGFloat(index * 52),
                    y: 120,
                    width: 44,
                    height: 28
                )
            )
        }

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: visible[4],
                visible: visible
            )
        )

        XCTAssertEqual(row.items, visible)
        XCTAssertEqual(row.selectedIndex, 4)
    }

    func testAXVisibleRowDeduplicatesEquivalentCandidates() throws {
        let selected = AXCandidateItem(
            text: "same",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "other",
                frame: CGRect(x: 80, y: 80, width: 50, height: 28)
            ),
            selected,
        ]

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(row.items.map(\.text), ["same", "other"])
        XCTAssertEqual(row.selectedIndex, 0)
    }

    func testAXVisibleRowAcceptsMinorVerticalJitter() throws {
        let selected = AXCandidateItem(
            text: "candidate0",
            frame: CGRect(x: 20, y: 80, width: 50, height: 28)
        )
        let visible = [
            selected,
            AXCandidateItem(
                text: "candidate1",
                frame: CGRect(x: 80, y: 81, width: 50, height: 28)
            ),
        ]

        let row = try XCTUnwrap(
            AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visible
            )
        )

        XCTAssertEqual(row.items.map(\.text), ["candidate0", "candidate1"])
        XCTAssertEqual(row.selectedIndex, 0)
    }

    func testCandidateMissRequiresTwoConsecutiveFrames() {
        var debouncer = CandidateMissDebouncer()

        XCTAssertFalse(debouncer.observeMiss())
        debouncer.observeCandidate()
        XCTAssertFalse(debouncer.observeMiss())
        XCTAssertTrue(debouncer.observeMiss())
    }

    func testCandidateMissResetClearsPartialAbsence() {
        var debouncer = CandidateMissDebouncer()

        XCTAssertFalse(debouncer.observeMiss())
        debouncer.reset()
        XCTAssertFalse(debouncer.observeMiss())
        XCTAssertTrue(debouncer.observeMiss())
    }

    func testCompositionTrackerDetectsExplicitEnd() {
        var tracker = CompositionTransitionTracker()

        XCTAssertFalse(tracker.observe(.composing))
        XCTAssertTrue(tracker.observe(.inactive))
        XCTAssertFalse(tracker.observe(.inactive))
    }

    func testCompositionTrackerDoesNotTreatUnknownStateAsEnd() {
        var tracker = CompositionTransitionTracker()

        XCTAssertFalse(tracker.observe(.unknown))
        XCTAssertFalse(tracker.observe(.inactive))
    }

    @MainActor
    func testInputSourceReturnsString() async {
        XCTAssertFalse(InputSourceMonitor().currentInputSourceID().contains(" "))
    }
}
