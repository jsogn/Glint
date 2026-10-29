import CoreGraphics
import Foundation
import GlintCore
import os
import XCTest

@testable import GlintMac

private struct InsertionFocus: FocusReading {
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

private final class MutableInsertionFocus:
    FocusReading, @unchecked Sendable
{
    private let caretRect = OSAllocatedUnfairLock(
        initialState: CGRect(
            x: 120,
            y: 160,
            width: 2,
            height: 20
        )
    )

    func snapshot() -> FocusSnapshot? {
        FocusSnapshot(
            caretRect: caretRect.withLock { $0 },
            elementFrame: nil,
            compositionState: .composing,
            isEditableTextInput: true,
            processIdentifier: 4242
        )
    }

    func moveCaret(to rect: CGRect) {
        caretRect.withLock {
            $0 = rect
        }
    }
}

private struct InsertionCandidates: AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        AXCandidateSnapshot(
            text: "并且",
            visibleTexts: ["并且", "并肩", "合并"],
            frame: CGRect(x: 120, y: 120, width: 48, height: 28),
            candidateListFrame: nil,
            selectedIndex: 1,
            selectionIsExact: true
        )
    }
}

private struct OffsetInsertionCandidates: AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        AXCandidateSnapshot(
            text: "five",
            visibleTexts: [
                "one", "two", "three", "four", "five", "six",
            ],
            frame: CGRect(x: 120, y: 120, width: 48, height: 28),
            candidateListFrame: nil,
            selectedIndex: 4,
            selectionIsExact: true
        )
    }
}

private struct InsertionCandidateRouter: CandidateReaderRouting {
    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading {
        InsertionCandidates()
    }

    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool {
        false
    }
}

private struct OffsetInsertionCandidateRouter: CandidateReaderRouting {
    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading {
        OffsetInsertionCandidates()
    }

    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool {
        false
    }
}

private final class RecordingTranslationTextWriter:
    TranslationTextInserting, Sendable
{
    private let requests =
        OSAllocatedUnfairLock<[(text: String, pid: pid_t)]>(
            initialState: []
        )

    func insert(
        _ text: String,
        into processIdentifier: pid_t
    ) async -> Bool {
        requests.withLock {
            $0.append((text, processIdentifier))
        }
        return true
    }

    var recordedRequests: [(text: String, pid: pid_t)] {
        requests.withLock { $0 }
    }
}

private final class InsertionOfferRecorder: Sendable {
    private let offer =
        OSAllocatedUnfairLock<TranslationChoiceOffer?>(initialState: nil)

    func record(_ value: TranslationChoiceOffer) {
        offer.withLock { $0 = value }
    }

    var current: TranslationChoiceOffer? {
        offer.withLock { $0 }
    }
}

private final class PresentationRecorder: Sendable {
    private let presentations =
        OSAllocatedUnfairLock<[CandidateTranslationPresentation]?>(initialState: nil)
    private let count = OSAllocatedUnfairLock(initialState: 0)

    func record(_ value: [CandidateTranslationPresentation]) {
        presentations.withLock { $0 = value }
        count.withLock { $0 += 1 }
    }

    var latest: [CandidateTranslationPresentation]? {
        presentations.withLock { $0 }
    }

    var recordedCount: Int {
        count.withLock { $0 }
    }
}

private final class InputCaretRectRecorder: Sendable {
    private let inputCaretRect =
        OSAllocatedUnfairLock<CGRect?>(initialState: nil)

    func record(_ value: CGRect?) {
        inputCaretRect.withLock { $0 = value }
    }

    var latest: CGRect? {
        inputCaretRect.withLock { $0 }
    }
}

private final class LayoutGeometryRecorder: Sendable {
    private let geometry =
        OSAllocatedUnfairLock<(CandidateRegion, CGRect?)?>(
            initialState: nil
        )

    func record(
        highlight: CandidateRegion,
        inputCaretRect: CGRect?
    ) {
        geometry.withLock {
            $0 = (highlight, inputCaretRect)
        }
    }

    var latest: (CandidateRegion, CGRect?)? {
        geometry.withLock { $0 }
    }
}

