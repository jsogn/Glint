import XCTest
@testable import GlintCore

private struct MockDictionary: DictionaryEngine {
    let result: TranslationResult?

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        result
    }
}

private struct MockTranslator: TranslationEngine {
    let result: TranslationResult?

    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        result
    }
}

private struct FailingDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        throw GlintError.engineUnavailable
    }
}

private struct FailingTranslator: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        throw GlintError.engineUnavailable
    }
}

final class SmartRouterTests: XCTestCase {
    func testDictionaryFirstUsesDictionaryWhenAvailable() async throws {
        let result = TranslationResult(
            text: "hello",
            source: .dictionary,
            confidence: 0.95
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: result),
            translation: MockTranslator(result: nil)
        )

        let output = try await router.route(
            Candidate(text: "你好", kind: .word),
            mode: .dictionaryFirst
        )
        XCTAssertEqual(output, result)
    }

    func testDictionaryFirstFallsBackToModelOnMiss() async throws {
        let result = TranslationResult(
            text: "How are you?",
            source: .translation,
            confidence: 0.8
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: nil),
            translation: MockTranslator(result: result)
        )

        let output = try await router.route(
            Candidate(text: "你好吗", kind: .sentence),
            mode: .dictionaryFirst
        )
        XCTAssertEqual(output, result)
    }

    func testDictionaryFirstFallsBackToModelOnDictionaryError() async throws {
        let result = TranslationResult(
            text: "hello",
            source: .translation,
            confidence: 0.8
        )
        let router = SmartRouter(
            dictionary: FailingDictionary(),
            translation: MockTranslator(result: result)
        )

        let output = try await router.route(
            Candidate(text: "你好", kind: .word),
            mode: .dictionaryFirst
        )
        XCTAssertEqual(output, result)
    }

    func testModelFirstUsesModelEvenWhenDictionaryHasResult() async throws {
        let dictionaryResult = TranslationResult(
            text: "dictionary result",
            source: .dictionary,
            confidence: 0.95
        )
        let modelResult = TranslationResult(
            text: "model result",
            source: .translation,
            confidence: 0.8
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: modelResult)
        )

        let output = try await router.route(
            Candidate(text: "这个方案需要再讨论", kind: .sentence),
            mode: .modelFirst
        )
        XCTAssertEqual(output, modelResult)
    }

    func testModelFirstFallsBackToDictionaryWhenModelHasNoResult() async throws {
        let dictionaryResult = TranslationResult(
            text: "hello",
            source: .dictionary,
            confidence: 0.95
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: nil)
        )

        let output = try await router.route(
            Candidate(text: "你好", kind: .word),
            mode: .modelFirst
        )
        XCTAssertEqual(output, dictionaryResult)
    }

    func testModelFirstFallsBackToDictionaryWhenModelFails() async throws {
        let dictionaryResult = TranslationResult(
            text: "backstop",
            source: .dictionary,
            confidence: 0.95
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: FailingTranslator()
        )

        let output = try await router.route(
            Candidate(text: "兜底", kind: .word),
            mode: .modelFirst
        )
        XCTAssertEqual(output, dictionaryResult)
    }
}
