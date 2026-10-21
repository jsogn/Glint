import Foundation
import GlintCore
import GlintPlugins
import Observation

public struct PluginUpdateInfo: Sendable, Equatable {
    public let currentVersion: String
    public let availableVersion: String
}

struct CatalogUpdatePolicy {
    static let successInterval: TimeInterval = 6 * 60 * 60
    static let failureInterval: TimeInterval = 15 * 60

    static func shouldCheck(
        force: Bool,
        now: Date,
        lastSuccess: Date?,
        lastFailure: Date?
    ) -> Bool {
        if force { return true }
        if let lastFailure,
           now.timeIntervalSince(lastFailure) < failureInterval {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= successInterval
    }
}

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
    public private(set) var ocrRecognitionPreferences: OCRRecognitionPreferences
    public private(set) var ocrEngineStatusText: String?
    public private(set) var ocrEngineStatusIsError = false
    public private(set) var translationMode: TranslationMode
    public private(set) var openAIProviders: [OpenAICompatibleProvider] = []
    public private(set) var isImportingLocalModel = false
    public private(set) var localImportProgress = 0.0
    public private(set) var localImportError: String?
    public private(set) var translationModelStatusText: String?
    public private(set) var translationModelStatusIsError = false
    public private(set) var translationModelStatusModelID: String?
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
    private let now: @MainActor () -> Date
    @ObservationIgnored
    private var lastCatalogSuccessAt: Date?
    @ObservationIgnored
    private var lastCatalogFailureAt: Date?
    @ObservationIgnored
    private var catalogETag: String?
    @ObservationIgnored
    private var catalogLastModified: String?
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
    public var requestPermissionsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var activateTranslationModelAction:
        @MainActor (String) async -> String? = { _ in nil }
    @ObservationIgnored
    public var releaseTranslationModelAction:
        @MainActor (String) async -> Void = { _ in }
    @ObservationIgnored
    public var configureOCRRecognitionAction:
        @MainActor (OCRRecognitionPreferences) async -> String? = { _ in nil }
    @ObservationIgnored
    public var testOpenAICompatibleAction:
        @MainActor (OpenAICompatibleConfiguration) async throws -> Void = { _ in }
    @ObservationIgnored
    public var translationModeAction: @MainActor (TranslationMode) -> Void = { _ in }
    @ObservationIgnored
    public var translationConfigurationChangedAction: @MainActor () -> Void = {}

