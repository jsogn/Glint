import AppKit
import GlintMac

extension AppDelegate {
    func refreshPermissionState() {
        windowModel.accessibilityGranted =
            FocusMonitor.isAccessibilityTrusted()
    }

    func refreshLaunchAtLoginState(error: String? = nil) {
        windowModel.updateLaunchAtLogin(
            status: launchAtLoginController.status,
            error: error
        )
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        if enabled, launchAtLoginController.status == .requiresApproval {
            launchAtLoginController.openSystemSettings()
            return
        }
        do {
            try launchAtLoginController.setEnabled(enabled)
            refreshLaunchAtLoginState()
        } catch {
            appLogger.error(
                "failed to update login item: \(String(describing: error), privacy: .public)"
            )
            refreshLaunchAtLoginState(
                error: "无法更改登录时启动设置，请稍后重试。"
            )
        }
    }

    func observeInputSourceChanges() {
        guard selectedInputSourceObserver == nil else {
            return
        }
        selectedInputSourceObserver =
            DistributedNotificationCenter.default().addObserver(
                forName:
                    InputSourceMonitor
                    .selectedInputSourceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshActiveInputMethodName()
                }
            }
    }

    func refreshActiveInputMethodName() {
        windowModel.updateActiveInputMethod(
            InputSourceMonitor()
                .currentInputSource()
                .identity
        )
    }

    func beginPermissionRequest() {
        refreshPermissionState()
        if windowModel.accessibilityGranted {
            permissionRequestPending = false
            permissionRequestWasIssued = false
            startMonitoring()
            return
        }
        if windowModel.hasRequestedAccessibilityPermission {
            openAccessibilitySettings()
            windowModel.statusText =
                "请在“系统设置 › 隐私与安全性 › 辅助功能”中开启 Glint。"
            return
        }

        permissionRequestPending = true
        permissionRequestWasIssued = false
        continuePermissionRequest()
    }

    func continuePermissionRequest() {
        refreshPermissionState()
        if windowModel.accessibilityGranted {
            permissionRequestPending = false
            permissionRequestWasIssued = false
            windowModel.statusText = ""
            startMonitoring()
            return
        }
        guard !permissionRequestWasIssued else {
            windowModel.statusText =
                "请在“系统设置 › 隐私与安全性 › 辅助功能”中开启 Glint。"
            return
        }
        permissionRequestWasIssued = true
        windowModel.hasRequestedAccessibilityPermission = true
        windowModel.statusText = "请在系统提示中允许 Glint 使用辅助功能。"
        FocusMonitor.requestAccessibility()
        refreshPermissionState()
        if windowModel.accessibilityGranted {
            continuePermissionRequest()
        }
    }

    func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSystemTranslationSettings() {
        let candidates = [
            URL(
                string:
                    "x-apple.systempreferences:com.apple.Localization?translation"
            ),
            URL(
                string:
                    "x-apple.systempreferences:com.apple.Localization-Settings.extension?translation"
            ),
            URL(
                string:
                    "x-apple.systempreferences:com.apple.Localization-Settings.extension"
            ),
        ].compactMap { $0 }
        guard !candidates.isEmpty else { return }
        appLogger.notice("system settings open requested")
        systemSettingsReturnPolicy.settingsOpened()
        for url in candidates where NSWorkspace.shared.open(url) {
            return
        }
    }

    func observeSystemSettingsTermination() {
        guard systemSettingsTerminationObserver == nil else { return }
        systemSettingsTerminationObserver =
            NSWorkspace.shared.notificationCenter.addObserver(
                forName:
                    NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let application =
                    notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication
                let bundleIdentifier = application?.bundleIdentifier
                appLogger.notice(
                    "application terminated bundle=\(bundleIdentifier ?? "unknown", privacy: .public)"
                )
                Task { @MainActor [weak self] in
                    guard let self,
                        self.systemSettingsReturnPolicy.shouldRestore(
                            afterTerminating: bundleIdentifier
                        )
                    else {
                        return
                    }
                    appLogger.notice(
                        "restoring Glint after system settings closed"
                    )
                    self.showMainWindow()
                    self.mainWindowController.window?
                        .orderFrontRegardless()
                    NSRunningApplication.current.activate(
                        options: [.activateAllWindows]
                    )
                }
            }
    }
}
