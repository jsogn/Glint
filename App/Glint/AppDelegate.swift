import AppKit
import GlintMac
import GlintPlugins
import GlintUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let initialPermissionRequestKey =
        "glint.permissions.accessibilityInitialRequestAttempted"

    private let readinessToken: String?
    private var statusItem: NSStatusItem!
    private var monitoringMenuItem: NSMenuItem!
    private var mainWindowController: MainWindowController!
    private let hudEventCoordinator: HUDEventCoordinator
    private let environment: AppEnvironment
    private let windowModel: MainWindowModel
    private var monitoringTask: Task<Void, Never>?
    private var permissionRequestPending = false
    private var permissionRequestWasIssued = false
    private var startupPreparationTask: Task<Void, Never>?
    private var shouldStartMonitoringAfterPreparation = false
    private var shouldRequestPermissionAfterPreparation = false

    override init() {
        let environment = AppEnvironment()
        let windowModel = MainWindowModel(
            pluginManager: environment.pluginManager,
            builtInPlugins: BundledPluginResources.manifests,
            openAICompatibleStore: environment.openAICompatibleStore
        )
        self.environment = environment
        self.windowModel = windowModel
        self.hudEventCoordinator = HUDEventCoordinator(
            hud: HUDController(),
            model: windowModel
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
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            await windowModel.refreshInstalledPlugins()
            await windowModel.checkForCatalogUpdatesAfterLaunch()
        }
        startupPreparationTask = Task { [weak self] in
            guard let self else { return }
            await environment.removeLegacyBundledPluginCopies()
            await environment.refreshDictionaryRoutes()
            await environment.translationRuntime.prepareSelectedModel()
            startupPreparationTask = nil
            if shouldStartMonitoringAfterPreparation {
                shouldStartMonitoringAfterPreparation = false
                let shouldRequestPermission =
                    shouldRequestPermissionAfterPreparation
                shouldRequestPermissionAfterPreparation = false
                startMonitoring(
                    requestPermissionIfNeeded: shouldRequestPermission
                )
            }
        }
        let permissionsGranted = FocusMonitor.isAccessibilityTrusted()
        let alreadyRequested = UserDefaults.standard.bool(
            forKey: Self.initialPermissionRequestKey
        )
        if !alreadyRequested {
            UserDefaults.standard.set(
                true,
                forKey: Self.initialPermissionRequestKey
            )
        }
        windowModel.hasRequestedAccessibilityPermission = alreadyRequested
        if !permissionsGranted, !alreadyRequested {
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.beginPermissionRequest()
            }
        }
        startMonitoring(requestPermissionIfNeeded: false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let wasGranted = windowModel.accessibilityGranted
        refreshPermissionState()
        if !wasGranted, windowModel.accessibilityGranted {
            windowModel.statusText = ""
            if !windowModel.isMonitoring {
                startMonitoring(requestPermissionIfNeeded: false)
            }
        }
        if permissionRequestPending {
            continuePermissionRequest()
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
        button.image = brandMarkImage()
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        if isMonitoring {
            let title = NSMutableAttributedString(
                string: "  ●",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 5.5, weight: .bold),
                    .foregroundColor: NSColor.systemBlue,
                    .baselineOffset: 1.2,
                ]
            )
            button.title = ""
            button.attributedTitle = title
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
        button.toolTip = isMonitoring ? "Glint · 翻译显示已开启" : "Glint · 翻译显示已关闭"
        button.setAccessibilityLabel(
            isMonitoring ? "Glint，翻译显示已开启" : "Glint，翻译显示已关闭"
        )
    }

    private func brandMarkImage() -> NSImage? {
        guard let image = NSImage(named: "BrandMark")?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
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
        windowModel.openAccessibilitySettingsAction = { [weak self] in
            self?.openAccessibilitySettings()
        }
        windowModel.activateTranslationModelAction = { [weak self] modelID in
            guard let self else { return "翻译运行时不可用" }
            return await self.environment.translationRuntime.prepare(
                modelID: modelID
            )
        }
        windowModel.releaseTranslationModelAction = { [weak self] modelID in
            guard let self else { return }
            await self.environment.translationRuntime.releaseResources(
                for: modelID
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
        windowModel.displayPreferences.candidateDwellDurationDidChange = {
            [weak self] duration in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setCandidateDwellDuration(
                    duration
                )
            }
        }
        windowModel.displayPreferences.translationScopeDidChange = {
            [weak self] scope in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setTranslationScope(scope)
            }
        }
        windowModel.translationConfigurationChangedAction = { [weak self] in
            self?.syncTranslationConfiguration()
        }
        windowModel.dictionaryConfigurationChangedAction = { [weak self] in
            await self?.environment.refreshDictionaryRoutes()
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
        startMonitoring(requestPermissionIfNeeded: true)
    }

    private func startMonitoring(
        requestPermissionIfNeeded: Bool
    ) {
        guard monitoringTask == nil else { return }
        guard startupPreparationTask == nil else {
            shouldStartMonitoringAfterPreparation = true
            shouldRequestPermissionAfterPreparation =
                shouldRequestPermissionAfterPreparation
                || requestPermissionIfNeeded
            return
        }
        refreshPermissionState()
        if !windowModel.accessibilityGranted,
           requestPermissionIfNeeded {
            beginPermissionRequest()
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
        let candidateDwellDuration =
            windowModel.displayPreferences.candidateDwellDuration
        let translationScope =
            windowModel.displayPreferences.translationScope
        let configurationToken = translationConfigurationToken
        Task { [weak self] in
            guard let self else { return }
            await environment.monitoring.setMode(mode)
            await environment.monitoring.setCandidateDwellDuration(
                candidateDwellDuration
            )
            await environment.monitoring.setTranslationScope(
                translationScope
            )
            await environment.monitoring.setTranslationConfigurationToken(
                configurationToken
            )
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
        shouldRequestPermissionAfterPreparation = false
        monitoringTask?.cancel()
        monitoringTask = nil
        hudEventCoordinator.hide(animated: false)
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
        case .candidateChanged:
            hudEventCoordinator.candidateChanged()
        case .selectionChanged(let index, let revision):
            hudEventCoordinator.updateSelection(
                index: index,
                revision: revision
            )
        case .candidateEnded(let immediate):
            hudEventCoordinator.candidateEnded(immediate: immediate)
        case .results(
            let translations,
            let highlight,
            let revision,
            let isProgressive
        ):
            hudEventCoordinator.show(
                translations: translations,
                highlight: highlight,
                revision: revision,
                isProgressive: isProgressive,
                isMonitoring: monitoringTask != nil
            )
        }
    }

    private func isActionableStatus(_ status: String) -> Bool {
        status == "需要屏幕录制权限"
            || status == "需要辅助功能权限"
            || status.hasPrefix("截取失败：")
    }

    private func syncTranslationConfiguration() {
        let token = translationConfigurationToken
        Task { [weak self] in
            guard let self else { return }
            await environment.monitoring.setTranslationConfigurationToken(
                token
            )
        }
    }

    private var translationConfigurationToken: String {
        let pluginVersions = windowModel.installedPlugins
            .filter {
                $0.type == .dictionary || $0.type == .translation
            }
            .map {
                "\($0.id)@\($0.version)#\($0.revision ?? $0.sha256)"
            }
            .sorted()
        let providerVersions = windowModel.openAIProviders
            .map {
                "\($0.id)@\($0.baseURL)#\($0.model)"
            }
            .sorted()
        return (
            [
                "model=\(windowModel.activeModelID)",
                "prompt=1",
            ]
                + pluginVersions
                + providerVersions
        ).joined(separator: "|")
    }

    private func refreshPermissionState() {
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

    private func continuePermissionRequest() {
        refreshPermissionState()
        if windowModel.accessibilityGranted {
            permissionRequestPending = false
            permissionRequestWasIssued = false
            windowModel.statusText = ""
            startMonitoring()
            return
        }
        guard !permissionRequestWasIssued else {
            windowModel.statusText = "请在“系统设置 › 隐私与安全性 › 辅助功能”中开启 Glint。"
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

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
