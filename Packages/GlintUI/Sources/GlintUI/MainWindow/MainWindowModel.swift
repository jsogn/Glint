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
            now.timeIntervalSince(lastFailure) < failureInterval
        {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= successInterval
    }
}

struct TranslationModelUpdatePolicy {
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
            now.timeIntervalSince(lastFailure) < failureInterval
        {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= successInterval
    }
}

private struct CachedTranslationModelUpdate: Codable {
    let currentRevision: String
    let latestRevision: String
    let lastModified: String?
    let manifest: PluginManifest

    init(_ update: UpstreamModelUpdate) {
        currentRevision = update.currentRevision
        latestRevision = update.latestRevision
        lastModified = update.lastModified
        manifest = update.manifest
    }

    var upstreamUpdate: UpstreamModelUpdate {
        UpstreamModelUpdate(
            currentRevision: currentRevision,
            latestRevision: latestRevision,
            lastModified: lastModified,
            manifest: manifest
        )
    }
}

private enum TranslationModelUpdateKey {
    static func lastSuccess(_ modelID: String) -> String {
        "translationModelUpdate.lastSuccess.\(modelID)"
    }

    static func lastFailure(_ modelID: String) -> String {
        "translationModelUpdate.lastFailure.\(modelID)"
    }

    static func cachedUpdate(_ modelID: String) -> String {
        "translationModelUpdate.update.\(modelID)"
    }
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

public struct CoreDictionaryUpdateState: Equatable, Sendable {
    public let isChecking: Bool
    public let statusText: String?
    public let isError: Bool
}

public struct TranslationModelUpdateState: Equatable, Sendable {
    public let isChecking: Bool
    public let statusText: String?
    public let isError: Bool
    public let update: UpstreamModelUpdate?
}

@MainActor
@Observable
public final class MainWindowModel {
    private struct InstallationAttempt {
        let plugin: PluginManifest
        let previousModelID: String
        let wasActiveTranslation: Bool
        let shouldValidateTranslation: Bool
    }

    public var isMonitoring = false
    public var isPreparingMonitoring = false
    public var accessibilityGranted = false
    public var hasRequestedAccessibilityPermission = false
    public private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .disabled
    public private(set) var launchAtLoginError: String?
    public var statusText = ""
    public private(set) var activeInputMethodName = "检测中"
    public private(set) var inputMethodSupportStatuses: [InputMethodSupportStatus] = [.applePinyin]
    public private(set) var isLoadingInputMethodSupport = false
    public private(set) var isUpdatingInputMethodSupport = false
    public private(set) var inputMethodSupportError: String?
    public private(set) var installedPlugins: [PluginManifest] = []
    public private(set) var isLoadingPlugins = false
    public private(set) var availablePlugins: [PluginManifest] = []
    public private(set) var isLoadingCatalog = false
    public private(set) var isInstalling: String?
    public private(set) var isCancellingInstallation = false
    public private(set) var installProgress: [String: PluginInstallProgress] = [:]
    public private(set) var catalogError: String?
    public private(set) var activeModelID: String
    public private(set) var translationMode: TranslationMode
    public private(set) var isImportingLocalModel = false
    public private(set) var localImportProgress = 0.0
    public private(set) var localImportError: String?
    public private(set) var translationModelStatusText: String?
    public private(set) var translationModelStatusIsError = false
    public private(set) var translationModelStatusModelID: String?
    public private(set) var coreDictionaryUpdateStates: [String: CoreDictionaryUpdateState] = [:]
    public private(set) var translationModelUpdateStates: [String: TranslationModelUpdateState] = [:]
    public private(set) var modelMarketResults: [UpstreamModelSummary] = []
    public private(set) var isLoadingModelMarket = false
    public private(set) var modelMarketError: String?
    public private(set) var isPreparingModelMarketInstallID: String?
    public private(set) var modelMarketInstallPreview: ModelInstallPreparation?
    public private(set) var modelMarketInstallRepository: String?
    public private(set) var modelMarketInstallPluginID: String?
    public let generalPreferences: GeneralPreferences
    public let displayPreferences: DisplayPreferences
    private let catalogURL: URL?

