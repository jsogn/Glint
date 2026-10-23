import CoreGraphics
import Carbon
import XCTest
import GlintCore
import os
@testable import GlintMac

private struct StubInputSource: InputSourceReading {
    let source: ActiveInputSource

    nonisolated init(active: Bool) {
        self.init(kind: active ? .applePinyin : .keyboardLayout)
    }

    nonisolated init(kind: InputSourceKind) {
        switch kind {
        case .applePinyin:
            source = ActiveInputSource(
                id: "com.apple.inputmethod.SCIM.ITABC",
                kind: kind
            )
        case .otherInputMethod:
            source = ActiveInputSource(
                id: "com.example.inputmethod.pinyin",
                kind: kind
            )
        case .keyboardLayout:
            source = ActiveInputSource(
                id: "com.apple.keylayout.ABC",
                kind: kind
            )
        case .unknown:
            source = ActiveInputSource(
                id: "",
                kind: kind
            )
        }
    }

    @MainActor
    func currentInputSource() -> ActiveInputSource {
        source
    }
}

private final class MutableAccessibilityTrust: Sendable {
    private let trusted = OSAllocatedUnfairLock(initialState: false)

    var isTrusted: Bool {
        trusted.withLock { $0 }
    }

    func grant() {
        trusted.withLock { $0 = true }
    }
}

private struct StubFocus: FocusReading {
    func snapshot() -> FocusSnapshot? {
        nil
    }
}

private struct StubCandidates: AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool
    ) -> AXCandidateSnapshot? {
        nil
    }
}

private struct VisibleCaretFocus: FocusReading {
    func snapshot() -> FocusSnapshot? {
        FocusSnapshot(
            caretRect: CGRect(x: 120, y: 160, width: 2, height: 20),
            elementFrame: nil,
            compositionState: .composing,
            isEditableTextInput: true
        )
    }
}

private final class RecordingCandidates: AXCandidateReading, Sendable {
    private struct Request: Sendable {
        let processIdentifier: pid_t?
        let includeVisibleCandidates: Bool
    }

    private let state = OSAllocatedUnfairLock<[Request]>(initialState: [])

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool
    ) -> AXCandidateSnapshot? {
        state.withLock {
            $0.append(
                Request(
                    processIdentifier: processIdentifier,
                    includeVisibleCandidates: includeVisibleCandidates
                )
            )
        }
        return nil
    }

    var requestedVisibleCandidates: [Bool] {
        state.withLock { $0.map(\.includeVisibleCandidates) }
    }

    var requestedProcessIdentifiers: [pid_t?] {
        state.withLock { $0.map(\.processIdentifier) }
    }
}

private struct PIDCaretFocus: FocusReading {
    func snapshot() -> FocusSnapshot? {
        FocusSnapshot(
            caretRect: CGRect(x: 120, y: 160, width: 2, height: 20),
            elementFrame: nil,
            compositionState: .composing,
            isEditableTextInput: true,
            processIdentifier: 4242
        )
    }
}

private struct EmptyDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct EmptyTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct ImmediateTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        try Task.checkCancellation()
        return TranslationResult(
            text: "english-\(candidate.text)"
        )
    }
}

private struct MultiOptionTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        TranslationResult(
            options: [
                TranslationOption(text: "primary", score: 1),
                TranslationOption(text: "alternative", score: 0.8),
                TranslationOption(text: "secondary", score: 0.6),
            ]
        )
    }
}

private actor ParallelTranslation: TranslationEngine {
    private var activeCount = 0
    private var peakActiveCount = 0

    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        try await Task.sleep(nanoseconds: 20_000_000)
        activeCount -= 1
        return TranslationResult(
            text: "english-\(candidate.text)"
        )
    }

    func maximumConcurrency() -> Int {
        peakActiveCount
    }
}

private actor PresentationBatchRecorder {
    private var batches: [[CandidateTranslationPresentation]] = []

    func record(_ batch: [CandidateTranslationPresentation]) {
        batches.append(batch)
    }

    func firstBatchIndices() -> [Int]? {
        batches.first?.map(\.index)
    }

    func recordedBatches() -> [[CandidateTranslationPresentation]] {
        batches
    }
}

final class GlintMacTests: XCTestCase {
    func testMonitoringControllerUsesInjectedBoundaries() async {
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(active: false),
            focus: StubFocus(),
            axCandidates: StubCandidates(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 250_000_000)
    }

    func testMonitoringRechecksAccessibilityAfterInitialDenial() async throws {
        let accessibility = MutableAccessibilityTrust()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(active: false),
            focus: StubFocus(),
            axCandidates: StubCandidates(),
            accessibilityIsTrusted: {
                accessibility.isTrusted
            },
            secureInputIsEnabled: { false }
        )

        let deniedInterval = await controller.tick()
        XCTAssertEqual(deniedInterval, 1_000_000_000)

        accessibility.grant()
        try await Task.sleep(for: .seconds(1.05))

