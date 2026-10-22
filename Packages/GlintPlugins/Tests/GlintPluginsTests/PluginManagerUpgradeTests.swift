import Foundation
import XCTest
@testable import GlintPlugins

final class PluginManagerUpgradeTests: XCTestCase {
    func testRollbackRestoresPreviousPluginVersion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)
        let first = manifest(version: "1.0.0")
        let second = manifest(version: "2.0.0")

        _ = try await manager.installLocalPlugin(
            at: try sourceDirectory(first, root: root)
        )
        _ = try await manager.installPreparedPlugin(
            at: try sourceDirectory(second, root: root),
            keepBackup: true
        )
        let installedAfterUpdate = await manager.installedPlugin(
            id: first.id
        )?.version
        XCTAssertEqual(installedAfterUpdate, second.version)

        try await manager.rollbackPendingUpgrade()

        let installedAfterRollback = await manager.installedPlugin(
            id: first.id
        )?.version
        XCTAssertEqual(installedAfterRollback, first.version)
    }

    func testCommitKeepsNewPluginVersionAndRemovesBackup() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)
        let first = manifest(version: "1.0.0")
        let second = manifest(version: "2.0.0")

        _ = try await manager.installLocalPlugin(
            at: try sourceDirectory(first, root: root)
        )
        _ = try await manager.installPreparedPlugin(
            at: try sourceDirectory(second, root: root),
            keepBackup: true
        )

        try await manager.commitPendingUpgrade()

        let installedAfterCommit = await manager.installedPlugin(
            id: first.id
        )?.version
        XCTAssertEqual(installedAfterCommit, second.version)
        let plugins = root.appendingPathComponent("plugins")
        let contents = try FileManager.default.contentsOfDirectory(
            at: plugins,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(contents.contains {
            $0.lastPathComponent.hasPrefix(".backup-")
        })
    }

    func testRestartRollsBackUncommittedUpgrade() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)
        let first = manifest(version: "1.0.0")
        let second = manifest(version: "2.0.0")

        _ = try await manager.installLocalPlugin(
            at: try sourceDirectory(first, root: root)
        )
        _ = try await manager.installPreparedPlugin(
            at: try sourceDirectory(second, root: root),
            keepBackup: true
        )

        let restarted = PluginManager(baseDirectory: root)
        let restoredVersion = await restarted.installedPlugin(
            id: first.id
        )?.version

        XCTAssertEqual(restoredVersion, first.version)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlintPluginUpgradeTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func manifest(version: String) -> PluginManifest {
        PluginManifest(
            id: "test-plugin",
            type: .dictionary,
            name: "Test Plugin",
            version: version,
            runtime: "sqlite-v1",
            capabilities: ["word"],
            languages: ["zh-Hans", "en"],
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.invalid/test-plugin.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
        )
    }

    private func sourceDirectory(
        _ manifest: PluginManifest,
        root: URL
    ) throws -> URL {
        let source = root.appendingPathComponent(
            "source-\(manifest.version)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(
            to: source.appendingPathComponent("manifest.json")
        )
        return source
    }
}
