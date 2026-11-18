import AppKit
import GlintCore
import GlintMac
import GlintPlugins
import GlintUI
import OSLog
import SwiftUI

let appLogger = Logger(
    subsystem: "com.local.glint",
    category: "App"
)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let initialPermissionRequestKey =
        "glint.permissions.accessibilityInitialRequestAttempted"

    let readinessToken: String?
    var initialActivationPolicy: NSApplication.ActivationPolicy {
        windowModel.generalPreferences.applicationActivationPolicy
    }

    var statusItem: NSStatusItem!
    var monitoringMenuItem: NSMenuItem!
    var updateMenuItem: NSMenuItem!
    var updatePanel: NSPanel?
    var pendingUpdateURL: URL?
    var mainWindowController: MainWindowController!
    let hudEventCoordinator: HUDEventCoordinator
    let translationChoiceShortcutCoordinator: TranslationChoiceShortcutCoordinator
    let translationSpeechController: TranslationSpeechController
    let translationAutoSpeechScheduler: TranslationAutoSpeechScheduler
    let translationSpeechShortcutCoordinator: TranslationChoiceShortcutCoordinator
    let environment: AppEnvironment
    let translationLanguageCoordinator: TranslationLanguageCoordinator
    let launchAtLoginController: LaunchAtLoginController
    let windowActionContext: AppWindowActionContext
    let windowPreferencesContext: AppWindowPreferencesContext
    let windowModel: MainWindowModel
    let appUpdateModel: AppUpdateModel
    var eventPumpTask: Task<Void, Never>?
    var automaticAppUpdateCheckTask: Task<Void, Never>?
    var sessionState: MonitoringSessionState = .idle
    var permissionRequestPending = false
    var permissionRequestWasIssued = false
    var selectedInputSourceObserver: NSObjectProtocol?
    var systemSettingsTerminationObserver: NSObjectProtocol?
    var systemSettingsReturnPolicy = SystemSettingsReturnPolicy()
    var startupPreparationTask: Task<Void, Never>?
    var shouldStartMonitoringAfterPreparation = false
    var shouldRequestPermissionAfterPreparation = false
    var wasLaunchedAtLogin = false

    override init() {
        let selectionStore = TranslationSelectionStore()
        selectionStore.migrateIfNeeded()
        let environment = AppEnvironment(
            selectionStore: selectionStore
        )
        let translationLanguageCoordinator =
            TranslationLanguageCoordinator(
                store: selectionStore,
                languageRuntime:
                    TranslationLanguageRuntimeAdapter(
                        runtime: environment.translationRuntime
                    ),
                system: environment.systemTranslationCoordinator
            )
        let launchAtLoginController = LaunchAtLoginController()
        let translationSpeechController = TranslationSpeechController()
        let windowActionContext = AppWindowActionContext(
            environment: environment,
            translationLanguageCoordinator:
                translationLanguageCoordinator,
            launchAtLoginController: launchAtLoginController,
            translationSpeechController: translationSpeechController
        )
        let windowModel = MainWindowModel(
            actions: windowActionContext.makeActions(),
            pluginManager: environment.pluginManager,
            builtInPlugins: BundledPluginResources.manifests,
            translationSelectionStore: selectionStore
        )
        windowActionContext.windowModel = windowModel
        self.environment = environment
        self.translationLanguageCoordinator =
            translationLanguageCoordinator
        self.launchAtLoginController = launchAtLoginController
        self.windowActionContext = windowActionContext
        self.windowModel = windowModel
        self.appUpdateModel = AppUpdateModel()
        self.hudEventCoordinator = HUDEventCoordinator(
            hud: HUDController(),
            model: windowModel
        )
        let translationChoiceShortcutCoordinator =
            TranslationChoiceShortcutCoordinator(
                shortcut:
                    windowModel.generalPreferences.insertionShortcut
                    ?? TranslationInsertionShortcut.defaultTrigger
            )
        let translationAutoSpeechScheduler =
            TranslationAutoSpeechScheduler()
        let translationSpeechShortcutCoordinator =
            TranslationChoiceShortcutCoordinator(
                shortcut:
                    windowModel.generalPreferences.speechShortcut
                    ?? GeneralPreferences.defaultSpeechShortcut,
                namespace: .speech
            )
        self.translationChoiceShortcutCoordinator =
            translationChoiceShortcutCoordinator
        self.translationSpeechController = translationSpeechController
        self.translationAutoSpeechScheduler =
            translationAutoSpeechScheduler
        self.translationSpeechShortcutCoordinator =
            translationSpeechShortcutCoordinator
        let windowPreferencesContext = AppWindowPreferencesContext(
            environment: environment,
            translationChoiceShortcutCoordinator:
                translationChoiceShortcutCoordinator,
            translationSpeechShortcutCoordinator:
                translationSpeechShortcutCoordinator,
            translationSpeechController: translationSpeechController,
            translationAutoSpeechScheduler: translationAutoSpeechScheduler
        )
        windowPreferencesContext.windowModel = windowModel
        self.windowPreferencesContext = windowPreferencesContext
        self.readinessToken = Self.readinessToken(
            from: CommandLine.arguments
        )
        super.init()
        configureWindowActionContext()
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
            let preferences = self.windowModel.generalPreferences
            let target = self.windowModel.translationTarget
            self.translationSpeechController.speak(
                text,
                target: target,
                accent: preferences.speechAccent,
                voiceIdentifier:
                    preferences.speechVoiceIdentifier(for: target),
                rate: preferences.speechRate,
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
            let preferences = self.windowModel.generalPreferences
            let target = self.windowModel.translationTarget
            self.translationSpeechController.speak(
                offer.choices[choiceIndex],
                target: target,
                accent: preferences.speechAccent,
                voiceIdentifier:
                    preferences.speechVoiceIdentifier(for: target),
                rate: preferences.speechRate,
                source: .manual
            )
            return false
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        wasLaunchedAtLogin = LoginLaunchDetector.wasLaunchedAtLogin()
        configureWindowModel()
        observeInputSourceChanges()
        observeSystemSettingsTermination()
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
            let readiness =
                await translationLanguageCoordinator
                .prepareCurrentConfiguration()
            if readiness != .superseded {
                windowModel.updateTranslationReadiness(readiness)
            }
            startupPreparationTask = nil
            windowModel.isPreparingMonitoring = false
            if shouldStartMonitoringAfterPreparation,
                windowModel.translationReadiness
                    == .ready(windowModel.translationTarget)
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
        if let systemSettingsTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(
                systemSettingsTerminationObserver
            )
        }
        stopMonitoring()
    }

    private func configureWindowActionContext() {
        windowActionContext.startMonitoring = { [weak self] in
            self?.startMonitoring()
        }
        windowActionContext.stopMonitoring = { [weak self] in
            self?.stopMonitoring()
        }
        windowActionContext.refreshPermissions = { [weak self] in
            self?.refreshPermissionState()
        }
        windowActionContext.requestPermissions = { [weak self] in
            self?.beginPermissionRequest()
        }
        windowActionContext.openAccessibilitySettings = { [weak self] in
            self?.openAccessibilitySettings()
        }
        windowActionContext.refreshLaunchAtLogin = { [weak self] in
            self?.refreshLaunchAtLoginState()
        }
        windowActionContext.setLaunchAtLogin = { [weak self] enabled in
            self?.setLaunchAtLoginEnabled(enabled)
        }
        windowActionContext.showMainWindow = { [weak self] in
            self?.showMainWindow()
        }
        windowActionContext.openSystemTranslationSettings = {
            [weak self] in
            self?.openSystemTranslationSettings()
        }
        windowActionContext.syncTranslationConfiguration = {
            [weak self] in
            self?.syncTranslationConfiguration()
        }
    }

    private func configureWindowModel() {
        windowPreferencesContext.windowModel = windowModel
        windowPreferencesContext.updateStatusItemVisibility = {
            [weak self] in
            self?.updateStatusItemVisibility()
        }
        windowPreferencesContext.updateActivationPolicy = {
            [weak self] in
            self?.updateActivationPolicy()
        }
        windowPreferencesContext.configure()
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

    func markRuntimeReady() {
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

}
