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
            source: .bundled,
            summary: "内置测试模型"
        )
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(
            ["plugins": [manifest]]
        ).write(to: catalogURL)
        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [manifest],
            catalogURL: catalogURL,
            defaults: defaults
        )

        await model.refreshInstalledPlugins()
        await model.checkForCatalogUpdates(force: true)

        XCTAssertEqual(model.translationPlugins.map(\.id), [manifest.id])
        XCTAssertEqual(model.activeModelID, manifest.id)
        XCTAssertEqual(model.translationSummary, manifest.name)
        XCTAssertEqual(
            model.translationCharacterSummary,
            "内置测试模型"
        )
        XCTAssertTrue(model.availablePlugins.isEmpty)

        await model.uninstallPlugin(manifest)
        let managedPlugins = await manager.installedPlugins()
        XCTAssertTrue(managedPlugins.isEmpty)
    }

    @MainActor
    func testInstalledCoreDictionaryOverlayReplacesBundledVersion()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionaryOverlayTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let bundled = dictionaryManifest(
            id: "dict-cedict",
            version: "2026.10.3"
        )
        let overlay = dictionaryManifest(
            id: "dict-cedict",
            version: "2026.10.28",
            sourceDate: "2026-10-28T00:15:09Z"
        )
        let manager = PluginManager(baseDirectory: root)
        try await install(overlay, using: manager, root: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [bundled],
            catalogURL: nil
        )

        await model.refreshInstalledPlugins()

        XCTAssertEqual(model.dictionaryPlugins.count, 1)
        XCTAssertEqual(
            model.dictionaryPlugins.first?.version,
            "2026.10.28"
        )
        XCTAssertEqual(
            model.dictionaryPlugins.first?.sourceDate,
            "2026-10-28T00:15:09Z"
        )
    }

    @MainActor
    func testManualCoreDictionaryUpdateShowsStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionaryUpdateTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [
                dictionaryManifest(id: "dict-cedict")
            ],
            catalogURL: nil
        )
        var refreshCount = 0
        model.dictionaryConfigurationChangedAction = {
            refreshCount += 1
        }
        var checkedUpdateKind: CoreDictionaryUpdateKind?
        model.checkCoreDictionaryUpdateAction = { updateKind in
            checkedUpdateKind = updateKind
            return "CC-CEDICT 已是最新"
        }

        model.checkCoreDictionaryUpdate(
            "dict-cedict",
            kind: .cedict
        )
        for _ in 0..<200
        where model.coreDictionaryUpdateState(
            for: "dict-cedict"
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            model.coreDictionaryUpdateState(
                for: "dict-cedict"
            )?.statusText,
            "CC-CEDICT 已是最新"
        )
        XCTAssertEqual(checkedUpdateKind, .cedict)
        XCTAssertEqual(
            model.coreDictionaryUpdateState(
                for: "dict-cedict"
            )?.isError,
            false
        )
        XCTAssertEqual(refreshCount, 1)
    }

    @MainActor
    func testCoreDictionaryUpdateCanBeCancelled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionaryCancelTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            builtInPlugins: [
                dictionaryManifest(id: "dict-cedict")
            ],
            catalogURL: nil
        )
        model.checkCoreDictionaryUpdateAction = { _ in
            try await Task.sleep(for: .seconds(10))
            return "unexpected"
        }

        model.checkCoreDictionaryUpdate(
            "dict-cedict",
            kind: .cedict
        )
        try await Task.sleep(for: .milliseconds(20))
        model.cancelCoreDictionaryUpdate("dict-cedict")
        for _ in 0..<200
        where model.coreDictionaryUpdateState(
            for: "dict-cedict"
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNil(
            model.coreDictionaryUpdateState(for: "dict-cedict")
        )
    }

    @MainActor
    func testCoreDictionaryUpdatesTrackEachDictionarySeparately()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionaryIndependentTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            builtInPlugins: [
                dictionaryManifest(id: "dict-cedict"),
                dictionaryManifest(id: "dict-ecdict"),
            ],
            catalogURL: nil
        )
        model.checkCoreDictionaryUpdateAction = { updateKind in
            if updateKind == .ecdict {
                return "ECDICT 已是最新"
            }
            return "CC-CEDICT 已是最新"
        }

        model.checkCoreDictionaryUpdate(
            "dict-cedict",
            kind: .cedict
        )
        for _ in 0..<200
        where model.coreDictionaryUpdateState(
            for: "dict-cedict"
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            model.coreDictionaryUpdateState(
                for: "dict-cedict"
            )?.statusText,
            "CC-CEDICT 已是最新"
        )

        model.checkCoreDictionaryUpdate(
            "dict-ecdict",
            kind: .ecdict
        )
        for _ in 0..<200
        where model.coreDictionaryUpdateState(
            for: "dict-ecdict"
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(
            model.coreDictionaryUpdateState(
                for: "dict-ecdict"
            )?.statusText,
            "ECDICT 已是最新"
        )
    }

    @MainActor
    func testCoreDictionaryUpdatesAreGloballySerialized() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionarySerializationTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            builtInPlugins: [
                dictionaryManifest(id: "dict-cedict"),
                dictionaryManifest(id: "dict-ecdict"),
            ],
            catalogURL: nil
        )
        var checkedKinds: [CoreDictionaryUpdateKind] = []
        model.checkCoreDictionaryUpdateAction = { updateKind in
            checkedKinds.append(updateKind)
            try await Task.sleep(for: .seconds(10))
            return "unexpected"
        }

        model.checkCoreDictionaryUpdate(
            "dict-cedict",
            kind: .cedict
        )
        try await Task.sleep(for: .milliseconds(20))
        model.checkCoreDictionaryUpdate(
            "dict-ecdict",
            kind: .ecdict
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(checkedKinds, [.cedict])
        XCTAssertNil(
            model.coreDictionaryUpdateState(for: "dict-ecdict")
        )

        model.cancelCoreDictionaryUpdate("dict-cedict")
        for _ in 0..<200 where model.hasActiveCoreDictionaryUpdate {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    func testFailedLocalImportRestoresPreviousModelAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintLocalImportTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(
            "ImportedModel",
            isDirectory: true
        )
        try makeLocalModelDirectory(source)

        let suiteName = "GlintLocalImportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let bundled = translationManifest(
            id: TranslationModelSelection.defaultModelID,
            source: .bundled
        )
        TranslationModelSelection.select(bundled.id, in: defaults)
        let manager = PluginManager(baseDirectory: root)
        let model = MainWindowModel(
            pluginManager: manager,
            builtInPlugins: [bundled],
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()

        var activationCalls: [String] = []
        model.activateTranslationModelAction = { modelID in
            activationCalls.append(modelID)
            return modelID == bundled.id ? nil : "新模型加载失败"
        }

        model.importLocalTranslationModel(from: source)
        for _ in 0..<200 where model.isImportingLocalModel {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.activeModelID, bundled.id)
        XCTAssertEqual(activationCalls.count, 2)
        XCTAssertEqual(activationCalls.last, bundled.id)
        XCTAssertTrue(
            model.localImportError?.contains("已恢复原模型") == true
        )
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
        try await install(
            manifest,
            using: PluginManager(
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

    @MainActor
    func testLaunchAtLoginUsesSystemStatusAndForwardsActions() throws {
        let suiteName = "GlintLaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = MainWindowModel(
            catalogURL: nil,
            defaults: defaults
        )
        var requestedValues: [Bool] = []
        var refreshCount = 0
        var openSettingsCount = 0
        model.setLaunchAtLoginAction = {
            requestedValues.append($0)
        }
        model.refreshLaunchAtLoginAction = {
            refreshCount += 1
        }
        model.openLoginItemsSettingsAction = {
            openSettingsCount += 1
        }

        model.updateLaunchAtLogin(status: .enabled)
        XCTAssertTrue(model.isLaunchAtLoginEnabled)

        model.setLaunchAtLoginEnabled(false)
        model.refreshLaunchAtLogin()
        model.openLoginItemsSettings()
        XCTAssertEqual(requestedValues, [false])
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(openSettingsCount, 1)

        model.updateLaunchAtLogin(
            status: .requiresApproval,
            error: "需要允许登录项"
        )
        XCTAssertFalse(model.isLaunchAtLoginEnabled)
        XCTAssertTrue(model.launchAtLoginRequiresApproval)
        XCTAssertEqual(model.launchAtLoginError, "需要允许登录项")

        model.updateLaunchAtLogin(
            status: .unavailable,
            error: "不可用"
        )
        model.setLaunchAtLoginEnabled(true)
        XCTAssertEqual(requestedValues, [false, true])
    }

    @MainActor
    func testActiveInputMethodUsesSystemDisplayName() throws {
        let suiteName =
            "GlintInputMethodDisplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(
                forName: suiteName
            )
        }
        let model = MainWindowModel(
            catalogURL: nil,
            defaults: defaults
        )
        let identity = InputMethodIdentity(
            bundleIdentifier:
                InputMethodIdentifier.weTypeBundle,
            inputSourceIdentifier:
                InputMethodIdentifier.weTypePinyinMode,
            sourceType: "TISTypeKeyboardInputMode",
            localizedName: "微信输入法"
        )

        model.updateActiveInputMethod(identity)

        XCTAssertEqual(
            model.activeInputMethodName,
            "微信输入法"
        )
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
        await model.refreshInstalledPlugins()
        await model.checkForCatalogUpdates(force: true)

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
        XCTAssertEqual(
            model.translationAttentionMessage,
            "翻译模型需要检查，请在插件与模型中查看。"
        )
        XCTAssertEqual(model.translationAttentionDetail, "模型加载失败")
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
        try JSONEncoder().encode(
            ["plugins": [update]]
        ).write(to: catalogURL)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: catalogURL,
            defaults: defaults
        )

        await model.refreshInstalledPlugins()
        await model.checkForCatalogUpdates(force: true)

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
    func testDownloadedCTranslateUpdateIsRejectedWithoutReplacingVersion() async throws {
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
            sizeBytes: Int64(archiveData.count),
            sha256: digest,
            url: archive,
            license: first.license,
            minRAMBytes: first.minRAMBytes
        )
        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(
            ["plugins": [second]]
        ).write(to: catalogURL)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: catalogURL,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()
        await model.checkForCatalogUpdates(force: true)
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
        XCTAssertEqual(model.catalogError, "插件使用了不支持的运行环境")
        XCTAssertEqual(activationCount, 0)
    }

    @MainActor
    func testTranslationModelUpdateCheckHonorsCooldown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelUpdateCooldown-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintModelUpdateCooldown.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = PluginManager(baseDirectory: root)
        let installed = PluginManifest(
            id: "cooldown-test-model",
            type: .translation,
            name: "Cooldown Test Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/cooldown"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "current-revision"
        )
        try await install(installed, using: manager, root: root)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()
        var checkCount = 0
        model.checkTranslationModelUpdateAction = { _ in
            checkCount += 1
            return nil
        }

        model.checkTranslationModelUpdate(installed)
        try await waitForTranslationModelUpdate(
            installed.id,
            in: model
        )
        model.checkTranslationModelUpdate(installed)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(checkCount, 1)
    }

    @MainActor
    func testManualTranslationModelUpdateCheckBypassesCooldown()
        async throws
    {
        let fixture = try await makeCatalogTranslationFixture(
            prefix: "GlintModelManualUpdate"
        )
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        var checkCount = 0
        fixture.model.checkTranslationModelUpdateAction = { _ in
            checkCount += 1
            return nil
        }

        fixture.model.checkTranslationModelUpdate(fixture.manifest)
        try await waitForTranslationModelUpdate(
            fixture.manifest.id,
            in: fixture.model
        )
        fixture.model.checkTranslationModelUpdate(
            fixture.manifest,
            force: true
        )
        try await waitForTranslationModelUpdate(
            fixture.manifest.id,
            in: fixture.model
        )

        XCTAssertEqual(checkCount, 2)
    }

    @MainActor
    func testTranslationModelUpdateStateRestoresFromCache() async throws {
        let fixture = try await makeCatalogTranslationFixture(
            prefix: "GlintModelUpdateCache"
        )
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.model.checkTranslationModelUpdateAction = { _ in nil }

        fixture.model.checkTranslationModelUpdate(fixture.manifest)
        try await waitForTranslationModelUpdate(
            fixture.manifest.id,
            in: fixture.model
        )
        let reloaded = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: fixture.root),
            catalogURL: nil,
            defaults: fixture.defaults
        )
        await reloaded.refreshInstalledPlugins()

        XCTAssertEqual(
            reloaded.translationModelUpdateState(
                for: fixture.manifest.id
            )?.statusText,
            "已是最新"
        )
    }

    @MainActor
    func testLaunchUpdateCheckOnlyChecksActiveTranslationModel()
        async throws
    {
        let fixture = try await makeCatalogTranslationFixture(
            prefix: "GlintModelActiveUpdate"
        )
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let other = PluginManifest(
            id: "other-update-model",
            type: .translation,
            name: "Other Update Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/other-update"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "other-revision"
        )
        try await install(
            other,
            using: PluginManager(baseDirectory: fixture.root),
            root: fixture.root
        )
        TranslationModelSelection.select(
            fixture.manifest.id,
            in: fixture.defaults
        )
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: fixture.root),
            catalogURL: nil,
            defaults: fixture.defaults
        )
        await model.refreshInstalledPlugins()
        var checkedModelIDs: [String] = []
        model.checkTranslationModelUpdateAction = { plugin in
            checkedModelIDs.append(plugin.id)
            return nil
        }

        model.checkActiveTranslationModelUpdateAfterLaunch()
        try await waitForTranslationModelUpdate(
            fixture.manifest.id,
            in: model
        )
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(checkedModelIDs, [fixture.manifest.id])
    }

    @MainActor
    func testTranslationModelUpdateShowsLatestUpstreamRevision() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelUpdateState-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PluginManager(baseDirectory: root)
        let installed = PluginManifest(
            id: "upstream-test-model",
            type: .translation,
            name: "Upstream Test Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "old-revision"
        )
        try await install(installed, using: manager, root: root)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil
        )
        await model.refreshInstalledPlugins()
        let updatedManifest = PluginManifest(
            id: installed.id,
            type: installed.type,
            name: installed.name,
            version: installed.version,
            runtime: installed.runtime,
            sizeBytes: 20,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: installed.url,
            license: installed.license,
            minRAMBytes: installed.minRAMBytes,
            revision: "new-revision"
        )
        model.checkTranslationModelUpdateAction = { plugin in
            XCTAssertEqual(plugin.id, installed.id)
            return UpstreamModelUpdate(
                currentRevision: "old-revision",
                latestRevision: "new-revision",
                lastModified: "2026-10-20T10:00:00Z",
                manifest: updatedManifest
            )
        }

        model.checkTranslationModelUpdate(installed)
        for _ in 0..<200
        where model.translationModelUpdateState(
            for: installed.id
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }

        let state = try XCTUnwrap(
            model.translationModelUpdateState(for: installed.id)
        )
        XCTAssertFalse(state.isChecking)
        XCTAssertFalse(state.isError)
        XCTAssertEqual(state.statusText, "上游有新版本")
        XCTAssertEqual(state.update?.latestRevision, "new-revision")
    }

    @MainActor
    func testTranslationModelUpdateReportsUpToDate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelUpToDate-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = PluginManager(baseDirectory: root)
        let installed = PluginManifest(
            id: "upstream-current-model",
            type: .translation,
            name: "Current Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/current"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "current-revision"
        )
        try await install(installed, using: manager, root: root)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil
        )
        await model.refreshInstalledPlugins()
        model.checkTranslationModelUpdateAction = { _ in nil }

        model.checkTranslationModelUpdate(installed)
        for _ in 0..<200
        where model.translationModelUpdateState(
            for: installed.id
        )?.isChecking == true {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            model.translationModelUpdateState(
                for: installed.id
            )?.statusText,
            "已是最新"
        )
    }

    @MainActor
    func testModelMarketSearchUsesLiveUpstreamResults() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketSearch-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = UpstreamModelSummary(
            repository: "mlx-community/Hy-MT2-1.8B-4bit",
            name: "Hy-MT2-1.8B-4bit",
            downloads: 1200,
            likes: 5,
            pipelineTag: "translation",
            tags: ["mlx", "translation"],
            license: "apache-2.0"
        )
        var receivedQuery: String?
        model.searchModelMarketAction = { query in
            receivedQuery = query
            return [result]
        }

        await model.searchModelMarket(query: "Hy-MT2")

        XCTAssertEqual(receivedQuery, "Hy-MT2")
        XCTAssertEqual(model.modelMarketResults, [result])
        XCTAssertFalse(model.isLoadingModelMarket)
        XCTAssertNil(model.modelMarketError)
    }

    @MainActor
    func testModelMarketSearchFailureLeavesUsableState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketOffline-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        model.searchModelMarketAction = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await model.searchModelMarket(query: "Qwen3")

        XCTAssertFalse(model.isLoadingModelMarket)
        XCTAssertTrue(model.modelMarketResults.isEmpty)
        XCTAssertTrue(model.modelMarketError?.isEmpty == false)
        XCTAssertNil(model.isInstalling)
    }

    @MainActor
    func testCancellingMarketPreflightClearsBusyState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketCancellation-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        model.prepareModelMarketInstallAction = { _, _ in
            try await Task.sleep(for: .seconds(10))
            throw ModelHubError.unavailable
        }

        model.installModelFromMarket(
            marketResult(repository: "example/cancel")
        )
        XCTAssertEqual(
            model.isPreparingModelMarketInstallID,
            "example/cancel"
        )

        model.cancelModelMarketInstall()
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertNil(model.isPreparingModelMarketInstallID)
        XCTAssertNil(model.modelMarketInstallPreview)
        XCTAssertNil(model.isInstalling)
        XCTAssertNil(model.modelMarketError)
    }

    @MainActor
    func testModelMarketPreparesInstallWithoutStartingDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketPreview-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = marketResult(repository: "example/preview")
        let preparation = marketPreparation(
            for: result,
            sizeBytes: 2_000
        )
        model.availableInstallationSpaceAction = { 100_000 }
        model.prepareModelMarketInstallAction = { _, _ in preparation }

        model.installModelFromMarket(result)
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(model.modelMarketInstallPreview, preparation)
        XCTAssertNil(model.isInstalling)
        XCTAssertNil(model.modelMarketError)

        model.cancelModelMarketInstallPreview()
        XCTAssertNil(model.modelMarketInstallPreview)
    }

    @MainActor
    func testConfirmModelMarketInstallTracksRepositoryAndPlugin()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketConfirm-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = marketResult(repository: "example/confirm")
        let preparation = marketPreparation(
            for: result,
            sizeBytes: 2_000
        )
        model.availableInstallationSpaceAction = { 100_000 }
        model.prepareModelMarketInstallAction = { _, _ in preparation }

        model.installModelFromMarket(result)
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        model.confirmModelMarketInstall()

        XCTAssertEqual(
            model.modelMarketInstallRepository,
            result.repository
        )
        XCTAssertEqual(
            model.modelMarketInstallPluginID,
            preparation.manifest.id
        )
        model.cancelInstallation()
    }

    @MainActor
    func testModelMarketRejectsInsufficientInstallationSpace() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketDisk-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = marketResult(repository: "example/disk")
        model.availableInstallationSpaceAction = { 1_000 }
        XCTAssertEqual(model.availableInstallationSpaceAction(), 1_000)
        model.prepareModelMarketInstallAction = { _, _ in
            self.marketPreparation(for: result, sizeBytes: 2_000)
        }

        model.installModelFromMarket(result)
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(
            model.modelMarketError?.contains("磁盘空间") == true,
            "error=\(String(describing: model.modelMarketError))"
        )
        XCTAssertNil(model.modelMarketInstallPreview)
        XCTAssertNil(model.isInstalling)
    }

    @MainActor
    func testModelMarketShowsPreparationFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketFailure-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = UpstreamModelSummary(
            repository: "example/unsupported",
            name: "unsupported",
            downloads: 0,
            likes: 0,
            pipelineTag: "translation",
            tags: ["mlx"],
            license: nil
        )
        model.prepareModelMarketInstallAction = { _, _ in
            throw ModelHubError.unsupportedModel
        }

        model.installModelFromMarket(result)
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            model.modelMarketError,
            "模型与当前 Glint 运行时不兼容"
        )
        XCTAssertNil(model.isInstalling)
    }

    @MainActor
    func testModelMarketRejectsModelBeyondAvailableMemory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelMarketMemory-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil
        )
        let result = UpstreamModelSummary(
            repository: "example/too-large",
            name: "too-large",
            downloads: 0,
            likes: 0,
            pipelineTag: "translation",
            tags: ["mlx"],
            license: nil
        )
        let manifest = PluginManifest(
            id: "upstream-mlx-too-large",
            type: .translation,
            name: "Too Large",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/too-large"
            )!,
            license: "MIT",
            minRAMBytes: .max,
            revision: "revision"
        )
        model.availableInstallationSpaceAction = { 100_000 }
        model.prepareModelMarketInstallAction = { _, _ in
            ModelInstallPreparation(
                manifest: manifest,
                snapshot: self.marketSnapshot(
                    repository: result.repository,
                    sizeBytes: 2_000
                )
            )
        }

        model.installModelFromMarket(result)
        for _ in 0..<200
        where model.isPreparingModelMarketInstallID != nil {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertTrue(model.modelMarketError?.contains("内存") == true)
        XCTAssertNil(model.modelMarketInstallPreview)
        XCTAssertNil(model.isInstalling)
    }

    @MainActor
    private func marketResult(
        repository: String
    ) -> UpstreamModelSummary {
        UpstreamModelSummary(
            repository: repository,
            name: repository.split(separator: "/").last.map(String.init)
                ?? repository,
            downloads: 0,
            likes: 0,
            pipelineTag: "translation",
            tags: ["mlx", "translation"],
            license: "MIT"
        )
    }

    private func marketPreparation(
        for model: UpstreamModelSummary,
        sizeBytes: Int64
    ) -> ModelInstallPreparation {
        ModelInstallPreparation(
            manifest: PluginManifest(
                id: "upstream-mlx-test",
                type: .translation,
                name: model.name,
                version: "1.0",
                runtime: "mlx",
                sizeBytes: sizeBytes,
                sha256: "HUGGINGFACE_SNAPSHOT",
                url: URL(
                    string: "https://huggingface.co/\(model.repository)"
                )!,
                license: "MIT",
                minRAMBytes: 4_294_967_296,
                revision: "revision"
            ),
            snapshot: marketSnapshot(
                repository: model.repository,
                sizeBytes: sizeBytes
            )
        )
    }

    private func marketSnapshot(
        repository: String,
        sizeBytes: Int64
    ) -> UpstreamModelSnapshot {
        UpstreamModelSnapshot(
            repository: repository,
            revision: "revision",
            lastModified: nil,
            modelType: "qwen3",
            sizeBytes: sizeBytes,
            license: "MIT",
            hasChatTemplate: true,
            parameterCount: 1_000_000_000,
            quantizationBits: 4,
            pipelineTag: "translation"
        )
    }

    @MainActor
    private func translationManifest(
        id: String,
        version: String = "1.0",
        runtime: String = "mlx",
        source: PluginSource = .catalog,
        summary: String? = nil
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .translation,
            name: id,
            version: version,
            runtime: runtime,
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.invalid/\(id).zip")!,
            license: "MIT",
            minRAMBytes: 0,
            summary: summary,
            source: source
        )
    }

    @MainActor
    private func dictionaryManifest(
        id: String = "dict-bundled-test",
        version: String = "1.0",
        source: PluginSource = .bundled,
        sourceDate: String? = nil
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .dictionary,
            name: "Bundled Test Dictionary",
            version: version,
            runtime: "sqlite-v1",
            sizeBytes: 10,
            sha256: "test",
            url: URL(string: "https://example.invalid/dictionary.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            source: source,
            sourceDate: sourceDate
        )
    }

    private func makeLocalModelDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"model_type":"qwen3","architectures":["Qwen3"]}"#.utf8
        ).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(
            to: directory.appendingPathComponent("tokenizer.json")
        )
        try Data(
            "{{ messages }}".utf8
        ).write(
            to: directory.appendingPathComponent("chat_template.jinja")
        )
        try Data(repeating: 1, count: 64).write(
            to: directory.appendingPathComponent("model.safetensors")
        )
    }

    @MainActor
    private func makeCatalogTranslationFixture(
        prefix: String
    ) async throws -> (
        root: URL,
        suiteName: String,
        defaults: UserDefaults,
        manifest: PluginManifest,
        model: MainWindowModel
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let suiteName = "\(prefix).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let manager = PluginManager(baseDirectory: root)
        let installed = PluginManifest(
            id: "\(prefix.lowercased())-model",
            type: .translation,
            name: "\(prefix) Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 10,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/\(prefix)"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "current-revision"
        )
        try await install(installed, using: manager, root: root)
        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        await model.refreshInstalledPlugins()
        return (
            root,
            suiteName,
            defaults,
            installed,
            model
        )
    }

    @MainActor
    private func waitForTranslationModelUpdate(
        _ modelID: String,
        in model: MainWindowModel
    ) async throws {
        for _ in 0..<200 {
            if model.translationModelUpdateState(for: modelID)?.isChecking
                == false
            {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Translation model update check did not finish")
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
        _ = try await manager.installPreparedPlugin(at: source)
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
