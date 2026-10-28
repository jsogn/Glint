import AppKit
import Carbon
import CoreGraphics
import Foundation
import GlintCore
import OSLog

private let translationChoiceLogger = Logger(
    subsystem: "com.local.glint",
    category: "Insertion"
)

public struct TranslationChoiceOffer: Sendable, Equatable {
    public let revision: UInt64
    public let choices: [String]

    public init(revision: UInt64, choices: [String]) {
        self.revision = revision
        self.choices = choices
    }
}

protocol TranslationTextInserting: Sendable {
    func insert(
        _ text: String,
        into processIdentifier: pid_t
    ) async -> Bool
}

protocol TranslationKeyboardEventPosting: Sendable {
    func postKey(
        virtualKey: UInt16,
        isKeyDown: Bool,
        to processIdentifier: pid_t
    ) -> Bool

    func postUnicode(
        _ text: String,
        to processIdentifier: pid_t
    ) -> Bool
}

struct SystemTranslationKeyboardEventPoster:
    TranslationKeyboardEventPosting
{
    func postKey(
        virtualKey: UInt16,
        isKeyDown: Bool,
        to processIdentifier: pid_t
    ) -> Bool {
        guard
            let event = CGEvent(
                keyboardEventSource: CGEventSource(
                    stateID: .combinedSessionState
                ),
                virtualKey: virtualKey,
                keyDown: isKeyDown
            )
        else {
            return false
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
        return true
    }

    func postUnicode(
        _ text: String,
        to processIdentifier: pid_t
    ) -> Bool {
        var characters = Array(text.utf16)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0,
                keyDown: false
            )
        else {
            return false
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters
        )
        keyUp.keyboardSetUnicodeString(
            stringLength: characters.count,
            unicodeString: &characters
        )
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

struct SystemTranslationTextInserter: TranslationTextInserting {
    private let focusSnapshot: @Sendable () -> FocusSnapshot?
    private let frontmostProcessIdentifier: @Sendable () -> pid_t?
    private let keyboardEventPoster: any TranslationKeyboardEventPosting

    init(
        focusSnapshot: @escaping @Sendable () -> FocusSnapshot? = {
            FocusMonitor().snapshot()
        },
        frontmostProcessIdentifier: @escaping @Sendable () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        keyboardEventPoster: any TranslationKeyboardEventPosting =
            SystemTranslationKeyboardEventPoster()
    ) {
        self.focusSnapshot = focusSnapshot
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.keyboardEventPoster = keyboardEventPoster
    }

    func insert(
        _ text: String,
        into processIdentifier: pid_t
    ) async -> Bool {
        let host =
            NSRunningApplication(
                processIdentifier: processIdentifier
            )?.bundleIdentifier ?? "unknown"
        guard !text.isEmpty else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=empty host=\(host, privacy: .public)"
            )
            return false
        }
        guard !FocusMonitor.isSecureInputEnabled() else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=secure_input host=\(host, privacy: .public)"
            )
            return false
        }
        guard let firstSnapshot = focusSnapshot() else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=focus_missing host=\(host, privacy: .public)"
            )
            return false
        }
        guard firstSnapshot.processIdentifier == processIdentifier else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=pid_changed host=\(host, privacy: .public)"
            )
            return false
        }
        guard firstSnapshot.isEditableTextInput else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=not_editable host=\(host, privacy: .public)"
            )
            return false
        }
        guard !firstSnapshot.hasTextSelection else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=text_selection host=\(host, privacy: .public)"
            )
            return false
        }
        guard !firstSnapshot.usesProcessFallback else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=process_fallback host=\(host, privacy: .public)"
            )
            return false
        }

        translationChoiceLogger.notice(
            "insert writer input host=\(host, privacy: .public) composition=\(firstSnapshot.compositionState.logValue, privacy: .public)"
        )
        let requiresCancellation =
            firstSnapshot.compositionState != .inactive
        if requiresCancellation {
            translationChoiceLogger.notice(
                "insert writer cancelling composition state=\(firstSnapshot.compositionState.logValue, privacy: .public)"
            )
            guard frontmostProcessIdentifier() == processIdentifier else {
                translationChoiceLogger.notice(
                    "insert writer rejected reason=frontmost_changed host=\(host, privacy: .public)"
                )
                return false
            }
            guard
                keyboardEventPoster.postKey(
                    virtualKey: UInt16(kVK_Escape),
                    isKeyDown: true,
                    to: processIdentifier
                ),
                keyboardEventPoster.postKey(
                    virtualKey: UInt16(kVK_Escape),
                    isKeyDown: false,
                    to: processIdentifier
                )
            else {
                translationChoiceLogger.notice(
                    "insert writer rejected reason=escape_post_failed host=\(host, privacy: .public)"
                )
                return false
            }

            if firstSnapshot.compositionState == .composing {
                var compositionEnded = false
                for _ in 0..<12 {
                    do {
                        try await Task.sleep(for: .milliseconds(5))
                    } catch {
                        return false
                    }
                    guard
                        let snapshot = focusSnapshot(),
                        snapshot.processIdentifier == processIdentifier,
                        snapshot.isEditableTextInput,
                        !snapshot.hasTextSelection
                    else {
                        return false
                    }
                    if snapshot.compositionState != .composing {
                        compositionEnded = true
                        break
                    }
                }
                guard compositionEnded else {
                    translationChoiceLogger.notice(
                        "insert writer rejected reason=composition_not_cancelled host=\(host, privacy: .public)"
                    )
                    return false
                }
            } else {
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return false
                }
            }
        }

        guard frontmostProcessIdentifier() == processIdentifier else {
            translationChoiceLogger.notice(
                "insert writer rejected reason=frontmost_changed host=\(host, privacy: .public)"
            )
            return false
        }
        let posted = keyboardEventPoster.postUnicode(
            text,
            to: processIdentifier
        )
        translationChoiceLogger.notice(
            "insert writer posted_unicode=\(posted, privacy: .public) transport=global_hid host=\(host, privacy: .public) composition=\(firstSnapshot.compositionState.logValue, privacy: .public)"
        )
        return posted
    }
}

