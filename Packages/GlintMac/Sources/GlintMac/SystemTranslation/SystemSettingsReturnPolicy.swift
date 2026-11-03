public struct SystemSettingsReturnPolicy: Sendable {
    private static let systemSettingsBundleIdentifier =
        "com.apple.systempreferences"

    private var isWaitingForSystemSettingsToClose = false

    public init() {}

    public mutating func settingsOpened() {
        isWaitingForSystemSettingsToClose = true
    }

    public mutating func shouldRestore(
        afterTerminating bundleIdentifier: String?
    ) -> Bool {
        guard
            isWaitingForSystemSettingsToClose,
            bundleIdentifier == Self.systemSettingsBundleIdentifier
        else {
            return false
        }
        isWaitingForSystemSettingsToClose = false
        return true
    }
}
