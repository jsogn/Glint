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
        XCTAssertEqual(hy.defaultAdapterMode, .translationInstruction)
        XCTAssertNil(hy.instructions(for: .translationInstruction))
        let hyPrompt = hy.prompt(
            for: "关于",
            adapterMode: .translationInstruction
        )
        XCTAssertEqual(
            hyPrompt,
            "将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n关于"
        )

        let index = MLXPromptProfile(modelID: "mt-index-translate-2b")
        XCTAssertEqual(index.defaultAdapterMode, .translationInstruction)
        XCTAssertNil(index.instructions(for: .translationInstruction))
        let indexPrompt = index.prompt(
            for: "关于",
            adapterMode: .translationInstruction
        )
        XCTAssertEqual(
            indexPrompt,
            "请将以下中文文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n关于"
        )

        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
        XCTAssertEqual(qwen.defaultAdapterMode, .systemInstruction)
        XCTAssertNotNil(qwen.instructions(for: .systemInstruction))
        XCTAssertEqual(
            qwen.prompt(
                for: "你好",
                adapterMode: .systemInstruction
            ),
            "你好"
        )

        let generic = MLXPromptProfile(modelID: "custom-translation-model")
        XCTAssertEqual(generic.defaultAdapterMode, .directSource)
        XCTAssertNil(generic.instructions(for: .directSource))
        XCTAssertEqual(
            generic.prompt(
                for: "你好",
                adapterMode: .directSource
            ),
            "你好"
        )
        XCTAssertTrue(
            generic.prompt(
                for: "你好",
                adapterMode: .translationInstruction
            ).contains("只输出翻译结果")
        )
        XCTAssertNotNil(generic.instructions(for: .systemInstruction))
    }

    func testCompatibilityProbeAcceptsShortTranslations() {
        XCTAssertTrue(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "Hello!",
                expected: ["hello", "hi"]
            )
        )
        XCTAssertTrue(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "weather",
                expected: ["weather"]
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "Hello, how can I help you today?",
                expected: ["hello", "hi"]
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "翻译",
                expected: ["translate", "translation"]
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "This is a response",
                expected: ["hello", "hi"]
            )
        )
    }

    func testModelsUseOfficialGenerationProfiles() {
        let hy = MLXPromptProfile(modelID: "mt-hy-mt2-1.8b")
            .generationParameters(maxTokens: 64)
        XCTAssertEqual(hy.maxTokens, 64)
        XCTAssertEqual(hy.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(hy.topP, 0.6, accuracy: 0.0001)
        XCTAssertEqual(hy.topK, 20)
        XCTAssertEqual(hy.repetitionPenalty ?? 0, 1.05, accuracy: 0.0001)

        let index = MLXPromptProfile(modelID: "mt-index-translate-2b")
            .generationParameters(maxTokens: 64)
        XCTAssertEqual(index.temperature, 0)
        XCTAssertEqual(index.topK, 0)

        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
            .generationParameters(maxTokens: 64)
        XCTAssertEqual(qwen.temperature, 0.7, accuracy: 0.0001)
        XCTAssertEqual(qwen.topP, 0.8, accuracy: 0.0001)
        XCTAssertEqual(qwen.topK, 20)
    }

    func testInstructionEchoIsRejectedForShortInput() {
        XCTAssertTrue(
            MLXTranslationEngine.isInstructionEcho(
                """
                Translate the following Chinese text into English. Only output the \
                translated result without any additional explanation.
                """,
                for: "翻译"
            )
        )
        XCTAssertTrue(
            MLXTranslationEngine.isInstructionEcho(
                """
                Word or short word first, most common concise English equivalent, \
                just output one answer, no list of synonyms or explanation.
                """,
                for: "翻译一下"
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isInstructionEcho(
                "translate",
                for: "翻译"
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isInstructionEcho(
                "Translated result without additional explanation",
                for: "翻译结果，不要解释"
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isInstructionEcho(
                """
                Translate the following Chinese text into English. Only output the \
                translated result without any additional explanation.
                """,
                for: "请将以下中文文本翻译成自然、简洁的英文"
            )
        )
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
