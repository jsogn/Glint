import Carbon

public struct InputSourceMonitor: Sendable {
    public init() {}

    @MainActor
    public func currentInputSourceID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    @MainActor
    public func isApplePinyinActive() -> Bool {
        ["com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.SCIM"]
            .contains(currentInputSourceID())
    }
}
