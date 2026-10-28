import Foundation
import XCTest
@testable import GlintInference

final class MLXTranslationEngineTests: XCTestCase {
    func testModelCompatibilityUsesRuntimeRegistry() async {
        let supportsQwen = await MLXModelCompatibility.supports(
            modelType: "qwen3"
        )
        let supportsUnknown = await MLXModelCompatibility.supports(
            modelType: "not-a-registered-model"
        )

        XCTAssertTrue(supportsQwen)
        XCTAssertFalse(supportsUnknown)
    }

    func testCleanRemovesLabelsAndQuotes() {
        XCTAssertEqual(
            MLXTranslationEngine.clean("Translation: \"Hello.\"\nignored"),
            "Hello."
        )
    }

    func testCleanKeepsTextAfterThinkingBlock() {
        XCTAssertEqual(
            MLXTranslationEngine.clean("<think>internal reasoning</think>\nHello there."),
            "Hello there."
        )
    }

    func testUnfinishedThinkingBlockIsRejected() {
        XCTAssertNil(MLXTranslationEngine.clean("<think>unfinished"))
    }

    func testChineseEchoIsRejected() {
        XCTAssertNil(MLXTranslationEngine.clean("这是一个测试"))
    }

    func testSpecializedModelsUseTheirOwnPrompts() {
        let hy = MLXPromptProfile(modelID: "mt-hy-mt2-1.8b")
        XCTAssertNil(hy.instructions)
        XCTAssertTrue(hy.prompt(for: "这个方案需要再讨论").contains("不要额外解释"))

        let index = MLXPromptProfile(modelID: "mt-index-translate-2b")
        XCTAssertNil(index.instructions)
        XCTAssertTrue(index.prompt(for: "这个方案需要再讨论").contains("直接输出翻译结果"))

        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
        XCTAssertNotNil(qwen.instructions)
        XCTAssertEqual(qwen.prompt(for: "你好"), "你好")
    }

    func testBatchPromptPreservesNumbersAndOrder() {
        let profile = MLXPromptProfile(modelID: "mt-hy-mt2-1.8b")
        let prompt = profile.batchPrompt(for: ["学习", "学校", "学生"])

        XCTAssertTrue(prompt.contains("1. 学习"))
        XCTAssertTrue(prompt.contains("2. 学校"))
        XCTAssertTrue(prompt.contains("3. 学生"))
        XCTAssertTrue(prompt.contains("不要合并"))
    }

    func testBatchParserReadsNumberedLines() throws {
        XCTAssertEqual(
            try MLXTranslationEngine.parseBatchTranslations(
                "1. Study\n2. School\n3. Student",
                expectedCount: 3
            ),
            ["Study", "School", "Student"]
        )
    }

    func testBatchParserFallsBackToSequentialLines() throws {
        XCTAssertEqual(
            try MLXTranslationEngine.parseBatchTranslations(
                "Study\nSchool\nStudent",
                expectedCount: 3
            ),
            ["Study", "School", "Student"]
        )
    }

    func testBatchParserRejectsIncompleteOutput() {
        XCTAssertThrowsError(
            try MLXTranslationEngine.parseBatchTranslations(
                "1. Study\n2. School",
                expectedCount: 3
            )
        )
    }

    func testModelDirectoryAcceptsSentencePieceTokenizer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintMLXModel-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for name in ["config.json", "tokenizer.model", "weights.safetensors"] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(name).path,
                    contents: Data()
                )
            )
        }

        XCTAssertTrue(
            MLXTranslationEngine.containsModelFiles(directory)
        )
    }
}
