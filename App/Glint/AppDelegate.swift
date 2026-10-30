import AppKit
import GlintMac
import GlintPlugins
import GlintUI
import OSLog

private let appLogger = Logger(
    subsystem: "com.local.glint",
    category: "App"
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let initialPermissionRequestKey =
        "glint.permissions.accessibilityInitialRequestAttempted"

    private let readinessToken: String?
    private var statusItem: NSStatusItem!
    private var monitoringMenuItem: NSMenuItem!
    private var mainWindowController: MainWindowController!
    private let hudEventCoordinator: HUDEventCoordinator
    private let translationChoiceShortcutCoordinator: TranslationChoiceShortcutCoordinator
    private let environment: AppEnvironment
    private let launchAtLoginController: LaunchAtLoginController
    private let windowModel: MainWindowModel
    private var eventPumpTask: Task<Void, Never>?
    private var sessionState: MonitoringSessionState = .idle
    private var permissionRequestPending = false
    private var permissionRequestWasIssued = false
    private var selectedInputSourceObserver: NSObjectProtocol?
    private var startupPreparationTask: Task<Void, Never>?
    private var shouldStartMonitoringAfterPreparation = false
    private var shouldRequestPermissionAfterPreparation = false
    private var wasLaunchedAtLogin = false

    override init() {
        let environment = AppEnvironment()
        let windowModel = MainWindowModel(
            pluginManager: environment.pluginManager,
            builtInPlugins: BundledPluginResources.manifests
        )
        self.environment = environment
        self.launchAtLoginController = LaunchAtLoginController()
        self.windowModel = windowModel
        self.hudEventCoordinator = HUDEventCoordinator(
            hud: HUDController(),
            model: windowModel
        )
        self.translationChoiceShortcutCoordinator =
            TranslationChoiceShortcutCoordinator(
                shortcut: windowModel.generalPreferences
                    .insertionShortcut
            )
        self.readinessToken = Self.readinessToken(
            from: CommandLine.arguments
        )
        super.init()
        translationChoiceShortcutCoordinator.setEnabled(
            windowModel.generalPreferences.insertionEnabled
        )
        translationChoiceShortcutCoordinator.onChoice = {
            [weak self] offer, choiceIndex in
            guard let self else { return false }
            return await self.environment.monitoringSession
                .insertTranslation(
                    offer,
                    choiceIndex: choiceIndex
                )
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wasLaunchedAtLogin = LoginLaunchDetector.wasLaunchedAtLogin()
        configureWindowModel()
        observeInputSourceChanges()
        refreshActiveInputMethodName()
        setupMainMenu()
        setupStatusItem()
        mainWindowController = MainWindowController(model: windowModel)
        if !wasLaunchedAtLogin {
            mainWindowController.show()
        }
        windowModel.isPreparingMonitoring = true
        updateMonitoringMenuItem()
        updateStatusItem(isMonitoring: false)
        startEventPump()
        refreshPermissionState()
        startupPreparationTask = Task { [weak self] in
            guard let self else { return }
            await environment.refreshDictionaryRoutes()
            #if DEBUG
                await synchronizeInstalledInputMethodSupport()
            #endif
            await environment.translationRuntime.prepareSelectedModel()
            startupPreparationTask = nil
            windowModel.isPreparingMonitoring = false
            if shouldStartMonitoringAfterPreparation {
                shouldStartMonitoringAfterPreparation = false
                let shouldRequestPermission =
                    shouldRequestPermissionAfterPreparation
                shouldRequestPermissionAfterPreparation = false
                startMonitoring(
                    requestPermissionIfNeeded: shouldRequestPermission
                )
            } else {
                updateStatusItem(isMonitoring: windowModel.isMonitoring)
                updateMonitoringMenuItem()
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
        refreshActiveInputMethodName()
        refreshLaunchAtLoginState()
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
        if let selectedInputSourceObserver {
            DistributedNotificationCenter.default()
                .removeObserver(selectedInputSourceObserver)
        }
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

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Glint")
        let hideItem = NSMenuItem(
            title: "隐藏 Glint",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "退出 Glint",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem(
            title: "Glint",
            action: nil,
            keyEquivalent: ""
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenu = NSMenu(title: "窗口")
        let closeItem = NSMenuItem(
            title: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(closeItem)

        let windowMenuItem = NSMenuItem(
            title: "窗口",
            action: nil,
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func updateStatusItem(isMonitoring: Bool) {
        guard let button = statusItem.button else { return }
        button.image = brandMarkImage(isMonitoring: isMonitoring)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip =
            windowModel.isPreparingMonitoring
            ? "Glint · 正在准备翻译模型"
            : (isMonitoring ? "Glint · 翻译显示已开启" : "Glint · 翻译显示已关闭")
        button.setAccessibilityLabel(
            isMonitoring ? "Glint，翻译显示已开启" : "Glint，翻译显示已关闭"
        )
    }

    private func brandMarkImage(isMonitoring: Bool) -> NSImage? {
        let resourceName = isMonitoring ? "BrandMark" : "BrandMarkOff"
        guard let image = NSImage(named: resourceName)?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    private func updateMonitoringMenuItem() {
        guard let monitoringMenuItem else { return }
        if windowModel.isPreparingMonitoring {
            monitoringMenuItem.title = "正在准备翻译模型…"
            monitoringMenuItem.isEnabled = false
            return
        }
        switch sessionState {
        case .idle:
            monitoringMenuItem.title = "开启翻译显示"
            monitoringMenuItem.isEnabled = true
        case .starting:
            monitoringMenuItem.title = "正在开启…"
            monitoringMenuItem.isEnabled = false
        case .running:
            monitoringMenuItem.title = "关闭翻译显示"
            monitoringMenuItem.isEnabled = true
        case .stopping:
            monitoringMenuItem.title = "正在关闭…"
            monitoringMenuItem.isEnabled = false
        }
    }

    private func configureWindowModel() {
        windowModel.startMonitoringAction = { [weak self] in
            self?.startMonitoring()
        }
        windowModel.stopMonitoringAction = { [weak self] in
            self?.stopMonitoring()
        }
        #if DEBUG
            windowModel.refreshInputMethodSupportAction = {
                [weak self] in
                guard
                    let service =
                        self?.environment.squirrelIntegrationService
                else {
                    return Self.inputMethodSupportStatuses(nil)
                }
                return Self.inputMethodSupportStatuses(
                    await service.status()
                )
            }
            windowModel.installSquirrelSupportAction = {
                [weak self] in
                guard
                    let service =
                        self?.environment.squirrelIntegrationService
                else {
                    throw SquirrelIntegrationError.squirrelUnavailable
                }
                return Self.inputMethodSupportStatuses(
                    try await service.install()
                )
            }
            windowModel.uninstallSquirrelSupportAction = {
                [weak self] in
                guard
                    let service =
                        self?.environment.squirrelIntegrationService
                else {
                    throw SquirrelIntegrationError.squirrelUnavailable
                }
                return Self.inputMethodSupportStatuses(
                    try await service.uninstall()
                )
            }
        #endif
        windowModel.refreshPermissionsAction = { [weak self] in
            self?.refreshPermissionState()
        }
        windowModel.requestPermissionsAction = { [weak self] in
            self?.beginPermissionRequest()
        }
        windowModel.refreshLaunchAtLoginAction = { [weak self] in
            self?.refreshLaunchAtLoginState()
        }
        windowModel.setLaunchAtLoginAction = { [weak self] enabled in
            self?.setLaunchAtLoginEnabled(enabled)
        }
        windowModel.openLoginItemsSettingsAction = { [weak self] in
            self?.launchAtLoginController.openSystemSettings()
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
        windowModel.translationModeAction = { [weak self] mode in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setMode(mode)
            }
        }
        windowModel.checkCoreDictionaryUpdateAction = {
            [weak self] updateKind in
            guard let self else {
                throw CoreDictionaryUpdateError.unavailable
            }
            return try await self.environment.checkCoreDictionaryUpdate(
                kind: updateKind
            )
        }
        windowModel.checkTranslationModelUpdateAction = {
            [weak self] manifest in
            guard let self else {
                throw ModelHubError.unavailable
            }
            return try await self.environment.checkTranslationModelUpdate(
                manifest
            )
        }
        windowModel.searchModelMarketAction = { [weak self] query in
            guard let self else {
                throw ModelHubError.unavailable
            }
            return try await self.environment.searchModelMarket(
                query: query
            )
        }
        windowModel.prepareModelMarketInstallAction = {
            [weak self] model, knownManifest in
            guard let self else {
                throw ModelHubError.unavailable
            }
            return try await self.environment.prepareModelMarketInstall(
                model,
                matching: knownManifest
            )
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
        windowModel.displayPreferences.maximumTranslationCountDidChange = {
            [weak self] count in
            guard let self else { return }
            Task {
                await self.environment.monitoring
                    .setMaximumTranslationCount(count)
            }
        }
        windowModel.generalPreferences.insertionShortcutDidChange = {
            [weak self] shortcut in
            self?.translationChoiceShortcutCoordinator.updateShortcut(
                shortcut
            )
        }
        windowModel.generalPreferences.insertionEnabledDidChange = {
            [weak self] enabled in
            self?.translationChoiceShortcutCoordinator.setEnabled(enabled)
        }
        windowModel.translationConfigurationChangedAction = { [weak self] in
            self?.syncTranslationConfiguration()
        }
        windowModel.dictionaryConfigurationChangedAction = { [weak self] in
            await self?.environment.refreshDictionaryRoutes()
        }
        refreshLaunchAtLoginState()
    }

    #if DEBUG
        private func synchronizeInstalledInputMethodSupport() async {
            guard
                let service =
                    environment.squirrelIntegrationService
            else {
                return
            }
            do {
                _ =
                    try await service
                    .synchronizeInstalledSupportIfNeeded()
                await windowModel.refreshInputMethodSupport()
            } catch {
                appLogger.error(
                    "failed to synchronize Rime candidate support: \(String(describing: error), privacy: .public)"
                )
                await windowModel.refreshInputMethodSupport()
            }
        }

        private static func inputMethodSupportStatuses(
            _ status: SquirrelIntegrationStatus?
        ) -> [InputMethodSupportStatus] {
            guard let status else {
                return [
                    .applePinyin,
                    InputMethodSupportStatus(
                        id: "squirrel",
                        name: "Rime",
                        detail: "未检测到可用的输入法。",
                        state: .unavailable,
                        schemaIDs: [],
                        protocolVersion: nil,
                        isExperimental: true
                    ),
                ]
            }
            let uiState: InputMethodSupportState
            switch status.state {
            case .unavailable:
                uiState = .unavailable
            case .available:
                uiState = .available
            case .installed:
                uiState = .installed
            case .repairRequired:
                uiState = .repairRequired
            case .manualSetupRequired:
                uiState = .manualSetupRequired
            }
            return [
                .applePinyin,
                InputMethodSupportStatus(
                    id: "squirrel",
                    name: "Rime",
                    detail: status.detail ?? defaultDetail(for: uiState),
                    state: uiState,
                    schemaIDs: status.schemaIDs,
                    protocolVersion: status.protocolVersion,
                    isExperimental: true
                ),
            ]
        }

        private static func defaultDetail(
            for state: InputMethodSupportState
        ) -> String {
            switch state {
            case .native:
                "原生读取当前候选。"
            case .available:
                "候选读取支持未安装。"
            case .installed:
                "候选读取支持已安装。"
            case .repairRequired:
                "候选读取支持需要重新安装。"
            case .manualSetupRequired:
                "当前配置无法自动合并，请按手动说明操作。"
            case .unavailable:
                "未检测到可用的输入法。"
            }
        }
    #endif

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        showMainWindow()
    }

    private func showMainWindow() {
        refreshActiveInputMethodName()
        NSApp.unhide(nil)
        mainWindowController.show()
    }

    @objc private func toggleMonitoring() {
        if windowModel.isPreparingMonitoring { return }
        switch sessionState {
        case .idle:
            startMonitoring()
        case .running:
            stopMonitoring()
        case .starting, .stopping:
            break
        }
    }

    @objc private func startMonitoring() {
        startMonitoring(requestPermissionIfNeeded: true)
    }

    private func startMonitoring(
        requestPermissionIfNeeded: Bool
    ) {
        if startupPreparationTask != nil || windowModel.isPreparingMonitoring {
            shouldStartMonitoringAfterPreparation = true
            shouldRequestPermissionAfterPreparation =
                shouldRequestPermissionAfterPreparation
                || requestPermissionIfNeeded
            updateMonitoringMenuItem()
            return
        }
        guard sessionState == .idle else { return }
        refreshPermissionState()
        if !windowModel.accessibilityGranted,
            requestPermissionIfNeeded
        {
            beginPermissionRequest()
        }
        let settings = monitoringSettings
        let session = environment.monitoringSession
        Task.detached(priority: .userInitiated) {
            await session.start(settings)
        }
    }

    @objc private func stopMonitoring() {
        shouldStartMonitoringAfterPreparation = false
        shouldRequestPermissionAfterPreparation = false
        translationChoiceShortcutCoordinator.update(nil)
        hudEventCoordinator.hide(animated: false)
        windowModel.isMonitoring = false
        windowModel.statusText = ""
        updateStatusItem(isMonitoring: false)
        updateMonitoringMenuItem()
        let session = environment.monitoringSession
        Task.detached(priority: .userInitiated) {
            await session.stop()
        }
    }

    private var monitoringSettings: MonitoringSettings {
        MonitoringSettings(
            mode: windowModel.translationMode,
            candidateDwellDuration: windowModel.displayPreferences
                .candidateDwellDuration,
            translationScope: windowModel.displayPreferences.translationScope,
            maximumTranslationCount: windowModel.displayPreferences
                .maximumTranslationCount,
            configurationToken: translationConfigurationToken
        )
    }

    private func startEventPump() {
        guard eventPumpTask == nil else { return }
        eventPumpTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.environment.monitoringSession.events
            for await event in events {
                self.handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: MonitoringSessionEvent) {
        switch event {
        case .state(let state):
            sessionState = state
            switch state {
            case .running:
                windowModel.isMonitoring = true
                markRuntimeReady()
            case .idle:
                windowModel.isMonitoring = false
                translationChoiceShortcutCoordinator.update(nil)
            case .starting, .stopping:
                break
            }
            updateStatusItem(isMonitoring: windowModel.isMonitoring)
            updateMonitoringMenuItem()
        case .monitoring(let monitoringEvent):
            handle(monitoringEvent)
        }
    }

    private func handle(_ event: MonitoringEvent) {
        switch event {
        case .status(let status):
            windowModel.statusText = isActionableStatus(status) ? status : ""
        case .inputSourceChanged(let identity):
            windowModel.updateActiveInputMethod(identity)
        case .candidateChanged:
            translationChoiceShortcutCoordinator.update(nil)
            hudEventCoordinator.candidateChanged()
        case .selectionChanged(let index, let revision):
            hudEventCoordinator.updateSelection(
                index: index,
                revision: revision
            )
        case .layoutChanged(let highlight, let inputCaretRect):
            hudEventCoordinator.layoutChanged(
                highlight: highlight,
                inputCaretRect: inputCaretRect
            )
        case .candidateEnded(let immediate):
            translationChoiceShortcutCoordinator.update(nil)
            hudEventCoordinator.candidateEnded(immediate: immediate)
        case .results(
            let translations,
            let highlight,
            let inputCaretRect,
            let revision,
            let isProgressive
        ):
            hudEventCoordinator.show(
                translations: translations,
                highlight: highlight,
                inputCaretRect: inputCaretRect,
                revision: revision,
                isProgressive: isProgressive,
                isMonitoring: windowModel.isMonitoring
            )
        case .insertionOffer(let offer):
            translationChoiceShortcutCoordinator.update(offer)
        }
    }

    private func isActionableStatus(_ status: String) -> Bool {
        status == "需要辅助功能权限"
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
        return
            ([
                "model=\(windowModel.activeModelID)",
                "prompt=1",
            ]
            + pluginVersions).joined(separator: "|")
    }

    private func refreshPermissionState() {
        windowModel.accessibilityGranted = FocusMonitor.isAccessibilityTrusted()
    }

    private func refreshLaunchAtLoginState(error: String? = nil) {
        windowModel.updateLaunchAtLogin(
            status: launchAtLoginController.status,
            error: error
        )
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) {
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

    private func observeInputSourceChanges() {
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

    private func refreshActiveInputMethodName() {
        windowModel.updateActiveInputMethod(
            InputSourceMonitor()
                .currentInputSource()
                .identity
        )
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
            appLogger.error(
                "failed to write runtime readiness: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func readinessToken(
        from arguments: [String]
    ) -> String? {
        guard let flagIndex = arguments.firstIndex(of: "--readiness-token"),
            arguments.indices.contains(flagIndex + 1)
        else {
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
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
