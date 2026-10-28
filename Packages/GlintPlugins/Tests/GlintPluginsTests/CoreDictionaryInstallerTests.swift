import Foundation
import XCTest

@testable import GlintPlugins

final class CoreDictionaryInstallerTests: XCTestCase {
    func testValidationFailureRestoresExistingDictionary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent(
            "bundled",
            isDirectory: true
        )
        let existing = root.appendingPathComponent(
            "existing",
            isDirectory: true
        )
        let work = root.appendingPathComponent(
            "work",
            isDirectory: true
        )
        for directory in [bundled, existing, work] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writePlugin(
            version: "1.0.0",
            content: Data("old".utf8),
            directory: bundled
        )
        try writePlugin(
            version: "1.0.0",
            content: Data("old".utf8),
            directory: existing
        )
        let built = work.appendingPathComponent("artifact.sqlite3")
        try Data("new".utf8).write(to: built)
        let manager = PluginManager(baseDirectory: root)
        _ = try await manager.installPreparedPlugin(at: existing)
        let installer = CoreDictionaryInstaller(pluginManager: manager)

        do {
            _ = try await installer.install(
                PreparedCoreDictionaryInstallation(
                    dictionaryID: "dict-test",
                    bundledDirectory: bundled,
                    builtArtifactURL: built,
                    artifactFileName: "artifact.sqlite3",
                    manifestFields: manifestFields(version: "2.0.0"),
                    validate: { _ in false }
                ),
                workDirectory: work
            )
            XCTFail("校验失败不应提交安装")
        } catch {
            XCTAssertTrue(error is CoreDictionaryInstallError)
        }

        let installed = await manager.installedPlugin(id: "dict-test")
        XCTAssertEqual(installed?.version, "1.0.0")
        let installedDirectory = await manager.pluginDirectory(
            for: "dict-test"
        )
        XCTAssertEqual(
            try Data(
                contentsOf: installedDirectory.appendingPathComponent(
                    "artifact.sqlite3"
                )
            ),
            Data("old".utf8)
        )
    }

    private func writePlugin(
        version: String,
        content: Data,
        directory: URL
    ) throws {
        try content.write(
            to: directory.appendingPathComponent("artifact.sqlite3")
        )
        let manifest = PluginManifest(
            id: "dict-test",
            type: .dictionary,
            name: "Test Dictionary",
            version: version,
            runtime: "sqlite-v1",
            sizeBytes: Int64(content.count),
            sha256: "test",
            url: URL(string: "https://example.invalid/dict-test")!,
            license: "MIT",
            minRAMBytes: 0,
            source: .bundled
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(
                PluginManifest.fileName
            )
        )
    }

    private func manifestFields(
        version: String
    ) -> CoreDictionaryManifestFields {
        CoreDictionaryManifestFields(
            name: "Test Dictionary",
            version: version,
            runtime: "sqlite-v1",
            url: URL(string: "https://example.invalid/dict-test")!,
            license: "MIT",
            minRAMBytes: 0,
            summary: nil,
            sourceDate: "2026-10-29T00:00:00Z",
            coreUpdateKind: .cedict
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionaryInstallerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
