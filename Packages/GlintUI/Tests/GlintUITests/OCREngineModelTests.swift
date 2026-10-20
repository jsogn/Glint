import Foundation
import GlintCore
import GlintPlugins
import XCTest
@testable import GlintUI

final class OCREngineModelTests: XCTestCase {
    @MainActor
    func testActiveOCRPluginFallsBackToVisionWhenRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintOCREngineModelTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
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

        let suiteName = "GlintOCREngineModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OCREngineSelection.select("ocr-test", in: defaults)

        let model = MainWindowModel(
            pluginManager: manager,
            catalogURL: nil,
            defaults: defaults
        )
        var configured: [String] = []
        model.activateOCREngineAction = { engineID, _ in
            configured.append(engineID)
            return nil
        }

        await model.refreshPlugins()
        XCTAssertEqual(model.activeOCREngineID, "ocr-test")

        let activePlugin = try XCTUnwrap(model.ocrPlugins.first)
        await model.uninstallPlugin(activePlugin)
        let stillInstalled = await manager.installedPlugins()
        XCTAssertFalse(stillInstalled.isEmpty)

        try await manager.remove(id: "ocr-test")
        await model.refreshPlugins()

        XCTAssertEqual(
            model.activeOCREngineID,
            OCREngineSelection.visionEngineID
        )
        XCTAssertEqual(configured.last, OCREngineSelection.visionEngineID)
    }
}