        let resumedInterval = await controller.tick()
        XCTAssertEqual(resumedInterval, 250_000_000)
    }

    func testSelectedScopeRequestsVisibleCandidateLayout() async {
        let candidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(active: true),
            focus: VisibleCaretFocus(),
            axCandidates: candidates,
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertEqual(candidates.requestedVisibleCandidates, [true])
    }

    func testOtherInputMethodStillUsesVerifiedCandidatePath() async {
        let candidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(kind: .otherInputMethod),
            focus: VisibleCaretFocus(),
            axCandidates: candidates,
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertEqual(candidates.requestedVisibleCandidates, [true])
    }

    func testKeyboardLayoutDoesNotScanCandidates() async {
        let candidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(kind: .keyboardLayout),
            focus: VisibleCaretFocus(),
            axCandidates: candidates,
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 250_000_000)
        XCTAssertTrue(candidates.requestedVisibleCandidates.isEmpty)
    }

    func testRowTranslationPublishesStableSlotsBeforeRowFinishes() async {
        let recorder = PresentationBatchRecorder()
        let candidates = ["one", "selected", "three"].map {
            Candidate(
                text: $0,
                kind: .word
            )
        }

        let presentations = await CandidateTranslationPipeline.translate(
            candidates,
            selectedIndex: 1,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: ImmediateTranslation()
            ),
            memo: TranslationMemo(),
            publishProgress: { batch in
                await recorder.record(batch)
            }
        )

        let firstIndices = await recorder.firstBatchIndices()
        let batches = await recorder.recordedBatches()

        XCTAssertEqual(firstIndices, [0, 1, 2])
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(
            batches[0].map(\.isSelected),
            [false, true, false]
        )
        XCTAssertEqual(presentations.map(\.index), [0, 1, 2])
        XCTAssertEqual(presentations[1].isSelected, true)
    }

    func testRowPresentationUsesPrimaryMeaningOnly() async {
        let presentations = await CandidateTranslationPipeline.translate(
            [
                Candidate(
                    text: "方案",
                    kind: .word
                )
            ],
            selectedIndex: 0,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: MultiOptionTranslation()
            ),
            memo: TranslationMemo(),
            displayOptionLimit: CandidateTranslationPipeline.displayOptionLimit(
                for: .row
            )
        )

        XCTAssertEqual(
            presentations.first?.translation,
            "primary"
        )
    }

    func testPrefetchDictionaryDependsOnModeAndScope() {
        XCTAssertTrue(
            MonitoringController.shouldPrefetchDictionary(
                mode: .dictionaryFirst,
                scope: .row
            )
        )
        XCTAssertTrue(
            MonitoringController.shouldPrefetchDictionary(
                mode: .dictionaryFirst,
                scope: .selected
            )
        )
        XCTAssertTrue(
            MonitoringController.shouldPrefetchDictionary(
                mode: .modelFirst,
                scope: .selected
            )
        )
        XCTAssertFalse(
            MonitoringController.shouldPrefetchDictionary(
                mode: .modelFirst,
                scope: .row
            )
        )
    }

    func testCachedPrefetchAvoidsTranslationRouting() async {
        let cachedResult = TranslationResult(
            text: "cached"
        )
        let presentations = await CandidateTranslationPipeline.translate(
            [
                Candidate(
                    text: "方案",
                    kind: .word
                )
            ],
            selectedIndex: 0,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            memo: TranslationMemo(),
            displayOptionLimit: 1,
            cachedPrefetchResults: [0: cachedResult]
        )

        XCTAssertEqual(presentations.first?.translation, "cached")
    }

    func testSelectedPresentationKeepsMultipleMeanings() async {
        let presentations = await CandidateTranslationPipeline.translate(
            [
                Candidate(
                    text: "方案",
                    kind: .word
                )
            ],
            selectedIndex: 0,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: MultiOptionTranslation()
            ),
            memo: TranslationMemo(),
            displayOptionLimit: CandidateTranslationPipeline.displayOptionLimit(
                for: .selected
            )
        )

        XCTAssertEqual(
            presentations.first?.translation,
            "primary · alternative · secondary"
        )
    }

    func testRowTranslationStartsAllCandidatesConcurrently() async {
        let translation = ParallelTranslation()
        let candidates = ["one", "two", "three"].map {
            Candidate(
                text: $0,
                kind: .word
            )
        }

        _ = await CandidateTranslationPipeline.translate(
            candidates,
            selectedIndex: 1,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: translation
            ),
            memo: TranslationMemo()
        )

        let maximumConcurrency = await translation.maximumConcurrency()
        XCTAssertGreaterThan(maximumConcurrency, 1)
    }

    func testRowTranslationSubmitsSelectedCandidateFirst() {
        XCTAssertEqual(
            CandidateTranslationPipeline.taskOrder(
                candidateCount: 5,
                selectedIndex: 3
            ),
            [3, 0, 1, 2, 4]
        )
    }

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
                ]
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 20, y: 80, width: 130, height: 28)
        )
    }

    func testRowModeAnchorsToVisibleRowInsideCandidateWindow() throws {
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 40, y: 170, width: 50, height: 28),
                options: [
                    AXCandidateOption(
                        text: "逆",
                        frame: CGRect(x: 40, y: 170, width: 50, height: 28),
                        isSelected: true
                    )
                ]
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 40, y: 170, width: 50, height: 28)
        )
    }

    func testRowModeUsesVisibleCandidateUnionInsteadOfContainer() throws {
        let frame = try XCTUnwrap(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: CGRect(x: 420, y: 80, width: 80, height: 28),
                options: [
                    AXCandidateOption(
                        text: "接下来做什么",
                        frame: CGRect(
                            x: 400,
                            y: 80,
                            width: 100,
                            height: 28
                        ),
                        isSelected: true
                    )
                ]
            )
        )

        XCTAssertEqual(
            frame,
            CGRect(x: 400, y: 80, width: 100, height: 28)
        )
    }

    func testSelectedModeKeepsSelectedCandidateFrame() {
        let selected = CGRect(x: 180, y: 80, width: 50, height: 28)

        XCTAssertEqual(
            MonitoringController.candidateDisplayFrame(
                scope: .selected,
                selectedFrame: selected,
                options: []
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
            )
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

    func testAXVisibleRowRejectsMoreThanNineCandidates() {
        let visible = (0..<10).map { index in
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
                selected: visible[0],
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
    func testInputSourceIdentifierDoesNotContainSpaces() async {
        XCTAssertFalse(InputSourceMonitor().currentInputSource().id.contains(" "))
    }

    func testInputSourceClassificationKeepsAppleAndThirdPartyDistinct() {
        XCTAssertEqual(
            InputSourceMonitor.inputSourceKind(
                identifier: "com.apple.inputmethod.SCIM.ITABC",
                type: kTISTypeKeyboardInputMode as String
            ),
            .applePinyin
        )
        XCTAssertEqual(
            InputSourceMonitor.inputSourceKind(
                identifier: "com.example.inputmethod.pinyin",
                type: kTISTypeKeyboardInputMode as String
            ),
            .otherInputMethod
        )
        XCTAssertEqual(
            InputSourceMonitor.inputSourceKind(
                identifier: "com.apple.keylayout.ABC",
                type: kTISTypeKeyboardLayout as String
            ),
            .keyboardLayout
        )
    }
}

final class MonitoringSessionTests: XCTestCase {
    func testCandidateReaderReceivesFocusedProcessIdentifier() async {
        let candidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(active: true),
            focus: PIDCaretFocus(),
            axCandidates: candidates,
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        _ = await controller.tick()

        XCTAssertEqual(candidates.requestedProcessIdentifiers.count, 1)
        XCTAssertEqual(
            candidates.requestedProcessIdentifiers.first ?? nil ?? 0,
            pid_t(4242)
        )
    }

    func testSessionKeepsDeliveringEventsAcrossStopAndStart() async throws {
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(kind: .keyboardLayout),
            focus: StubFocus(),
            axCandidates: StubCandidates(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )
        let session = MonitoringSession(controller: controller)
        let recorder = SessionEventRecorder()
        let collector = Task {
            let events = await session.events
            for await event in events {
                recorder.record(event)
            }
        }
        defer { collector.cancel() }

        let settings = MonitoringSettings(
            mode: .modelFirst,
            candidateDwellDuration: 0.08,
            translationScope: .selected,
            configurationToken: "test"
        )

        await session.start(settings)
        try await waitUntil {
            recorder.states.filter { $0 == .running }.count == 1
        }
        try await waitUntil { recorder.statuses.count >= 1 }

        await session.stop()
        try await waitUntil { recorder.states.last == .idle }

        await session.start(settings)
        try await waitUntil {
            recorder.states.filter { $0 == .running }.count == 2
        }
        try await waitUntil { recorder.statuses.count >= 2 }

        XCTAssertEqual(
            recorder.states.filter { $0 == .running }.count,
            2
        )
        XCTAssertGreaterThanOrEqual(recorder.statuses.count, 2)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for condition")
    }
}

private final class SessionEventRecorder: Sendable {
    private let events = OSAllocatedUnfairLock<[MonitoringSessionEvent]>(
        initialState: []
    )

    func record(_ event: MonitoringSessionEvent) {
        events.withLock { $0.append(event) }
    }

    var states: [MonitoringSessionState] {
        events.withLock { $0.compactMap(\.state) }
    }

    var statuses: [String] {
        events.withLock { $0.compactMap(\.monitoringStatus) }
    }
}

private extension MonitoringSessionEvent {
    var state: MonitoringSessionState? {
        if case .state(let state) = self { return state }
        return nil
    }

    var monitoringStatus: String? {
        if case .monitoring(.status(let status)) = self { return status }
        return nil
    }
}
