import Foundation
import GlintCore
import os
import XCTest
@testable import GlintMac

final class RimeCandidateBridgeTests: XCTestCase {
    func testLuaJSONEncoderUsesCurrentProtocolVersion() throws {
        let luaFile = try XCTUnwrap(
            repositoryRoot?
                .appendingPathComponent(
                    "Tools/RimeCandidateLab/rime/lua/glint/json.lua"
                )
        )
        let source = try String(
            contentsOf: luaFile,
            encoding: .utf8
        )
        let marker = "{\"version\":"
        let markerRange = try XCTUnwrap(
            source.range(of: marker)
        )
        let versionText = source[markerRange.upperBound...]
            .prefix(while: { $0.isNumber })

        XCTAssertEqual(
            Int(versionText),
            RimeCandidateEnvelope.currentVersion
        )
    }

    func testStoreReturnsFreshActiveEnvelope() {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 100)
        let store = RimeCandidateSnapshotStore(
            clock: { clock.withLock { $0 } }
        )
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 1,
            heartbeat: false,
            active: true,
            schemaID: "luna_pinyin",
            selectedText: "妳好",
            selectedIndex: 1,
            candidates: ["你好", "妳好"]
        )

        store.record(envelope)

        XCTAssertEqual(
            store.latest(maxAgeNanoseconds: 1_000_000_000),
            envelope
        )
    }

    func testStoreRejectsInvalidEnvelope() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 2,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 2,
                candidates: ["你好", "妳好"]
            )
        )

        XCTAssertNil(store.latest(maxAgeNanoseconds: 1_000_000_000))
    }

    func testStoreExpiresStaleEnvelope() {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 100)
        let store = RimeCandidateSnapshotStore(
            clock: { clock.withLock { $0 } }
        )
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 3,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好"]
            )
        )
        clock.withLock { $0 += 2_000_000_000 }

        XCTAssertNil(store.latest(maxAgeNanoseconds: 1_000_000_000))
    }

    func testInactiveEnvelopeClearsActiveState() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 4,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好"]
            )
        )
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 5,
                heartbeat: false,
                active: false,
                schemaID: nil,
                selectedText: nil,
                selectedIndex: nil,
                candidates: []
            )
        )

        XCTAssertNil(store.latest(maxAgeNanoseconds: 1_000_000_000))
    }

    func testInactiveEnvelopeFromAnotherSessionCannotClearCurrentState() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "old",
                sequence: 1,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你",
                selectedIndex: 0,
                candidates: ["你"]
            )
        )
        store.record(
            RimeCandidateEnvelope(
                sessionID: "current",
                sequence: 1,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好", "妳好"]
            )
        )

        store.record(
            RimeCandidateEnvelope(
                sessionID: "old",
                sequence: 2,
                heartbeat: false,
                active: false,
                schemaID: nil,
                selectedText: nil,
                selectedIndex: nil,
                candidates: []
            )
        )

        XCTAssertEqual(
            store.latest(maxAgeNanoseconds: 1_000_000_000)?
                .selectedText,
            "你好"
        )
    }

    func testSquirrelReaderReturnsSelectedCandidateAtPanelFrame() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 6,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "妳好",
                selectedIndex: 1,
                candidates: ["你好", "妳好", "逆号"]
            )
        )
        let reader = SquirrelCandidateReader(
            store: store,
            panelFrame: {
                CGRect(x: 120, y: 40, width: 96, height: 140)
            }
        )

        let snapshot = reader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )

        XCTAssertEqual(snapshot?.text, "妳好")
        XCTAssertEqual(snapshot?.selectedIndex, 1)
        XCTAssertEqual(snapshot?.selectionIsExact, true)
        XCTAssertEqual(
            snapshot?.frame,
            CGRect(x: 120, y: 40, width: 96, height: 140)
        )
    }

    func testSquirrelReaderKeepsCandidateWhenPanelFrameIsUnavailable() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 7,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好", "妳好"]
            )
        )
        let reader = SquirrelCandidateReader(
            store: store,
            panelFrame: { nil }
        )

        let snapshot = reader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )

        XCTAssertEqual(snapshot?.text, "你好")
        XCTAssertNil(snapshot?.frame)
        XCTAssertEqual(snapshot?.selectionIsExact, true)
    }

    func testSquirrelReaderUsesSelectedTextWithoutCandidateList() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 8,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: nil,
                candidates: []
            )
        )
        let reader = SquirrelCandidateReader(
            store: store,
            panelFrame: { nil }
        )

        let snapshot = reader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )

        XCTAssertEqual(snapshot?.text, "你好")
        XCTAssertEqual(snapshot?.selectedIndex, 0)
        XCTAssertEqual(snapshot?.options.count, 1)
        XCTAssertEqual(snapshot?.selectionIsExact, true)
    }

    func testSquirrelReaderHidesWhenBridgeSnapshotIsInactive() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        let reader = SquirrelCandidateReader(
            store: store,
            panelFrame: {
                CGRect(x: 120, y: 40, width: 96, height: 140)
            }
        )

        XCTAssertNil(
            reader.snapshot(
                includeVisibleCandidates: true,
                includeVisibleTexts: false
            )
        )
        XCTAssertEqual(reader.missReason, .candidateEnded)
    }

    func testSquirrelReaderUsesInputCaretWhenPanelFrameIsUnavailable()
        async
    {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 9,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好", "妳好"]
            )
        )
        let reader = SquirrelCandidateReader(
            store: store,
            panelFrame: { nil }
        )
        let caretFrame = CGRect(
            x: 120,
            y: 160,
            width: 2,
            height: 20
        )
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: RimeTestDictionary(),
                translation: RimeTestTranslation()
            ),
            inputSource: RimeTestInputSource(),
            focus: RimeTestFocus(caretFrame: caretFrame),
            candidateReaders: RimeTestCandidateReaderRouter(
                reader: reader
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )
        var iterator = await controller.events.makeAsyncIterator()

        _ = await controller.tick()

        guard case .inputSourceChanged = await iterator.next() else {
            return XCTFail("Expected input source event")
        }
        guard case .candidateChanged = await iterator.next() else {
            return XCTFail("Expected a candidate despite missing panel frame")
        }
        guard
            case .layoutChanged(let highlight, let inputCaretRect) =
                await iterator.next()
        else {
            return XCTFail("Expected layout event")
        }
        XCTAssertEqual(
            highlight.cgRect,
            caretFrame
        )
        XCTAssertEqual(inputCaretRect, caretFrame)
    }

    func testNonBridgeCandidateWithoutFrameDoesNotUseCaretFallback()
        async
    {
        let controller = MonitoringController(
            router: SmartRouter(
                dictionary: RimeTestDictionary(),
                translation: RimeTestTranslation()
            ),
            inputSource: RimeWeChatInputSource(),
            focus: RimeTestFocus(
                caretFrame: CGRect(
                    x: 120,
                    y: 160,
                    width: 2,
                    height: 20
                )
            ),
            candidateReaders: RimeTestCandidateReaderRouter(
                reader: RimeFixedCandidateReader()
            ),
            accessibilityIsTrusted: { true },
            secureInputIsEnabled: { false }
        )
        var iterator = await controller.events.makeAsyncIterator()

        _ = await controller.tick()

        guard case .inputSourceChanged = await iterator.next() else {
            return XCTFail("Expected input source event")
        }
        guard case .status = await iterator.next() else {
            return XCTFail("Expected a frame-position miss")
        }
    }

    func testSquirrelRegistrationDoesNotChangeOtherInputReaders() {
        let store = RimeCandidateSnapshotStore(clock: { 100 })
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 10,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好"]
            )
        )
        let router = CandidateReaderConfiguration.standard(
            rimeCandidateStore: store
        )

        XCTAssertTrue(
            router.reader(
                for: ActiveInputSource(
                    id: InputMethodIdentifier.squirrelHansMode,
                    kind: .otherInputMethod,
                    bundleIdentifier:
                        InputMethodIdentifier.squirrelBundle
                )
            ) is SquirrelCandidateReader
        )
        XCTAssertTrue(
            router.reader(
                for: ActiveInputSource(
                    id: InputMethodIdentifier.weTypePinyinMode,
                    kind: .otherInputMethod,
                    bundleIdentifier:
                        InputMethodIdentifier.weTypeBundle
                )
            ) is WeTypeCandidateReader
        )
    }

    func testSquirrelWithoutBridgeKeepsAdaptiveFallback() {
        let router = CandidateReaderConfiguration.standard()
        let reader = router.reader(
            for: ActiveInputSource(
                id: InputMethodIdentifier.squirrelHansMode,
                kind: .otherInputMethod,
                bundleIdentifier:
                    InputMethodIdentifier.squirrelBundle
            )
        )

        XCTAssertTrue(reader is AdaptiveUnknownCandidateReader)
    }

    func testSquirrelWithEmptyBridgeStoreKeepsAdaptiveFallback() {
        let router = CandidateReaderConfiguration.standard(
            rimeCandidateStore: RimeCandidateSnapshotStore(
                clock: { 100 }
            )
        )
        let reader = router.reader(
            for: ActiveInputSource(
                id: InputMethodIdentifier.squirrelHansMode,
                kind: .otherInputMethod,
                bundleIdentifier:
                    InputMethodIdentifier.squirrelBundle
            )
        )

        XCTAssertTrue(reader is AdaptiveUnknownCandidateReader)
    }

    func testExpiredSquirrelSnapshotFallsBackWithoutAffectingOtherReaders() {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 100)
        let store = RimeCandidateSnapshotStore(
            clock: { clock.withLock { $0 } }
        )
        store.record(
            RimeCandidateEnvelope(
                sessionID: "test-session",
                sequence: 11,
                heartbeat: false,
                active: true,
                schemaID: "luna_pinyin",
                selectedText: "你好",
                selectedIndex: 0,
                candidates: ["你好"]
            )
        )
        let router = CandidateReaderConfiguration.standard(
            rimeCandidateStore: store
        )
        let source = ActiveInputSource(
            id: InputMethodIdentifier.squirrelHansMode,
            kind: .otherInputMethod,
            bundleIdentifier: InputMethodIdentifier.squirrelBundle
        )

        XCTAssertTrue(router.reader(for: source) is SquirrelCandidateReader)

        clock.withLock { $0 += 6_000_000_000 }

        XCTAssertTrue(
            router.reader(for: source) is AdaptiveUnknownCandidateReader
        )
        XCTAssertTrue(
            router.reader(
                for: ActiveInputSource(
                    id: InputMethodIdentifier.weTypePinyinMode,
                    kind: .otherInputMethod,
                    bundleIdentifier: InputMethodIdentifier.weTypeBundle
                )
            ) is WeTypeCandidateReader
        )
    }

    func testSocketClientRejectsOversizedPath() {
        let client = RimeCandidateSocketClient(
            socketPath: "/tmp/" + String(repeating: "a", count: 200)
        )

        XCTAssertThrowsError(try client.send(Data([0x7B, 0x7D])))
    }

    func testReceiverStoresDecodedEnvelope() {
        let receiver = RimeCandidateBridgeReceiver(
            socketPath: "/tmp/unused-glint-rime-bridge.sock"
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"sessionID":"test-session","sequence":1,"heartbeat":false,"active":true,"schemaID":"luna_pinyin","selectedText":"妳好","selectedIndex":1,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )

        XCTAssertEqual(
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedIndex,
            1
        )
        XCTAssertEqual(
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedText,
            "妳好"
        )
    }

    func testHeartbeatCannotReplaceAnotherSessionSnapshot() {
        let receiver = RimeCandidateBridgeReceiver(
            socketPath: "/tmp/unused-glint-rime-bridge.sock",
            store: RimeCandidateSnapshotStore(clock: { 100 })
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"active":true,"sessionID":"old","sequence":7,"heartbeat":false,"schemaID":"luna_pinyin","selectedText":"你","selectedIndex":0,"candidates":["你"]}"#
                    .utf8
            )
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"active":true,"sessionID":"current","sequence":1,"heartbeat":false,"schemaID":"luna_pinyin","selectedText":"你好","selectedIndex":0,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )

        receiver.handle(
            line: Data(
                #"{"version":3,"active":true,"sessionID":"old","sequence":7,"heartbeat":true,"schemaID":"luna_pinyin","selectedText":"你","selectedIndex":0,"candidates":["你"]}"#
                    .utf8
            )
        )

        XCTAssertEqual(
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedText,
            "你好"
        )
    }

    func testOlderSequenceCannotReplaceNewerCandidate() {
        let receiver = RimeCandidateBridgeReceiver(
            socketPath: "/tmp/unused-glint-rime-bridge.sock",
            store: RimeCandidateSnapshotStore(clock: { 100 })
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"sessionID":"current","sequence":2,"heartbeat":false,"active":true,"schemaID":"luna_pinyin","selectedText":"妳好","selectedIndex":1,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"sessionID":"current","sequence":1,"heartbeat":false,"active":true,"schemaID":"luna_pinyin","selectedText":"你好","selectedIndex":0,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )

        XCTAssertEqual(
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedText,
            "妳好"
        )
    }

    func testMatchingHeartbeatKeepsStableCandidateFresh() {
        let clock = OSAllocatedUnfairLock<UInt64>(initialState: 100)
        let receiver = RimeCandidateBridgeReceiver(
            socketPath: "/tmp/unused-glint-rime-bridge.sock",
            store: RimeCandidateSnapshotStore(
                clock: { clock.withLock { $0 } }
            )
        )
        receiver.handle(
            line: Data(
                #"{"version":3,"sessionID":"current","sequence":1,"heartbeat":false,"active":true,"schemaID":"luna_pinyin","selectedText":"你好","selectedIndex":0,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )
        clock.withLock { $0 = 4_000_000_100 }
        receiver.handle(
            line: Data(
                #"{"version":3,"sessionID":"current","sequence":1,"heartbeat":true,"active":true,"schemaID":"luna_pinyin","selectedText":"你好","selectedIndex":0,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )
        clock.withLock { $0 = 8_000_000_100 }

        XCTAssertEqual(
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedText,
            "你好"
        )
    }

    func testReceiverAcceptsSocketEnvelope() async throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-\(UUID().uuidString).sock"
            )
            .path
        let receiver = RimeCandidateBridgeReceiver(
            socketPath: socketPath
        )
        XCTAssertTrue(receiver.start())
        defer {
            receiver.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let client = RimeCandidateSocketClient(socketPath: socketPath)

        try client.send(
            Data(
                #"{"version":3,"sessionID":"test-session","sequence":1,"heartbeat":false,"active":true,"schemaID":"luna_pinyin","selectedText":"你好","selectedIndex":0,"candidates":["你好","妳好"]}"#
                    .utf8
            )
        )

        let stored = await waitUntil {
            receiver.store.latest(
                maxAgeNanoseconds: 5_000_000_000
            )?.selectedText == "你好"
        }
        XCTAssertTrue(stored)
    }

    func testDuplicateSocketServerStartDoesNotBreakListener() async throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-\(UUID().uuidString).sock"
            )
            .path
        let server = RimeCandidateSocketServer(socketPath: socketPath)
        let received = OSAllocatedUnfairLock(initialState: false)
        XCTAssertTrue(
            server.start { _ in
                received.withLock { $0 = true }
            }
        )
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        XCTAssertFalse(server.start { _ in })

        let client = RimeCandidateSocketClient(socketPath: socketPath)
        XCTAssertNoThrow(
            try client.send(
                Data(
                    #"{"version":3,"sessionID":"test-session","sequence":1,"heartbeat":false,"active":false,"schemaID":null,"selectedText":null,"selectedIndex":null,"candidates":[]}"#
                        .utf8
                )
            )
        )
        let wasReceived = await waitUntil {
            received.withLock { $0 }
        }
        XCTAssertTrue(wasReceived)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private var repositoryRoot: URL? {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath:
                    directory.appendingPathComponent("project.yml").path
            ) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}

private struct RimeTestInputSource: InputSourceReading {
    @MainActor
    func currentInputSource() -> ActiveInputSource {
        ActiveInputSource(
            id: InputMethodIdentifier.squirrelHansMode,
            kind: .otherInputMethod,
            bundleIdentifier: InputMethodIdentifier.squirrelBundle
        )
    }
}

private struct RimeWeChatInputSource: InputSourceReading {
    @MainActor
    func currentInputSource() -> ActiveInputSource {
        ActiveInputSource(
            id: InputMethodIdentifier.weTypePinyinMode,
            kind: .otherInputMethod,
            bundleIdentifier: InputMethodIdentifier.weTypeBundle
        )
    }
}

private struct RimeTestFocus: FocusReading {
    let caretFrame: CGRect

    func snapshot() -> FocusSnapshot? {
        FocusSnapshot(
            caretRect: caretFrame,
            elementFrame: nil,
            compositionState: .composing,
            isEditableTextInput: true,
            processIdentifier: 4242
        )
    }
}

private struct RimeFixedCandidateReader: AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        AXCandidateSnapshot(
            text: "你好",
            visibleTexts: [],
            frame: nil,
            candidateListFrame: nil
        )
    }
}

private struct RimeTestCandidateReaderRouter: CandidateReaderRouting {
    let reader: any AXCandidateReading

    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading {
        reader
    }

    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool {
        true
    }
}

private struct RimeTestDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct RimeTestTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}