private actor TranslationGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation {
            continuation = $0
        }
    }

    func waitUntilStarted(
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !started {
            guard clock.now < deadline else {
                throw TranslationGateError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum TranslationGateError: Error {
    case timedOut
}

private final class MutableSecureInput: Sendable {
    private let enabled = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool {
        enabled.withLock { $0 }
    }

    func enable() {
        enabled.withLock { $0 = true }
    }
}

final class TranslationChoiceMonitoringTests: XCTestCase {
    func testSelectedModePublishesConfiguredMaximumChoices() async throws {
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: InsertionManyOptionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = InsertionOfferRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .insertionOffer(let offer) = event {
                    recorder.record(offer)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.current != nil }
        let offer = try XCTUnwrap(recorder.current)

        XCTAssertEqual(
            offer.choices,
            ["one", "two", "three", "four"]
        )
        let insertedHiddenChoice = await controller.insertTranslation(
            offer,
            choiceIndex: 4
        )
        XCTAssertFalse(insertedHiddenChoice)
        XCTAssertTrue(writer.recordedRequests.isEmpty)
    }

    func testChosenTranslationIsWrittenToFocusedProcess() async throws {
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: InsertionMultiOptionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = InsertionOfferRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .insertionOffer(let offer) = event {
                    recorder.record(offer)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.current != nil }
        let offer = try XCTUnwrap(recorder.current)

        XCTAssertEqual(
            offer.choices,
            ["primary", "alternative", "secondary"]
        )
        let inserted = await controller.insertTranslation(
            offer,
            choiceIndex: 1
        )

        XCTAssertTrue(inserted)
        XCTAssertEqual(
            writer.recordedRequests.map(\.text),
            ["alternative"]
        )
        XCTAssertEqual(
            writer.recordedRequests.map(\.pid),
            [pid_t(4242)]
        )
    }

    func testSecureInputBlocksTranslationInsertion() async throws {
        let writer = RecordingTranslationTextWriter()
        let secureInput = MutableSecureInput()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: InsertionMultiOptionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: {
                secureInput.isEnabled
            },
            translationTextInserter: writer
        )
        let recorder = InsertionOfferRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .insertionOffer(let offer) = event {
                    recorder.record(offer)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.current != nil }
        let offer = try XCTUnwrap(recorder.current)
        secureInput.enable()

        let inserted = await controller.insertTranslation(
            offer,
            choiceIndex: 1
        )

        XCTAssertFalse(inserted)
        XCTAssertTrue(writer.recordedRequests.isEmpty)
    }

    func testRowModePublishesConfiguredMaximumChoices()
        async throws
    {
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: RowInsertionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = InsertionOfferRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .insertionOffer(let offer) = event {
                    recorder.record(offer)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setMaximumTranslationCount(2)
        await controller.setTranslationScope(.row)
        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.current != nil }
        let offer = try XCTUnwrap(recorder.current)

        XCTAssertEqual(
            offer.choices,
            ["and", "side by side"]
        )
        let insertedHiddenChoice = await controller.insertTranslation(
            offer,
            choiceIndex: 2
        )

        XCTAssertFalse(insertedHiddenChoice)
        XCTAssertTrue(writer.recordedRequests.isEmpty)
    }

    func testRowModeKeepsVisibleChoicesWhenSelectionExceedsLimit()
        async throws
    {
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: EchoInsertionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: OffsetInsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = PresentationRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .results(let presentations, _, _, _, _) = event {
                    recorder.record(presentations)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setMaximumTranslationCount(2)
        await controller.setTranslationScope(.row)
        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.latest != nil }

        XCTAssertEqual(
            recorder.latest?.map(\.translation),
            ["one", "two"]
        )
    }

    func testResultsCarryFocusedInputCaretRect() async throws {
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: InsertionMultiOptionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: InsertionFocus(),
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = InputCaretRectRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .results(_, _, let inputCaretRect, _, _) = event {
                    recorder.record(inputCaretRect)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { recorder.latest != nil }

        XCTAssertEqual(
            recorder.latest,
            CGRect(x: 120, y: 160, width: 2, height: 20)
        )
    }

    func testCaretMovementPublishesGeometryWithoutNewTranslation()
        async throws
    {
        let focus = MutableInsertionFocus()
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: InsertionMultiOptionTranslation()
            ),
            inputSource: InsertionInputSource(),
            focus: focus,
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let presentations = PresentationRecorder()
        let geometry = LayoutGeometryRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                switch event {
                case .results(let value, _, _, _, _):
                    presentations.record(value)
                case .layoutChanged(
                    let highlight,
                    let inputCaretRect
                ):
                    geometry.record(
                        highlight: highlight,
                        inputCaretRect: inputCaretRect
                    )
                default:
                    break
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await waitUntil { presentations.latest != nil }
        let translationResultCount = presentations.recordedCount

        let movedCaret = CGRect(
            x: 300,
            y: 160,
            width: 2,
            height: 20
        )
        focus.moveCaret(to: movedCaret)
        _ = await controller.tick()
        try await waitUntil {
            geometry.latest?.1 == movedCaret
        }

        XCTAssertEqual(
            geometry.latest?.0,
            CandidateRegion(x: 120, y: 120, width: 48, height: 28)
        )
        XCTAssertEqual(geometry.latest?.1, movedCaret)
        XCTAssertEqual(
            presentations.latest?.map(\.candidateText),
            ["并且"]
        )
        XCTAssertEqual(
            presentations.recordedCount,
            translationResultCount
        )
    }

    func testCompletedTranslationUsesLatestCaretRect()
        async throws
    {
        let focus = MutableInsertionFocus()
        let gate = TranslationGate()
        defer {
            Task {
                await gate.release()
            }
        }
        let writer = RecordingTranslationTextWriter()
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: EmptyInsertionDictionary(),
                translation: GatedInsertionTranslation(gate: gate)
            ),
            inputSource: InsertionInputSource(),
            focus: focus,
            candidateReaders: InsertionCandidateRouter(),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false },
            translationTextInserter: writer
        )
        let recorder = InputCaretRectRecorder()
        let events = await controller.events
        let collector = Task {
            for await event in events {
                if case .results(_, _, let inputCaretRect, _, _) = event {
                    recorder.record(inputCaretRect)
                }
            }
        }
        defer { collector.cancel() }

        await controller.setCandidateDwellDuration(0.08)
        _ = await controller.tick()
        try await Task.sleep(for: .milliseconds(90))
        _ = await controller.tick()
        try await gate.waitUntilStarted()

        let movedCaret = CGRect(
            x: 420,
            y: 160,
            width: 2,
            height: 20
        )
        focus.moveCaret(to: movedCaret)
        _ = await controller.tick()
        await gate.release()
        try await waitUntil { recorder.latest != nil }

        XCTAssertEqual(recorder.latest, movedCaret)
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
        throw TestWaitError.timedOut
    }
}

