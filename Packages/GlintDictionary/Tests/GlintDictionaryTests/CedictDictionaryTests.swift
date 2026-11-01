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
        let routes = [
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
        return DictionaryRouter(routes: routes)
    }

    func testCedictOptionsGetPOSFromEnglishLookup() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ecdict = directory.appendingPathComponent("rank.sqlite3")
        try makeECDICTFixture(at: ecdict)

        let ranker = ECDICTRanker(databaseURL: ecdict)
        let dictionary = CedictDictionary(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-cedict/cedict.sqlite3"
            ),
            ranker: ranker
        )
        let router = SmartRouter(
            dictionary: dictionary,
            translation: NoTranslation(),
            partOfSpeechProvider: ranker
        )
        let result = try await router.route(
            Candidate(text: "设计"),
            mode: .dictionaryFirst
        )
        let design = result?.options.first {
            $0.text.lowercased() == "design"
        }

        XCTAssertEqual(design?.partsOfSpeech, [.noun, .verb])
    }

    func testCedictFunctionWordUsesPOSWithoutRankRow() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ecdict = directory.appendingPathComponent("rank.sqlite3")
        try makeECDICTFixture(at: ecdict)

        let ranker = ECDICTRanker(databaseURL: ecdict)
        XCTAssertTrue(ranker.rankings(for: "关于").isEmpty)

        let dictionary = CedictDictionary(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-cedict/cedict.sqlite3"
            ),
            ranker: ranker
        )
        let router = SmartRouter(
            dictionary: dictionary,
            translation: NoTranslation(),
            partOfSpeechProvider: ranker
        )
        let result = try await router.route(
            Candidate(text: "关于"),
            mode: .dictionaryFirst
        )
        let about = result?.options.first {
            $0.text.lowercased() == "about"
        }

        XCTAssertEqual(about?.partsOfSpeech, [.preposition])
    }

    func testECDICTFallbackCarriesPartsOfSpeech() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ecdict = directory.appendingPathComponent("rank.sqlite3")
        try makeECDICTFixture(at: ecdict)

        let dictionary = ECDICTDictionary(
            ranker: ECDICTRanker(databaseURL: ecdict)
        )
        let ranker = ECDICTRanker(databaseURL: ecdict)
        let router = SmartRouter(
            dictionary: dictionary,
            translation: NoTranslation(),
            partOfSpeechProvider: ranker
        )
        let result = try await router.route(
            Candidate(text: "设计"),
            mode: .dictionaryFirst
        )
        let design = result?.options.first {
            $0.text.lowercased() == "design"
        }

        XCTAssertEqual(design?.partsOfSpeech, [.noun, .verb])
    }

    func testBundledProviderTagsModelOnlySingleWord() async throws {
        let ranker = ECDICTRanker(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
            )
        )
        let router = SmartRouter(
            dictionary: NoDictionary(),
            translation: FixedTranslation(text: "convenient"),
            partOfSpeechProvider: ranker
        )

        let result = try await router.route(
            Candidate(text: "方便"),
            mode: .modelFirst
        )

        XCTAssertEqual(result?.text, "convenient")
        XCTAssertEqual(result?.options.first?.partsOfSpeech, [.adjective])
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

    func testRouterFiltersLongPlaceDefinition() async {
        let router = makeRouter()
        let beijing = await router.lookup(
            Candidate(text: "北京", kind: .word)
        )
        let london = await router.lookup(
            Candidate(text: "伦敦", kind: .word)
        )

        XCTAssertEqual(beijing?.text, "Beijing")
        XCTAssertFalse(
            beijing?.options.contains {
                $0.text.contains("capital of the People's Republic")
            } == true
        )
        XCTAssertEqual(london?.text, "London")
        XCTAssertFalse(
            london?.options.contains {
                $0.text.contains("capital of United Kingdom")
            } == true
        )
    }

    func testRouterPreservesCommasBelongingToCompactPhrases() async {
        let router = makeRouter()
        let washington = await router.lookup(
            Candidate(text: "华盛顿", kind: .word)
        )
        let policy = await router.lookup(
            Candidate(text: "一中一台", kind: .word)
        )
        let surly = await router.lookup(
            Candidate(text: "倔头", kind: .word)
        )

        XCTAssertTrue(
            washington?.options.contains {
                $0.text == "Washington, D.C."
            } == true,
            "\(washington?.options.map(\.text) ?? [])"
        )
        XCTAssertFalse(
            washington?.options.contains {
                $0.text.contains("first US president")
                    || $0.text == "Washington, US State"
            } == true
        )
        XCTAssertTrue(
            policy?.options.contains {
                $0.text == "one China, one Taiwan"
            } == true
        )
        XCTAssertTrue(
            surly?.options.contains {
                $0.text == "surly, irascible person"
            } == true
        )
        XCTAssertFalse(
            surly?.options.contains {
                $0.text == "surly" || $0.text == "irascible person"
            } == true
        )
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

    func testSchemaV3PreservesSenses() async throws {
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

    func testQuotedHeadwordDropsTrailingExplanation() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(
            Candidate(text: "弹幕", kind: .word)
        )
        let surfaces = result?.options.map(\.text) ?? []

        XCTAssertTrue(surfaces.contains("barrage"))
        XCTAssertTrue(surfaces.contains("bullet screen"))
        XCTAssertTrue(surfaces.contains("danmaku"))
        XCTAssertFalse(
            surfaces.contains {
                $0.contains("allows viewers to post on-screen comments")
            }
        )
    }

    func testQuotedHeadwordPreservesCommaInsidePhrase() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(
            Candidate(text: "一中一台", kind: .word)
        )
        let surfaces = result?.options.map(\.text) ?? []

        XCTAssertTrue(
            surfaces.contains("one China, one Taiwan")
        )
        XCTAssertFalse(
            surfaces.contains {
                $0.contains("the notion that China and Taiwan")
            }
        )
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCedictPOS-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeECDICTFixture(at database: URL) throws {
        let source = database.deletingLastPathComponent()
            .appendingPathComponent("ecdict.csv")
        try Data(
            """
            word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
            design,,,"n. 设计\\nv. 设计",,5,1,,,100,,
            plan,,,"n. 计划\\nvt. 计划",,4,1,,,120,,
            about,,,"prep. 关于",,4,1,,,200,,
            """.utf8
        ).write(to: source)
        try ECDICTRankBuilder.build(
            fromCSVURL: source,
            to: database
        )
    }
}

private struct NoTranslation: TranslationEngine {
    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct NoDictionary: DictionaryEngine {
    func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        nil
    }
}

private struct FixedTranslation: TranslationEngine {
    let text: String

    func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        TranslationResult(text: text)
    }
}
