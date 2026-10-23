import Carbon

public enum InputSourceKind: String, Sendable {
    case applePinyin
    case otherInputMethod
    case keyboardLayout
    case unknown
}

public struct ActiveInputSource: Sendable, Equatable {
    public let id: String
    public let kind: InputSourceKind

    public init(
        id: String,
        kind: InputSourceKind
    ) {
        self.id = id
        self.kind = kind
    }
}

public struct InputSourceMonitor: Sendable {
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
        let type =
            Self.stringProperty(
                source,
                kTISPropertyInputSourceType
            ) ?? ""
        return ActiveInputSource(
            id: identifier,
            kind: Self.inputSourceKind(
                identifier: identifier,
                type: type
            )
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
        type: String
    ) -> InputSourceKind {
        if [
            "com.apple.inputmethod.SCIM.ITABC",
            "com.apple.inputmethod.SCIM",
        ].contains(identifier) {
            return .applePinyin
        }
        if [
            kTISTypeKeyboardInputMode as String,
            kTISTypeKeyboardInputMethodWithoutModes as String,
            kTISTypeKeyboardInputMethodModeEnabled as String,
        ].contains(type) {
            return .otherInputMethod
        }
        if type == kTISTypeKeyboardLayout as String {
            return .keyboardLayout
        }
        return identifier.localizedCaseInsensitiveContains("inputmethod")
            ? .otherInputMethod
            : .unknown
    }
}
