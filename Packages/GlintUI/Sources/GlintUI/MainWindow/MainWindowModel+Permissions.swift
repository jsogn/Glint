extension MainWindowModel {
    public func startMonitoring() {
        actions.monitoring.startMonitoring()
    }

    public func stopMonitoring() {
        actions.monitoring.stopMonitoring()
    }

    public func refreshPermissions() {
        actions.permissions.refreshPermissions()
    }

    public func requestPermissions() {
        actions.permissions.requestPermissions()
    }

    public func openAccessibilitySettings() {
        actions.permissions.openAccessibilitySettings()
    }

    public func refreshLaunchAtLogin() {
        actions.permissions.refreshLaunchAtLogin()
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginError = nil
        actions.permissions.setLaunchAtLogin(enabled)
    }

    public func openLoginItemsSettings() {
        actions.permissions.openLoginItemsSettings()
    }

    public func updateLaunchAtLogin(
        status: LaunchAtLoginStatus,
        error: String? = nil
    ) {
        launchAtLoginStatus = status
        launchAtLoginError = error
    }
}
