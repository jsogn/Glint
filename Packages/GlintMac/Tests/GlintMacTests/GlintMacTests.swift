import CoreGraphics
import Carbon
import Dispatch
import Foundation
import XCTest
import GlintCore
import os
@testable import GlintMac

private struct StubInputSource: InputSourceReading {
    let source: ActiveInputSource

    nonisolated init(active: Bool) {
        self.init(kind: active ? .applePinyin : .keyboardLayout)
    }

    nonisolated init(source: ActiveInputSource) {
        self.source = source
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
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        nil
    }
}

private struct FixedSnapshotCandidates: AXCandidateReading {
    let candidate: AXCandidateSnapshot

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        candidate
    }
}

private struct FixedCandidateReaderRouter:
    CandidateReaderRouting
{
    let sourceReader: any AXCandidateReading

    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading {
        sourceReader
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
        let includeVisibleTexts: Bool
    }

    private let state = OSAllocatedUnfairLock<[Request]>(initialState: [])

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        state.withLock {
            $0.append(
                Request(
                    processIdentifier: processIdentifier,
                    includeVisibleCandidates: includeVisibleCandidates,
                    includeVisibleTexts: includeVisibleTexts
                )
            )
        }
        return nil
    }

    var requestedVisibleCandidates: [Bool] {
        state.withLock { $0.map(\.includeVisibleCandidates) }
    }

    var requestedVisibleTexts: [Bool] {
        state.withLock { $0.map(\.includeVisibleTexts) }
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: StubCandidates()
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 250_000_000)
    }

    func testEmitsSystemInputMethodIdentityOnFirstTick() async {
        let identity = InputMethodIdentity(
            bundleIdentifier:
                InputMethodIdentifier.weTypeBundle,
            inputSourceIdentifier:
                InputMethodIdentifier.weTypePinyinMode,
            sourceType: kTISTypeKeyboardInputMode as String,
            localizedName: "微信输入法"
        )
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(
                source: ActiveInputSource(
                    identity: identity,
                    kind: .otherInputMethod
                )
            ),
            focus: StubFocus(),
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: StubCandidates()
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )
        var iterator = await controller.events.makeAsyncIterator()

        _ = await controller.tick()
        let event = await iterator.next()

        guard case .inputSourceChanged(let received) = event
        else {
            return XCTFail("Expected input source event")
        }
        XCTAssertEqual(received, identity)
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: StubCandidates()
            ),
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: candidates
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertEqual(candidates.requestedVisibleCandidates, [true])
        XCTAssertEqual(candidates.requestedVisibleTexts, [false])
    }

    func testRowScopeRequestsVisibleCandidateTexts() async {
        let candidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(active: true),
            focus: VisibleCaretFocus(),
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: candidates
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        await controller.setTranslationScope(.row)
        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertEqual(candidates.requestedVisibleCandidates, [true])
        XCTAssertEqual(candidates.requestedVisibleTexts, [true])
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: candidates
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertEqual(candidates.requestedVisibleCandidates, [true])
    }

    func testWeTypeUsesDedicatedCandidatePath() async {
        let genericCandidates = RecordingCandidates()
        let weTypeCandidates = RecordingCandidates()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(
                source: ActiveInputSource(
                    identity: InputMethodIdentity(
                        bundleIdentifier:
                            InputMethodIdentifier.weTypeBundle,
                        inputSourceIdentifier:
                            InputMethodIdentifier.weTypePinyinMode,
                        sourceType:
                            kTISTypeKeyboardInputMode as String,
                        localizedName: "微信输入法"
                    ),
                    kind: .otherInputMethod
                )
            ),
            focus: VisibleCaretFocus(),
            candidateReaders: CandidateReaderRouter(
                fallback: genericCandidates,
                registrations: [
                    CandidateReaderRegistration(
                        bundleIdentifiers: [
                            InputMethodIdentifier.weTypeBundle
                        ],
                        inputSourceIdentifiers: [],
                        reader: weTypeCandidates
                    )
                ]
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )

        let interval = await controller.tick()

        XCTAssertEqual(interval, 60_000_000)
        XCTAssertTrue(
            genericCandidates.requestedVisibleCandidates.isEmpty
        )
        XCTAssertEqual(
            weTypeCandidates.requestedVisibleCandidates,
            [true]
        )
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: candidates
            ),
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

    func testInexactSelectionDoesNotHighlightFallbackCandidate() async {
        let presentations = await CandidateTranslationPipeline.translate(
            [
                Candidate(text: "one", kind: .word),
                Candidate(text: "two", kind: .word),
            ],
            selectedIndex: 0,
            selectionIsExact: false,
            mode: .modelFirst,
            configurationToken: "model-a",
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: ImmediateTranslation()
            ),
            memo: TranslationMemo()
        )

        XCTAssertEqual(
            presentations.map(\.isSelected),
            [false, false]
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
                ],
                geometry: itemGeometry(
                    frame: CGRect(
                        x: 180,
                        y: 80,
                        width: 50,
                        height: 28
                    )
                )
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
                ],
                geometry: itemGeometry(
                    frame: CGRect(
                        x: 40,
                        y: 170,
                        width: 50,
                        height: 28
                    )
                )
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
                ],
                geometry: itemGeometry(
                    frame: CGRect(
                        x: 420,
                        y: 80,
                        width: 80,
                        height: 28
                    )
                )
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
                options: [],
                geometry: itemGeometry(frame: selected)
            ),
            selected
        )
    }

    func testTextFrameAddsLeadingVisualInsetWithoutMovingTrailingEdge() {
        let raw = CGRect(x: 108, y: 216, width: 46, height: 28)
        let geometry = AXCandidateGeometry(
            horizontalFrame: raw,
            horizontalSource: .text,
            verticalFrame: raw,
            verticalSource: .text
        )

        XCTAssertEqual(
            geometry.horizontalAnchor,
            CGRect(x: 103, y: 216, width: 51, height: 28)
        )
        XCTAssertEqual(geometry.horizontalAnchor.maxX, raw.maxX)
    }

    func testControlFramesDoNotReceiveTextVisualInset() {
        let frame = CGRect(x: 108, y: 216, width: 46, height: 28)

        for source in [
            AXCandidateFrameKind.window,
            .list,
            .item,
        ] {
            let geometry = AXCandidateGeometry(
                horizontalFrame: frame,
                horizontalSource: source,
                verticalFrame: frame,
                verticalSource: source
            )
            XCTAssertEqual(geometry.horizontalAnchor, frame)
        }
    }

    func testSogouUsesTextAnchorAndTrimmedWindowVerticalBounds() {
        let selected = CGRect(x: 180, y: 260, width: 50, height: 28)
        let container = CGRect(x: 120, y: 200, width: 400, height: 118)
        let geometry = AXCandidateGeometry(
            horizontalFrame: selected,
            horizontalSource: .text,
            verticalFrame: container,
            verticalSource: .window
        )

        XCTAssertEqual(
            geometry.verticalBounds,
            CGRect(x: 120, y: 208, width: 400, height: 102)
        )
        XCTAssertEqual(
            MonitoringController.candidateDisplayFrame(
                scope: .selected,
                selectedFrame: selected,
                options: [],
                geometry: geometry
            ),
            CGRect(x: 175, y: 208, width: 55, height: 102)
        )
        XCTAssertEqual(
            MonitoringController.candidateDisplayFrame(
                scope: .row,
                selectedFrame: selected,
                options: [
                    AXCandidateOption(
                        text: "输入法",
                        frame: selected,
                        isSelected: false
                    ),
                    AXCandidateOption(
                        text: "输入",
                        frame: CGRect(
                            x: 250,
                            y: 260,
                            width: 50,
                            height: 28
                        ),
                        isSelected: false
                    ),
                ],
                geometry: geometry
            ),
            CGRect(x: 175, y: 208, width: 125, height: 102)
        )
    }

    func testNonWindowVerticalBoundsRemainUnchanged() {
        let frame = CGRect(x: 120, y: 200, width: 400, height: 118)

        for source in [
            AXCandidateFrameKind.list,
            .item,
            .text,
        ] {
            let geometry = AXCandidateGeometry(
                horizontalFrame: frame,
                horizontalSource: .item,
                verticalFrame: frame,
                verticalSource: source
            )
            XCTAssertEqual(geometry.verticalBounds, frame)
        }
    }

    private func itemGeometry(
        frame: CGRect
    ) -> AXCandidateGeometry {
        AXCandidateGeometry(
            horizontalFrame: frame,
            horizontalSource: .item,
            verticalFrame: frame,
            verticalSource: .item
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
                identifier: WeTypeCandidateReader.inputSourceID,
                type: kTISTypeKeyboardInputMode as String,
                bundleIdentifier:
                    InputMethodIdentifier.weTypeBundle
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

final class WeTypeCandidateParserTests: XCTestCase {
    func testParserPairsCandidatesAndSelectsBrightShortcut() throws {
        let observations = makeObservations(
            texts: ["one", "two", "three"],
            selectedShortcutIndex: 1
        )

        let groups = try XCTUnwrap(
            WeTypeCandidateParser.groups(
                from: observations
            )
        )

        XCTAssertEqual(
            groups.map(\.text),
            ["one", "two", "three"]
        )
        XCTAssertEqual(
            WeTypeCandidateParser.selectedIndex(in: groups),
            1
        )
        XCTAssertTrue(
            WeTypeCandidateParser.selection(
                in: groups
            ).isExact
        )
        XCTAssertEqual(
            groups[1].frame,
            CGRect(x: 60, y: 10, width: 22, height: 20)
        )
    }

    func testParserFallsBackToFirstCandidateWithoutStyleContrast() throws {
        let observations = makeObservations(
            texts: ["one", "two"],
            selectedShortcutIndex: nil
        )
        let groups = try XCTUnwrap(
            WeTypeCandidateParser.groups(
                from: observations
            )
        )

        XCTAssertEqual(
            WeTypeCandidateParser.selectedIndex(in: groups),
            0
        )
        XCTAssertFalse(
            WeTypeCandidateParser.selection(
                in: groups
            ).isExact
        )
    }

    func testParserFallsBackWhenMaximumBrightnessIsAmbiguous() throws {
        let observations = [
            observation(
                "1",
                x: 0,
                brightness: 1
            ),
            observation(
                "one",
                x: 12,
                brightness: 1
            ),
            observation(
                "2",
                x: 60,
                brightness: 1
            ),
            observation(
                "two",
                x: 72,
                brightness: 1
            ),
        ]
        let groups = try XCTUnwrap(
            WeTypeCandidateParser.groups(
                from: observations
            )
        )

        XCTAssertEqual(
            WeTypeCandidateParser.selectedIndex(in: groups),
            0
        )
    }

    func testParserRejectsMultipleVisibleRows() {
        let observations = [
            observation(
                "1",
                x: 0,
                brightness: 1
            ),
            observation(
                "one",
                x: 12,
                brightness: 1
            ),
            observation(
                "2",
                x: 60,
                y: 40,
                brightness: 0.54
            ),
            observation(
                "two",
                x: 72,
                y: 40,
                brightness: 0.78
            ),
        ]

        XCTAssertNil(
            WeTypeCandidateParser.groups(
                from: observations
            )
        )
    }

    private func makeObservations(
        texts: [String],
        selectedShortcutIndex: Int?
    ) -> [WeTypeCandidateObservation] {
        texts.enumerated().flatMap { index, text in
            let x = CGFloat(index * 60)
            return [
                observation(
                    "\(index + 1)",
                    x: x,
                    brightness:
                        selectedShortcutIndex == index ? 1 : 0.54
                ),
                observation(
                    text,
                    x: x + 12,
                    brightness:
                        selectedShortcutIndex == index ? 1 : 0.78
                ),
            ]
        }
    }

    private func observation(
        _ text: String,
        x: CGFloat,
        y: CGFloat = 10,
        brightness: Double
    ) -> WeTypeCandidateObservation {
        WeTypeCandidateObservation(
            text: text,
            frame: CGRect(
                x: x,
                y: y,
                width: 10,
                height: 20
            ),
            foregroundBrightness: brightness
        )
    }
}

final class SogouCandidateParserTests: XCTestCase {
    func testParserSortsOneVisibleCandidateRow() throws {
        let observations = [
            observation("two", x: 80),
            observation("one", x: 20),
            observation("three", x: 140),
        ]

        let candidates = try XCTUnwrap(
            SogouCandidateParser.candidates(
                from: observations
            )
        )

        XCTAssertEqual(
            candidates.map(\.text),
            ["one", "two", "three"]
        )
    }

    func testParserRejectsExpandedCandidateRows() {
        let observations = [
            observation("one", x: 20),
            observation("two", x: 80),
            observation("three", x: 20, y: 50),
        ]

        XCTAssertNil(
            SogouCandidateParser.candidates(
                from: observations
            )
        )
    }

    func testParserRejectsMoreThanNineCandidates() {
        let observations = (0..<10).map {
            observation(
                "candidate-\($0)",
                x: CGFloat($0 * 60)
            )
        }

        XCTAssertNil(
            SogouCandidateParser.candidates(
                from: observations
            )
        )
    }

    private func observation(
        _ text: String,
        x: CGFloat,
        y: CGFloat = 10
    ) -> SogouCandidateObservation {
        SogouCandidateObservation(
            text: text,
            frame: CGRect(
                x: x,
                y: y,
                width: 40,
                height: 26
            )
        )
    }
}

final class CandidateReaderRouterTests: XCTestCase {
    func testRoutesWeTypeByBundleIdentifier() {
        let fallback = RecordingCandidates()
        let weType = RecordingCandidates()
        let router = CandidateReaderRouter(
            fallback: fallback,
            registrations: [
                CandidateReaderRegistration(
                    bundleIdentifiers: [
                        InputMethodIdentifier.weTypeBundle
                    ],
                    inputSourceIdentifiers: [],
                    reader: weType
                )
            ]
        )

        let reader = router.reader(
            for: source(
                bundleIdentifier:
                    InputMethodIdentifier.weTypeBundle,
                inputSourceIdentifier:
                    InputMethodIdentifier.weTypePinyinMode
            )
        )

        XCTAssertTrue(
            (reader as? RecordingCandidates) === weType
        )
    }

    func testUnknownInputMethodUsesStandardFallback() {
        let fallback = RecordingCandidates()
        let weType = RecordingCandidates()
        let router = CandidateReaderRouter(
            fallback: fallback,
            registrations: [
                CandidateReaderRegistration(
                    bundleIdentifiers: [
                        InputMethodIdentifier.weTypeBundle
                    ],
                    inputSourceIdentifiers: [],
                    reader: weType
                )
            ]
        )

        let reader = router.reader(
            for: source(
                bundleIdentifier:
                    "com.example.inputmethod.sogou",
                inputSourceIdentifier:
                    "com.example.inputmethod.sogou.pinyin"
            )
        )

        XCTAssertTrue(
            (reader as? RecordingCandidates) === fallback
        )
    }

    func testUnknownInputMethodUsesAdaptiveProfileReader() {
        let router = CandidateReaderRouter(
            fallback: RecordingCandidates(),
            registrations: [],
            adaptiveProfiles: CandidateProfileCache(
                discover: { _ in nil }
            )
        )

        let reader = router.reader(
            for: source(
                bundleIdentifier:
                    "com.example.inputmethod.unknown",
                inputSourceIdentifier:
                    "com.example.inputmethod.unknown.pinyin"
            )
        )

        XCTAssertTrue(reader is AdaptiveUnknownCandidateReader)
    }

    func testProfileDiscoveryIsDisabledOutsideComposition() throws {
        let router = CandidateReaderRouter(
            fallback: RecordingCandidates(),
            registrations: [],
            adaptiveProfiles: CandidateProfileCache(
                discover: { _ in nil }
            )
        )

        let reader = router.reader(
            for: source(
                bundleIdentifier:
                    "com.example.inputmethod.unknown",
                inputSourceIdentifier:
                    "com.example.inputmethod.unknown.pinyin"
            ),
            allowProfileDiscovery: false
        )
        let adaptive = try XCTUnwrap(
            reader as? AdaptiveUnknownCandidateReader
        )

        XCTAssertFalse(adaptive.allowsProfileDiscovery)
    }

    func testStandardConfigurationRoutesSogou() {
        let router = CandidateReaderConfiguration.standard()
        let reader = router.reader(
            for: source(
                bundleIdentifier:
                    InputMethodIdentifier.sogouBundle,
                inputSourceIdentifier:
                    InputMethodIdentifier.sogouPinyinMode
            )
        )

        XCTAssertTrue(reader is SogouCandidateReader)
    }

    private func source(
        bundleIdentifier: String,
        inputSourceIdentifier: String
    ) -> ActiveInputSource {
        ActiveInputSource(
            identity: InputMethodIdentity(
                bundleIdentifier: bundleIdentifier,
                inputSourceIdentifier: inputSourceIdentifier,
                sourceType: "TISTypeKeyboardInputMode",
                localizedName: nil
            ),
            kind: .otherInputMethod
        )
    }
}

final class CandidateProfileDiscoveryTests: XCTestCase {
    func testProfileClassifierSeparatesListAndStyledTextShapes() {
        XCTAssertEqual(
            CandidateProfileDetector.classify(
                listSnapshot: snapshot(
                    candidateCount: 5,
                    selectionIsExact: false
                ),
                textSnapshot: snapshot(
                    candidateCount: 5,
                    selectionIsExact: true
                )
            ),
            .isolatedCandidateList
        )
        XCTAssertEqual(
            CandidateProfileDetector.classify(
                listSnapshot: nil,
                textSnapshot: snapshot(
                    candidateCount: 3,
                    selectionIsExact: true
                )
            ),
            .isolatedStyledText
        )
    }

    func testProfileClassifierRejectsSingleOrInexactCandidates() {
        XCTAssertNil(
            CandidateProfileDetector.classify(
                listSnapshot: snapshot(
                    candidateCount: 1,
                    selectionIsExact: false
                ),
                textSnapshot: nil
            )
        )
        XCTAssertNil(
            CandidateProfileDetector.classify(
                listSnapshot: nil,
                textSnapshot: snapshot(
                    candidateCount: 3,
                    selectionIsExact: false
                )
            )
        )
    }

    func testDiscoveredProfileIsReusedWithoutAnotherProbe() async {
        let cache = CandidateProfileCache(
            clock: { 0 },
            discover: { _ in .isolatedCandidateList }
        )
        let identity = identity()

        let task = cache.requestDiscovery(for: identity)
        await task?.value

        XCTAssertEqual(
            cache.profile(for: identity),
            .isolatedCandidateList
        )
        XCTAssertNil(cache.requestDiscovery(for: identity))
    }

    func testFailedDiscoveryRetriesQuicklyThenUsesLongCooldown() async {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
        let cache = CandidateProfileCache(
            clock: { clock.withLock { $0 } },
            discover: { _ in nil }
        )
        let identity = identity()

        let first = cache.requestDiscovery(for: identity)
        await first?.value
        XCTAssertNil(cache.requestDiscovery(for: identity))

        clock.withLock { $0 = 600_000_000 }
        let second = cache.requestDiscovery(for: identity)
        XCTAssertNotNil(second)
        await second?.value
        XCTAssertNil(cache.requestDiscovery(for: identity))

        clock.withLock { $0 = 600_000_000 + 10 * 60 * 1_000_000_000 }
        let third = cache.requestDiscovery(for: identity)
        XCTAssertNotNil(third)
        await third?.value
    }

    func testOnlyOneProfileDiscoveryRunsAtATime() async {
        let cache = CandidateProfileCache(
            clock: { 0 },
            discover: { _ in
                Thread.sleep(forTimeInterval: 0.05)
                return .isolatedStyledText
            }
        )
        let identity = identity()

        let first = cache.requestDiscovery(for: identity)
        XCTAssertNil(cache.requestDiscovery(for: identity))
        await first?.value
    }

    func testStandardFallbackSuccessDoesNotStartProfileProbe() {
        let identity = identity()
        let probeCalls = OSAllocatedUnfairLock(initialState: 0)
        let cache = CandidateProfileCache(
            clock: { 0 },
            discover: { _ in
                probeCalls.withLock { $0 += 1 }
                return .isolatedCandidateList
            }
        )
        let reader = AdaptiveUnknownCandidateReader(
            source: ActiveInputSource(
                identity: identity,
                kind: .otherInputMethod
            ),
            fallback: FixedSnapshotCandidates(
                candidate: AXCandidateSnapshot(
                    text: "candidate",
                    visibleTexts: [],
                    frame: CGRect(x: 10, y: 20, width: 30, height: 30),
                    candidateListFrame: nil
                )
            ),
            profiles: cache,
            allowsProfileDiscovery: true
        )

        XCTAssertNotNil(
            reader.snapshot(
                processIdentifier: 42,
                includeVisibleCandidates: true,
                includeVisibleTexts: false
            )
        )
        XCTAssertEqual(probeCalls.withLock { $0 }, 0)
    }

    func testPersistedProfileSurvivesCacheRecreationAndVersionBoundsIt()
        async throws
    {
        let suiteName =
            "GlintMacTests.ProfilePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let identity = identity()
        let persistence = CandidateProfilePersistence(
            defaults: defaults,
            storageKey: "profiles"
        )
        let first = CandidateProfileCache(
            clock: { 0 },
            applicationVersion: { _ in "1.0" },
            persistence: persistence,
            discover: { _ in .isolatedCandidateList }
        )
        await first.requestDiscovery(for: identity)?.value

        let probeCalls = OSAllocatedUnfairLock(initialState: 0)
        let sameVersion = CandidateProfileCache(
            clock: { 0 },
            applicationVersion: { _ in "1.0" },
            persistence: persistence,
            discover: { _ in
                probeCalls.withLock { $0 += 1 }
                return nil
            }
        )
        XCTAssertEqual(
            sameVersion.profile(for: identity),
            .isolatedCandidateList
        )
        XCTAssertEqual(probeCalls.withLock { $0 }, 0)

        let newVersion = CandidateProfileCache(
            clock: { 0 },
            applicationVersion: { _ in "2.0" },
            persistence: persistence,
            discover: { _ in nil }
        )
        XCTAssertNil(newVersion.profile(for: identity))
    }

    func testFailedDiscoveryIsNotPersisted() async throws {
        let suiteName =
            "GlintMacTests.ProfileFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let persistence = CandidateProfilePersistence(
            defaults: defaults,
            storageKey: "profiles"
        )
        let identity = identity()
        let first = CandidateProfileCache(
            clock: { 0 },
            applicationVersion: { _ in "1.0" },
            persistence: persistence,
            discover: { _ in nil }
        )
        await first.requestDiscovery(for: identity)?.value

        let second = CandidateProfileCache(
            clock: { 10 * 60 * 1_000_000_000 },
            applicationVersion: { _ in "1.0" },
            persistence: persistence,
            discover: { _ in nil }
        )
        XCTAssertNil(second.profile(for: identity))
        XCTAssertNotNil(second.requestDiscovery(for: identity))
    }

    private func identity() -> InputMethodIdentity {
        InputMethodIdentity(
            bundleIdentifier: "com.example.inputmethod.unknown",
            inputSourceIdentifier:
                "com.example.inputmethod.unknown.pinyin",
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: nil
        )
    }

    private func snapshot(
        candidateCount: Int,
        selectionIsExact: Bool
    ) -> AXCandidateSnapshot {
        let options = (0..<candidateCount).map { index in
            AXCandidateOption(
                text: "candidate-\(index)",
                frame: CGRect(
                    x: CGFloat(index * 50),
                    y: 10,
                    width: 40,
                    height: 28
                ),
                isSelected:
                    selectionIsExact && index == 0
            )
        }
        return AXCandidateSnapshot(
            text: options[0].text,
            visibleTexts: options.map(\.text),
            options: options,
            frame: options[0].frame,
            candidateListFrame: nil,
            selectedIndex: 0,
            selectionIsExact: selectionIsExact
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: candidates
            ),
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
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: StubCandidates()
            ),
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

    func testStopDuringStartSettlesIdleAndCanRestart() async throws {
        let harness = makeSession()
        defer { harness.collector.cancel() }
        let recorder = harness.recorder

        await harness.session.start(testSettings)
        await harness.session.stop()
        try await waitUntil { recorder.states.last == .idle }

        await harness.session.start(testSettings)
        try await waitUntil {
            recorder.states.filter { $0 == .running }.count >= 2
        }
        try await waitUntil { recorder.statuses.count >= 1 }

        XCTAssertEqual(recorder.states.last, .running)
    }

    func testSessionSurvivesRepeatedStopStartCycles() async throws {
        let harness = makeSession()
        defer { harness.collector.cancel() }
        let recorder = harness.recorder

        let cycles = 3
        for cycle in 1...cycles {
            await harness.session.start(testSettings)
            try await waitUntil {
                recorder.states.filter { $0 == .running }.count == cycle
            }
            try await waitUntil { recorder.statuses.count >= cycle }

            await harness.session.stop()
            try await waitUntil { recorder.states.last == .idle }
        }

        XCTAssertEqual(
            recorder.states.filter { $0 == .running }.count,
            cycles
        )
        XCTAssertGreaterThanOrEqual(recorder.statuses.count, cycles)
    }

    private func makeSession() -> (
        session: MonitoringSession,
        recorder: SessionEventRecorder,
        collector: Task<Void, Never>
    ) {
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyDictionary(),
                translation: EmptyTranslation()
            ),
            inputSource: StubInputSource(kind: .keyboardLayout),
            focus: StubFocus(),
            candidateReaders: FixedCandidateReaderRouter(
                sourceReader: StubCandidates()
            ),
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
        return (session, recorder, collector)
    }

    private var testSettings: MonitoringSettings {
        MonitoringSettings(
            mode: .modelFirst,
            candidateDwellDuration: 0.08,
            translationScope: .selected,
            configurationToken: "test"
        )
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

final class AXCandidateRowSelectionTests: XCTestCase {
    func testFrameOnlyVisibleItemsStillProduceSelectedRow() {
        let selected = AXCandidateItem(
            text: "你",
            frame: CGRect(x: 40, y: 0, width: 20, height: 20)
        )
        let row = AXCandidateVisibleRowSelector.select(
            selected: selected,
            visible: [
                AXCandidateItem(
                    text: "",
                    frame: CGRect(x: 10, y: 0, width: 20, height: 20)
                ),
                selected,
                AXCandidateItem(
                    text: "",
                    frame: CGRect(x: 70, y: 0, width: 20, height: 20)
                ),
            ]
        )

        XCTAssertEqual(row?.items.count, 3)
        XCTAssertEqual(row?.selectedIndex, 1)
        XCTAssertEqual(row?.items.map(\.text), ["", "你", ""])
    }
}
