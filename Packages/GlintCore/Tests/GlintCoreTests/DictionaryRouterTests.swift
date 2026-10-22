import XCTest
@testable import GlintCore

private struct OrderedDictionary: DictionaryEngine {
    let value: String?

    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        guard let value else { return nil }
        return TranslationResult(text: value, source: .dictionary, confidence: 0.9)
    }
}

final class DictionaryRouterTests: XCTestCase {
    func testRoutesByPriority() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "second",
                priority: 1,
                engine: OrderedDictionary(value: "second result")
            ),
            DictionaryRoute(
                id: "first",
                priority: 0,
                engine: OrderedDictionary(value: "first result")
            ),
        ])

        let result = try await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "first result")
    }

    func testFallsThroughToNextDictionary() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "cedict",
                priority: 0,
                engine: OrderedDictionary(value: nil)
            ),
            DictionaryRoute(
                id: "ecdict",
                priority: 1,
                engine: OrderedDictionary(value: "fallback")
            ),
        ])

        let result = try await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "fallback")
    }

    func testMergesAllMatchingDictionaries() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "primary",
                priority: 0,
                engine: OrderedDictionary(value: "primary")
            ),
            DictionaryRoute(
                id: "secondary",
                priority: 1,
                engine: OrderedDictionary(value: "secondary")
            ),
        ])

        let result = try await router.lookup(Candidate(text: "测试", kind: .word))
        XCTAssertEqual(result?.text, "primary")
        XCTAssertEqual(
            Set(result?.options.map(\.text) ?? []),
            Set(["primary", "secondary"])
        )
    }

    func testBlockedTermsStayHiddenAcrossDictionaryRoutes() async throws {
        let router = DictionaryRouter(
            routes: [
                DictionaryRoute(
                    id: "example",
                    priority: 0,
                    engine: OrderedDictionary(value: "should not appear")
                ),
            ],
            blocked: ["打"]
        )

        let result = try await router.lookup(Candidate(text: "打", kind: .word))
        XCTAssertNil(result)
    }

    func testDefaultPolicyKeepsLegitimateWordsAndBlocksInvalidFragment() async throws {
        let router = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "example",
                priority: 0,
                engine: OrderedDictionary(value: "result")
            ),
        ])

        let legitimate = try await router.lookup(
            Candidate(text: "打", kind: .word)
        )
        let invalidFragment = try await router.lookup(
            Candidate(text: "你号", kind: .word)
        )

        XCTAssertEqual(legitimate?.text, "result")
        XCTAssertNil(invalidFragment)
    }
}