    @ObservationIgnored
    private let pluginLifecycle: PluginLifecycleService
    @ObservationIgnored
    private let builtInPlugins: [PluginManifest]
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
    private var coreDictionaryUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var translationModelUpdateTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var modelMarketInstallTask: Task<Void, Never>?
    @ObservationIgnored
    public var startMonitoringAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var stopMonitoringAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var refreshPermissionsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var requestPermissionsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var openAccessibilitySettingsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var refreshLaunchAtLoginAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var setLaunchAtLoginAction: @MainActor (Bool) -> Void = { _ in }
    @ObservationIgnored
    public var openLoginItemsSettingsAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var refreshInputMethodSupportAction: @MainActor () async -> [InputMethodSupportStatus] = {
        [.applePinyin]
    }
    @ObservationIgnored
    public var installSquirrelSupportAction: @MainActor () async throws -> [InputMethodSupportStatus] = {
        [.applePinyin]
    }
    @ObservationIgnored
    public var uninstallSquirrelSupportAction: @MainActor () async throws -> [InputMethodSupportStatus] = {
        [.applePinyin]
    }
    @ObservationIgnored
    public var activateTranslationModelAction: @MainActor (String) async -> String? = { _ in nil }
    @ObservationIgnored
    public var releaseTranslationModelAction: @MainActor (String) async -> Void = { _ in }
    @ObservationIgnored
    public var translationModeAction: @MainActor (TranslationMode) -> Void = { _ in }
    @ObservationIgnored
    public var translationConfigurationChangedAction: @MainActor () -> Void = {}
    @ObservationIgnored
    public var dictionaryConfigurationChangedAction: @MainActor () async -> Void = {}
    @ObservationIgnored
    public var checkCoreDictionaryUpdateAction: @MainActor (CoreDictionaryUpdateKind) async throws -> String = {
        _ in "词典更新服务不可用"
    }
    @ObservationIgnored
    public var checkTranslationModelUpdateAction: @MainActor (PluginManifest) async throws -> UpstreamModelUpdate? = {
        _ in nil
    }
    @ObservationIgnored
    public var searchModelMarketAction: @MainActor (String) async throws -> [UpstreamModelSummary] = {
        _ in []
    }
    @ObservationIgnored
    public var prepareModelMarketInstallAction:
        @MainActor (
            UpstreamModelSummary,
            PluginManifest?
        ) async throws -> ModelInstallPreparation = { _, _ in
            throw ModelHubError.unavailable
        }
    @ObservationIgnored
    public var availableInstallationSpaceAction: @MainActor () -> Int64? = {
        let directory =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        return try? directory?.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    public init(
        generalPreferences: GeneralPreferences? = nil,
        displayPreferences: DisplayPreferences? = nil,
        pluginManager: PluginManager = PluginManager(),
        builtInPlugins: [PluginManifest] = [],
        catalogURL: URL? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.generalPreferences = generalPreferences ?? GeneralPreferences()
        self.displayPreferences = displayPreferences ?? DisplayPreferences()
        self.pluginLifecycle = PluginLifecycleService(manager: pluginManager)
        self.builtInPlugins = builtInPlugins
        self.installedPlugins = builtInPlugins.sorted {
            $0.name < $1.name
        }
        self.catalogURL =
            catalogURL
            ?? Self.defaultCatalogURL(
                defaults: defaults
            )
        self.defaults = defaults
        self.now = now
        self.activeModelID = TranslationModelSelection.selected(in: defaults)
        self.translationMode = TranslationModeSelection.selected(in: defaults)
    }

    public var dictionaryPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .dictionary }
    }

