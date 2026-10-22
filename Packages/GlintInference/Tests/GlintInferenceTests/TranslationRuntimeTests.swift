import Foundation
import GlintCore
import XCTest
@testable import GlintInference

final class TranslationRuntimeTests: XCTestCase {
    func testFailedPreparationReportsDetailedErrorAndIsNotUsable() async throws {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-ct2-\(UUID().uuidString)")
        let runtime = TranslationRuntime { modelID in
            .ctranslate2(
                modelID: modelID,
                directory: missingDirectory
            )
        }

        let error = await runtime.prepare(modelID: "broken-ct2")
        let lastError = await runtime.lastError

        XCTAssertNotNil(error)
        XCTAssertEqual(lastError, error)
        do {
            _ = try await runtime.translate(
                Candidate(
                    text: "你好",
                    kind: .word,
                    confidence: 1
                )
            )
            XCTFail("A failed model must not be used")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("模型目录不存在")
            )
        }
    }

    func testBundledOPUSModelLoadsAndTranslates() async throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let pluginDirectory = repositoryRoot.appendingPathComponent(
            "Resources/Plugins/mt-opus-zh-en",
            isDirectory: true
        )
        let modelDirectory = pluginDirectory.appendingPathComponent(
            "model",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip(
                "Run scripts/prepare_opus_model.sh before package tests."
            )
        }

        let engine = try CTranslate2Engine(
            modelDirectory: modelDirectory,
            libraryURL: pluginDirectory.appendingPathComponent(
                "bin/libglintct2.dylib"
            )
        )
        let result = try await engine.translate(
            Candidate(
                text: "今天天气不错",
                kind: .sentence,
                confidence: 1
            )
        )

        XCTAssertEqual(result?.text, "It's a nice day.")
    }

    func testBrokenSelectedModelFallsBackToBundledOPUS() async throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let pluginDirectory = repositoryRoot.appendingPathComponent(
            "Resources/Plugins/mt-opus-zh-en",
            isDirectory: true
        )
        let modelDirectory = pluginDirectory.appendingPathComponent(
            "model",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip(
                "Run scripts/prepare_opus_model.sh before package tests."
            )
        }

        let suiteName = "GlintTranslationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        TranslationModelSelection.select("broken-optional-model", in: defaults)
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-ct2-\(UUID().uuidString)")
        let runtime = TranslationRuntime(
            defaults: defaults
        ) { modelID in
            if modelID == TranslationModelSelection.defaultModelID {
                return .ctranslate2(
                    modelID: modelID,
                    directory: modelDirectory
                )
            }
            return .ctranslate2(
                modelID: modelID,
                directory: missingDirectory
            )
        }

        let preparationError = await runtime.prepare(
            modelID: "broken-optional-model"
        )
        XCTAssertNotNil(preparationError)

        let result = try await runtime.translate(
            Candidate(
                text: "今天天气不错",
                kind: .sentence,
                confidence: 1
            )
        )
        XCTAssertEqual(result?.text, "It's a nice day.")
    }
}
