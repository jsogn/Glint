import CryptoKit
import Foundation
import GlintCore
import GlintPlugins
import XCTest
@testable import GlintUI

final class MainWindowModelTests: XCTestCase {
    @MainActor
    func testBuiltInDictionaryIsVisibleAndCannotBeUninstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintBundledPluginTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintBundledPluginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manifest = dictionaryManifest()
        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [manifest],
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()
        XCTAssertEqual(model.dictionaryPlugins.map(\.id), [manifest.id])

        var dictionaryRefreshCount = 0
        model.dictionaryConfigurationChangedAction = {
            dictionaryRefreshCount += 1
        }
        await model.uninstallPlugin(manifest)
        XCTAssertEqual(dictionaryRefreshCount, 0)
        let managedPlugins = await manager.installedPlugins()
        XCTAssertTrue(managedPlugins.isEmpty)
    }

    @MainActor
    func testBundledTranslationIsActiveAndExcludedFromCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintBundledTranslationTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintBundledTranslationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manifest = translationManifest(
            id: TranslationModelSelection.defaultModelID,
            source: .bundled
        )
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode([manifest]).write(to: catalogURL)
        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [manifest],
            catalogURL: catalogURL,
            defaults: defaults
        )

        await model.refreshPlugins()

        XCTAssertEqual(model.translationPlugins.map(\.id), [manifest.id])
        XCTAssertEqual(model.activeModelID, manifest.id)
        XCTAssertEqual(model.translationSummary, manifest.name)
        XCTAssertTrue(model.availablePlugins.isEmpty)

        await model.uninstallPlugin(manifest)
        let managedPlugins = await manager.installedPlugins()
        XCTAssertTrue(managedPlugins.isEmpty)
    }

    @MainActor
    func testOptionalDictionaryUninstallRefreshesRoutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintOptionalDictionaryTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintOptionalDictionaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manifest = dictionaryManifest(
            id: "dict-optional-test",
            source: .catalog
        )
        try await install(manifest, using: PluginManager(
            baseDirectory: root
        ), root: root)
        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()

        var dictionaryRefreshCount = 0
        model.dictionaryConfigurationChangedAction = {
            dictionaryRefreshCount += 1
        }
        await model.uninstallPlugin(manifest)

        XCTAssertEqual(dictionaryRefreshCount, 1)
        let managedPlugins = await manager.installedPlugins()
        XCTAssertTrue(managedPlugins.isEmpty)
    }

    @MainActor
    func testRequestPermissionsForwardsToAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintMainWindowModelTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintMainWindowModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        XCTAssertEqual(model.candidateSummary, "系统候选词")
        var requestCount = 0
        model.requestPermissionsAction = {
            requestCount += 1
        }

        model.requestPermissions()

        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testOpenAccessibilitySettingsForwardsToAction() throws {
        let suiteName = "GlintMainWindowModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = MainWindowModel(
            catalogURL: nil,
            defaults: defaults
        )
        var openSettingsCount = 0
        model.openAccessibilitySettingsAction = {
            openSettingsCount += 1
        }

        model.openAccessibilitySettings()

        XCTAssertEqual(openSettingsCount, 1)
    }

    func testCatalogUpdatePolicyHonorsSuccessAndFailureCooldowns() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(
            CatalogUpdatePolicy.shouldCheck(
                force: false,
                now: now,
                lastSuccess: now.addingTimeInterval(6 * 60 * 60 - 1),
                lastFailure: nil
            )
        )
        XCTAssertTrue(
            CatalogUpdatePolicy.shouldCheck(
                force: false,
                now: now,
                lastSuccess: now.addingTimeInterval(-6 * 60 * 60),
                lastFailure: nil
            )
        )
        XCTAssertFalse(
            CatalogUpdatePolicy.shouldCheck(
                force: false,
                now: now,
                lastSuccess: now.addingTimeInterval(-24 * 60 * 60),
                lastFailure: now.addingTimeInterval(-15 * 60 + 1)
            )
        )
        XCTAssertTrue(
            CatalogUpdatePolicy.shouldCheck(
                force: true,
                now: now,
                lastSuccess: now,
                lastFailure: now
            )
        )
    }

    @MainActor
    func testFailedTranslationActivationRollsBackAndCanBeUninstalled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintTranslationActivationTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintTranslationActivationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PluginManager(baseDirectory: root)
        let previous = translationManifest(id: "mt-previous")
        let broken = translationManifest(id: "mt-broken")
        try await install(previous, using: manager, root: root)
        try await install(broken, using: manager, root: root)
        TranslationModelSelection.select(previous.id, in: defaults)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshPlugins()

        var activationCalls: [String] = []
        var releasedModels: [String] = []
        model.activateTranslationModelAction = { modelID in
            activationCalls.append(modelID)
            return modelID == broken.id ? "模型加载失败" : nil
        }
        model.releaseTranslationModelAction = { modelID in
            releasedModels.append(modelID)
        }
        model.activateTranslationModel(broken)

        for _ in 0..<100 where model.translationModelStatusText == "正在加载…" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.activeModelID, previous.id)
        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            previous.id
        )
        XCTAssertEqual(model.translationModelStatusModelID, broken.id)
        XCTAssertEqual(model.translationModelStatusText, "模型加载失败")
        XCTAssertTrue(model.translationModelStatusIsError)
        XCTAssertEqual(activationCalls, [broken.id, previous.id])

        await model.uninstallPlugin(broken)
        let installed = await manager.installedPlugins()
        XCTAssertFalse(installed.contains { $0.id == broken.id })
        XCTAssertEqual(releasedModels, [broken.id])
    }

    @MainActor
    func testCatalogUpdateIsOnlyOfferedWhenCatalogVersionIsNewer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintPluginUpdateTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintPluginUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PluginManager(baseDirectory: root)
        let installed = translationManifest(
            id: "mt-opus-zh-en",
            version: "1.0.0"
        )
        let update = translationManifest(
            id: "mt-opus-zh-en",
            version: "1.2.0"
        )
        try await install(installed, using: manager, root: root)
        TranslationModelSelection.select(installed.id, in: defaults)

        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode([update]).write(to: catalogURL)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: catalogURL,
            defaults: defaults
        )

        await model.refreshPlugins()

        XCTAssertEqual(
            model.update(for: update),
            PluginUpdateInfo(
                currentVersion: "1.0.0",
                availableVersion: "1.2.0"
            )
        )
        XCTAssertEqual(model.availablePlugins.map(\.version), ["1.2.0"])
    }

    @MainActor
    func testFailedActiveTranslationUpdateRollsBackPluginAndRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintActivePluginUpdateTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintActivePluginUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PluginManager(baseDirectory: root)
        let first = translationManifest(
            id: "mt-update-test",
            version: "1.0.0",
            runtime: "ctranslate2"
        )
        try await install(first, using: manager, root: root)
        TranslationModelSelection.select(first.id, in: defaults)

        let secondSource = root.appendingPathComponent(
            "second-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: secondSource,
            withIntermediateDirectories: true
        )
        let embeddedSecond = translationManifest(
            id: first.id,
            version: "2.0.0",
            runtime: "ctranslate2"
        )
        try JSONEncoder().encode(embeddedSecond).write(
            to: secondSource.appendingPathComponent("manifest.json")
        )
        let archive = root.appendingPathComponent("update.zip")
        try createArchive(from: secondSource, at: archive)
        let archiveData = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        let second = PluginManifest(
            id: first.id,
            type: .translation,
            name: first.name,
            version: "2.0.0",
            runtime: "ctranslate2",
            capabilities: first.capabilities,
            languages: first.languages,
            sizeBytes: Int64(archiveData.count),
            sha256: digest,
            url: archive,
            license: first.license,
            minRAMBytes: first.minRAMBytes,
            quality: first.quality,
            recommended: false
        )
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode([second]).write(to: catalogURL)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: catalogURL,
            defaults: defaults
        )
        await model.refreshPlugins()
        var activationCount = 0
        model.activateTranslationModelAction = { _ in
            activationCount += 1
            return activationCount == 1 ? "新版本加载失败" : nil
        }

        model.installPlugin(second)
        for _ in 0..<200 where model.isInstalling != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let installedVersion = await manager.installedPlugin(
            id: first.id
        )?.version
        XCTAssertEqual(installedVersion, first.version)
        XCTAssertEqual(
            model.translationModelStatusText,
            "更新失败，已恢复旧版本：新版本加载失败"
        )
        XCTAssertEqual(model.translationModelStatusModelID, first.id)
        XCTAssertEqual(activationCount, 2)
    }

    @MainActor
    private func translationManifest(
        id: String,
        version: String = "1.0",
        runtime: String = "mlx",
        source: PluginSource = .catalog
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .translation,
            name: id,
            version: version,
            runtime: runtime,
            capabilities: ["sentence"],
            languages: ["zh-Hans", "en"],
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.invalid/\(id).zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false,
            source: source
        )
    }

    @MainActor
    private func dictionaryManifest(
        id: String = "dict-bundled-test",
        source: PluginSource = .bundled
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .dictionary,
            name: "Bundled Test Dictionary",
            version: "1.0",
            runtime: "sqlite-v1",
            capabilities: ["word"],
            languages: ["zh-Hans", "en"],
            sizeBytes: 10,
            sha256: "test",
            url: URL(string: "https://example.invalid/dictionary.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "basic",
            recommended: true,
            source: source
        )
    }

    @MainActor
    private func install(
        _ manifest: PluginManifest,
        using manager: PluginManager,
        root: URL
    ) async throws {
        let source = root.appendingPathComponent(
            "source-\(manifest.id)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(manifest).write(
            to: source.appendingPathComponent("manifest.json")
        )
        _ = try await manager.installLocalPlugin(at: source)
    }

    @MainActor
    private func createArchive(from source: URL, at archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--keepParent",
            source.path,
            archive.path,
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
