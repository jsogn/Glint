import Foundation
import GlintCore
import GlintPlugins
import Observation

@MainActor
@Observable
public final class MainWindowModel {
    public var isMonitoring = false
    public var screenRecordingGranted = false
    public var accessibilityGranted = false
    public var statusText = ""
    public private(set) var installedPlugins: [PluginManifest] = []
    public private(set) var isLoadingPlugins = false
    public private(set) var availablePlugins: [PluginManifest] = []
    public private(set) var isLoadingCatalog = false
    public private(set) var isInstalling: String?
    public private(set) var isCancellingInstallation = false
    public private(set) var installProgress: [String: Double] = [:]
    public private(set) var catalogError: String?
    public private(set) var catalogMessage = "未配置插件目录"
    public private(set) var activeModelID: String
    public private(set) var activeOCREngineID: String
    public private(set) var ocrEnhancementMode: OCREnhancementMode
    public private(set) var ocrEngineStatusText: String?
    public private(set) var ocrEngineStatusIsError = false
    public private(set) var translationMode: TranslationMode
    public private(set) var openAIProviders: [OpenAICompatibleProvider] = []
    public private(set) var isImportingLocalModel = false
    public private(set) var localImportProgress = 0.0
    public private(set) var localImportError: String?
    public private(set) var translationModelStatusText: String?
    public private(set) var translationModelStatusIsError = false
    public let displayPreferences: DisplayPreferences
    private let catalogURL: URL?

    @ObservationIgnored
    private let pluginManager: PluginManager
    @ObservationIgnored
    private let catalogService: PluginCatalogService
    @ObservationIgnored
    private let localImportService: LocalModelImportService
    @ObservationIgnored
    private let openAICompatibleStore: OpenAICompatibleConfigurationStore
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var installTask: Task<Void, Never>?
    @ObservationIgnored
    private var localImportTask: Task<Void, Never>?
    @ObservationIgnored
    public var startMonitoringAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var stopMonitoringAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var refreshPermissionsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var activateTranslationModelAction: @MainActor () async -> String? = { nil }
    @ObservationIgnored
    public var activateOCREngineAction:
        @MainActor (String, OCREnhancementMode) async -> String? = {
            _, _ in nil
        }
    @ObservationIgnored
    public var testOpenAICompatibleAction:
        @MainActor (OpenAICompatibleConfiguration) async throws -> Void = { _ in }
    @ObservationIgnored
    public var translationModeAction: @MainActor (TranslationMode) -> Void = { _ in }

    public init(
        displayPreferences: DisplayPreferences? = nil,
        pluginManager: PluginManager = PluginManager(),
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        openAICompatibleStore: OpenAICompatibleConfigurationStore? = nil
    ) {
        self.displayPreferences = displayPreferences ?? DisplayPreferences()
        self.pluginManager = pluginManager
        self.catalogService = PluginCatalogService(manager: pluginManager)
        self.localImportService = LocalModelImportService(manager: pluginManager)
        self.catalogURL = catalogURL ?? Self.defaultCatalogURL()
        self.defaults = defaults
        let openAICompatibleStore = openAICompatibleStore
            ?? OpenAICompatibleConfigurationStore(defaults: defaults)
        self.openAICompatibleStore = openAICompatibleStore
        let providers = openAICompatibleStore.loadProviders()
        self.openAIProviders = providers
        var activeModelID = TranslationModelSelection.selected(in: defaults)
        if activeModelID == TranslationModelSelection.openAICompatibleModelID,
           let firstProvider = providers.first {
            activeModelID = TranslationModelSelection.openAICompatibleSelectionID(
                for: firstProvider.id
            )
            TranslationModelSelection.select(activeModelID, in: defaults)
        }
        self.activeModelID = activeModelID
        self.activeOCREngineID = OCREngineSelection.selected(in: defaults)
        self.ocrEnhancementMode = OCREnhancementSelection.selected(
            in: defaults
        )
        self.translationMode = TranslationModeSelection.selected(in: defaults)
    }