private extension TextCompositionState {
    var logValue: String {
        switch self {
        case .unknown:
            return "unknown"
        case .composing:
            return "composing"
        case .inactive:
            return "inactive"
        }
    }
}

@MainActor
protocol TranslationChoiceHotKeyRegistering: AnyObject {
    var onChoice: (@MainActor (Int) -> Void)? { get set }

    func setChoiceModifiers(
        _ modifiers: TranslationInsertionModifiers
    )
    func setChoiceKeysEnabled(
        _ enabled: Bool,
        count: Int
    ) -> Bool
}

@MainActor
public final class TranslationChoiceShortcutCoordinator {
    public var onChoice: (@MainActor (TranslationChoiceOffer, Int) -> Void)?

    private let hotKeys: any TranslationChoiceHotKeyRegistering
    private var shortcut: TranslationInsertionShortcut
    private var offer: TranslationChoiceOffer?
    private var choiceKeysAreEnabled = false
    private var isEnabled = true

    public convenience init() {
        self.init(
            shortcut: TranslationInsertionShortcut.defaultTrigger
        )
    }

    public convenience init(
        shortcut: TranslationInsertionShortcut
    ) {
        self.init(
            shortcut: shortcut,
            hotKeys: CarbonTranslationChoiceHotKeys()
        )
    }

    init(
        shortcut: TranslationInsertionShortcut =
            TranslationInsertionShortcut.defaultTrigger,
        hotKeys: any TranslationChoiceHotKeyRegistering
    ) {
        self.shortcut = shortcut
        self.hotKeys = hotKeys
        hotKeys.onChoice = { [weak self] index in
            self?.choose(index)
        }
        hotKeys.setChoiceModifiers(shortcut.modifiers)
    }

