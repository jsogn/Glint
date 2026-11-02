import Carbon
import CoreGraphics
import GlintCore
import os
import XCTest

@testable import GlintMac

@MainActor
private final class FakeTranslationChoiceHotKeys:
    TranslationChoiceHotKeyRegistering
{
    let choiceRegistrationSucceeds: Bool
    var onChoice: (@MainActor (Int) -> Void)?
    private(set) var choiceTransitions: [(Bool, Int)] = []
    private(set) var choiceModifiers =
        TranslationInsertionShortcut.defaultTrigger.modifiers

    init(choiceRegistrationSucceeds: Bool = true) {
        self.choiceRegistrationSucceeds =
            choiceRegistrationSucceeds
    }

    func setChoiceModifiers(
        _ modifiers: TranslationInsertionModifiers
    ) {
        choiceModifiers = modifiers
    }

    func setChoiceKeysEnabled(
        _ enabled: Bool,
        count: Int
    ) -> Bool {
        choiceTransitions.append((enabled, count))
        return !enabled || choiceRegistrationSucceeds
    }

    func choose(_ index: Int) {
        onChoice?(index)
    }
}

private enum FakeTextInsertionEvent: Equatable {
    case key(virtualKey: UInt16, isKeyDown: Bool)
    case unicode(String)
}

private final class FakeTextInsertionEventPoster:
    TranslationKeyboardEventPosting, Sendable
{
    private let events =
        OSAllocatedUnfairLock<[FakeTextInsertionEvent]>(initialState: [])

    func postKey(
        virtualKey: UInt16,
        isKeyDown: Bool,
        to processIdentifier: pid_t
    ) -> Bool {
        events.withLock {
            $0.append(
                .key(
                    virtualKey: virtualKey,
                    isKeyDown: isKeyDown
                )
            )
        }
        return processIdentifier == 4242
    }

    func postUnicode(
        _ text: String,
        to processIdentifier: pid_t
    ) -> Bool {
        events.withLock {
            $0.append(.unicode(text))
        }
        return processIdentifier == 4242
    }

    var recordedEvents: [FakeTextInsertionEvent] {
        events.withLock { $0 }
    }
}

private final class RecordingCGEventTransport:
    TranslationCGEventTransport, Sendable
{
    private let processIdentifiers =
        OSAllocatedUnfairLock<[pid_t]>(initialState: [])

    func post(_ event: CGEvent, to processIdentifier: pid_t) -> Bool {
        processIdentifiers.withLock {
            $0.append(processIdentifier)
        }
        return true
    }

    var recordedProcessIdentifiers: [pid_t] {
        processIdentifiers.withLock { $0 }
    }
}

private final class BooleanSequence: Sendable {
    private let values: OSAllocatedUnfairLock<[Bool]>

    init(_ values: [Bool]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    func next() -> Bool {
        values.withLock {
            guard !$0.isEmpty else { return $0.last ?? false }
            return $0.count == 1 ? $0[0] : $0.removeFirst()
        }
    }
}

private final class ProcessIdentifierSequence: Sendable {
    private let values: OSAllocatedUnfairLock<[pid_t]>

    init(_ values: [pid_t]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    func next() -> pid_t? {
        values.withLock {
            guard !$0.isEmpty else { return nil }
            return $0.count == 1 ? $0[0] : $0.removeFirst()
        }
    }
}

@MainActor
final class TranslationChoiceInsertionTests: XCTestCase {
    func testChoiceHotKeyNamespacesUseDistinctSignatures() {
        XCTAssertNotEqual(
            TranslationChoiceHotKeyNamespace.insertion.signature,
            TranslationChoiceHotKeyNamespace.speech.signature
        )
    }