    public init(
        displayPreferences: DisplayPreferences? = nil,
        pluginManager: PluginManager = PluginManager(),
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        openAICompatibleStore: OpenAICompatibleConfigurationStore? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.displayPreferences = displayPreferences ?? DisplayPreferences()
        self.pluginManager = pluginManager
        self.catalogService = PluginCatalogService(manager: pluginManager)
        self.localImportService = LocalModelImportService(manager: pluginManager)
        self.catalogURL = catalogURL ?? Self.defaultCatalogURL()
        self.defaults = defaults
        self.now = now
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
        self.ocrRecognitionPreferences = OCRRecognitionPreferences.load(
            from: defaults
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
        let primary = ocrModelName(ocrRecognitionPreferences.primaryModelID)
        guard ocrRecognitionPreferences.strategy != .primaryOnly,
              let backupID = ocrRecognitionPreferences.backupModelID else {
            return primary
        }
        return "\(primary) → \(ocrModelName(backupID))"
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

    public func requestPermissions() {
        requestPermissionsAction()
    }

    public func refreshInstalledPlugins() async {
        isLoadingPlugins = true
        installedPlugins = await pluginManager.installedPlugins()
        reconcileActiveTranslationModel()
        reconcileOCRRecognitionPreferences()
        isLoadingPlugins = false
        await configureOCRRecognition()
        translationConfigurationChangedAction()
    }

    public func checkForCatalogUpdates(force: Bool = false) async {
        guard let catalogURL else {
            availablePlugins = []
            catalogMessage = "未配置插件目录"
            return
        }
        guard !isLoadingCatalog else { return }
        let currentDate = now()
        guard CatalogUpdatePolicy.shouldCheck(
            force: force,
            now: currentDate,
            lastSuccess: lastCatalogSuccessAt,
            lastFailure: lastCatalogFailureAt
        ) else {
            return
        }

        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let result = try await catalogService.fetchCatalogResult(
                from: catalogURL,
                etag: catalogETag,
                lastModified: catalogLastModified
            )
            if !result.isNotModified {
                availablePlugins = result.plugins.sorted {
                    $0.name < $1.name
                }
            }
            catalogETag = result.etag
            catalogLastModified = result.lastModified
            lastCatalogSuccessAt = now()
            lastCatalogFailureAt = nil
            catalogMessage = ""
        } catch {
            lastCatalogFailureAt = now()
            catalogMessage = "暂时无法更新模型列表"
        }
    }

    public func checkForCatalogUpdatesAfterLaunch() async {
        guard lastCatalogSuccessAt == nil,
              lastCatalogFailureAt == nil else {
            return
        }
        await checkForCatalogUpdates(force: true)
    }

    public func refreshPlugins() async {
        await refreshInstalledPlugins()
        await checkForCatalogUpdates(force: true)
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
        let wasActiveTranslation = plugin.type == .translation
            && activeModelID == plugin.id
        let wasActiveOCR = plugin.type == .ocr
            && isOCRModelInUse(plugin.id)
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
            let hadPendingUpgrade = await pluginManager.hasPendingUpgrade()
            await refreshInstalledPlugins()

            if wasActiveTranslation {
                translationModelStatusText = "正在加载新版本…"
                translationModelStatusIsError = false
                translationModelStatusModelID = plugin.id
                let error = await activateTranslationModelAction(plugin.id)
                if let error {
                    if hadPendingUpgrade {
                        try await pluginManager.rollbackPendingUpgrade()
                        await refreshInstalledPlugins()
                        _ = await activateTranslationModelAction(plugin.id)
                        translationModelStatusText =
                            "更新失败，已恢复旧版本：\(error)"
                    } else {
                        await releaseTranslationModelAction(plugin.id)
                        try await catalogService.uninstall(id: plugin.id)
                        await refreshInstalledPlugins()
                        translationModelStatusText = "模型加载失败：\(error)"
                    }
                    translationModelStatusIsError = true
                    translationModelStatusModelID = plugin.id
                } else {
                    try await pluginManager.commitPendingUpgrade()
                    translationModelStatusText = nil
                    translationModelStatusIsError = false
                    translationModelStatusModelID = nil
                }
                translationConfigurationChangedAction()
            } else if wasActiveOCR, ocrEngineStatusIsError {
                if hadPendingUpgrade {
                    try await pluginManager.rollbackPendingUpgrade()
                    await refreshInstalledPlugins()
                    catalogError = "识别模型更新失败，已恢复旧版本"
                } else {
                    try await catalogService.uninstall(id: plugin.id)
                    await refreshInstalledPlugins()
                    catalogError = "识别模型加载失败，已移除模型"
                }
            } else {
                try await pluginManager.commitPendingUpgrade()
            }
            installProgress[plugin.id] = 1
        } catch {
            try? await pluginManager.rollbackPendingUpgrade()
            if !Self.isCancellation(error) {
                catalogError = error.localizedDescription
            }
        }
        installProgress.removeValue(forKey: plugin.id)
    }

