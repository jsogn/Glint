import Foundation
import GlintPlugins

@MainActor
final class PluginUpdateCoordinator {
    private let pluginLifecycle: PluginLifecycleService
    private let catalogURL: URL?
    private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private var lastCatalogSuccessAt: Date?
    private var lastCatalogFailureAt: Date?
    private var catalogETag: String?
    private var catalogLastModified: String?
    private var coreDictionaryUpdateTasks: [String: Task<Void, Never>] = [:]
    private var translationModelUpdateTasks: [String: Task<Void, Never>] = [:]

    init(
        pluginLifecycle: PluginLifecycleService,
        catalogURL: URL?,
        defaults: UserDefaults,
        now: @escaping @MainActor () -> Date
    ) {
        self.pluginLifecycle = pluginLifecycle
        self.catalogURL = catalogURL
        self.defaults = defaults
        self.now = now
    }

    func checkCoreDictionaryUpdate(
        _ dictionaryID: String,
        kind: CoreDictionaryUpdateKind,
        on model: MainWindowModel
    ) {
        guard !model.hasActiveCoreDictionaryUpdate else {
            return
        }
        model.coreDictionaryUpdateStates[dictionaryID] =
            CoreDictionaryUpdateState(
                isChecking: true,
                statusText: nil,
                isError: false
            )
        coreDictionaryUpdateTasks[dictionaryID] = Task {
            [weak self, weak model] in
            guard let self else { return }
            guard let model else {
                self.coreDictionaryUpdateTasks[dictionaryID] = nil
                return
            }
            defer {
                self.coreDictionaryUpdateTasks[dictionaryID] = nil
            }
            do {
                let message =
                    try await model.actions.plugins
                    .checkCoreDictionaryUpdate(kind)
                try Task.checkCancellation()
                await model.refreshInstalledPlugins()
                await model.actions.plugins
                    .dictionaryConfigurationChanged()
                model.coreDictionaryUpdateStates[dictionaryID] =
                    CoreDictionaryUpdateState(
                        isChecking: false,
                        statusText: message,
                        isError: false
                    )
            } catch {
                if Task.isCancelled {
                    model.coreDictionaryUpdateStates[dictionaryID] = nil
                    return
                }
                model.coreDictionaryUpdateStates[dictionaryID] =
                    CoreDictionaryUpdateState(
                        isChecking: false,
                        statusText:
                            "更新失败：\(error.localizedDescription)",
                        isError: true
                    )
            }
        }
    }

    func cancelCoreDictionaryUpdate(_ dictionaryID: String) {
        coreDictionaryUpdateTasks[dictionaryID]?.cancel()
    }

    func checkTranslationModelUpdate(
        _ plugin: PluginManifest,
        force: Bool,
        on model: MainWindowModel
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
            MainWindowUpdatePolicies.translationModel.shouldCheck(
                force: force,
                now: now(),
                lastSuccess: lastSuccess,
                lastFailure: lastFailure
            )
        else {
            return
        }
        model.translationModelUpdateStates[plugin.id] =
            TranslationModelUpdateState(
                isChecking: true,
                statusText: nil,
                isError: false,
                update: nil
            )
        translationModelUpdateTasks[plugin.id] = Task {
            [weak self, weak model] in
            guard let self else { return }
            guard let model else {
                self.translationModelUpdateTasks[plugin.id] = nil
                return
            }
            defer {
                self.translationModelUpdateTasks[plugin.id] = nil
            }
            do {
                let update =
                    try await model.actions.plugins
                    .checkTranslationModelUpdate(
                        plugin
                    )
                try Task.checkCancellation()
                self.recordSuccessfulTranslationModelUpdateCheck(
                    pluginID: plugin.id,
                    update: update,
                    on: model
                )
            } catch {
                if Task.isCancelled {
                    model.translationModelUpdateStates[plugin.id] = nil
                    return
                }
                model.translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText:
                            "更新检查失败：\(error.localizedDescription)",
                        isError: true,
                        update: nil
                    )
                self.defaults.set(
                    self.now(),
                    forKey: TranslationModelUpdateKey.lastFailure(
                        plugin.id
                    )
                )
            }
        }
    }

    func checkActiveTranslationModelUpdateAfterLaunch(
        on model: MainWindowModel
    ) {
        guard let plugin = model.activeTranslationPlugin else { return }
        checkTranslationModelUpdate(plugin, force: false, on: model)
    }

    func recordSuccessfulTranslationModelUpdateCheck(
        pluginID: String,
        update: UpstreamModelUpdate?,
        on model: MainWindowModel
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
        model.translationModelUpdateStates[pluginID] =
            TranslationModelUpdateState(
                isChecking: false,
                statusText:
                    update == nil ? "已是最新" : "上游有新版本",
                isError: false,
                update: update
            )
    }

    func hydrateCachedTranslationModelUpdateStates(
        on model: MainWindowModel
    ) {
        for plugin in model.translationPlugins
        where plugin.source == .catalog
            && model.translationModelUpdateStates[plugin.id] == nil
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
                model.translationModelUpdateStates[plugin.id] =
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
                model.translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText: "上游有新版本",
                        isError: false,
                        update: update
                    )
            } else if lastSuccess != nil {
                model.translationModelUpdateStates[plugin.id] =
                    TranslationModelUpdateState(
                        isChecking: false,
                        statusText: "已是最新",
                        isError: false,
                        update: nil
                    )
            }
        }
    }

    func checkForCatalogUpdates(
        force: Bool,
        on model: MainWindowModel
    ) async {
        guard let catalogURL else {
            model.availablePlugins = []
            return
        }
        guard !model.isLoadingCatalog else { return }
        let currentDate = now()
        guard
            MainWindowUpdatePolicies.catalog.shouldCheck(
                force: force,
                now: currentDate,
                lastSuccess: lastCatalogSuccessAt,
                lastFailure: lastCatalogFailureAt
            )
        else {
            return
        }

        model.isLoadingCatalog = true
        defer { model.isLoadingCatalog = false }
        do {
            let result = try await pluginLifecycle.catalogUpdates(
                from: catalogURL,
                etag: catalogETag,
                lastModified: catalogLastModified
            )
            if !result.isNotModified {
                let builtInIDs = Set(model.builtInPlugins.map(\.id))
                model.availablePlugins = result.plugins
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

    func checkForCatalogUpdatesAfterLaunch(
        on model: MainWindowModel
    ) async {
        guard lastCatalogSuccessAt == nil,
            lastCatalogFailureAt == nil
        else {
            return
        }
        await checkForCatalogUpdates(force: true, on: model)
    }

    private func cachedTranslationModelUpdateDate(
        key: String
    ) -> Date? {
        defaults.object(forKey: key) as? Date
    }
}