private enum TestWaitError: Error {
    case timedOut
}

private struct EmptyInsertionDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct InsertionMultiOptionTranslation: TranslationEngine {
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

private struct InsertionManyOptionTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        TranslationResult(
            options: (1...8).map { index in
                TranslationOption(
                    text: [
                        "one",
                        "two",
                        "three",
                        "four",
                        "five",
                        "six",
                        "seven",
                        "eight",
                    ][index - 1],
                    score: Double(9 - index)
                )
            }
        )
    }
}

private struct RowInsertionTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        let translations = [
            "并且": "and",
            "并肩": "side by side",
            "合并": "join",
        ]
        guard let text = translations[candidate.text] else {
            return nil
        }
        return TranslationResult(text: text)
    }
}

private struct EchoInsertionTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        TranslationResult(text: candidate.text)
    }
}

private struct GatedInsertionTranslation: TranslationEngine {
    let gate: TranslationGate

    func translate(_ candidate: Candidate) async throws
        -> TranslationResult?
    {
        await gate.wait()
        return TranslationResult(text: "primary")
    }
}

private struct InsertionInputSource: InputSourceReading {
    @MainActor
    func currentInputSource() -> ActiveInputSource {
        ActiveInputSource(
            id: "com.apple.inputmethod.SCIM.ITABC",
            kind: .applePinyin
        )
    }
}
