import AppKit
import GlintCore
import GlintMac
import GlintPlugins
import GlintUI
import OSLog
import SwiftUI

private let appLogger = Logger(
    subsystem: "com.local.glint",
    category: "App"
)

@MainActor
private final class GlintUpdatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let initialPermissionRequestKey =
        "glint.permissions.accessibilityInitialRequestAttempted"

    private let readinessToken: String?
    private var statusItem: NSStatusItem!
    private var monitoringMenuItem: NSMenuItem!
    private var updateMenuItem: NSMenuItem!
    private var updatePanel: NSPanel?
    private var pendingUpdateURL: URL?
    private var mainWindowController: MainWindowController!
    private let hudEventCoordinator: HUDEventCoordinator
    private let translationChoiceShortcutCoordinator: TranslationChoiceShortcutCoordinator
    private let translationSpeechController: TranslationSpeechController
    private let translationAutoSpeechScheduler: TranslationAutoSpeechScheduler
    private let translationSpeechShortcutCoordinator: TranslationChoiceShortcutCoordinator
    private let environment: AppEnvironment
    private let translationLanguageCoordinator:
        TranslationLanguageCoordinator
    private let launchAtLoginController: LaunchAtLoginController
    private let windowModel: MainWindowModel
    private let appUpdateModel: AppUpdateModel
    private var eventPumpTask: Task<Void, Never>?
    private var automaticAppUpdateCheckTask: Task<Void, Never>?
    private var sessionState: MonitoringSessionState = .idle
    private var permissionRequestPending = false
    private var permissionRequestWasIssued = false
    private var selectedInputSourceObserver: NSObjectProtocol?
    private var startupPreparationTask: Task<Void, Never>?
    private var shouldStartMonitoringAfterPreparation = false
    private var shouldRequestPermissionAfterPreparation = false
    private var wasLaunchedAtLogin = false

    override init() {
        let selectionStore = TranslationSelectionStore()
        selectionStore.migrateIfNeeded()
        let environment = AppEnvironment(
            selectionStore: selectionStore
        )
        let windowModel = MainWindowModel(
            pluginManager: environment.pluginManager,
            builtInPlugins: BundledPluginResources.manifests,
            translationSelectionStore: selectionStore
        )
        self.environment = environment
        self.translationLanguageCoordinator =
            TranslationLanguageCoordinator(
                store: selectionStore,
                languageRuntime:
                    TranslationLanguageRuntimeAdapter(
                        runtime: environment.translationRuntime
                    ),
                system: environment.systemTranslationCoordinator
            )
        self.launchAtLoginController = LaunchAtLoginController()
        self.windowModel = windowModel
        self.appUpdateModel = AppUpdateModel()
        self.hudEventCoordinator = HUDEventCoordinator(
            hud: HUDController(),
            model: windowModel
        )
        self.translationChoiceShortcutCoordinator =
            TranslationChoiceShortcutCoordinator(
                shortcut:
                    windowModel.generalPreferences.insertionShortcut
                    ?? TranslationInsertionShortcut.defaultTrigger
            )
        self.translationSpeechController = TranslationSpeechController()
        self.translationAutoSpeechScheduler =
            TranslationAutoSpeechScheduler()
        self.translationSpeechShortcutCoordinator =
            TranslationChoiceShortcutCoordinator(
                shortcut:
                    windowModel.generalPreferences.speechShortcut
                    ?? GeneralPreferences.defaultSpeechShortcut,
                namespace: .speech
            )
        self.readinessToken = Self.readinessToken(
            from: CommandLine.arguments
        )
        super.init()
        translationLanguageCoordinator.wasMonitoring = { [weak self] in
            self?.windowModel.isMonitoring ?? false
        }
        translationLanguageCoordinator.stopActiveOutput = { [weak self] in
            await self?.stopMonitoringForLanguageSwitch()
        }
        translationLanguageCoordinator.clearTranslationCache = {
            [weak self] in
            guard let self else { return }
            await self.environment.monitoring
                .setTranslationConfigurationToken(
                    "switching=\(UUID().uuidString)"
                )
        }
        translationLanguageCoordinator.resumeMonitoring = { [weak self] in
            guard let self else { return }
            self.windowModel.updateTranslationReadiness(
                .ready(self.windowModel.translationTarget)
            )
            self.startMonitoring(
                requestPermissionIfNeeded: false
            )
        }
        translationAutoSpeechScheduler.onSpeak = { [weak self] text in
            guard
                let self,
                self.windowModel.isMonitoring,
                self.windowModel.generalPreferences.autoSpeechEnabled
            else {
                return
            }
            self.translationSpeechController.speak(
                text,
                target: self.windowModel.translationTarget,
                accent: self.windowModel.generalPreferences.speechAccent,
                rate: self.windowModel.generalPreferences.speechRate,
                source: .automatic
            )
        }
        translationChoiceShortcutCoordinator.setEnabled(
            windowModel.generalPreferences.insertionShortcut != nil
        )
        translationSpeechShortcutCoordinator.setEnabled(
            windowModel.generalPreferences.speechShortcut != nil
        )
        translationChoiceShortcutCoordinator.onChoice = {
            [weak self] offer, choiceIndex in
            guard let self else { return false }
            let inserted = await self.environment.monitoringSession
                .insertTranslation(
                    offer,
                    choiceIndex: choiceIndex
                )
            if inserted {
                self.translationSpeechShortcutCoordinator.update(nil)
            }
            return inserted
        }
        translationSpeechShortcutCoordinator.onChoice = {
            [weak self] offer, choiceIndex in
            guard
                let self,
                offer.choices.indices.contains(choiceIndex)
            else {
                return false
            }
            self.translationAutoSpeechScheduler.manualSpeechStarted()
            self.translationSpeechController.speak(
                offer.choices[choiceIndex],
                target: self.windowModel.translationTarget,
                accent: self.windowModel.generalPreferences.speechAccent,
                rate: self.windowModel.generalPreferences.speechRate,
                source: .manual
            )
            return false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wasLaunchedAtLogin = LoginLaunchDetector.wasLaunchedAtLogin()
        configureWindowModel()
        observeInputSourceChanges()
        refreshActiveInputMethodName()
        setupMainMenu()
        setupStatusItem()
        mainWindowController = MainWindowController(
            model: windowModel,
            auxiliaryContent: AnyView(
                SystemTranslationHostView(
                    coordinator:
                        environment.systemTranslationCoordinator
                )
            ),
            appUpdateModel: appUpdateModel,
            onCheckForUpdates: { [weak self] in
                self?.performUpdateCheck()
            }
        )
        if !wasLaunchedAtLogin {
            mainWindowController.show()
        }
        windowModel.isPreparingMonitoring = true
        updateMonitoringMenuItem()
        updateStatusItem(isMonitoring: false)
        startEventPump()
        refreshPermissionState()
        scheduleAutomaticAppUpdateCheck()
        startupPreparationTask = Task { [weak self] in
            guard let self else { return }
            await environment.repairInvalidCoreDictionaryInstallations()
            await environment.refreshDictionaryRoutes()
            await synchronizeInstalledInputMethodSupport()
            let direction = TranslationDirection(
                target: windowModel.translationTarget
            )
            await environment.systemTranslationCoordinator
                .refreshAvailability(for: direction)
            if let availability =
                environment.systemTranslationCoordinator.availability
            {
                windowModel.updateSystemTranslationAvailability(
                    availability
                )
            }
            let readiness: TranslationReadiness
            if windowModel.isActiveSystemTranslationModel {
                if await environment.systemTranslationCoordinator
                    .prepareInstalledSessionIfAvailable(for: direction)
                {
                    readiness = .ready(windowModel.translationTarget)
                } else if environment.systemTranslationCoordinator
                    .availability == .unsupported
                {
                    readiness = .unsupported(
                        windowModel.translationTarget
                    )
                } else {
                    readiness = .needsSetup(
                        windowModel.translationTarget,
                        "需要安装 Apple 翻译语言包"
                    )
                }
            } else if let error =
                await environment.translationRuntime.prepare(
                    modelID: windowModel.activeModelID,
                    direction: direction
                )
            {
                readiness = .failed(
                    windowModel.translationTarget,
                    error
                )
            } else {
                readiness = .ready(windowModel.translationTarget)
            }
            windowModel.updateTranslationReadiness(readiness)
            startupPreparationTask = nil
            windowModel.isPreparingMonitoring = false
            if shouldStartMonitoringAfterPreparation,
                readiness == .ready(windowModel.translationTarget)
            {
                shouldStartMonitoringAfterPreparation = false
                let shouldRequestPermission =
                    shouldRequestPermissionAfterPreparation
                shouldRequestPermissionAfterPreparation = false
                startMonitoring(
                    requestPermissionIfNeeded: shouldRequestPermission
                )
            } else {
                shouldStartMonitoringAfterPreparation = false
                shouldRequestPermissionAfterPreparation = false
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
        automaticAppUpdateCheckTask?.cancel()
        environment.systemTranslationCoordinator.shutdown()
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
        menu.autoenablesItems = false
        menu.addItem(item("显示主界面", action: #selector(openMainWindow)))
        monitoringMenuItem = item("开启翻译显示", action: #selector(toggleMonitoring))
        menu.addItem(monitoringMenuItem)
        menu.addItem(NSMenuItem.separator())
        updateMenuItem = item("检查更新…", action: #selector(checkForUpdates))
        menu.addItem(updateMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("退出", action: #selector(quit)))
        menu.delegate = self
        statusItem.menu = menu
        updateAppUpdateMenuItem()
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
        windowModel.generalPreferences.shortcutAvailabilityCheck = {
            shortcut in
            TranslationChoiceHotKeyProbe.canRegister(
                modifiers: shortcut.modifiers
            )
        }
        environment.systemTranslationCoordinator.onAvailabilityChange = {
            [weak windowModel] availability in
            windowModel?.updateSystemTranslationAvailability(availability)
        }
        windowModel.startMonitoringAction = { [weak self] in
            self?.startMonitoring()
        }
        windowModel.stopMonitoringAction = { [weak self] in
            self?.stopMonitoring()
        }
        windowModel.refreshInputMethodSupportAction = {
            [weak self] in
            guard let self else {
                return Self.inputMethodSupportStatuses(nil)
            }
            return Self.inputMethodSupportStatuses(
                await environment.squirrelIntegrationService.status()
            )
        }
        windowModel.installSquirrelSupportAction = {
            [weak self] in
            guard let self else {
                throw SquirrelIntegrationError.squirrelUnavailable
            }
            return Self.inputMethodSupportStatuses(
                try await environment.squirrelIntegrationService.install()
            )
        }
        windowModel.uninstallSquirrelSupportAction = {
            [weak self] in
            guard let self else {
                throw SquirrelIntegrationError.squirrelUnavailable
            }
            return Self.inputMethodSupportStatuses(
                try await environment.squirrelIntegrationService.uninstall()
            )
        }
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
                modelID: modelID,
                direction: TranslationDirection(
                    target: self.windowModel.translationTarget
                )
            )
        }
        windowModel.refreshSystemTranslationAction = { [weak self] in
            guard let self else { return .unsupported }
            let direction = TranslationDirection(
                target: self.windowModel.translationTarget
            )
            await self.environment.systemTranslationCoordinator
                .refreshAvailability(for: direction)
            return self.environment.systemTranslationCoordinator
                .availability ?? .unsupported
        }
        windowModel.prepareSystemTranslationAction = { [weak self] in
            guard let self else {
                throw SystemTranslationError.sessionUnavailable
            }
            let direction = TranslationDirection(
                target: self.windowModel.translationTarget
            )
            try await self.environment.systemTranslationCoordinator
                .prepareLanguagePack(for: direction)
            let readiness =
                await self.translationLanguageCoordinator
                .retryCurrentConfiguration()
            self.windowModel.updateTranslationReadiness(readiness)
            return self.environment.systemTranslationCoordinator
                .availability ?? .failed("系统翻译状态未知")
        }
        windowModel.activateSystemTranslationAction = { [weak self] in
            guard let self else {
                return "系统翻译会话不可用"
            }
            let direction = TranslationDirection(
                target: self.windowModel.translationTarget
            )
            guard
                await self.environment.systemTranslationCoordinator
                    .prepareInstalledSessionIfAvailable(for: direction)
            else {
                if case .failed(let message) =
                    self.environment.systemTranslationCoordinator
                    .availability
                {
                    return message
                }
                return "系统翻译会话不可用，请稍后重试"
            }
            return await self.environment.translationRuntime.prepare(
                modelID: SystemTranslationModel.appleTranslationID,
                direction: direction
            )
        }
        windowModel.changeTranslationTargetAction = { [weak self] target in
            guard let self else {
                return .failed(target, "翻译运行时不可用")
            }
            return await self.translationLanguageCoordinator
                .switchTarget(to: target)
        }
        windowModel.selectTranslationModelAction = {
            [weak self] modelID, target in
            guard let self else {
                return .failed(target, "翻译运行时不可用")
            }
            return await self.translationLanguageCoordinator
                .selectModel(modelID, for: target)
        }
        windowModel.systemTranslationPresentationAction = {
            [weak self] in
            self?.showMainWindow()
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
        windowModel.displayPreferences.showsPartsOfSpeechDidChange = {
            [weak self] enabled in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setShowsPartsOfSpeech(
                    enabled
                )
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
            guard let self else { return }
            if let shortcut {
                self.translationChoiceShortcutCoordinator.updateShortcut(
                    shortcut
                )
                self.translationChoiceShortcutCoordinator.setEnabled(true)
            } else {
                self.translationChoiceShortcutCoordinator.setEnabled(false)
            }
        }
        windowModel.generalPreferences.speechShortcutDidChange = {
            [weak self] shortcut in
            guard let self else { return }
            if let shortcut {
                self.translationSpeechShortcutCoordinator.updateShortcut(
                    shortcut
                )
                self.translationSpeechShortcutCoordinator.setEnabled(true)
            } else {
                self.translationSpeechShortcutCoordinator.setEnabled(false)
                self.translationSpeechController.stopManual()
            }
        }
        windowModel.generalPreferences.speechAccentDidChange = {
            [weak self] _ in
            self?.translationSpeechController.stop()
        }
        windowModel.generalPreferences.speechRateDidChange = {
            [weak self] _ in
            self?.translationSpeechController.stop()
        }
        windowModel.generalPreferences.autoSpeechEnabledDidChange = {
            [weak self] enabled in
            guard let self, !enabled else { return }
            self.translationAutoSpeechScheduler.cancel()
            self.translationSpeechController.stopAutomatic()
        }
        windowModel.generalPreferences.autoSpeechDelayDidChange = {
            [weak self] delay in
            self?.translationAutoSpeechScheduler.setDelay(delay)
        }
        windowModel.translationConfigurationChangedAction = { [weak self] in
            self?.syncTranslationConfiguration()
        }
        windowModel.dictionaryConfigurationChangedAction = { [weak self] in
            await self?.environment.refreshDictionaryRoutes()
        }
        refreshLaunchAtLoginState()
    }

    private func synchronizeInstalledInputMethodSupport() async {
        do {
            _ =
                try await environment.squirrelIntegrationService
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
                    name: "Rime 输入法",
                    detail: "未检测到可用的输入法。",
                    state: .unavailable,
                    schemaIDs: [],
                    protocolVersion: nil
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
                name: "Rime 输入法",
                detail: status.detail ?? defaultDetail(for: uiState),
                state: uiState,
                schemaIDs: status.schemaIDs,
                protocolVersion: status.protocolVersion
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

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        updateAppUpdateMenuItem()
    }

    private func updateAppUpdateMenuItem() {
        guard let updateMenuItem else { return }
        let presentation = appUpdateModel.status.menuPresentation
        updateMenuItem.title = presentation.title
        updateMenuItem.isEnabled = presentation.isEnabled
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

    @objc private func checkForUpdates() {
        let presentation = appUpdateModel.status.menuPresentation
        if let destinationURL = presentation.destinationURL {
            NSWorkspace.shared.open(destinationURL)
            return
        }

        performUpdateCheck()
    }

    private func performUpdateCheck() {
        guard !appUpdateModel.isChecking else { return }

        updateMenuItem.title =
            AppUpdateStatus.checking.menuPresentation.title
        updateMenuItem.isEnabled = false
        showUpdateProgress()
        Task { [weak self] in
            guard let self else { return }
            await appUpdateModel.checkForUpdates()
            updateAppUpdateMenuItem()
            showUpdateResult()
        }
    }

    private func scheduleAutomaticAppUpdateCheck() {
        automaticAppUpdateCheckTask?.cancel()
        automaticAppUpdateCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await appUpdateModel.automaticallyCheckForUpdates()
            guard !Task.isCancelled else { return }
            updateAppUpdateMenuItem()
            automaticAppUpdateCheckTask = nil
        }
    }

    private func showUpdateProgress() {
        dismissUpdatePanel()

        let panel = makeUpdatePanel()
        updatePanel = panel
        let content = AppUpdatePanelContent.checking
        installUpdatePanelContent(
            AppUpdatePanelView(content: content),
            size: AppUpdatePanelView.panelSize(for: content),
            in: panel
        )
    }

    private func showUpdateResult() {
        guard let presentation = appUpdateModel.status.resultPresentation else {
            dismissUpdatePanel()
            return
        }

        presentUpdateResult(presentation)
    }

    private func presentUpdateResult(
        _ presentation: AppUpdateResultPresentation
    ) {
        guard let panel = updatePanel else { return }
        pendingUpdateURL = presentation.destinationURL
        let content = AppUpdatePanelContent.result(presentation)

        installUpdatePanelContent(
            AppUpdatePanelView(
                content: content,
                onPrimaryAction: { [weak self] in
                    guard let self else { return }
                    if presentation.destinationURL == nil {
                        dismissUpdatePanel()
                    } else {
                        openUpdateDownload()
                    }
                },
                onSecondaryAction: { [weak self] in
                    self?.dismissUpdatePanel()
                }
            ),
            size: AppUpdatePanelView.panelSize(for: content),
            in: panel
        )
    }

    private func makeUpdatePanel() -> GlintUpdatePanel {
        let panel = GlintUpdatePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = contentView
        return panel
    }

    private func installUpdatePanelContent<Content: View>(
        _ content: Content,
        size: CGSize,
        in panel: NSPanel
    ) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.setContentSize(size)

        guard let contentView = panel.contentView else { return }
        UpdatePanelContent.install(hostingView, in: contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.center()
        panel.orderFrontRegardless()
    }

    @objc private func openUpdateDownload() {
        if let pendingUpdateURL {
            NSWorkspace.shared.open(pendingUpdateURL)
        }
        dismissUpdatePanel()
    }

    @objc private func dismissUpdatePanel() {
        updatePanel?.orderOut(nil)
        updatePanel = nil
        pendingUpdateURL = nil
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
        guard
            windowModel.translationReadiness
                == .ready(windowModel.translationTarget)
        else {
            if requestPermissionIfNeeded {
                showMainWindow()
            }
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
        translationLanguageCoordinator.cancelPendingResume()
        prepareForMonitoringStop()
        let session = environment.monitoringSession
        Task.detached(priority: .userInitiated) {
            await session.stop()
        }
    }

    private func stopMonitoringForLanguageSwitch() async {
        prepareForMonitoringStop()
        await environment.monitoringSession.stop()
        if sessionState != .idle {
            sessionState = .idle
            updateStatusItem(isMonitoring: false)
            updateMonitoringMenuItem()
        }
    }

    private func prepareForMonitoringStop() {
        shouldStartMonitoringAfterPreparation = false
        shouldRequestPermissionAfterPreparation = false
        translationChoiceShortcutCoordinator.update(nil)
        translationSpeechShortcutCoordinator.update(nil)
        translationAutoSpeechScheduler.cancel()
        translationSpeechController.stop()
        hudEventCoordinator.hide(animated: false)
        windowModel.isMonitoring = false
        windowModel.statusText = ""
        updateStatusItem(isMonitoring: false)
        updateMonitoringMenuItem()
    }

    private var monitoringSettings: MonitoringSettings {
        MonitoringSettings(
            mode: windowModel.translationMode,
            translationTarget: windowModel.translationTarget,
            candidateDwellDuration: windowModel.displayPreferences
                .candidateDwellDuration,
            translationScope: windowModel.displayPreferences.translationScope,
            maximumTranslationCount: windowModel.displayPreferences
                .maximumTranslationCount,
            showsPartsOfSpeech: windowModel.displayPreferences
                .showsPartsOfSpeech,
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
                translationSpeechShortcutCoordinator.update(nil)
                translationAutoSpeechScheduler.cancel()
                translationSpeechController.stop()
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
            if status == "安全输入场景已跳过" {
                translationSpeechShortcutCoordinator.update(nil)
                translationAutoSpeechScheduler.cancel()
                translationSpeechController.stop()
            }
        case .inputSourceChanged(let identity):
            windowModel.updateActiveInputMethod(identity)
            translationAutoSpeechScheduler.cancel()
            translationSpeechController.stop()
        case .candidateChanged(let revision):
            translationChoiceShortcutCoordinator.update(nil)
            translationSpeechShortcutCoordinator.update(nil)
            translationSpeechController.stopAutomatic()
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.candidateChanged(
                    revision: revision,
                    delay: windowModel.generalPreferences
                        .autoSpeechDelay
                )
            } else {
                translationAutoSpeechScheduler.cancel()
            }
            hudEventCoordinator.candidateChanged()
        case .selectionChanged(let index, let revision):
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.selectionChanged(
                    index: index,
                    revision: revision,
                    delay: windowModel.generalPreferences
                        .autoSpeechDelay
                )
            }
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
            translationSpeechShortcutCoordinator.update(nil)
            translationAutoSpeechScheduler.cancel()
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
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.updateTranslations(
                    primaryTranslations(from: translations),
                    revision: revision,
                    selectedIndex: selectedTranslationIndex(
                        from: translations
                    )
                )
            }
        case .insertionOffer(let offer):
            translationChoiceShortcutCoordinator.update(offer)
            translationSpeechShortcutCoordinator.update(offer)
        }
    }

    private func primaryTranslations(
        from translations: [CandidateTranslationPresentation]
    ) -> [Int: String] {
        var values: [Int: String] = [:]
        for item in translations {
            guard
                let text =
                    item.insertionOptions.first
                    ?? item.translation
            else {
                continue
            }
            values[item.index] = text
        }
        return values
    }

    private func selectedTranslationIndex(
        from translations: [CandidateTranslationPresentation]
    ) -> Int? {
        translations.first(where: \.isSelected)?.index
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
                "target=\(windowModel.translationTarget.rawValue)",
                "model=\(windowModel.activeModelID)",
                "prompt=2",
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
