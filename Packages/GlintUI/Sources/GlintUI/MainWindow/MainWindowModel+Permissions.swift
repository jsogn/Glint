extension MainWindowModel {
    public func startMonitoring() {
        startMonitoringAction()
    }

    public func stopMonitoring() {
        stopMonitoringAction()
    }

    public func refreshPermissions() {
        refreshPermissionsAction()
    }

    public func requestPermissions() {
        requestPermissionsAction()
    }

    public func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }

    public func refreshLaunchAtLogin() {
        refreshLaunchAtLoginAction()
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginError = nil
        setLaunchAtLoginAction(enabled)
    }

    public func openLoginItemsSettings() {
        openLoginItemsSettingsAction()
    }

    public func updateLaunchAtLogin(
        status: LaunchAtLoginStatus,
        error: String? = nil
    ) {
        launchAtLoginStatus = status
        launchAtLoginError = error
    }
}
