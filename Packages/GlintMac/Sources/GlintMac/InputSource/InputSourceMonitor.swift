import Carbon
import Foundation
import GlintCore

public enum InputSourceKind: String, Sendable {
    case applePinyin
    case otherInputMethod
    case keyboardLayout
    case unknown
}

public struct ActiveInputSource: Sendable, Equatable {
    public let identity: InputMethodIdentity
    public let kind: InputSourceKind

    public var id: String {
        identity.inputSourceIdentifier
    }

    public init(
        identity: InputMethodIdentity,
        kind: InputSourceKind
    ) {
        self.identity = identity
        self.kind = kind
    }

    public init(
        id: String,
        kind: InputSourceKind,
        bundleIdentifier: String? = nil,
        sourceType: String = "",
        localizedName: String? = nil
    ) {
        self.init(
            identity: InputMethodIdentity(
                bundleIdentifier: bundleIdentifier,
                inputSourceIdentifier: id,
                sourceType: sourceType,
                localizedName: localizedName
            ),
            kind: kind
        )
    }
}

public struct InputSourceMonitor: Sendable {
    public static let selectedInputSourceDidChangeNotification =
        Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String
        )

    public init() {}

    @MainActor
    public func currentInputSource() -> ActiveInputSource {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
            let identifier = Self.stringProperty(
                source,
                kTISPropertyInputSourceID
            )
        else {
            return ActiveInputSource(
                id: "",
                kind: .unknown
            )
        }
        let sourceType =
            Self.stringProperty(
                source,
                kTISPropertyInputSourceType
            ) ?? ""
        let identity = InputMethodIdentity(
            bundleIdentifier: Self.stringProperty(
                source,
                kTISPropertyBundleID
            ),
            inputSourceIdentifier: identifier,
            sourceType: sourceType,
            localizedName: Self.stringProperty(
                source,
                kTISPropertyLocalizedName
            )
        )
        return ActiveInputSource(
            identity: identity,
            kind: Self.inputSourceKind(identity: identity)
        )
    }

    private static func stringProperty(
        _ source: TISInputSource,
        _ key: CFString
    ) -> String? {
        guard let property = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(property)
            .takeUnretainedValue() as String
    }

    static func inputSourceKind(
        identifier: String,
        type: String,
        bundleIdentifier: String? = nil
    ) -> InputSourceKind {
        inputSourceKind(
            identity: InputMethodIdentity(
                bundleIdentifier: bundleIdentifier,
                inputSourceIdentifier: identifier,
                sourceType: type,
                localizedName: nil
            )
        )
    }

    static func inputSourceKind(
        identity: InputMethodIdentity
    ) -> InputSourceKind {
        if [
            InputMethodIdentifier.applePinyinInputMode,
            InputMethodIdentifier.appleInputMethodBundle,
        ].contains(identity.inputSourceIdentifier) {
            return .applePinyin
        }
        if [
            kTISTypeKeyboardInputMode as String,
            kTISTypeKeyboardInputMethodWithoutModes as String,
            kTISTypeKeyboardInputMethodModeEnabled as String,
        ].contains(identity.sourceType) {
            return .otherInputMethod
        }
        if identity.sourceType == kTISTypeKeyboardLayout as String {
            return .keyboardLayout
        }
        return identity.inputSourceIdentifier
            .localizedCaseInsensitiveContains("inputmethod")
            ? .otherInputMethod
            : .unknown
    }
}
