import Foundation
import GlintCore
import GlintPlugins
import Observation

@MainActor
@Observable
public final class MainWindowModel {
    public var isMonitoring = false
    public var isPreparingMonitoring = false
    public var accessibilityGranted = false
    public var hasRequestedAccessibilityPermission = false
    public internal(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    public internal(set) var launchAtLoginError: String?
    public var statusText = ""
    public internal(set) var activeInputMethodName = "检测中"
    public internal(set) var inputMethodSupportStatuses: [InputMethodSupportStatus] = [.applePinyin]
    public internal(set) var isLoadingInputMethodSupport = false
    public internal(set) var isUpdatingInputMethodSupport = false
    public internal(set) var inputMethodSupportError: String?
    public internal(set) var installedPlugins: [PluginManifest] = []
    public internal(set) var isLoadingPlugins = false
    public internal(set) var availablePlugins: [PluginManifest] = []
    public internal(set) var isLoadingCatalog = false
    public internal(set) var isInstalling: String?
    public internal(set) var isCancellingInstallation = false
    public internal(set) var installProgress: [String: PluginInstallProgress] =
        [:]
    public internal(set) var catalogError: String?
    public internal(set) var translationTarget: TranslationTarget
    public internal(set) var translationReadiness: TranslationReadiness = .idle
    public internal(set) var isChangingTranslationTarget = false
    public internal(set) var activeModelID: String
    public private(set) var translationMode: TranslationMode
    public internal(set) var isImportingLocalModel = false
    public internal(set) var localImportProgress = 0.0
    public internal(set) var localImportError: String?
    public internal(set) var translationModelStatusText: String?
    public internal(set) var translationModelStatusIsError = false
    public internal(set) var translationModelStatusModelID: String?
    public internal(set) var systemTranslationAvailability: SystemTranslationAvailability?
    public internal(set) var isRefreshingSystemTranslation = false
    public internal(set) var isPreparingSystemTranslation = false
    public internal(set) var systemTranslationError: String?
    public internal(set) var systemTranslationPreparationIsIncomplete = false
    public internal(set) var systemTranslationPresentationEvent = 0
    public internal(set) var coreDictionaryUpdateStates: [String: CoreDictionaryUpdateState] = [:]
    public internal(set) var translationModelUpdateStates: [String: TranslationModelUpdateState] = [:]
    public internal(set) var modelMarketResults: [UpstreamModelSummary] = []
    public internal(set) var isLoadingModelMarket = false
    public internal(set) var modelMarketError: String?
    public internal(set) var isPreparingModelMarketInstallID: String?
    public internal(set) var modelMarketInstallPreview: ModelInstallPreparation?
    public internal(set) var modelMarketInstallRepository: String?
    public internal(set) var modelMarketInstallPluginID: String?
    public let generalPreferences: GeneralPreferences
    public let displayPreferences: DisplayPreferences

    @ObservationIgnored
    let pluginLifecycle: PluginLifecycleService
    @ObservationIgnored
    let pluginUpdateCoordinator: PluginUpdateCoordinator
    @ObservationIgnored
    let pluginInstallCoordinator: PluginInstallCoordinator
    @ObservationIgnored
    let localModelImportCoordinator: LocalModelImportCoordinator
    @ObservationIgnored
    private let translationCoordinator: TranslationCoordinator
    @ObservationIgnored
    let builtInPlugins: [PluginManifest]
    @ObservationIgnored
    let defaults: UserDefaults
    @ObservationIgnored
    private let now: @MainActor () -> Date
    @ObservationIgnored
    var actions: MainWindowActions
    @ObservationIgnored
    var discardDownloadAction: @MainActor (String) async -> Void = { _ in }

    public init(
        actions: MainWindowActions,
        generalPreferences: GeneralPreferences? = nil,
        displayPreferences: DisplayPreferences? = nil,
        pluginManager: PluginManager = PluginManager(),
        builtInPlugins: [PluginManifest] = [],
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        translationSelectionStore: TranslationSelectionStore? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.actions = actions
        self.generalPreferences = generalPreferences ?? GeneralPreferences()
        self.displayPreferences = displayPreferences ?? DisplayPreferences()
        let pluginLifecycle = PluginLifecycleService(manager: pluginManager)
        self.pluginLifecycle = pluginLifecycle
        let resolvedCatalogURL =
            catalogURL
            ?? Self.defaultCatalogURL(
                defaults: defaults
            )
        self.pluginUpdateCoordinator = PluginUpdateCoordinator(
            pluginLifecycle: pluginLifecycle,
            catalogURL: resolvedCatalogURL,
            defaults: defaults,
            now: now
        )
        self.pluginInstallCoordinator = PluginInstallCoordinator(
            pluginLifecycle: pluginLifecycle
        )
        self.localModelImportCoordinator = LocalModelImportCoordinator(
            pluginLifecycle: pluginLifecycle
        )
        self.discardDownloadAction = { id in
            await pluginLifecycle.discardDownload(id: id)
        }
        self.builtInPlugins = builtInPlugins
        self.installedPlugins = builtInPlugins.sorted {
            $0.name < $1.name
        }
        self.defaults = defaults
        let selectionStore =
            translationSelectionStore
            ?? TranslationSelectionStore(defaults: defaults)
        if translationSelectionStore == nil {
            selectionStore.migrateIfNeeded()
        }
        let selectedTarget = selectionStore.selectedTarget
        self.translationTarget = selectedTarget
        self.now = now
        self.activeModelID = selectionStore.selectedModelID(
            for: selectedTarget
        )
        self.translationMode = TranslationModeSelection.selected(in: defaults)
        self.translationCoordinator = TranslationCoordinator(
            selectionStore: selectionStore
        )
    }

    convenience init(
        generalPreferences: GeneralPreferences? = nil,
        displayPreferences: DisplayPreferences? = nil,
        pluginManager: PluginManager = PluginManager(),
        builtInPlugins: [PluginManifest] = [],
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        translationSelectionStore: TranslationSelectionStore? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            actions: .stub,
            generalPreferences: generalPreferences,
            displayPreferences: displayPreferences,
            pluginManager: pluginManager,
            builtInPlugins: builtInPlugins,
            catalogURL: catalogURL,
            defaults: defaults,
            translationSelectionStore: translationSelectionStore,
            now: now
        )
    }

