import Foundation
import GlintCore
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

    func testEngineCapabilitiesFollowDeclaredTargets() async {
        let englishOnly = MLXTranslationEngine(
            supportedTargets: [.english]
        )
        let multilingual = MLXTranslationEngine(
            supportedTargets: [
                .english,
                .japanese,
                .spanish,
                .french,
                .german,
                .russian,
            ]
        )

        let englishOnlySupportsJapanese =
            await englishOnly.supports(
                .simplifiedChineseToJapanese
            )
        let multilingualSupportsJapanese =
            await multilingual.supports(
                .simplifiedChineseToJapanese
            )

        XCTAssertFalse(englishOnlySupportsJapanese)
        XCTAssertTrue(multilingualSupportsJapanese)
        for target in TranslationTarget.allCases
        where target != .english {
            let supported = await multilingual.supports(
                TranslationDirection(target: target)
            )
            XCTAssertTrue(supported)
        }
    }

    func testEngineDefaultsToEnglishWhenCapabilitiesAreNotDeclared()
        async
    {
        let engine = MLXTranslationEngine()
        let supportsEnglish = await engine.supports(
            .simplifiedChineseToEnglish
        )

        XCTAssertTrue(supportsEnglish)
        for target in TranslationTarget.allCases
        where target != .english {
            let supported = await engine.supports(
                TranslationDirection(target: target)
            )
            XCTAssertFalse(supported)
        }
    }

    func testUndeclaredTargetCannotTranslate() async {
        let engine = MLXTranslationEngine()

        do {
            _ = try await engine.translate(
                TranslationRequest(
                    candidate: Candidate(
                        text: "你好",
                        kind: .word
                    ),
                    direction: .simplifiedChineseToJapanese
                )
            )
            XCTFail("Undeclared target must be rejected")
        } catch MLXTranslationError.unsupportedTarget {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCleanRemovesLabelsAndQuotes() {
        XCTAssertEqual(
            MLXTranslationEngine.clean(
                "Translation: \"Hello.\"\nignored",
                target: .english
            ),
            "Hello."
        )
    }

    func testCleanKeepsTextAfterThinkingBlock() {
        XCTAssertEqual(
            MLXTranslationEngine.clean(
                "<think>internal reasoning</think>\nHello there.",
                target: .english
            ),
            "Hello there."
        )
    }

    func testUnfinishedThinkingBlockIsRejected() {
        XCTAssertNil(
            MLXTranslationEngine.clean(
                "<think>unfinished",
                target: .english
            )
        )
    }

    func testChineseEchoIsRejected() {
        XCTAssertNil(
            MLXTranslationEngine.clean(
                "这是一个测试",
                target: .english
            )
        )
    }

    func testJapaneseCleanAcceptsKanjiAndKana() {
        XCTAssertEqual(
            MLXTranslationEngine.clean(
                "翻訳：学生です。",
                target: .japanese
            ),
            "学生です。"
        )
        XCTAssertEqual(
            MLXTranslationEngine.clean(
                "天気がいい",
                target: .japanese
            ),
            "天気がいい"
        )
    }

    func testSpecializedModelsUseTheirOwnPrompts() {
        let hy = MLXPromptProfile(modelID: "mt-hy-mt2-1.8b")
        XCTAssertEqual(hy.defaultAdapterMode, .translationInstruction)
        XCTAssertNil(
            hy.instructions(
                for: .translationInstruction,
                target: .english
            )
        )
        let hyPrompt = hy.prompt(
            for: "关于",
            target: .english,
            adapterMode: .translationInstruction
        )
        XCTAssertEqual(
            hyPrompt,
            "将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n关于"
        )

        let index = MLXPromptProfile(modelID: "mt-index-translate-2b")
        XCTAssertEqual(index.defaultAdapterMode, .translationInstruction)
        XCTAssertNil(
            index.instructions(
                for: .translationInstruction,
                target: .english
            )
        )
        let indexPrompt = index.prompt(
            for: "关于",
            target: .english,
            adapterMode: .translationInstruction
        )
        XCTAssertEqual(
            indexPrompt,
            "请将以下中文文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n关于"
        )

        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
        XCTAssertEqual(qwen.defaultAdapterMode, .systemInstruction)
        XCTAssertNotNil(
            qwen.instructions(
                for: .systemInstruction,
                target: .english
            )
        )
        XCTAssertEqual(
            qwen.prompt(
                for: "你好",
                target: .english,
                adapterMode: .systemInstruction
            ),
            "你好"
        )

        let generic = MLXPromptProfile(modelID: "custom-translation-model")
        XCTAssertEqual(generic.defaultAdapterMode, .directSource)
        XCTAssertNil(
            generic.instructions(
                for: .directSource,
                target: .english
            )
        )
        XCTAssertEqual(
            generic.prompt(
                for: "你好",
                target: .english,
                adapterMode: .directSource
            ),
            "你好"
        )
        XCTAssertTrue(
            generic.prompt(
                for: "你好",
                target: .english,
                adapterMode: .translationInstruction
            ).contains("只输出翻译结果")
        )
        XCTAssertNotNil(
            generic.instructions(
                for: .systemInstruction,
                target: .english
            )
        )
    }

    func testJapaneseTranslationPromptTargetsJapanese() {
        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")
        let prompt = qwen.prompt(
            for: "你好",
            target: .japanese,
            adapterMode: .translationInstruction
        )

        XCTAssertTrue(prompt.contains("日语"))
        XCTAssertFalse(prompt.contains("翻译为英语"))
    }

    func testNewTargetPromptsUseTargetLanguageNames() {
        let qwen = MLXPromptProfile(modelID: "llm-qwen3-1.7b")

        for target in TranslationTarget.allCases {
            let prompt = qwen.prompt(
                for: "你好",
                target: target,
                adapterMode: .translationInstruction
            )
            XCTAssertTrue(prompt.contains(target.chineseDisplayName))
            XCTAssertFalse(
                target == .english
                    ? !prompt.contains("英语")
                    : prompt.contains("翻译为英语")
            )
        }
    }

    func testNewTargetOutputLabelsAreCleaned() {
        let samples: [(TranslationTarget, String, String)] = [
            (.spanish, "Spanish: Hola.", "Hola."),
            (.french, "French: Bonjour.", "Bonjour."),
            (.german, "German: Hallo.", "Hallo."),
            (.russian, "Russian: Привет.", "Привет."),
        ]

        for (target, input, expected) in samples {
            XCTAssertEqual(
                MLXTranslationEngine.clean(input, target: target),
                expected
            )
        }
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

    func testJapaneseCompatibilityProbeAcceptsNaturalSentence() {
        XCTAssertTrue(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "今日はこんにちは。",
                expected: ["こんにちは", "ハロー"]
            )
        )
        XCTAssertFalse(
            MLXTranslationEngine.isAcceptedProbeOutput(
                "hello",
                expected: ["こんにちは", "ハロー"]
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
        let prompt = profile.batchPrompt(
            for: ["学习", "学校", "学生"],
            target: .japanese
        )

        XCTAssertTrue(prompt.contains("1. 学习"))
        XCTAssertTrue(prompt.contains("2. 学校"))
        XCTAssertTrue(prompt.contains("3. 学生"))
        XCTAssertTrue(prompt.contains("日语"))
        XCTAssertTrue(prompt.contains("不要合并"))
    }

    func testBatchParserReadsNumberedLines() throws {
        XCTAssertEqual(
            try MLXTranslationEngine.parseBatchTranslations(
                "1. Study\n2. School\n3. Student",
                expectedCount: 3,
                target: .english
            ),
            ["Study", "School", "Student"]
        )
    }

    func testBatchParserFallsBackToSequentialLines() throws {
        XCTAssertEqual(
            try MLXTranslationEngine.parseBatchTranslations(
                "Study\nSchool\nStudent",
                expectedCount: 3,
                target: .english
            ),
            ["Study", "School", "Student"]
        )
    }

    func testBatchParserRejectsIncompleteOutput() {
        XCTAssertThrowsError(
            try MLXTranslationEngine.parseBatchTranslations(
                "1. Study\n2. School",
                expectedCount: 3,
                target: .english
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