    public func updateShortcut(
        _ shortcut: TranslationInsertionShortcut
    ) {
        guard shortcut.isValid else { return }
        let wasEnabled = choiceKeysAreEnabled
        disableChoiceKeys()
        self.shortcut = shortcut
        hotKeys.setChoiceModifiers(shortcut.modifiers)
        if wasEnabled, offer != nil {
            enableChoiceKeys()
        }
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            if offer != nil {
                enableChoiceKeys()
            }
        } else {
            disableChoiceKeys()
        }
    }

    public func update(_ offer: TranslationChoiceOffer?) {
        let offerChanged = offer != self.offer
        if offerChanged {
            disableChoiceKeys()
        }
        self.offer = offer
        if offerChanged {
            if let offer {
                translationChoiceLogger.notice(
                    "choice offer active revision=\(offer.revision, privacy: .public) count=\(offer.choices.count, privacy: .public)"
                )
            } else {
                translationChoiceLogger.notice("choice offer cleared")
            }
        }
        guard
            isEnabled,
            let offer,
            !offer.choices.isEmpty
        else {
            return
        }
        enableChoiceKeys()
    }

    private func enableChoiceKeys() {
        guard !choiceKeysAreEnabled, let offer else { return }
        let choiceCount = min(offer.choices.count, 9)
        guard choiceCount > 0 else { return }
        choiceKeysAreEnabled = hotKeys.setChoiceKeysEnabled(
            true,
            count: choiceCount
        )
        translationChoiceLogger.notice(
            "choice number keys enabled=\(self.choiceKeysAreEnabled, privacy: .public) count=\(choiceCount, privacy: .public)"
        )
    }

    private func disableChoiceKeys() {
        guard choiceKeysAreEnabled else { return }
        choiceKeysAreEnabled = false
        _ = hotKeys.setChoiceKeysEnabled(false, count: 0)
        translationChoiceLogger.notice(
            "choice number keys enabled=false"
        )
    }

    private func choose(_ index: Int) {
        guard
            choiceKeysAreEnabled,
            let offer,
            offer.choices.indices.contains(index)
        else {
            return
        }
        disableChoiceKeys()
        self.offer = nil
        translationChoiceLogger.notice(
            "choice selected index=\(index, privacy: .public)"
        )
        onChoice?(offer, index)
    }
}

private let translationChoiceHotKeySignature: OSType = 0x474C_4E54  // GLNT

@MainActor
private final class CarbonTranslationChoiceHotKeys:
    TranslationChoiceHotKeyRegistering
{
    var onChoice: (@MainActor (Int) -> Void)?

    private var eventHandler: EventHandlerRef?
    private var choiceHotKeyRefs: [EventHotKeyRef?] = []
    private var choiceModifiers =
        TranslationInsertionShortcut.defaultTrigger.modifiers

    init() {
        installEventHandler()
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
        unregisterChoiceHotKeys()
        guard enabled else { return true }
        guard eventHandler != nil else { return false }

        var hotKeyRefs = Array<EventHotKeyRef?>(
            repeating: nil,
            count: max(0, min(count, 9))
        )
        for (index, keyCode) in [
            UInt32(kVK_ANSI_1),
            UInt32(kVK_ANSI_2),
            UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4),
            UInt32(kVK_ANSI_5),
            UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7),
            UInt32(kVK_ANSI_8),
            UInt32(kVK_ANSI_9),
        ].prefix(hotKeyRefs.count).enumerated() {
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                keyCode,
                choiceModifiers.carbonModifiers,
                hotKeyID(UInt32(index + 2)),
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &hotKeyRef
            )
            guard status == noErr, hotKeyRef != nil else {
                unregister(refs: hotKeyRefs)
                if let hotKeyRef {
                    UnregisterEventHotKey(hotKeyRef)
                }
                return false
            }
            hotKeyRefs[index] = hotKeyRef
        }
        choiceHotKeyRefs = hotKeyRefs
        return true
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard
                    parameterStatus == noErr,
                    hotKeyID.signature
                        == translationChoiceHotKeySignature,
                    (2...10).contains(hotKeyID.id)
                else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotKeys = Unmanaged<CarbonTranslationChoiceHotKeys>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    hotKeys.onChoice?(Int(hotKeyID.id) - 2)
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        if status != noErr {
            eventHandler = nil
        }
    }

    private func unregisterChoiceHotKeys() {
        unregister(refs: choiceHotKeyRefs)
        choiceHotKeyRefs.removeAll()
    }

    private func unregister(refs: [EventHotKeyRef?]) {
        for hotKeyRef in refs {
            if let hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
            }
        }
    }

    private func hotKeyID(_ id: UInt32) -> EventHotKeyID {
        var value = EventHotKeyID()
        value.signature = translationChoiceHotKeySignature
        value.id = id
        return value
    }

}

extension TranslationInsertionModifiers {
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        if contains(.command) {
            value |= UInt32(cmdKey)
        }
        if contains(.control) {
            value |= UInt32(controlKey)
        }
        if contains(.option) {
            value |= UInt32(optionKey)
        }
        if contains(.shift) {
            value |= UInt32(shiftKey)
        }
        if contains(.capsLock) {
            value |= UInt32(alphaLock)
        }
        return value
    }
}
