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

private actor CountingDictionary: DictionaryEngine {
    let result: TranslationResult?
    private var count = 0

    init(result: TranslationResult?) {
        self.result = result
    }

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        count += 1
        return result
    }

    func lookupCount() -> Int {
        count
    }
}

final class SmartRouterTests: XCTestCase {
    func testDictionaryFirstUsesDictionaryWhenAvailable() async throws {
        let result = TranslationResult(
            text: "hello"
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
            text: "How are you?"
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

    func testDictionaryFirstUsesModelBeforeDictionaryForSentence()
        async throws
    {
        let dictionaryResult = TranslationResult(
            text: "dictionary result"
        )
        let modelResult = TranslationResult(
            text: "What do you think?"
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: modelResult)
        )

        let output = try await router.route(
            Candidate(text: "你觉得呢", kind: .sentence),
            mode: .dictionaryFirst
        )

        XCTAssertEqual(output, modelResult)
    }

    func testDictionaryFirstFallsBackToDictionaryWhenSentenceModelMisses()
        async throws
    {
        let dictionaryResult = TranslationResult(
            text: "dictionary result"
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: nil)
        )

        let output = try await router.route(
            Candidate(text: "你觉得呢", kind: .sentence),
            mode: .dictionaryFirst
        )

        XCTAssertEqual(output, dictionaryResult)
    }

    func testDictionaryFirstFallsBackToModelOnDictionaryError() async throws {
        let result = TranslationResult(
            text: "hello"
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

    func testDictionaryPrefetchIsReusedByRoute() async throws {
        let result = TranslationResult(
            text: "hello"
        )
        let dictionary = CountingDictionary(result: result)
        let router = SmartRouter(
            dictionary: dictionary,
            translation: MockTranslator(result: nil)
        )
        let candidate = Candidate(text: "你好", kind: .word)
        let prefetch = Task {
            await router.prefetchDictionary(candidate)
        }

        let output = try await router.route(
            candidate,
            mode: .dictionaryFirst,
            dictionaryPrefetch: prefetch
        )

        XCTAssertEqual(output, result)
        let lookupCount = await dictionary.lookupCount()
        XCTAssertEqual(lookupCount, 1)
    }

    func testModelFirstKeepsModelFirstAndAppendsDictionaryOptions() async throws {
        let dictionaryResult = TranslationResult(
            text: "dictionary result"
        )
        let modelResult = TranslationResult(
            options: [
                TranslationOption(text: "model result", score: 0.8),
                TranslationOption(text: "model alternative", score: 0.7),
            ]
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: modelResult)
        )

        let output = try await router.route(
            Candidate(text: "方案", kind: .word),
            mode: .modelFirst
        )
        XCTAssertEqual(
            output?.options.map(\.text),
            ["model result", "model alternative", "dictionary result"]
        )
    }

    func testModelFirstPrimaryOnlySkipsDictionaryAlternatives() async throws {
        let modelResult = TranslationResult(
            options: [
                TranslationOption(text: "model result", score: 0.8),
                TranslationOption(text: "model alternative", score: 0.7),
            ]
        )
        let dictionary = CountingDictionary(
            result: TranslationResult(
                text: "dictionary result"
            )
        )
        let router = SmartRouter(
            dictionary: dictionary,
            translation: MockTranslator(result: modelResult)
        )

        let output = try await router.route(
            Candidate(text: "方案", kind: .word),
            mode: .modelFirst,
            includesAlternatives: false
        )

        XCTAssertEqual(output, modelResult)
        let lookupCount = await dictionary.lookupCount()
        XCTAssertEqual(lookupCount, 0)
    }

    func testModelFirstSkipsDictionaryForSentence() async throws {
        let dictionaryResult = TranslationResult(
            text: "dictionary result"
        )
        let modelResult = TranslationResult(
            text: "sentence result"
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

    func testModelFirstKeepsModelWhenDictionaryFails() async throws {
        let modelResult = TranslationResult(
            text: "model result"
        )
        let router = SmartRouter(
            dictionary: FailingDictionary(),
            translation: MockTranslator(result: modelResult)
        )

        let output = try await router.route(
            Candidate(text: "方案", kind: .word),
            mode: .modelFirst
        )

        XCTAssertEqual(output, modelResult)
    }

    func testModelFirstTreatsEmptyModelResultAsMiss() async throws {
        let dictionaryResult = TranslationResult(
            text: "dictionary result"
        )
        let emptyModelResult = TranslationResult(
            options: []
        )
        let router = SmartRouter(
            dictionary: MockDictionary(result: dictionaryResult),
            translation: MockTranslator(result: emptyModelResult)
        )

        let output = try await router.route(
            Candidate(text: "方案", kind: .word),
            mode: .modelFirst
        )

        XCTAssertEqual(output, dictionaryResult)
    }

    func testModelFirstFallsBackToDictionaryWhenModelHasNoResult() async throws {
        let dictionaryResult = TranslationResult(
            text: "hello"
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
            text: "backstop"
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