    public var dictionaryPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .dictionary }
    }

    public var translationPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .translation }
    }

    public var ocrPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .ocr }
    }

    public var dictionarySummary: String {
        Self.summary(for: dictionaryPlugins)
    }

    public var translationSummary: String {
        if let provider = activeOpenAIProvider {
            return provider.name
        }
        if let plugin = translationPlugins.first(where: {
            $0.id == activeModelID
        }) {
            return plugin.name
        }
        return "未安装"
    }

    public var ocrSummary: String {
        if activeOCREngineID == OCREngineSelection.visionEngineID {
            return "Apple Vision"
        }
        return ocrPlugins.first { $0.id == activeOCREngineID }?.name
            ?? "Apple Vision"
    }

    public var isVisionOCREngineActive: Bool {
        activeOCREngineID == OCREngineSelection.visionEngineID
    }

    public var isOpenAICompatibleActive: Bool {
        activeOpenAIProvider != nil
            || activeModelID == TranslationModelSelection.openAICompatibleModelID
    }

    public var activeOpenAIProvider: OpenAICompatibleProvider? {
        guard let providerID = TranslationModelSelection.openAIProviderID(
            fromSelectionID: activeModelID
        ) else {
            return nil
        }
        return openAIProviders.first(where: { $0.id == providerID })
    }

    public func startMonitoring() {
        startMonitoringAction()
    }

    public func stopMonitoring() {
        stopMonitoringAction()
    }

    public func refreshPermissions() {
        refreshPermissionsAction()
    }

    public func refreshPlugins() async {
        isLoadingPlugins = true
        installedPlugins = await pluginManager.installedPlugins()
        reconcileActiveTranslationModel()
        reconcileActiveOCREngine()
        isLoadingPlugins = false
        await configureActiveOCREngine()
        guard let catalogURL else {
            availablePlugins = []
            catalogMessage = "未配置插件目录"
            catalogError = nil
            return
        }

        isLoadingCatalog = true
        catalogError = nil
        do {
            availablePlugins = try await catalogService.fetchCatalog(from: catalogURL)
                .sorted {
                    if $0.recommended != $1.recommended {
                        return $0.recommended && !$1.recommended
                    }
                    return $0.name < $1.name
                }
            catalogMessage = ""
        } catch {
            availablePlugins = []
            catalogMessage = "无法读取插件目录"
            catalogError = error.localizedDescription
        }
        isLoadingCatalog = false
    }

    public func installPlugin(_ plugin: PluginManifest) {
        guard installTask == nil else { return }
        isInstalling = plugin.id
        isCancellingInstallation = false
        installProgress[plugin.id] = 0
        catalogError = nil
        installTask = Task { [weak self] in
            guard let self else { return }
            await self.performInstallation(plugin)
        }
    }

    public func cancelInstallation() {
        guard let installTask else { return }
        isCancellingInstallation = true
        installTask.cancel()
    }

    public func importLocalTranslationModel(from directory: URL) {
        guard localImportTask == nil, installTask == nil else { return }
        localImportError = nil
        localImportProgress = 0
        isImportingLocalModel = true
        localImportTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImportingLocalModel = false
                localImportTask = nil
            }
            do {
                let manifest = try await localImportService.importModel(
                    from: directory
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.localImportProgress = value
                    }
                }
                installedPlugins = await pluginManager.installedPlugins()
                reconcileActiveTranslationModel()
                activateTranslationModel(manifest)
                localImportProgress = 1
            } catch {
                if !Self.isCancellation(error) {
                    localImportError = error.localizedDescription
                }
            }
        }
    }

    public func cancelLocalModelImport() {
        localImportTask?.cancel()
    }

    private func performInstallation(_ plugin: PluginManifest) async {
        defer {
            installTask = nil
            isInstalling = nil
            isCancellingInstallation = false
        }

        do {
            _ = try await catalogService.install(plugin) { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.installProgress[plugin.id] = value
                }
            }
            await refreshPlugins()
            installProgress[plugin.id] = 1
        } catch {
            if !Self.isCancellation(error) {
                catalogError = error.localizedDescription
            }
        }
        installProgress.removeValue(forKey: plugin.id)
    }

    public func uninstallPlugin(_ plugin: PluginManifest) async {
        guard !isActiveTranslationModel(plugin),
              !isActiveOCREngine(plugin) else {
            catalogError = "使用中的模型不可卸载，请先切换模型。"
            return
        }
        catalogError = nil
        do {
            try await catalogService.uninstall(id: plugin.id)
            await refreshPlugins()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    public func activateTranslationModel(_ plugin: PluginManifest) {
        guard plugin.type == .translation else { return }
        activeModelID = plugin.id
        TranslationModelSelection.select(plugin.id, in: defaults)
        prepareActiveTranslationModel()
    }

    public func activateOCREngine(id: String) {
        guard id == OCREngineSelection.visionEngineID
            || ocrPlugins.contains(where: { $0.id == id }) else {
            return
        }
        activeOCREngineID = id
        OCREngineSelection.select(id, in: defaults)
        prepareActiveOCREngine()
    }

    public func setOCREnhancementMode(_ mode: OCREnhancementMode) {
        guard ocrEnhancementMode != mode else { return }
        ocrEnhancementMode = mode
        OCREnhancementSelection.select(mode, in: defaults)
        prepareActiveOCREngine()
    }

    public func activateOpenAICompatibleProvider(
        _ provider: OpenAICompatibleProvider
    ) {
        guard openAIProviders.contains(where: { $0.id == provider.id }) else {
            return
        }
        activeModelID = TranslationModelSelection.openAICompatibleSelectionID(
            for: provider.id
        )
        TranslationModelSelection.select(activeModelID, in: defaults)
        prepareActiveTranslationModel()
    }

    @discardableResult
    public func saveOpenAICompatibleProvider(
        id: String?,
        name: String,
        baseURL: String,
        model: String,
        apiKey: String
    ) throws -> OpenAICompatibleProvider {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = OpenAICompatibleConfiguration(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey
        )
        guard !name.isEmpty else {
            throw OpenAIProviderError.missingName
        }
        guard configuration.chatCompletionsURL != nil else {
            throw OpenAIProviderError.invalidConfiguration
        }
        if openAIProviders.contains(where: {
            $0.id != id
                && $0.name.compare(
                    name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }) {
            throw OpenAIProviderError.duplicateName
        }
        let provider = OpenAICompatibleProvider(
            id: id ?? UUID().uuidString,
            name: name,
            baseURL: configuration.baseURL,
            model: configuration.model
        )
        try openAICompatibleStore.saveProvider(provider, apiKey: apiKey)
        openAIProviders = openAICompatibleStore.loadProviders()
        if activeOpenAIProvider?.id == provider.id {
            prepareActiveTranslationModel()
        }
        return provider
    }

    public func removeOpenAICompatibleProvider(
        _ provider: OpenAICompatibleProvider
    ) throws {
        let wasActive = activeOpenAIProvider?.id == provider.id
        try openAICompatibleStore.removeProvider(id: provider.id)
        openAIProviders = openAICompatibleStore.loadProviders()
        if wasActive {
            translationModelStatusText = nil
            translationModelStatusIsError = false
            reconcileActiveTranslationModel()
        }
    }

    public func apiKey(for provider: OpenAICompatibleProvider) -> String {
        openAICompatibleStore.apiKey(for: provider.id)
    }

    public func testOpenAICompatibleConfiguration(
        _ configuration: OpenAICompatibleConfiguration
    ) async throws {
        try await testOpenAICompatibleAction(configuration)
    }

    public func setTranslationMode(_ mode: TranslationMode) {
        guard translationMode != mode else { return }
        translationMode = mode
        TranslationModeSelection.select(mode, in: defaults)
        translationModeAction(mode)
    }

    public func isActiveTranslationModel(_ plugin: PluginManifest) -> Bool {
        plugin.type == .translation && plugin.id == activeModelID
    }

    public func isActiveOCREngine(_ plugin: PluginManifest) -> Bool {
        plugin.type == .ocr && plugin.id == activeOCREngineID
    }

    public func installedVersion(for id: String) -> String? {
        installedPlugins.first { $0.id == id }?.version
    }

    public func isCompatible(_ plugin: PluginManifest) -> Bool {
        ProcessInfo.processInfo.physicalMemory >= UInt64(max(0, plugin.minRAMBytes))
    }

    public func minimumMemoryText(for plugin: PluginManifest) -> String {
        ByteCountFormatter.string(
            fromByteCount: plugin.minRAMBytes,
            countStyle: .memory
        )
    }

    private static func summary(for plugins: [PluginManifest]) -> String {
        if plugins.isEmpty {
            return "未安装"
        }
        if plugins.count == 1 {
            return plugins[0].name
        }
        return "\(plugins.count) 个已安装"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return Task.isCancelled
    }

    private func reconcileActiveTranslationModel() {
        if let provider = activeOpenAIProvider,
           openAICompatibleStore.configuration(for: provider.id)?.isConfigured == true {
            return
        }
        if activeModelID == TranslationModelSelection.openAICompatibleModelID,
           let firstProvider = openAIProviders.first {
            activateOpenAICompatibleProvider(firstProvider)
            return
        }
        let models = installedPlugins.filter { $0.type == .translation }
        guard !models.contains(where: { $0.id == activeModelID }) else { return }
        if let fallback = models.first(where: \.recommended) ?? models.first {
            activateTranslationModel(fallback)
        } else {
            activeModelID = TranslationModelSelection.defaultModelID
            TranslationModelSelection.select(activeModelID, in: defaults)
        }
    }

    private func prepareActiveTranslationModel() {
        let modelID = activeModelID
        translationModelStatusText = "正在加载…"
        translationModelStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            let error = await activateTranslationModelAction()
            guard activeModelID == modelID else { return }
            if let error {
                translationModelStatusText = error
                translationModelStatusIsError = true
            } else {
                translationModelStatusText = nil
                translationModelStatusIsError = false
            }
        }
    }

    private func reconcileActiveOCREngine() {
        guard activeOCREngineID != OCREngineSelection.visionEngineID else {
            return
        }
        guard ocrPlugins.contains(where: { $0.id == activeOCREngineID }) else {
            activeOCREngineID = OCREngineSelection.visionEngineID
            OCREngineSelection.select(
                OCREngineSelection.visionEngineID,
                in: defaults
            )
            ocrEngineStatusText = nil
            ocrEngineStatusIsError = false
            return
        }
    }

    private func configureActiveOCREngine() async {
        let engineID = activeOCREngineID
        let enhancementMode = ocrEnhancementMode
        let warning = await activateOCREngineAction(
            engineID,
            enhancementMode
        )
        guard activeOCREngineID == engineID else { return }
        ocrEngineStatusText = warning
        ocrEngineStatusIsError = warning != nil
    }

    private func prepareActiveOCREngine() {
        let engineID = activeOCREngineID
        let enhancementMode = ocrEnhancementMode
        ocrEngineStatusText = nil
        ocrEngineStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            let warning = await activateOCREngineAction(
                engineID,
                enhancementMode
            )
            guard activeOCREngineID == engineID,
                  ocrEnhancementMode == enhancementMode else {
                return
            }
            ocrEngineStatusText = warning
            ocrEngineStatusIsError = warning != nil
        }
    }

    private static func defaultCatalogURL() -> URL? {
        if let value = ProcessInfo.processInfo.environment["GLINT_PLUGIN_CATALOG_URL"],
           let url = URL(string: value) {
            return url
        }
        if let value = UserDefaults.standard.string(forKey: "plugin.catalogURL"),
           let url = URL(string: value) {
            return url
        }
        let catalogURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Glint/catalog.json")
        if let catalogURL, FileManager.default.fileExists(atPath: catalogURL.path) {
            return catalogURL
        }
        return Bundle.main.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "Resources"
        ) ?? Bundle.main.url(forResource: "catalog", withExtension: "json")
    }
}

private enum OpenAIProviderError: Error, LocalizedError {
    case missingName
    case invalidConfiguration
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .missingName:
            "请填写接口名称"
        case .invalidConfiguration:
            "请填写有效的 HTTP 或 HTTPS 接口地址和模型名称"
        case .duplicateName:
            "已存在同名接口"
        }
    }
}
