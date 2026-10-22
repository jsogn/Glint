import Foundation
import XCTest
@testable import GlintPlugins

final class LocalModelImportServiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintLocalModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testInspectsAndImportsMLXFolder() async throws {
        let source = try makeValidModel(named: "TinyModel")
        let support = root.appendingPathComponent("support", isDirectory: true)
        let manager = PluginManager(baseDirectory: support)
        let service = LocalModelImportService(manager: manager)

        let candidate = try await service.inspect(directory: source)
        XCTAssertEqual(candidate.modelType, "qwen3")
        XCTAssertTrue(candidate.hasChatTemplate)
        XCTAssertGreaterThan(candidate.sizeBytes, 0)

        let manifest = try await service.importModel(from: source)
        XCTAssertEqual(manifest.name, "TinyModel")
        XCTAssertEqual(manifest.type, .translation)
        XCTAssertEqual(manifest.runtime, "mlx")
        XCTAssertEqual(manifest.source, .local)
        XCTAssertEqual(manifest.promptProfile, .generic)
        XCTAssertTrue(manifest.id.hasPrefix("user-mlx-"))

        let installed = await manager.pluginDirectory(for: manifest.id)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("manifest.json").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installed.appendingPathComponent("model/config.json").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testRejectsFolderWithoutWeights() async throws {
        let source = root.appendingPathComponent("BrokenModel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data(#"{"model_type":"qwen3"}"#.utf8).write(
            to: source.appendingPathComponent("config.json")
        )
        try Data("{}".utf8).write(
            to: source.appendingPathComponent("tokenizer.json")
        )

        let service = LocalModelImportService()
        do {
            _ = try await service.inspect(directory: source)
            XCTFail("Expected inspect to reject the model")
        } catch {
            XCTAssertEqual(error as? LocalModelImportError, .missingWeights)
        }
    }

    func testRejectsFolderWithoutChatTemplate() async throws {
        let source = try makeValidModel(named: "NoTemplate")
        try FileManager.default.removeItem(
            at: source.appendingPathComponent("tokenizer_config.json")
        )

        let service = LocalModelImportService()
        do {
            _ = try await service.inspect(directory: source)
            XCTFail("Expected inspect to reject the model")
        } catch {
            XCTAssertEqual(
                error as? LocalModelImportError,
                .missingChatTemplate
            )
        }
    }

    func testReimportAtomicallyReplacesExistingModel() async throws {
        let source = try makeValidModel(named: "RepeatModel")
        let support = root.appendingPathComponent("support", isDirectory: true)
        let manager = PluginManager(baseDirectory: support)
        let service = LocalModelImportService(manager: manager)

        let first = try await service.importModel(from: source)
        try Data(repeating: 2, count: 512).write(
            to: source.appendingPathComponent("model.safetensors"),
            options: .atomic
        )
        let second = try await service.importModel(from: source)

        XCTAssertEqual(first.id, second.id)
        let installed = await manager.pluginDirectory(for: second.id)
        let data = try Data(
            contentsOf: installed.appendingPathComponent(
                "model/model.safetensors"
            )
        )
        XCTAssertEqual(data.count, 512)
        let plugins = await manager.installedPlugins()
        XCTAssertEqual(plugins.filter { $0.id == second.id }.count, 1)
    }

    func testImportedModelIsIndependentFromSourceMutation() async throws {
        let source = try makeValidModel(named: "SourceMutation")
        let support = root.appendingPathComponent("support", isDirectory: true)
        let manager = PluginManager(baseDirectory: support)
        let service = LocalModelImportService(manager: manager)
        let manifest = try await service.importModel(from: source)
        let installed = await manager.pluginDirectory(for: manifest.id)
            .appendingPathComponent("model/model.safetensors")
        let before = try Data(contentsOf: installed)

        let handle = try FileHandle(
            forWritingTo: source.appendingPathComponent("model.safetensors")
        )
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 9, count: before.count))
        try handle.close()

        XCTAssertEqual(try Data(contentsOf: installed), before)
    }

    private func makeValidModel(named name: String) throws -> URL {
        let source = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data(
            #"{"model_type":"qwen3","architectures":["Qwen3ForCausalLM"]}"#.utf8
        ).write(to: source.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(
            to: source.appendingPathComponent("tokenizer.json")
        )
        try Data(
            #"{"chat_template":"{{ messages }}"}"#.utf8
        ).write(to: source.appendingPathComponent("tokenizer_config.json"))
        try Data(repeating: 1, count: 256).write(
            to: source.appendingPathComponent("model.safetensors")
        )
        return source
    }

}