    public func uninstallPlugin(_ plugin: PluginManifest) async {
        guard !isActiveTranslationModel(plugin),
              !isOCRModelInUse(plugin.id) else {
            catalogError = "主模型或备用模型不可卸载，请先更换。"
            return
        }
        catalogError = nil
        do {
            await releaseTranslationModelAction(plugin.id)
            try await catalogService.uninstall(id: plugin.id)
            if translationModelStatusModelID == plugin.id {
                translationModelStatusText = nil
                translationModelStatusIsError = false
                translationModelStatusModelID = nil
            }
            await refreshInstalledPlugins()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    public func activateTranslationModel(_ plugin: PluginManifest) {
        guard plugin.type == .translation else { return }
        let previousModelID = activeModelID
        activeModelID = plugin.id
        TranslationModelSelection.select(plugin.id, in: defaults)
        prepareActiveTranslationModel(rollbackTo: previousModelID)
    }

    public func setPrimaryOCRModel(id: String) {
        guard isAvailableOCRModel(id) else {
            return
        }
        let backup = ocrRecognitionPreferences.backupModelID == id
            ? nil
            : ocrRecognitionPreferences.backupModelID
        updateOCRRecognitionPreferences(
            OCRRecognitionPreferences(
                primaryModelID: id,
                backupModelID: backup,
                strategy: ocrRecognitionPreferences.strategy
            )
        )
    }

    public func setBackupOCRModel(id: String?) {
        if let id {
            guard isAvailableOCRModel(id),
                  id != ocrRecognitionPreferences.primaryModelID else {
                return
            }
        }
        updateOCRRecognitionPreferences(
            OCRRecognitionPreferences(
                primaryModelID: ocrRecognitionPreferences.primaryModelID,
                backupModelID: id,
                strategy: ocrRecognitionPreferences.strategy
            )
        )
    }

    public func setOCRRecognitionStrategy(
        _ strategy: OCRRecognitionStrategy
    ) {
        updateOCRRecognitionPreferences(
            OCRRecognitionPreferences(
                primaryModelID: ocrRecognitionPreferences.primaryModelID,
                backupModelID: ocrRecognitionPreferences.backupModelID,
                strategy: strategy
            )
        )
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
        translationConfigurationChangedAction()
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
            translationConfigurationChangedAction()
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
            translationModelStatusModelID = nil
            reconcileActiveTranslationModel()
            translationConfigurationChangedAction()
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

    public func update(for plugin: PluginManifest) -> PluginUpdateInfo? {
        guard let installedVersion = installedVersion(for: plugin.id),
              PluginVersion.isNewer(
                plugin.version,
                than: installedVersion
              ) else {
            return nil
        }
        return PluginUpdateInfo(
            currentVersion: installedVersion,
            availableVersion: plugin.version
        )
    }

    public func isOCRModelInUse(_ modelID: String) -> Bool {
        ocrRecognitionPreferences.primaryModelID == modelID
            || ocrRecognitionPreferences.backupModelID == modelID
    }

    public func ocrModelName(_ modelID: String) -> String {
        if modelID == OCRRecognitionPreferences.visionModelID {
            return "Apple Vision"
        }
        return ocrPlugins.first { $0.id == modelID }?.name ?? modelID
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
        let fallback = models.first {
            $0.id == TranslationModelSelection.defaultModelID
        } ?? models.first
        if let fallback {
            activateTranslationModel(fallback)
        } else {
            activeModelID = TranslationModelSelection.defaultModelID
            TranslationModelSelection.select(activeModelID, in: defaults)
        }
    }

    private func prepareActiveTranslationModel(rollbackTo previousModelID: String? = nil) {
        let modelID = activeModelID
        translationModelStatusText = "正在加载…"
        translationModelStatusIsError = false
        translationModelStatusModelID = modelID
        Task { [weak self] in
            guard let self else { return }
            let error = await activateTranslationModelAction(modelID)
            guard activeModelID == modelID else { return }
            if let error {
                translationModelStatusText = error
                translationModelStatusIsError = true
                translationModelStatusModelID = modelID
                if let previousModelID,
                   previousModelID != modelID {
                    activeModelID = previousModelID
                    TranslationModelSelection.select(
                        previousModelID,
                        in: defaults
                    )
                    _ = await activateTranslationModelAction(previousModelID)
                }
            } else {
                translationModelStatusText = nil
                translationModelStatusIsError = false
                translationModelStatusModelID = nil
            }
            translationConfigurationChangedAction()
        }
    }

    private func reconcileOCRRecognitionPreferences() {
        let validModels = Set(
            [OCRRecognitionPreferences.visionModelID]
                + ocrPlugins.map(\.id)
        )
        let primary = validModels.contains(
            ocrRecognitionPreferences.primaryModelID
        ) ? ocrRecognitionPreferences.primaryModelID
            : OCRRecognitionPreferences.visionModelID
        let backup = ocrRecognitionPreferences.backupModelID.flatMap {
            $0 != primary && validModels.contains($0) ? $0 : nil
        }
        let reconciled = OCRRecognitionPreferences(
            primaryModelID: primary,
            backupModelID: backup,
            strategy: ocrRecognitionPreferences.strategy
        )
        guard reconciled != ocrRecognitionPreferences else { return }
        ocrRecognitionPreferences = reconciled
        reconciled.save(to: defaults)
        ocrEngineStatusText = nil
        ocrEngineStatusIsError = false
    }

    private func configureOCRRecognition() async {
        let preferences = ocrRecognitionPreferences
        let warning = await configureOCRRecognitionAction(preferences)
        guard ocrRecognitionPreferences == preferences else { return }
        ocrEngineStatusText = warning
        ocrEngineStatusIsError = warning != nil
    }

    private func updateOCRRecognitionPreferences(
        _ preferences: OCRRecognitionPreferences
    ) {
        guard preferences != ocrRecognitionPreferences else { return }
        ocrRecognitionPreferences = preferences
        preferences.save(to: defaults)
        prepareOCRRecognition()
    }

    private func prepareOCRRecognition() {
        let preferences = ocrRecognitionPreferences
        ocrEngineStatusText = nil
        ocrEngineStatusIsError = false
        Task { [weak self] in
            guard let self else { return }
            let warning = await configureOCRRecognitionAction(preferences)
            guard ocrRecognitionPreferences == preferences else {
                return
            }
            ocrEngineStatusText = warning
            ocrEngineStatusIsError = warning != nil
        }
    }

    private func isAvailableOCRModel(_ modelID: String) -> Bool {
        modelID == OCRRecognitionPreferences.visionModelID
            || ocrPlugins.contains { $0.id == modelID }
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