    func testHotKeyProbeDetectsExistingGlobalRegistration() throws {
        let modifiers: TranslationInsertionModifiers = [
            .control,
            .option,
            .shift,
            .command,
        ]
        var occupyingRef: EventHotKeyRef?
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = 0x5052_4F42  // PROB
        hotKeyID.id = 1
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            modifiers.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &occupyingRef
        )
        XCTAssertEqual(status, noErr)
        let registeredRef = try XCTUnwrap(occupyingRef)
        defer { UnregisterEventHotKey(registeredRef) }

        XCTAssertFalse(
            TranslationChoiceHotKeyProbe.canRegister(
                modifiers: modifiers,
                count: 1
            )
        )
    }

    func testCarbonModifierMaskIncludesAllSupportedKeys() {
        let modifiers: TranslationInsertionModifiers = [
            .control,
            .option,
            .shift,
            .command,
            .capsLock,
        ]

        XCTAssertEqual(
            modifiers.carbonModifiers,
            UInt32(
                controlKey | optionKey | shiftKey
                    | cmdKey | alphaLock
            )
        )
    }

    func testOfferImmediatelyEnablesChoiceShortcuts() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        XCTAssertEqual(hotKeys.choiceTransitions.map(\.0), [true])
        XCTAssertEqual(hotKeys.choiceTransitions.first?.1, 2)
        XCTAssertEqual(hotKeys.choiceModifiers, [.option])
    }

