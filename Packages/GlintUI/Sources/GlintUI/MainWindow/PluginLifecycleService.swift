import Foundation
import GlintPlugins

@MainActor
public final class PluginLifecycleService {
    private let manager: PluginManager
    private let catalog: PluginCatalogService
    private let localImport: LocalModelImportService

    public init(manager: PluginManager) {
        self.manager = manager
        self.catalog = PluginCatalogService(manager: manager)
        self.localImport = LocalModelImportService(manager: manager)
    }

    public func installedPlugins() async -> [PluginManifest] {
        await manager.installedPlugins()
    }

    public func catalogUpdates(
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

    public func install(
        _ plugin: PluginManifest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try await catalog.install(plugin, progress: progress)
    }

    public func importLocalModel(
        from directory: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try await localImport.importModel(
            from: directory,
            progress: progress
        )
    }

    public func uninstall(id: String) async throws {
        try await catalog.uninstall(id: id)
    }

    public func hasPendingUpgrade() async -> Bool {
        await manager.hasPendingUpgrade()
    }

    public func commitPendingUpgrade() async throws {
        try await manager.commitPendingUpgrade()
    }

    public func rollbackPendingUpgrade() async throws {
        try await manager.rollbackPendingUpgrade()
    }
}
