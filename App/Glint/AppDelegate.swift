import AppKit
import CoreGraphics
import GlintMac
import GlintUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let initialPermissionRequestKey =
        "glint.permissions.initialRequestAttempted"

    private let readinessToken: String?
    private var statusItem: NSStatusItem!
    private var monitoringMenuItem: NSMenuItem!
    private var mainWindowController: MainWindowController!
    private let hud = HUDController()
    private let environment: AppEnvironment
    private let windowModel: MainWindowModel
    private var monitoringTask: Task<Void, Never>?
    private var pendingHUDTask: Task<Void, Never>?
    private var pendingCandidateText: String?
    private var hudGeneration = 0
    private var pendingPermissionStep: PermissionRequestStep?
    private var permissionRequestWasIssued = false
    private var screenCaptureWasRequested = false
    private var startupPreparationTask: Task<Void, Never>?
    private var shouldStartMonitoringAfterPreparation = false

    private enum PermissionRequestStep {
        case screenRecording
        case accessibility
    }

    override init() {
        let environment = AppEnvironment()
        self.environment = environment
        self.windowModel = MainWindowModel(
            pluginManager: environment.pluginManager,
            openAICompatibleStore: environment.openAICompatibleStore
        )
        self.readinessToken = Self.readinessToken(
            from: CommandLine.arguments
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindowModel()
        setupStatusItem()
        mainWindowController = MainWindowController(model: windowModel)
        mainWindowController.show()
        refreshPermissionState()
        startupPreparationTask = Task { [weak self] in
            guard let self else { return }
            _ = await environment.configureOCR(
                preferences: windowModel.ocrRecognitionPreferences
            )
            await environment.translationRuntime.prepareSelectedModel()
            startupPreparationTask = nil
            if shouldStartMonitoringAfterPreparation {
                shouldStartMonitoringAfterPreparation = false
                startMonitoring()
            }
        }
        let permissionsGranted =
            CGPreflightScreenCaptureAccess()
            && FocusMonitor.isAccessibilityTrusted()
        let alreadyRequested = UserDefaults.standard.bool(
            forKey: Self.initialPermissionRequestKey
        )
        if !alreadyRequested {
            UserDefaults.standard.set(
                true,
                forKey: Self.initialPermissionRequestKey
            )
        }
        if permissionsGranted {
            startMonitoring()
        } else if !alreadyRequested {
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.beginPermissionRequest()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
        if pendingPermissionStep != nil {
            continuePermissionRequest()
        }
        Task {
            await windowModel.refreshPlugins()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(isMonitoring: false)

        let menu = NSMenu()
        menu.addItem(item("显示主界面", action: #selector(openMainWindow)))
        monitoringMenuItem = item("开启翻译显示", action: #selector(toggleMonitoring))
        menu.addItem(monitoringMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("退出", action: #selector(quit)))
        statusItem.menu = menu
    }

    private func updateStatusItem(isMonitoring: Bool) {
        guard let button = statusItem.button else { return }
        button.image = nil
        if isMonitoring {
            let title = NSMutableAttributedString(
                string: "✦",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
            title.append(NSAttributedString(
                string: " ●",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                    .foregroundColor: NSColor(
                        srgbRed: 1,
                        green: 0.90,
                        blue: 0,
                        alpha: 1
                    ),
                    .baselineOffset: 1.2,
                ]
            ))
            button.title = ""
            button.attributedTitle = title
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = "✦"
        }
        button.toolTip = isMonitoring ? "Glint · 翻译显示已开启" : "Glint · 翻译显示已关闭"
        button.setAccessibilityLabel(
            isMonitoring ? "Glint，翻译显示已开启" : "Glint，翻译显示已关闭"
        )
    }

    private func updateMonitoringMenuItem() {
        monitoringMenuItem?.title = monitoringTask == nil ? "开启翻译显示" : "关闭翻译显示"
    }

    private func configureWindowModel() {
        windowModel.startMonitoringAction = { [weak self] in
            self?.startMonitoring()
        }
        windowModel.stopMonitoringAction = { [weak self] in
            self?.stopMonitoring()
        }
        windowModel.refreshPermissionsAction = { [weak self] in
            self?.refreshPermissionState()
        }
        windowModel.requestPermissionsAction = { [weak self] in
            self?.beginPermissionRequest()
        }
        windowModel.activateTranslationModelAction = { [weak self] in
            guard let self else { return "翻译运行时不可用" }
            await self.environment.translationRuntime.prepareSelectedModel()
            return await self.environment.translationRuntime.lastError
        }
        windowModel.configureOCRRecognitionAction = {
            [weak self] preferences in
            guard let self else { return "文字识别服务不可用" }
            return await self.environment.configureOCR(
                preferences: preferences
            )
        }
        windowModel.testOpenAICompatibleAction = { [weak self] configuration in
            guard let self else { return }
            try await self.environment.validateOpenAICompatibleConfiguration(
                configuration
            )
        }
        windowModel.translationModeAction = { [weak self] mode in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setMode(mode)
            }
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    private func showMainWindow() {
        NSApp.unhide(nil)
        mainWindowController.show()
    }

    @objc private func toggleMonitoring() {
        if monitoringTask == nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    @objc private func startMonitoring() {
        guard monitoringTask == nil else { return }
        guard startupPreparationTask == nil else {
            shouldStartMonitoringAfterPreparation = true
            return
        }
        refreshPermissionState()
        guard windowModel.screenRecordingGranted,
              windowModel.accessibilityGranted else {
            beginPermissionRequest()
            return
        }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.environment.monitoring.events
            for await event in events {
                await MainActor.run {
                    self.handle(event)
                }
            }
        }
        let mode = windowModel.translationMode
        Task { [weak self] in
            guard let self else { return }
            await environment.monitoring.setMode(mode)
            await environment.monitoring.start()
            markRuntimeReady()
        }
        windowModel.isMonitoring = true
        windowModel.statusText = ""
        updateStatusItem(isMonitoring: true)
        updateMonitoringMenuItem()
    }

    @objc private func stopMonitoring() {
        shouldStartMonitoringAfterPreparation = false
        monitoringTask?.cancel()
        monitoringTask = nil
        cancelPendingHUD()
        hud.hide()
        updateStatusItem(isMonitoring: false)
        windowModel.isMonitoring = false
        windowModel.statusText = ""
        updateMonitoringMenuItem()
        Task {
            await environment.monitoring.stop()
        }
    }

    private func handle(_ event: MonitoringEvent) {
        switch event {
        case .status(let status):
            windowModel.statusText = isActionableStatus(status) ? status : ""
            NSLog("Glint: %@", status)
        case .result(let candidate, let result, let highlight):
            windowModel.statusText = ""
            scheduleHUD(
                candidate: candidate.text,
                text: result.displayText,
                near: highlight.cgRect
            )
        case .hidden:
            cancelPendingHUD()
            hud.hide()
        }
    }

    private func isActionableStatus(_ status: String) -> Bool {
        status == "需要屏幕录制权限"
            || status == "需要辅助功能权限"
            || status.hasPrefix("截取失败：")
    }

    private func scheduleHUD(candidate: String, text: String, near rect: CGRect) {
        guard pendingCandidateText != candidate else { return }
        pendingCandidateText = candidate
        pendingHUDTask?.cancel()
        hudGeneration += 1
        let generation = hudGeneration
        hud.hide()

        let delay = windowModel.displayPreferences.stabilityDelay
        pendingHUDTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            } catch {
                return
            }
            guard let self,
                  self.monitoringTask != nil,
                  self.hudGeneration == generation,
                  self.pendingCandidateText == candidate else {
                return
            }
            self.hud.show(
                text: text,
                near: rect,
                position: self.windowModel.displayPreferences.position,
                spacing: self.windowModel.displayPreferences.candidateSpacing,
                opacity: self.windowModel.displayPreferences.hudOpacity
            )
            self.pendingHUDTask = nil
        }
    }

    private func cancelPendingHUD() {
        pendingHUDTask?.cancel()
        pendingHUDTask = nil
        pendingCandidateText = nil
        hudGeneration += 1
    }

    private func refreshPermissionState() {
        windowModel.screenRecordingGranted = CGPreflightScreenCaptureAccess()
        windowModel.accessibilityGranted = FocusMonitor.isAccessibilityTrusted()
    }

    private func markRuntimeReady() {
        guard let readinessToken else { return }
        let url = Self.runtimeReadyURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try readinessToken.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("Glint: failed to write runtime readiness: %@", String(describing: error))
        }
    }

    private static func readinessToken(
        from arguments: [String]
    ) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--readiness-token"),
              arguments.indices.contains(flagIndex + 1) else {
            return nil
        }
        let token = arguments[flagIndex + 1]
        return token.isEmpty ? nil : token
    }

    private static var runtimeReadyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Glint")
            .appendingPathComponent("runtime-ready")
    }

    private func beginPermissionRequest() {
        refreshPermissionState()
        if windowModel.screenRecordingGranted,
           windowModel.accessibilityGranted {
            pendingPermissionStep = nil
            permissionRequestWasIssued = false
            startMonitoring()
            return
        }

        pendingPermissionStep = windowModel.screenRecordingGranted
            ? .accessibility
            : .screenRecording
        permissionRequestWasIssued = false
        screenCaptureWasRequested = false
        continuePermissionRequest()
    }

    private func continuePermissionRequest() {
        refreshPermissionState()
        guard let step = pendingPermissionStep else { return }

        switch step {
        case .screenRecording:
            if windowModel.screenRecordingGranted {
                pendingPermissionStep = .accessibility
                permissionRequestWasIssued = false
                continuePermissionRequest()
                return
            }
            guard !permissionRequestWasIssued else {
                windowModel.statusText = "请在“系统设置 › 隐私与安全性 › 录屏与系统录音”中开启 Glint。"
                return
            }
            permissionRequestWasIssued = true
            screenCaptureWasRequested = true
            windowModel.statusText = "请在系统提示中允许 Glint 录制屏幕。"
            _ = CGRequestScreenCaptureAccess()
            refreshPermissionState()
            if windowModel.screenRecordingGranted {
                pendingPermissionStep = .accessibility
                permissionRequestWasIssued = false
                continuePermissionRequest()
            }
        case .accessibility:
            if windowModel.accessibilityGranted {
                pendingPermissionStep = nil
                permissionRequestWasIssued = false
                if screenCaptureWasRequested {
                    windowModel.statusText = "屏幕录制已授权，请重新启动 Glint。"
                } else {
                    windowModel.statusText = ""
                    startMonitoring()
                }
                return
            }
            guard !permissionRequestWasIssued else {
                windowModel.statusText = "请在“系统设置 › 隐私与安全性 › 辅助功能”中开启 Glint。"
                return
            }
            permissionRequestWasIssued = true
            windowModel.statusText = "请在系统提示中允许 Glint 使用辅助功能。"
            FocusMonitor.requestAccessibility()
            refreshPermissionState()
            if windowModel.accessibilityGranted {
                continuePermissionRequest()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
