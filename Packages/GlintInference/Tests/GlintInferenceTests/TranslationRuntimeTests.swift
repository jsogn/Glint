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

    func testInstalledOPUSPluginLoadsAndTranslates() async throws {
        let support = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        let modelDirectory = support.appendingPathComponent(
            "Glint/plugins/mt-opus-zh-en/model",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip("Development OPUS plugin is not installed")
        }

        let engine = try CTranslate2Engine(modelDirectory: modelDirectory)
        let result = try await engine.translate(
            Candidate(
                text: "你好",
                kind: .word,
                confidence: 1
            )
        )

        XCTAssertFalse(result?.text.isEmpty ?? true)
    }
}
