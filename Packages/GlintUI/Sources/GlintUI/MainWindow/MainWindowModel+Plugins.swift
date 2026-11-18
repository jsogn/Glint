import Foundation
import GlintCore
import GlintPlugins

extension MainWindowModel {
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
        pluginUpdateCoordinator.hydrateCachedTranslationModelUpdateStates(
            on: self
        )
        isLoadingPlugins = false
        translationConfigurationChangedAction()
    }

    public func coreDictionaryUpdateState(
        for dictionaryID: String
    ) -> CoreDictionaryUpdateState? {
        coreDictionaryUpdateStates[dictionaryID]
    }

    public func checkCoreDictionaryUpdate(
        _ dictionaryID: String,
        kind: CoreDictionaryUpdateKind
    ) {
        pluginUpdateCoordinator.checkCoreDictionaryUpdate(
            dictionaryID,
            kind: kind,
            on: self
        )
    }

    public func cancelCoreDictionaryUpdate(
        _ dictionaryID: String
    ) {
        pluginUpdateCoordinator.cancelCoreDictionaryUpdate(dictionaryID)
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
        pluginUpdateCoordinator.checkTranslationModelUpdate(
            plugin,
            force: force,
            on: self
        )
    }

    public func checkActiveTranslationModelUpdateAfterLaunch() {
        pluginUpdateCoordinator.checkActiveTranslationModelUpdateAfterLaunch(
            on: self
        )
    }

    func recordSuccessfulTranslationModelUpdateCheck(
        pluginID: String,
        update: UpstreamModelUpdate?
    ) {
        pluginUpdateCoordinator
            .recordSuccessfulTranslationModelUpdateCheck(
                pluginID: pluginID,
                update: update,
                on: self
            )
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
        pluginInstallCoordinator.installModelFromMarket(model, on: self)
    }

    public func cancelModelMarketInstall() {
        pluginInstallCoordinator.cancelModelMarketInstall()
    }

    public func confirmModelMarketInstall() {
        pluginInstallCoordinator.confirmModelMarketInstall(on: self)
    }

    public func cancelModelMarketInstallPreview() {
        pluginInstallCoordinator.cancelModelMarketInstallPreview(on: self)
    }

    public func knownPlugin(
        forRepository repository: String
    ) -> PluginManifest? {
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

    func matchesRepository(
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

    public func checkForCatalogUpdates(force: Bool = false) async {
        await pluginUpdateCoordinator.checkForCatalogUpdates(
            force: force,
            on: self
        )
    }

    public func checkForCatalogUpdatesAfterLaunch() async {
        await pluginUpdateCoordinator.checkForCatalogUpdatesAfterLaunch(
            on: self
        )
    }

    public func installPlugin(_ plugin: PluginManifest) {
        pluginInstallCoordinator.install(plugin, on: self)
    }

    public func cancelInstallation() {
        pluginInstallCoordinator.cancelInstallation(on: self)
    }

    public func importLocalTranslationModel(from directory: URL) {
        localModelImportCoordinator.importModel(
            from: directory,
            on: self
        )
    }

    public func cancelLocalModelImport() {
        localModelImportCoordinator.cancelImport()
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
        ProcessInfo.processInfo.physicalMemory
            >= UInt64(
                max(0, plugin.minRAMBytes)
            )
    }

    public func minimumMemoryText(for plugin: PluginManifest) -> String {
        ByteCountFormatting.memory(plugin.minRAMBytes)
    }
}
