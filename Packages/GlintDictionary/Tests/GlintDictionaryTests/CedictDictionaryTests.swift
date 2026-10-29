import Foundation
import XCTest
import GlintCore
@testable import GlintDictionary

final class CedictDictionaryTests: XCTestCase {
    private var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeDictionary(
        databaseURL: URL? = nil
    ) -> CedictDictionary {
        CedictDictionary(
            databaseURL: databaseURL
                ?? rootURL.appendingPathComponent(
                    "Resources/Plugins/dict-cedict/cedict.sqlite3"
                ),
            ranker: ECDICTRanker(
                databaseURL: rootURL.appendingPathComponent(
                    "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
                )
            )
        )
    }

    private func makeRouter() -> DictionaryRouter {
        let ecdictURL = rootURL.appendingPathComponent(
            "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
        )
        let ranker = ECDICTRanker(databaseURL: ecdictURL)
        var routes = [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                role: .authoritative,
                engine: CedictDictionary(
                    databaseURL: rootURL.appendingPathComponent(
                        "Resources/Plugins/dict-cedict/cedict.sqlite3"
                    ),
                    ranker: ranker
                )
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                role: .fallback,
                engine: ECDICTDictionary(ranker: ranker)
            ),
        ]
        if let wiktionary = GenericSQLiteDictionary(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-wiktionary-zh-en/dictionary.sqlite3"
            ),
            sourceLanguage: "zh-Hans",
            targetLanguage: "en"
        ) {
            routes.append(
                DictionaryRoute(
                    id: "dict-wiktionary-zh-en",
                    priority: 2,
                    role: .fallback,
                    engine: wiktionary
                )
            )
        }
        return DictionaryRouter(routes: routes)
    }

    func testKnownWord() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(Candidate(text: "你好", kind: .word))
        XCTAssertEqual(result?.text.lowercased(), "hello")
    }

    func testLegitimateWordIsNotBlocked() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(Candidate(text: "打", kind: .word))
        XCTAssertNotNil(result)
        XCTAssertFalse(result?.options.isEmpty ?? true)
    }

    func testInvalidFragmentIsBlocked() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(Candidate(text: "你号", kind: .word))
        XCTAssertNil(result)
    }

    func testUnknownWordReturnsNil() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(Candidate(text: "不存在", kind: .word))
        XCTAssertNil(result)
    }

    func testMultipleSensesAreRanked() async throws {
        let dictionary = makeDictionary()
        for word in ["设计", "程序", "运行", "复杂", "结构", "处理"] {
            let result = try await dictionary.lookup(
                Candidate(text: word, kind: .word)
            )
            XCTAssertGreaterThan(result?.options.count ?? 0, 1)
        }

        let design = try await dictionary.lookup(Candidate(text: "设计"))
        XCTAssertEqual(design?.text, "design")
        XCTAssertTrue(design?.displayText.contains("plan") == true)

        let run = try await dictionary.lookup(Candidate(text: "运行"))
        XCTAssertTrue(run?.options.contains { $0.text == "run" } == true)

        let complex = try await dictionary.lookup(Candidate(text: "复杂"))
        XCTAssertTrue(
            complex?.options.contains { $0.text == "complex" } == true
        )
        XCTAssertTrue(
            complex?.options.contains { $0.text == "complicated" } == true
        )
    }

    func testECDICTHeadwordCompetesWhenCedictSenseOrderMissesCommonMeaning()
        async throws
    {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(
            Candidate(text: "程序", kind: .word)
        )

        XCTAssertEqual(result?.text, "program")
    }

    func testAuthoritativeRoutingKeepsConciseHeadwordFirst() async {
        let router = makeRouter()
        let result = await router.lookup(
            Candidate(text: "中文", kind: .word)
        )

        XCTAssertEqual(result?.text, "Chinese")
    }

    func testAuthoritativeRoutingIncludesTaggedSynonyms() async {
        let router = makeRouter()
        let dictionary = await router.lookup(
            Candidate(text: "词典", kind: .word)
        )
        let child = await router.lookup(
            Candidate(text: "孩子", kind: .word)
        )

        XCTAssertTrue(
            dictionary?.options.contains { $0.text == "lexicon" } == true
        )
        XCTAssertTrue(
            child?.options.contains { $0.text == "children" } == true
        )
    }

    func testAuthoritativeRoutingSuppressesUntaggedFallbacks()
        async
    {
        let router = makeRouter()
        let dictionary = await router.lookup(
            Candidate(text: "词典", kind: .word)
        )
        let world = await router.lookup(
            Candidate(text: "世界", kind: .word)
        )
        let child = await router.lookup(
            Candidate(text: "孩子", kind: .word)
        )
        let music = await router.lookup(
            Candidate(text: "音乐", kind: .word)
        )

        XCTAssertFalse(
            dictionary?.options.contains { $0.text == "dick" } == true
        )
        XCTAssertFalse(
            world?.options.contains {
                ["extremely", "super"].contains($0.text)
            } == true
        )
        XCTAssertFalse(
            child?.options.contains { $0.text == "homerun" } == true
        )
        XCTAssertFalse(
            music?.options.contains {
                ["tonic", "blaring"].contains($0.text)
            } == true
        )
    }

    func testLiteralTechnicalHeadwordOutranksBroaderSynonym() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(
            Candidate(text: "用户", kind: .word)
        )

        XCTAssertEqual(result?.text, "user")
    }

    func testUnrelatedECDICTHeadwordsDoNotReplaceExactCedictMeaning()
        async throws
    {
        let dictionary = makeDictionary()

        let important = try await dictionary.lookup(
            Candidate(text: "重要", kind: .word)
        )
        let need = try await dictionary.lookup(
            Candidate(text: "需要", kind: .word)
        )

        XCTAssertEqual(important?.text, "important")
        XCTAssertEqual(need?.text, "need")
    }

    func testSchemaV2PreservesReadingsAndSenses() async throws {
        let dictionary = makeDictionary()

        let kan = try await dictionary.lookup(
            Candidate(text: "看", kind: .word)
        )
        let da = try await dictionary.lookup(
            Candidate(text: "打", kind: .word)
        )

        XCTAssertTrue(
            kan?.options.contains { $0.text == "read" } == true
        )
        XCTAssertTrue(
            da?.options.contains { $0.text == "hit" } == true
        )
        XCTAssertGreaterThan(kan?.options.count ?? 0, 3)
        XCTAssertGreaterThan(da?.options.count ?? 0, 3)
    }

    func testCandidateSurfacesRemoveMetadataAndBrokenParentheses() async throws {
        let dictionary = makeDictionary()

        for word in ["开发", "英文", "复盘", "模块"] {
            let result = try await dictionary.lookup(
                Candidate(text: word, kind: .word)
            )
            let surfaces = result?.options.map(\.text) ?? []

            XCTAssertFalse(surfaces.isEmpty)
            XCTAssertTrue(
                surfaces.allSatisfy {
                    !$0.contains("(")
                        && !$0.contains(")")
                        && !$0.contains("【")
                        && !$0.contains("】")
                },
                "\(word): \(surfaces)"
            )
            XCTAssertFalse(
                surfaces.contains {
                    let value = $0.lowercased()
                    return value.hasPrefix("see ")
                        || value.hasPrefix("variant of ")
                        || value.hasPrefix("taiwan pr.")
                }
            )
        }
    }

    func testMissingTermIsLeftForModelFallback() async throws {
        let dictionary = makeDictionary()

        let result = try await dictionary.lookup(
            Candidate(text: "颗粒度", kind: .word)
        )

        XCTAssertNil(result)
    }

    func testECDICTFallbackReturnsMultipleOptions() async throws {
        let dictionary = ECDICTDictionary(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
            )
        )
        let result = try await dictionary.lookup(Candidate(text: "需求"))

        XCTAssertEqual(result?.text, "demand")
        XCTAssertTrue(result?.displayText.contains("requirement") == true)
    }
}
