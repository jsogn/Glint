import AppKit
import CoreGraphics
import GlintMac
import GlintUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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

    override init() {
        let environment = AppEnvironment()
        self.environment = environment
        self.windowModel = MainWindowModel(
            pluginManager: environment.pluginManager,
            openAICompatibleStore: environment.openAICompatibleStore
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureWindowModel()
        setupStatusItem()
        mainWindowController = MainWindowController(model: windowModel)
        mainWindowController.show()
        refreshPermissionState()
        Task {
            _ = await environment.configureOCR(
                engineID: windowModel.activeOCREngineID,
                enhancementMode: windowModel.ocrEnhancementMode
            )
        }
        Task {
            await environment.translationRuntime.prepareSelectedModel()
        }
        if CGPreflightScreenCaptureAccess() && FocusMonitor.isAccessibilityTrusted() {
            startMonitoring()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionState()
        Task {
            await windowModel.refreshPlugins()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem(isMonitoring: false)

        let menu = NSMenu()
        menu.addItem(item("打开 Glint", action: #selector(openMainWindow)))
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
        windowModel.activateTranslationModelAction = { [weak self] in
            guard let self else { return "翻译运行时不可用" }
            await self.environment.translationRuntime.prepareSelectedModel()
            return await self.environment.translationRuntime.lastError
        }
        windowModel.activateOCREngineAction = {
            [weak self] engineID, enhancementMode in
            guard let self else { return "文字识别服务不可用" }
            return await self.environment.configureOCR(
                engineID: engineID,
                enhancementMode: enhancementMode
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
        refreshPermissionState()
        guard windowModel.screenRecordingGranted else {
            let granted = CGRequestScreenCaptureAccess()
            refreshPermissionState()
            guard !granted else {
                startMonitoring()
                return
            }
            windowModel.statusText = "需要屏幕录制权限"
            showPermissionAlert(
                title: "需要屏幕录制权限",
                message: "请允许 Glint 录制屏幕，授权后重新启动 Glint。Glint 只截取输入法候选栏区域。",
                settingsAnchor: "Privacy_ScreenCapture"
            )
            return
        }
        guard windowModel.accessibilityGranted else {
            FocusMonitor.requestAccessibility()
            refreshPermissionState()
            windowModel.statusText = "需要辅助功能权限"
            showPermissionAlert(
                title: "需要辅助功能权限",
                message: "请允许 Glint 使用辅助功能来定位当前输入光标和候选栏。授权后重新启动 Glint。",
                settingsAnchor: "Privacy_Accessibility"
            )
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
        Task {
            await environment.monitoring.setMode(mode)
            await environment.monitoring.start()
        }
        windowModel.isMonitoring = true
        windowModel.statusText = ""
        updateStatusItem(isMonitoring: true)
        updateMonitoringMenuItem()
    }

    @objc private func stopMonitoring() {
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

    private func showPermissionAlert(
        title: String,
        message: String,
        settingsAnchor: String
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(
               string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)"
           ) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
