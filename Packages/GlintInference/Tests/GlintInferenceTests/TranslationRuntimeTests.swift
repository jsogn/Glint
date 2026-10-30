import Foundation
import GlintCore
import XCTest
import os
@testable import GlintInference

final class TranslationRuntimeTests: XCTestCase {
    func testSystemModelUsesInjectedEngineWithoutResolvingPlugin() async throws {
        let suiteName = "GlintTranslationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        TranslationModelSelection.select(
            SystemTranslationModel.appleTranslationID,
            in: defaults
        )
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let runtime = TranslationRuntime(
            defaults: defaults,
            systemEngine: StubTranslationEngine(
                output: "System translation"
            ),
            modelResolver: { _ in
                resolverCalls.withLock { $0 += 1 }
                return nil
            }
        )

        await runtime.prepareSelectedModel()
        let result = try await runtime.translate(
            Candidate(text: "你好", kind: .word)
        )

        XCTAssertEqual(result?.text, "System translation")
        XCTAssertEqual(resolverCalls.withLock { $0 }, 0)
    }

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
                    kind: .word
                )
            )
            XCTFail("A failed model must not be used")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("模型目录不存在")
            )
        }
    }

    func testSystemTranslationFailureDoesNotResolveFallbackModel()
        async throws
    {
        let suiteName = "GlintTranslationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        TranslationModelSelection.select(
            SystemTranslationModel.appleTranslationID,
            in: defaults
        )
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let runtime = TranslationRuntime(
            defaults: defaults,
            systemEngine: StubTranslationEngine(
                error: TranslationRuntimeTestError.systemFailed
            ),
            modelResolver: { _ in
                resolverCalls.withLock { $0 += 1 }
                return nil
            }
        )

        await runtime.prepareSelectedModel()
        do {
            _ = try await runtime.translate(
                Candidate(text: "今天天气不错", kind: .sentence)
            )
            XCTFail("System translation failure must not use another model")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "System translation failed"
            )
        }
        XCTAssertEqual(resolverCalls.withLock { $0 }, 0)
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
                kind: .sentence
            )
        )

        XCTAssertEqual(result?.text, "It's a nice day.")
    }

    func testBrokenSelectedModelDoesNotResolveAnotherModel() async throws {
        let suiteName = "GlintTranslationRuntimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        let resolverCalls = OSAllocatedUnfairLock(initialState: [String]())
        let runtime = TranslationRuntime(
            defaults: defaults
        ) { modelID in
            resolverCalls.withLock { $0.append(modelID) }
            return nil
        }

        let preparationError = await runtime.prepare(
            modelID: "broken-optional-model"
        )
        XCTAssertNotNil(preparationError)
        XCTAssertEqual(
            resolverCalls.withLock { $0 },
            ["broken-optional-model"]
        )
    }
}

private struct StubTranslationEngine: TranslationEngine {
    let output: String?
    let error: (any Error)?

    init(
        output: String? = nil,
        error: (any Error)? = nil
    ) {
        self.output = output
        self.error = error
    }

    func translate(
        _ candidate: Candidate
    ) async throws -> TranslationResult? {
        if let error {
            throw error
        }
        return output.map(TranslationResult.init(text:))
    }
}

private enum TranslationRuntimeTestError: LocalizedError {
    case systemFailed

    var errorDescription: String? {
        "System translation failed"
    }
}
