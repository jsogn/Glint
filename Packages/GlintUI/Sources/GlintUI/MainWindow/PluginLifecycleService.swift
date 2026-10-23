import Foundation
import GlintPlugins

@MainActor
final class PluginLifecycleService {
    private let manager: PluginManager
    private let catalog: PluginCatalogService
    private let localImport: LocalModelImportService

    init(manager: PluginManager) {
        self.manager = manager
        self.catalog = PluginCatalogService(manager: manager)
        self.localImport = LocalModelImportService(manager: manager)
    }

    func installedPlugins() async -> [PluginManifest] {
        await manager.installedPlugins()
    }

    func catalogUpdates(
        from url: URL,
        etag: String?,
        lastModified: String?
    ) async throws -> PluginCatalogFetchResult {
        try await catalog.fetchCatalogResult(
            from: url,
            etag: etag,
            lastModified: lastModified
        )
    }

    func install(
        _ plugin: PluginManifest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try await catalog.install(plugin, progress: progress)
    }

    func importLocalModel(
        from directory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try await localImport.importModel(
            from: directory,
            preserveInstalledVersion: true,
            progress: progress
        )
    }

    func uninstall(id: String) async throws {
        try await catalog.uninstall(id: id)
    }

    func hasPendingUpgrade() async -> Bool {
        await manager.hasPendingUpgrade()
    }

    func commitPendingUpgrade() async throws {
        try await manager.commitPendingUpgrade()
    }

    func rollbackPendingUpgrade() async throws {
        try await manager.rollbackPendingUpgrade()
    }
}