    public var translationPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .translation }
    }

    public var translationSummary: String {
        activeTranslationPlugin?.name ?? "未安装"
    }

    public var translationCharacterSummary: String {
        guard let plugin = activeTranslationPlugin else {
            return "未安装"
        }
        let summary =
            plugin.summary?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        return summary.isEmpty ? "本地翻译模型" : summary
    }

    public var translationAttentionMessage: String? {
        guard translationModelStatusIsError else { return nil }
        return "翻译模型需要检查，请在插件与模型中查看。"
    }

    public var translationAttentionDetail: String? {
        guard translationModelStatusIsError else { return nil }
        return translationModelStatusText
    }

    private var activeTranslationPlugin: PluginManifest? {
        translationPlugins.first { $0.id == activeModelID }
    }

    public var candidateSummary: String {
        "系统候选词"
    }

    public var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled
    }

    public var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    public func updateActiveInputMethod(
        _ identity: InputMethodIdentity?
    ) {
        let name = identity?.displayName ?? "输入法"
        guard activeInputMethodName != name else { return }
        activeInputMethodName = name
    }

    public var squirrelSupportStatus: InputMethodSupportStatus? {
        inputMethodSupportStatuses.first { $0.id == "squirrel" }
    }

    public var inputMethodSupportPageStatuses: [InputMethodSupportStatus] {
        inputMethodSupportStatuses.filter { $0.id == "squirrel" }
    }

    public func refreshInputMethodSupport() async {
        guard !isLoadingInputMethodSupport else { return }
        isLoadingInputMethodSupport = true
        inputMethodSupportError = nil
        inputMethodSupportStatuses =
            await refreshInputMethodSupportAction()
        isLoadingInputMethodSupport = false
    }

    public func installSquirrelSupport() async {
        guard !isUpdatingInputMethodSupport else { return }
        isUpdatingInputMethodSupport = true
        inputMethodSupportError = nil
        defer { isUpdatingInputMethodSupport = false }
        do {
            inputMethodSupportStatuses =
                try await installSquirrelSupportAction()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await refreshInputMethodSupportAction()
            inputMethodSupportError = message
        }
    }

    public func uninstallSquirrelSupport() async {
        guard !isUpdatingInputMethodSupport else { return }
        isUpdatingInputMethodSupport = true
        inputMethodSupportError = nil
        defer { isUpdatingInputMethodSupport = false }
        do {
            inputMethodSupportStatuses =
                try await uninstallSquirrelSupportAction()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await refreshInputMethodSupportAction()
            inputMethodSupportError = message
        }
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

    public func openAccessibilitySettings() {
        openAccessibilitySettingsAction()
    }

    public func refreshLaunchAtLogin() {
        refreshLaunchAtLoginAction()
    }

    public func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginError = nil
        setLaunchAtLoginAction(enabled)
    }

    public func openLoginItemsSettings() {
        openLoginItemsSettingsAction()
    }

    public func updateLaunchAtLogin(
        status: LaunchAtLoginStatus,
        error: String? = nil
    ) {
        launchAtLoginStatus = status
        launchAtLoginError = error
    }

    public func refreshInstalledPlugins() async {
        isLoadingPlugins = true
        let managedPlugins = await pluginLifecycle.installedPlugins()
        let builtInIDs = Set(builtInPlugins.map(\.id))
        var managedByID: [String: PluginManifest] = [:]
        for plugin in managedPlugins {
            managedByID[plugin.id] = plugin
        }
        let effectiveBuiltIns = builtInPlugins.map { plugin in
            guard
                let managed = managedByID[plugin.id],
                managed.source == .bundled
            else {
                return plugin
            }
            return managed
        }
        installedPlugins =
            (effectiveBuiltIns
            + managedPlugins.filter { !builtInIDs.contains($0.id) })
            .sorted { $0.name < $1.name }
        hydrateCachedTranslationModelUpdateStates()
        reconcileActiveTranslationModel()
        isLoadingPlugins = false
        translationConfigurationChangedAction()
    }

    public func coreDictionaryUpdateState(
        for dictionaryID: String
    ) -> CoreDictionaryUpdateState? {
        coreDictionaryUpdateStates[dictionaryID]
    }

    public var hasActiveCoreDictionaryUpdate: Bool {
        coreDictionaryUpdateStates.values.contains {
            $0.isChecking
        }
    }

    public func checkCoreDictionaryUpdate(
        _ dictionaryID: String,
        kind: CoreDictionaryUpdateKind
    ) {
        guard !hasActiveCoreDictionaryUpdate else {
            return
        }
        coreDictionaryUpdateStates[dictionaryID] =
            CoreDictionaryUpdateState(
                isChecking: true,
                statusText: nil,
                isError: false
            )
        coreDictionaryUpdateTasks[dictionaryID] = Task { [weak self] in
            guard let self else { return }
            defer {
                coreDictionaryUpdateTasks[dictionaryID] = nil
            }
            do {
                let message = try await checkCoreDictionaryUpdateAction(
                    kind
                )
                try Task.checkCancellation()
                await refreshInstalledPlugins()
                await dictionaryConfigurationChangedAction()
                coreDictionaryUpdateStates[dictionaryID] =
                    CoreDictionaryUpdateState(
                        isChecking: false,
                        statusText: message,
                        isError: false
                    )
            } catch {
                if Task.isCancelled {
                    coreDictionaryUpdateStates[dictionaryID] = nil
                    return
                }
                coreDictionaryUpdateStates[dictionaryID] =
                    CoreDictionaryUpdateState(
                        isChecking: false,
                        statusText:
                            "更新失败：\(error.localizedDescription)",
                        isError: true
                    )
            }
        }
    }

    public func cancelCoreDictionaryUpdate(
        _ dictionaryID: String
    ) {
        coreDictionaryUpdateTasks[dictionaryID]?.cancel()
    }

    public func translationModelUpdateState(
        for modelID: String
    ) -> TranslationModelUpdateState? {
        translationModelUpdateStates[modelID]
    }

    public func checkTranslationModelUpdate(
        _ plugin: PluginManifest,
        force: Bool = false
    ) {
        guard plugin.type == .translation,
            plugin.source == .catalog,
            plugin.revision != nil,
            translationModelUpdateTasks[plugin.id] == nil
        else {
            return
        }
        let lastSuccess = cachedTranslationModelUpdateDate(
            key: TranslationModelUpdateKey.lastSuccess(plugin.id)
        )
        let lastFailure = cachedTranslationModelUpdateDate(
            key: TranslationModelUpdateKey.lastFailure(plugin.id)
        )
        guard
            TranslationModelUpdatePolicy.shouldCheck(
                force: force,
                now: now(),
                lastSuccess: lastSuccess,
                lastFailure: lastFailure
            )
        else {
            return
        }
        translationModelUpdateStates[plugin.id] =
            TranslationModelUpdateState(
                isChecking: true,
                statusText: nil,
                isError: false,
                update: nil
            )
        translationModelUpdateTasks[plugin.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                translationModelUpdateTasks[plugin.id] = nil
            }
            do {
                let update = try await checkTranslationModelUpdateAction(
                    plugin
                )
                try Task.checkCancellation()
                recordSuccessfulTranslationModelUpdateCheck(
                    pluginID: plugin.id,
                    update: update
                )
            } catch {
                if Task.isCancelled {
                    translationModelUpdateStates[plugin.id] = nil
                    return
                }
                translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText:
                            "更新检查失败：\(error.localizedDescription)",
                        isError: true,
                        update: nil
                    )
                defaults.set(
                    now(),
                    forKey: TranslationModelUpdateKey.lastFailure(
                        plugin.id
                    )
                )
            }
        }
    }

    public func checkActiveTranslationModelUpdateAfterLaunch() {
        guard let plugin = activeTranslationPlugin else { return }
        checkTranslationModelUpdate(plugin)
    }

    private func cachedTranslationModelUpdateDate(
        key: String
    ) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    private func recordSuccessfulTranslationModelUpdateCheck(
        pluginID: String,
        update: UpstreamModelUpdate?
    ) {
        let checkedAt = now()
        defaults.set(
            checkedAt,
            forKey: TranslationModelUpdateKey.lastSuccess(pluginID)
        )
        defaults.removeObject(
            forKey: TranslationModelUpdateKey.lastFailure(pluginID)
        )
        if let update,
            let data = try? JSONEncoder().encode(
                CachedTranslationModelUpdate(update)
            )
        {
            defaults.set(
                data,
                forKey: TranslationModelUpdateKey.cachedUpdate(pluginID)
            )
        } else {
            defaults.removeObject(
                forKey: TranslationModelUpdateKey.cachedUpdate(pluginID)
            )
        }
        translationModelUpdateStates[pluginID] =
            TranslationModelUpdateState(
                isChecking: false,
                statusText:
                    update == nil ? "已是最新" : "上游有新版本",
                isError: false,
                update: update
            )
    }

    private func hydrateCachedTranslationModelUpdateStates() {
        for plugin in translationPlugins
        where plugin.source == .catalog
            && translationModelUpdateStates[plugin.id] == nil
        {
            let lastSuccess = cachedTranslationModelUpdateDate(
                key: TranslationModelUpdateKey.lastSuccess(plugin.id)
            )
            let lastFailure = cachedTranslationModelUpdateDate(
                key: TranslationModelUpdateKey.lastFailure(plugin.id)
            )
            if let lastFailure,
                lastSuccess.map({ lastFailure > $0 }) ?? true
            {
                translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText: "上次更新检查失败",
                        isError: true,
                        update: nil
                    )
                continue
            }
            let update =
                defaults
                .data(
                    forKey: TranslationModelUpdateKey.cachedUpdate(
                        plugin.id
                    )
                )
                .flatMap {
                    try? JSONDecoder().decode(
                        CachedTranslationModelUpdate.self,
                        from: $0
                    )
                }
                .map(\.upstreamUpdate)
            if update != nil {
                translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText: "上游有新版本",
                        isError: false,
                        update: update
                    )
            } else if lastSuccess != nil {
                translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText: "已是最新",
                        isError: false,
                        update: nil
                    )
            }
        }
    }

    public func installTranslationModelUpdate(_ modelID: String) {
        guard
            let update = translationModelUpdateStates[modelID]?.update
        else {
            return
        }
        installPlugin(update.manifest)
    }

    public func searchModelMarket(query: String) async {
        guard !isLoadingModelMarket else { return }
        isLoadingModelMarket = true
        modelMarketError = nil
        defer { isLoadingModelMarket = false }
        do {
            modelMarketResults = try await searchModelMarketAction(query)
        } catch {
            if Task.isCancelled {
                return
            }
            modelMarketError = error.localizedDescription
        }
    }

    public func installModelFromMarket(_ model: UpstreamModelSummary) {
        guard isPreparingModelMarketInstallID == nil,
            modelMarketInstallPreview == nil,
            installTask == nil,
            localImportTask == nil
        else {
            return
        }
        let knownManifest = knownPlugin(forRepository: model.repository)
        isPreparingModelMarketInstallID = model.id
        modelMarketError = nil
        modelMarketInstallTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isPreparingModelMarketInstallID = nil
                modelMarketInstallTask = nil
            }
            do {
                let preparation = try await prepareModelMarketInstallAction(
                    model,
                    knownManifest
                )
                try Task.checkCancellation()
                guard isCompatible(preparation.manifest) else {
                    modelMarketError =
                        "预计至少需要 \(minimumMemoryText(for: preparation.manifest)) 内存，当前设备可能无法运行"
                    return
                }
                let requiredSpace = preparation.snapshot.sizeBytes
                    .multipliedReportingOverflow(by: 2)
                if !requiredSpace.overflow,
                    let available = availableInstallationSpaceAction(),
                    available < requiredSpace.partialValue
                {
                    modelMarketError =
                        "模型需要约 \(Self.byteCountText(preparation.snapshot.sizeBytes)) 可用磁盘空间，当前可用 \(Self.byteCountText(available))"
                    return
                }
                modelMarketInstallPreview = preparation
            } catch {
                if !Task.isCancelled {
                    modelMarketError = error.localizedDescription
                }
            }
        }
    }

    public func cancelModelMarketInstall() {
        modelMarketInstallTask?.cancel()
    }

    public func confirmModelMarketInstall() {
        guard let preview = modelMarketInstallPreview else { return }
        modelMarketInstallPreview = nil
        modelMarketInstallRepository = preview.snapshot.repository
        modelMarketInstallPluginID = preview.manifest.id
        installPlugin(preview.manifest)
    }

    public func cancelModelMarketInstallPreview() {
        modelMarketInstallPreview = nil
    }

    public func knownPlugin(
        forRepository repository: String
    ) -> PluginManifest? {
        return
            installedPlugin(forRepository: repository)
            ?? (availablePlugins + builtInPlugins).first {
                matchesRepository($0, repository: repository)
            }
    }

    public func installedPlugin(
        forRepository repository: String
    ) -> PluginManifest? {
        installedPlugins.first {
            matchesRepository($0, repository: repository)
        }
    }

    private func matchesRepository(
        _ plugin: PluginManifest,
        repository: String
    ) -> Bool {
        let path = plugin.url.path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let repository = repository.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return path == repository || path.hasSuffix("/\(repository)")
    }

    private static func byteCountText(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }

    public func checkForCatalogUpdates(force: Bool = false) async {
        guard let catalogURL else {
            availablePlugins = []
            return
        }
        guard !isLoadingCatalog else { return }
        let currentDate = now()
        guard
            CatalogUpdatePolicy.shouldCheck(
                force: force,
                now: currentDate,
                lastSuccess: lastCatalogSuccessAt,
                lastFailure: lastCatalogFailureAt
            )
        else {
            return
        }

        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            let result = try await pluginLifecycle.catalogUpdates(
                from: catalogURL,
                etag: catalogETag,
                lastModified: catalogLastModified
            )
            if !result.isNotModified {
                let builtInIDs = Set(builtInPlugins.map(\.id))
                availablePlugins = result.plugins
                    .filter { !builtInIDs.contains($0.id) }
                    .sorted {
                        $0.name < $1.name
                    }
            }
            catalogETag = result.etag
            catalogLastModified = result.lastModified
            lastCatalogSuccessAt = now()
            lastCatalogFailureAt = nil
        } catch {
            lastCatalogFailureAt = now()
        }
    }

    public func checkForCatalogUpdatesAfterLaunch() async {
        guard lastCatalogSuccessAt == nil,
            lastCatalogFailureAt == nil
        else {
            return
        }
        await checkForCatalogUpdates(force: true)
    }

    public func installPlugin(_ plugin: PluginManifest) {
        guard installTask == nil, localImportTask == nil else { return }
        isInstalling = plugin.id
        isCancellingInstallation = false
        installProgress[plugin.id] = PluginInstallProgress(
            fraction: 0,
            phase: .preparing
        )
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
                let previousModelID = activeModelID
                let manifest = try await pluginLifecycle.importLocalModel(
                    from: directory
                ) { [weak self] value in
                    Task { @MainActor [weak self] in
                        self?.localImportProgress = value
                    }
                }
                let hadPendingUpgrade =
                    await pluginLifecycle.hasPendingUpgrade()
                await refreshInstalledPlugins()
                if Task.isCancelled {
                    _ = await recoverFromLocalModelFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: "导入已取消"
                    )
                    return
                }
                activeModelID = manifest.id
                TranslationModelSelection.select(manifest.id, in: defaults)
                translationModelStatusText = "正在加载本地模型…"
                translationModelStatusIsError = false
                translationModelStatusModelID = manifest.id

                let activationError =
                    await activateTranslationModelAction(manifest.id)
                if Task.isCancelled {
                    _ = await recoverFromLocalModelFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: "导入已取消"
                    )
                    return
                }
                if let activationError {
                    let message = await recoverFromLocalModelFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: activationError
                    )
                    localImportError = message
                    translationModelStatusText = message
                    translationModelStatusIsError = true
                    translationModelStatusModelID = previousModelID
                    return
                }

                do {
                    try await pluginLifecycle.commitPendingUpgrade()
                    localImportProgress = 1
                    translationModelStatusText = nil
                    translationModelStatusIsError = false
                    translationModelStatusModelID = nil
                    translationConfigurationChangedAction()
                } catch {
                    let message = await recoverFromLocalModelFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: error.localizedDescription
                    )
                    localImportError = message
                    translationModelStatusText = message
                    translationModelStatusIsError = true
                    translationModelStatusModelID = previousModelID
                }
            } catch {
                if !Self.isCancellation(error) {
                    localImportError = error.localizedDescription
                }
            }
        }
    }

    private func recoverFromLocalModelFailure(
        manifest: PluginManifest,
        previousModelID: String,
        hadPendingUpgrade: Bool,
        error: String
    ) async -> String {
        await releaseTranslationModelAction(manifest.id)
        var recoveryErrors: [String] = []

        if hadPendingUpgrade {
            do {
                try await pluginLifecycle.rollbackPendingUpgrade()
            } catch {
                recoveryErrors.append(
                    "恢复旧版本失败：\(error.localizedDescription)"
                )
            }
        } else {
            do {
                try await pluginLifecycle.uninstall(id: manifest.id)
            } catch {
                recoveryErrors.append(
                    "移除失败模型失败：\(error.localizedDescription)"
                )
            }
        }

        activeModelID = previousModelID
        TranslationModelSelection.select(previousModelID, in: defaults)
        await refreshInstalledPlugins()
        if let recoveryError = await activateTranslationModelAction(
            previousModelID
        ) {
            recoveryErrors.append(
                "恢复原模型失败：\(recoveryError)"
            )
        }
        translationConfigurationChangedAction()

        if recoveryErrors.isEmpty {
            return "导入失败，已恢复原模型：\(error)"
        }
        return
            ("导入失败：\(error)"
            + "（\(recoveryErrors.joined(separator: "；"))）")
    }

    public func cancelLocalModelImport() {
        localImportTask?.cancel()
    }

    private func performInstallation(_ plugin: PluginManifest) async {
        let attempt = installationAttempt(for: plugin)
        var hadPendingUpgrade = false
        defer { finishInstallationAttempt(for: plugin.id) }

        do {
            hadPendingUpgrade = try await installPackage(attempt.plugin)
            if attempt.shouldValidateTranslation {
                let succeeded = try await validateTranslationInstallation(
                    attempt,
                    hadPendingUpgrade: hadPendingUpgrade
                )
                guard succeeded else { return }
            } else {
                try await pluginLifecycle.commitPendingUpgrade()
                if plugin.type == .translation {
                    recordSuccessfulTranslationModelUpdateCheck(
                        pluginID: plugin.id,
                        update: nil
                    )
                }
            }
            installProgress[plugin.id] = PluginInstallProgress(
                fraction: 1,
                phase: .installing
            )
        } catch {
            await recoverInstallationFailure(
                attempt,
                hadPendingUpgrade: hadPendingUpgrade,
                error: error
            )
        }
    }

    private func installationAttempt(
        for plugin: PluginManifest
    ) -> InstallationAttempt {
        InstallationAttempt(
            plugin: plugin,
            previousModelID: activeModelID,
            wasActiveTranslation:
                plugin.type == .translation
                && activeModelID == plugin.id,
            shouldValidateTranslation:
                plugin.type == .translation
                && (activeModelID == plugin.id
                    || modelMarketInstallPluginID == plugin.id)
        )
    }

    private func finishInstallationAttempt(for pluginID: String) {
        installTask = nil
        isInstalling = nil
        isCancellingInstallation = false
        installProgress.removeValue(forKey: pluginID)
        if modelMarketInstallPluginID == pluginID {
            modelMarketInstallRepository = nil
            modelMarketInstallPluginID = nil
        }
    }

    private func installPackage(
        _ plugin: PluginManifest
    ) async throws -> Bool {
        _ = try await pluginLifecycle.install(plugin) { [weak self] value in
            Task { @MainActor [weak self] in
                self?.applyInstallProgress(value, for: plugin.id)
            }
        }
        let hadPendingUpgrade = await pluginLifecycle.hasPendingUpgrade()
        await refreshInstalledPlugins()
        if plugin.type == .dictionary {
            await dictionaryConfigurationChangedAction()
        }
        return hadPendingUpgrade
    }

    private func validateTranslationInstallation(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool
    ) async throws -> Bool {
        let plugin = attempt.plugin
        translationModelStatusText =
            attempt.wasActiveTranslation ? "正在加载新版本…" : "正在验证模型…"
        translationModelStatusIsError = false
        translationModelStatusModelID = plugin.id
        let error = await activateTranslationModelAction(plugin.id)
        if let error {
            try await recoverTranslationValidationFailure(
                attempt,
                hadPendingUpgrade: hadPendingUpgrade,
                error: error
            )
            return false
        }
        if !attempt.wasActiveTranslation {
            await releaseTranslationModelAction(plugin.id)
            if let restoreError =
                await activateTranslationModelAction(
                    attempt.previousModelID
                )
            {
                catalogError =
                    "模型已安装，但恢复原模型失败：\(restoreError)"
            }
        }
        try await pluginLifecycle.commitPendingUpgrade()
        translationModelStatusText = nil
        translationModelStatusIsError = false
        translationModelStatusModelID = nil
        recordSuccessfulTranslationModelUpdateCheck(
            pluginID: plugin.id,
            update: nil
        )
        translationConfigurationChangedAction()
        return true
    }

    private func recoverTranslationValidationFailure(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool,
        error: String
    ) async throws {
        let plugin = attempt.plugin
        let wasCancelled = Task.isCancelled
        if hadPendingUpgrade {
            try await pluginLifecycle.rollbackPendingUpgrade()
            await refreshInstalledPlugins()
            if !wasCancelled {
                translationModelStatusText =
                    "更新失败，已恢复旧版本：\(error)"
            }
        } else {
            await releaseTranslationModelAction(plugin.id)
            try await pluginLifecycle.uninstall(id: plugin.id)
            await refreshInstalledPlugins()
            if !wasCancelled {
                translationModelStatusText =
                    "模型加载失败：\(error)"
            }
        }
        let recoveryModelID =
            hadPendingUpgrade ? plugin.id : attempt.previousModelID
        if recoveryModelID != plugin.id || hadPendingUpgrade {
            let restoreError =
                await activateTranslationModelAction(recoveryModelID)
            if let restoreError, !wasCancelled {
                translationModelStatusText =
                    "模型验证失败，且原模型恢复失败：\(restoreError)"
            }
        }
        if wasCancelled {
            translationModelStatusText = nil
            translationModelStatusIsError = false
            translationModelStatusModelID = nil
        } else {
            translationModelStatusIsError = true
            translationModelStatusModelID = plugin.id
            catalogError = error
        }
        translationConfigurationChangedAction()
    }

    private func recoverInstallationFailure(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool,
        error: Error
    ) async {
        let plugin = attempt.plugin
        try? await pluginLifecycle.rollbackPendingUpgrade()
        if attempt.wasActiveTranslation, hadPendingUpgrade {
            await releaseTranslationModelAction(plugin.id)
        }
        await refreshInstalledPlugins()
        if plugin.type == .dictionary {
            await dictionaryConfigurationChangedAction()
        }
        if attempt.wasActiveTranslation, hadPendingUpgrade {
            let recoveryError =
                await activateTranslationModelAction(plugin.id)
            if Self.isCancellation(error) {
                translationModelStatusText = nil
                translationModelStatusIsError = false
                translationModelStatusModelID = nil
            } else if let recoveryError {
                translationModelStatusText =
                    "更新失败，模型恢复失败：\(recoveryError)"
                translationModelStatusIsError = true
                translationModelStatusModelID = plugin.id
            } else {
                translationModelStatusText =
                    "更新失败，已恢复当前版本：\(error)"
                translationModelStatusIsError = true
                translationModelStatusModelID = plugin.id
            }
            translationConfigurationChangedAction()
        }
        if !Self.isCancellation(error) {
            catalogError = error.localizedDescription
        }
    }

    private func applyInstallProgress(
        _ progress: PluginInstallProgress,
        for pluginID: String
    ) {
        guard isInstalling == pluginID else { return }
        if let current = installProgress[pluginID],
            current.phase == progress.phase,
            current.sourceHost == progress.sourceHost,
            progress.fraction < current.fraction
        {
            return
        }
        installProgress[pluginID] = progress
    }

    public func uninstallPlugin(_ plugin: PluginManifest) async {
        guard plugin.source != .bundled else { return }
        guard !isActiveTranslationModel(plugin) else {
            catalogError = "当前翻译模型不可卸载，请先更换。"
            return
        }
        catalogError = nil
        do {
            await releaseTranslationModelAction(plugin.id)
            try await pluginLifecycle.uninstall(id: plugin.id)
            translationModelUpdateStates.removeValue(forKey: plugin.id)
            defaults.removeObject(
                forKey: TranslationModelUpdateKey.lastSuccess(plugin.id)
            )
            defaults.removeObject(
                forKey: TranslationModelUpdateKey.lastFailure(plugin.id)
            )
            defaults.removeObject(
                forKey: TranslationModelUpdateKey.cachedUpdate(plugin.id)
            )
            if translationModelStatusModelID == plugin.id {
                translationModelStatusText = nil
                translationModelStatusIsError = false
                translationModelStatusModelID = nil
            }
            await refreshInstalledPlugins()
            if plugin.type == .dictionary {
                await dictionaryConfigurationChangedAction()
            }
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
            )
        else {
            return nil
        }
        return PluginUpdateInfo(
            currentVersion: installedVersion,
            availableVersion: plugin.version
        )
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
        let models = installedPlugins.filter { $0.type == .translation }
        guard !models.contains(where: { $0.id == activeModelID }) else { return }
        let fallback =
            models.first {
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
                    previousModelID != modelID
                {
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