    public static func supports(
        _ plugin: PluginManifest,
        target: TranslationTarget
    ) -> Bool {
        plugin.type == .translation
            && plugin.availableTranslationTargets.contains(target)
    }

    public func setTranslationTarget(
        _ target: TranslationTarget
    ) async {
        await translationCoordinator.setTranslationTarget(
            target,
            on: self
        )
    }

    public func updateTranslationReadiness(
        _ readiness: TranslationReadiness
    ) {
        translationCoordinator.updateTranslationReadiness(
            readiness,
            on: self
        )
    }

    public func retryTranslationConfiguration() async {
        await translationCoordinator.retryTranslationConfiguration(
            on: self
        )
    }

    public func setTranslationModel(
        _ modelID: String,
        for target: TranslationTarget
    ) async {
        await translationCoordinator.setTranslationModel(
            modelID,
            for: target,
            on: self
        )
    }

    public func previewTranslationSpeech() {
        translationCoordinator.previewTranslationSpeech(on: self)
    }

    func persistActiveModelID() {
        translationCoordinator.persistActiveModelID(
            activeModelID,
            target: translationTarget
        )
    }

    public func updateSystemTranslationAvailability(
        _ availability: SystemTranslationAvailability
    ) {
        translationCoordinator.updateSystemTranslationAvailability(
            availability,
            on: self
        )
    }

    public func refreshSystemTranslationSupport() async {
        await translationCoordinator.refreshSystemTranslationSupport(
            on: self
        )
    }

    public func prepareSystemTranslationSupport() async {
        await translationCoordinator.prepareSystemTranslationSupport(
            on: self
        )
    }

    public func openSystemTranslationSettings() {
        translationCoordinator.openSystemTranslationSettings(on: self)
    }

    public func activateTranslationModel(_ plugin: PluginManifest) {
        guard plugin.type == .translation else { return }
        let previousModelID = activeModelID
        activeModelID = plugin.id
        persistActiveModelID()
        prepareActiveTranslationModel(rollbackTo: previousModelID)
    }

    public func setTranslationMode(_ mode: TranslationMode) {
        guard translationMode != mode else { return }
        translationMode = mode
        TranslationModeSelection.select(mode, in: defaults)
        actions.translation.setMode(mode)
    }

    public func isActiveTranslationModel(_ plugin: PluginManifest) -> Bool {
        plugin.type == .translation && plugin.id == activeModelID
    }

    private func prepareActiveTranslationModel(rollbackTo previousModelID: String? = nil) {
        let modelID = activeModelID
        translationModelStatusText = "正在加载…"
        translationModelStatusIsError = false
        translationModelStatusModelID = modelID
        Task { [weak self] in
            guard let self else { return }
            let error = await actions.translation.activateModel(modelID)
            guard activeModelID == modelID else { return }
            if let error {
                translationModelStatusText = error
                translationModelStatusIsError = true
                translationModelStatusModelID = modelID
                if let previousModelID,
                    previousModelID != modelID
                {
                    activeModelID = previousModelID
                    persistActiveModelID()
                    _ = await actions.translation.activateModel(
                        previousModelID
                    )
                }
            } else {
                translationModelStatusText = nil
                translationModelStatusIsError = false
                translationModelStatusModelID = nil
            }
            actions.translation.configurationChanged()
        }
    }

    private static func defaultCatalogURL(
        defaults: UserDefaults
    ) -> URL? {
        if let value = ProcessInfo.processInfo.environment["GLINT_PLUGIN_CATALOG_URL"],
            let url = URL(string: value)
        {
            return url
        }
        if let value = defaults.string(forKey: "plugin.catalogURL"),
            let url = URL(string: value)
        {
            return url
        }
        if let bundledCatalogURL =
            Bundle.main.url(
                forResource: "catalog",
                withExtension: "json",
                subdirectory: "Resources"
            )
            ?? Bundle.main.url(
                forResource: "catalog",
                withExtension: "json"
            )
        {
            return bundledCatalogURL
        }
        let developmentCatalogURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
        .appendingPathComponent("Glint/catalog.json")
        if let developmentCatalogURL,
            FileManager.default.fileExists(
                atPath: developmentCatalogURL.path
            )
        {
            return developmentCatalogURL
        }
        return nil
    }

}