    func testDisablingCoordinatorUnregistersChoiceKeys() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        var selectedIndex: Int?
        coordinator.onChoice = { _, index in
            selectedIndex = index
            return true
        }
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        coordinator.setEnabled(false)

        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false]
        )
        hotKeys.choose(0)
        XCTAssertNil(selectedIndex)
    }

    func testReenablingCoordinatorRestoresActiveChoiceKeys() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )
        coordinator.setEnabled(false)

        coordinator.setEnabled(true)

        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false, true]
        )
    }

    func testClearingOfferDisablesChoiceShortcuts() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        coordinator.update(nil)

        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false]
        )
    }

    func testUpdatingShortcutReregistersActiveChoiceKeys() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let custom = TranslationInsertionShortcut(
            modifiers: [.control, .command]
        )
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        coordinator.updateShortcut(custom)

        XCTAssertEqual(
            hotKeys.choiceModifiers,
            custom.modifiers
        )
        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false, true]
        )
    }

    func testChoiceUsesCurrentOfferAndDisablesHotKeys() async throws {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        let offer = TranslationChoiceOffer(
            revision: 11,
            choices: ["primary", "alternative", "secondary"]
        )
        var selectedRevision: UInt64?
        var selectedIndex: Int?
        coordinator.onChoice = { receivedOffer, index in
            selectedRevision = receivedOffer.revision
            selectedIndex = index
            return true
        }
        coordinator.update(offer)

        hotKeys.choose(1)
        try await waitUntil {
            selectedRevision != nil
        }

        XCTAssertEqual(selectedRevision, 11)
        XCTAssertEqual(selectedIndex, 1)
        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false]
        )
        XCTAssertEqual(hotKeys.choiceTransitions.first?.1, 3)
    }

    func testOnlyPublishedChoiceCountsBecomeHotKeys() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        var selectedIndex: Int?
        coordinator.onChoice = { _, index in
            selectedIndex = index
            return true
        }
        coordinator.update(
            TranslationChoiceOffer(
                revision: 12,
                choices: ["one", "two", "three", "four", "five"]
            )
        )

        hotKeys.choose(5)

        XCTAssertEqual(hotKeys.choiceTransitions.first?.1, 5)
        XCTAssertNil(selectedIndex)
    }

    func testFailedRegistrationDoesNotAcceptChoice() {
        let hotKeys = FakeTranslationChoiceHotKeys(
            choiceRegistrationSucceeds: false
        )
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        var selectedIndex: Int?
        coordinator.onChoice = { _, index in
            selectedIndex = index
            return true
        }
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        hotKeys.choose(1)

        XCTAssertNil(selectedIndex)
    }

    func testChoiceKeysStopAtNine() {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: (1...12).map { "option-\($0)" }
            )
        )

        XCTAssertEqual(hotKeys.choiceTransitions.first?.1, 9)
    }

    func testFailedChoiceRestoresCurrentOffer() async throws {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.onChoice = { _, _ in false }
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        hotKeys.choose(1)
        try await waitUntil {
            hotKeys.choiceTransitions.map(\.0) == [true, false, true]
        }

        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false, true]
        )
    }

    func testFailedChoiceDoesNotRestoreStaleOffer() async throws {
        let hotKeys = FakeTranslationChoiceHotKeys()
        let coordinator = TranslationChoiceShortcutCoordinator(
            hotKeys: hotKeys
        )
        coordinator.onChoice = { _, _ in
            try? await Task.sleep(for: .milliseconds(40))
            return false
        }
        coordinator.update(
            TranslationChoiceOffer(
                revision: 7,
                choices: ["primary", "alternative"]
            )
        )

        hotKeys.choose(0)
        coordinator.update(nil)
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(
            hotKeys.choiceTransitions.map(\.0),
            [true, false]
        )
    }

    func testArbitraryFrontmostProcessReceivesUnicodeWithoutFocusEvidence()
        async
    {
        let poster = FakeTextInsertionEventPoster()
        let inserter = SystemTranslationTextInserter(
            frontmostProcessIdentifier: { 4242 },
            keyboardEventPoster: poster
        )

        let inserted = await inserter.insert("hello", into: 4242)

        XCTAssertTrue(inserted)
        XCTAssertEqual(
            poster.recordedEvents,
            [
                .key(virtualKey: 53, isKeyDown: true),
                .key(virtualKey: 53, isKeyDown: false),
                .unicode("hello"),
            ]
        )
    }

    func testFrontmostChangeAfterEscapePreventsUnicode()
        async
    {
        let poster = FakeTextInsertionEventPoster()
        let frontmost = ProcessIdentifierSequence([4242, 9999])
        let inserter = SystemTranslationTextInserter(
            frontmostProcessIdentifier: {
                frontmost.next() ?? 9999
            },
            keyboardEventPoster: poster
        )

        let inserted = await inserter.insert("hello", into: 4242)

        XCTAssertFalse(inserted)
        XCTAssertEqual(
            poster.recordedEvents,
            [
                .key(virtualKey: 53, isKeyDown: true),
                .key(virtualKey: 53, isKeyDown: false),
            ]
        )
    }

    func testSystemPosterRoutesEventsToSelectedProcess() {
        let transport = RecordingCGEventTransport()
        let poster = SystemTranslationKeyboardEventPoster(
            eventTransport: transport
        )

        XCTAssertTrue(
            poster.postUnicode("hello", to: 4242)
        )
        XCTAssertEqual(
            transport.recordedProcessIdentifiers,
            [4242, 4242]
        )
    }

    func testInsertionRechecksSecureInputBeforePosting() async {
        let poster = FakeTextInsertionEventPoster()
        let secureInput = BooleanSequence([false, true])
        let inserter = SystemTranslationTextInserter(
            frontmostProcessIdentifier: { 4242 },
            secureInputIsEnabled: { secureInput.next() },
            keyboardEventPoster: poster
        )

        let inserted = await inserter.insert("hello", into: 4242)

        XCTAssertFalse(inserted)
        XCTAssertEqual(
            poster.recordedEvents,
            [
                .key(virtualKey: 53, isKeyDown: true),
                .key(virtualKey: 53, isKeyDown: false),
            ]
        )
    }

    func testFrontmostChangePreventsSyntheticEvents() async {
        let poster = FakeTextInsertionEventPoster()
        let inserter = SystemTranslationTextInserter(
            frontmostProcessIdentifier: { 9999 },
            keyboardEventPoster: poster
        )

        let inserted = await inserter.insert("hello", into: 4242)

        XCTAssertFalse(inserted)
        XCTAssertEqual(poster.recordedEvents, [])
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for condition")
    }
}
