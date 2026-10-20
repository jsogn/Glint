import Foundation
import GlintCore
import GlintPlugins
import XCTest
@testable import GlintUI

final class OCREngineModelTests: XCTestCase {
    @MainActor
    func testActiveOCRPluginFallsBackToVisionWhenRemoved() async throws {
        let (root, manager) = try await makeInstalledOCRTestPlugin()
        defer { try? FileManager.default.removeItem(at: root) }

        let (defaults, removeDefaults) = try makeDefaults()
        defer { removeDefaults() }
        let preferences = OCRRecognitionPreferences(
            primaryModelID: "ocr-test",
            backupModelID: nil,
            strategy: .primaryOnly
        )
        preferences.save(to: defaults)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        var configured: [OCRRecognitionPreferences] = []
        model.configureOCRRecognitionAction = { preferences in
            configured.append(preferences)
            return nil
        }

        await model.refreshPlugins()
        XCTAssertEqual(
            model.ocrRecognitionPreferences.primaryModelID,
            "ocr-test"
        )

        let activePlugin = try XCTUnwrap(model.ocrPlugins.first)
        await model.uninstallPlugin(activePlugin)
        let stillInstalled = await manager.installedPlugins()
        XCTAssertTrue(stillInstalled.contains { $0.id == "ocr-test" })

        try await manager.remove(id: "ocr-test")
        await model.refreshPlugins()

        XCTAssertEqual(
            model.ocrRecognitionPreferences.primaryModelID,
            OCRRecognitionPreferences.visionModelID
        )
        XCTAssertEqual(
            configured.last?.primaryModelID,
            OCRRecognitionPreferences.visionModelID
        )
    }

    @MainActor
    func testBackupOCRPluginCannotBeUninstalled() async throws {
        let (root, manager) = try await makeInstalledOCRTestPlugin()
        defer { try? FileManager.default.removeItem(at: root) }

        let (defaults, removeDefaults) = try makeDefaults()
        defer { removeDefaults() }
        OCRRecognitionPreferences(
            primaryModelID: OCRRecognitionPreferences.visionModelID,
            backupModelID: "ocr-test",
            strategy: .automaticFallback
        ).save(to: defaults)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        model.configureOCRRecognitionAction = { _ in nil }
        await model.refreshPlugins()

        let plugin = try XCTUnwrap(model.ocrPlugins.first)
        await model.uninstallPlugin(plugin)
        let installed = await manager.installedPlugins()
        XCTAssertTrue(installed.contains { $0.id == "ocr-test" })
        XCTAssertEqual(
            model.ocrRecognitionPreferences.backupModelID,
            "ocr-test"
        )

        try await manager.remove(id: "ocr-test")
        await model.refreshPlugins()
        XCTAssertNil(model.ocrRecognitionPreferences.backupModelID)
        XCTAssertEqual(
            model.ocrRecognitionPreferences.primaryModelID,
            OCRRecognitionPreferences.visionModelID
        )
    }

    @MainActor
    private func makeInstalledOCRTestPlugin() async throws
        -> (URL, PluginManager) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintOCREngineModelTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let manifest = PluginManifest(
            id: "ocr-test",
            type: .ocr,
            name: "Test OCR",
            version: "1.0",
            runtime: "onnxruntime",
            capabilities: ["candidate"],
            languages: ["zh-Hans"],
            sizeBytes: 0,
            sha256: "test",
            url: URL(string: "file:///tmp/ocr-test.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
        )
        try JSONEncoder().encode(manifest).write(
            to: source.appendingPathComponent("manifest.json")
        )
        let manager = PluginManager(baseDirectory: root)
        _ = try await manager.installLocalPlugin(at: source)
        return (root, manager)
    }

    @MainActor
    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "GlintOCREngineModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (
            defaults,
            {
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }
}
