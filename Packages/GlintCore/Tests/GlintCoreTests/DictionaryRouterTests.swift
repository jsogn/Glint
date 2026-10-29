import XCTest
@testable import GlintCore

private struct OrderedDictionary: DictionaryEngine {
    let value: String?

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        guard let value else { return nil }
        return TranslationResult(text: value)
    }
}

private struct OptionsDictionary: DictionaryEngine {
    let options: [String]

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        guard !options.isEmpty else { return nil }
        return TranslationResult(
            options: options.enumerated().map {
                TranslationOption(
                    text: $0.element,
                    score: 1 - Double($0.offset) * 0.01
                )
            }
        )
    }
}

private struct FailingDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        throw GlintError.engineUnavailable
    }
}

private actor CountingDictionary: DictionaryEngine {
    let value: String?
    private var count = 0

    init(value: String?) {
        self.value = value
    }

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        count += 1
        return value.map(TranslationResult.init(text:))
    }

    func lookupCount() -> Int {
        count
    }
}

final class DictionaryRouterTests: XCTestCase {
    func testRouteDefaultsToFallbackRole() {
        let route = DictionaryRoute(
            id: "optional",
            priority: 0,
            engine: OrderedDictionary(value: "fallback")
        )

        XCTAssertEqual(route.role, .fallback)
    }

    func testRoutesByPriority() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "second",
                priority: 1,
                role: .authoritative,
                engine: OrderedDictionary(value: "second result")
            ),
            DictionaryRoute(
                id: "first",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: "first result")
            ),
        ])

        let result = await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "first result")
    }

    func testFallsThroughToNextDictionary() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: nil)
            ),
            DictionaryRoute(
                id: "ecdict",
                priority: 1,
                role: .authoritative,
                engine: OrderedDictionary(value: "fallback")
            ),
        ])

        let result = await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "fallback")
    }

    func testLongExplanatoryResultDoesNotBlockConciseFallback() async {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(
                    value:
                        "Beijing municipality, capital of the People's Republic of China"
                )
            ),
            DictionaryRoute(
                id: "ecdict",
                priority: 1,
                role: .fallback,
                engine: OrderedDictionary(value: "Beijing")
            ),
        ])

        let result = await router.lookup(
            Candidate(text: "北京", kind: .word)
        )

        XCTAssertEqual(result?.options.map(\.text), ["Beijing"])
    }

    func testShortAppositiveDescriptionDoesNotBlockConciseFallback() async {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(
                    value: "London, capital of United Kingdom"
                )
            ),
            DictionaryRoute(
                id: "ecdict",
                priority: 1,
                role: .fallback,
                engine: OrderedDictionary(value: "London")
            ),
        ])

        let result = await router.lookup(
            Candidate(text: "伦敦", kind: .word)
        )

        XCTAssertEqual(result?.options.map(\.text), ["London"])
    }

    func testFiltersExplanatoryOptionsWithoutDroppingCompactSynonyms() async {
        let fallback = CountingDictionary(value: "should not be used")
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                role: .authoritative,
                engine: OptionsDictionary(
                    options: [
                        "London, capital of United Kingdom",
                        "London",
                    ]
                )
            ),
            DictionaryRoute(
                id: "fallback",
                priority: 1,
                role: .fallback,
                engine: fallback
            ),
        ])

        let result = await router.lookup(
            Candidate(text: "伦敦", kind: .word)
        )

        XCTAssertEqual(result?.options.map(\.text), ["London"])
        let fallbackCount = await fallback.lookupCount()
        XCTAssertEqual(fallbackCount, 0)
    }

    func testOnlyExplanatoryOptionsProduceNoDictionaryMatch() async {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(
                    value:
                        "Beijing municipality, capital of the People's Republic of China"
                )
            )
        ])

        let result = await router.lookup(
            Candidate(text: "北京", kind: .word)
        )

        XCTAssertNil(result)
    }

    func testFallsThroughWhenDictionaryFails() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "broken",
                priority: 0,
                role: .authoritative,
                engine: FailingDictionary()
            ),
            DictionaryRoute(
                id: "fallback",
                priority: 1,
                role: .authoritative,
                engine: OrderedDictionary(value: "fallback")
            ),
        ])

        let result = await router.lookup(
            Candidate(text: "测试", kind: .word)
        )

        XCTAssertEqual(result?.text, "fallback")
    }

    func testMergesAllMatchingDictionaries() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "primary",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: "primary")
            ),
            DictionaryRoute(
                id: "secondary",
                priority: 1,
                role: .authoritative,
                engine: OrderedDictionary(value: "secondary")
            ),
        ])

        let result = await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "primary")
        XCTAssertEqual(
            Set(result?.options.map(\.text) ?? []),
            Set(["primary", "secondary"])
        )
    }

    func testAuthoritativeMatchSkipsFallbackRoutes() async {
        let fallback = CountingDictionary(value: "fallback")
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "authoritative",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: "trusted")
            ),
            DictionaryRoute(
                id: "fallback",
                priority: 1,
                role: .fallback,
                engine: fallback
            ),
        ])

        let result = await router.lookup(Candidate(text: "测试", kind: .word))

        XCTAssertEqual(result?.options.map(\.text), ["trusted"])
        let fallbackCount = await fallback.lookupCount()
        XCTAssertEqual(fallbackCount, 0)
    }

    func testFallbackRoutesStopAfterFirstMatch() async {
        let firstFallback = CountingDictionary(value: "first fallback")
        let secondFallback = CountingDictionary(value: "second fallback")
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "authoritative",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: nil)
            ),
            DictionaryRoute(
                id: "first-fallback",
                priority: 1,
                role: .fallback,
                engine: firstFallback
            ),
            DictionaryRoute(
                id: "second-fallback",
                priority: 2,
                role: .fallback,
                engine: secondFallback
            ),
        ])

        let result = await router.lookup(Candidate(text: "测试", kind: .word))

        XCTAssertEqual(result?.options.map(\.text), ["first fallback"])
        let firstCount = await firstFallback.lookupCount()
        let secondCount = await secondFallback.lookupCount()
        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
    }

    func testBlockedTermsStayHiddenAcrossDictionaryRoutes() async throws {
        let router = DictionaryRouter(
            routes: [
                DictionaryRoute(
                    id: "example",
                    priority: 0,
                    role: .authoritative,
                    engine: OrderedDictionary(value: "should not appear")
                )
            ],
            blocked: ["打"]
        )

        let result = await router.lookup(Candidate(text: "打", kind: .word))
        XCTAssertNil(result)
    }

    func testDefaultPolicyKeepsLegitimateWordsAndBlocksInvalidFragment() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "example",
                priority: 0,
                role: .authoritative,
                engine: OrderedDictionary(value: "result")
            )
        ])

        let legitimate = await router.lookup(
            Candidate(text: "打", kind: .word)
        )
        let invalidFragment = await router.lookup(
            Candidate(text: "你号", kind: .word)
        )
        let spacedInvalidFragment = await router.lookup(
            Candidate(text: " 你号 ", kind: .word)
        )

        XCTAssertEqual(legitimate?.text, "result")
        XCTAssertNil(invalidFragment)
        XCTAssertNil(spacedInvalidFragment)
    }
}
