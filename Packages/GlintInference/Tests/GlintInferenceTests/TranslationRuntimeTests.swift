import Foundation
import GlintCore
import XCTest
import os

@testable import GlintInference

final class TranslationRuntimeTests: XCTestCase {
    func testSystemModelUsesInjectedEngineWithoutResolvingPlugin() async throws {
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let runtime = TranslationRuntime(
            systemEngine: StubTranslationEngine(
                output: "System translation"
            ),
            modelResolver: { _ in
                resolverCalls.withLock { $0 += 1 }
                return nil
            }
        )

        let preparationError = await runtime.prepare(
            modelID: SystemTranslationModel.appleTranslationID,
            direction: .simplifiedChineseToEnglish
        )
        let result = try await runtime.translate(
            TranslationRequest(
                candidate: Candidate(text: "你好", kind: .word),
                direction: .simplifiedChineseToEnglish
            )
        )

        XCTAssertNil(preparationError)
        XCTAssertEqual(result?.text, "System translation")
        XCTAssertEqual(resolverCalls.withLock { $0 }, 0)
        let activeDirection = await runtime.activeDirection
        XCTAssertEqual(activeDirection, .simplifiedChineseToEnglish)
    }

    func testPreparingEnglishModelForJapaneseFailsBeforeLoading() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
        let runtime = TranslationRuntime { modelID in
            ResolvedTranslationModel(
                modelID: modelID,
                storage: .mlx(
                    directory: directory,
                    promptProfile: .generic
                ),
                supportedDirections: [
                    .simplifiedChineseToEnglish
                ]
            )
        }

        let error = await runtime.prepare(
            modelID: "english-only",
            direction: .simplifiedChineseToJapanese
        )

        XCTAssertEqual(error, "当前模型不支持目标语言")
        let activeDirection = await runtime.activeDirection
        XCTAssertNil(activeDirection)
    }

    func testFailedPreparationReportsDetailedErrorAndIsNotUsable() async {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "missing-ct2-\(UUID().uuidString)"
            )
        let runtime = TranslationRuntime { modelID in
            ResolvedTranslationModel(
                modelID: modelID,
                storage: .ctranslate2(
                    directory: missingDirectory
                ),
                supportedDirections: [
                    .simplifiedChineseToEnglish
                ]
            )
        }

        let error = await runtime.prepare(
            modelID: "broken-ct2",
            direction: .simplifiedChineseToEnglish
        )
        let lastError = await runtime.lastError

        XCTAssertNotNil(error)
        XCTAssertEqual(lastError, error)
        do {
            _ = try await runtime.translate(
                TranslationRequest(
                    candidate: Candidate(
                        text: "你好",
                        kind: .word
                    ),
                    direction: .simplifiedChineseToEnglish
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
        async
    {
        let resolverCalls = OSAllocatedUnfairLock(initialState: 0)
        let runtime = TranslationRuntime(
            systemEngine: StubTranslationEngine(
                error: TranslationRuntimeTestError.systemFailed
            ),
            modelResolver: { _ in
                resolverCalls.withLock { $0 += 1 }
                return nil
            }
        )

        _ = await runtime.prepare(
            modelID: SystemTranslationModel.appleTranslationID,
            direction: .simplifiedChineseToEnglish
        )
        do {
            _ = try await runtime.translate(
                TranslationRequest(
                    candidate: Candidate(
                        text: "今天天气不错",
                        kind: .sentence
                    ),
                    direction: .simplifiedChineseToEnglish
                )
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

    func testOnlineOPUSModelDataLoadsWithBundledRuntime() async throws {
        let repositoryRoot = repositoryRoot()
        let modelDirectory = repositoryRoot.appendingPathComponent(
            "Resources/OnlineModels/mt-opus-zh-en/model",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw XCTSkip(
                "Run scripts/package_opus_model_data.sh before package tests."
            )
        }

        let direction = TranslationDirection.simplifiedChineseToEnglish
        let engine = try CTranslate2Engine(
            direction: direction,
            modelDirectory: modelDirectory,
            libraryURL: repositoryRoot.appendingPathComponent(
                "Resources/CTranslate2Runtime/bin/libglintct2.dylib"
            )
        )
        let result = try await engine.translate(
            TranslationRequest(
                candidate: Candidate(
                    text: "今天天气不错",
                    kind: .sentence
                ),
                direction: direction
            )
        )

        XCTAssertEqual(result?.text, "It's a nice day.")
    }

    func testBrokenSelectedModelDoesNotResolveAnotherModel() async {
        let resolverCalls = OSAllocatedUnfairLock<[String]>(
            initialState: []
        )
        let runtime = TranslationRuntime { modelID in
            resolverCalls.withLock { $0.append(modelID) }
            return nil
        }

        let preparationError = await runtime.prepare(
            modelID: "broken-optional-model",
            direction: .simplifiedChineseToEnglish
        )

        XCTAssertNotNil(preparationError)
        XCTAssertEqual(
            resolverCalls.withLock { $0 },
            ["broken-optional-model"]
        )
    }

    func testLatestPreparationWinsWhenEarlierPreparationFinishesLast()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-switch-\(UUID().uuidString)")
        let gate = PreparationGate()
        let runtime = TranslationRuntime { modelID in
            if modelID == "slow-japanese" {
                await gate.waitForRelease()
            }
            return ResolvedTranslationModel(
                modelID: modelID,
                storage: .mlx(
                    directory: directory,
                    promptProfile: .generic
                ),
                supportedDirections: [
                    .simplifiedChineseToJapanese,
                    .simplifiedChineseToSpanish,
                ]
            )
        }

        async let slowerPreparation = runtime.prepare(
            modelID: "slow-japanese",
            direction: .simplifiedChineseToJapanese
        )
        await gate.waitUntilStarted()
        let latestPreparation = await runtime.prepare(
            modelID: "fast-spanish",
            direction: .simplifiedChineseToSpanish
        )
        await gate.release()
        let supersededPreparation = await slowerPreparation

        XCTAssertNil(latestPreparation)
        XCTAssertNil(supersededPreparation)
        let activeDirection = await runtime.activeDirection
        XCTAssertEqual(
            activeDirection,
            .simplifiedChineseToSpanish
        )
    }

    private func repositoryRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root
    }
}

private struct StubTranslationEngine: TranslationEngine {
    let output: String?
    let error: (any Error)?
    let supportedDirections: Set<TranslationDirection>

    init(
        output: String? = nil,
        error: (any Error)? = nil,
        supportedDirections: Set<TranslationDirection> = [
            .simplifiedChineseToEnglish,
            .simplifiedChineseToJapanese,
        ]
    ) {
        self.output = output
        self.error = error
        self.supportedDirections = supportedDirections
    }

    func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        supportedDirections.contains(direction)
    }

    func translate(
        _ request: TranslationRequest
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

private actor PreparationGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation {
            releaseWaiter = $0
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation {
            startWaiter = $0
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
