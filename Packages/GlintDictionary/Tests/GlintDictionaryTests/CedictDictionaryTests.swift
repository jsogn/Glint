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
        databaseURL: URL? = nil,
        overridesURL: URL? = nil
    ) -> CedictDictionary {
        CedictDictionary(
            databaseURL: databaseURL ?? rootURL.appendingPathComponent(
                "Resources/Plugins/dict-cedict/cedict.sqlite3"
            ),
            overridesURL: overridesURL ?? rootURL.appendingPathComponent(
                "Resources/Plugins/dict-cedict/overrides.json"
            ),
            ranker: ECDICTRanker(
                databaseURL: rootURL.appendingPathComponent(
                    "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
                )
            )
        )
    }

    private func temporaryOverrides(
        _ contents: String
    ) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("overrides.json")
        try Data(contents.utf8).write(to: file)
        return (directory, file)
    }

    func testKnownWord() async throws {
        let dictionary = makeDictionary()
        let result = try await dictionary.lookup(Candidate(text: "你好", kind: .word))
        XCTAssertEqual(result?.text.lowercased(), "hello")
        XCTAssertEqual(result?.source, .dictionary)
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
            print("\(word) -> \(result?.displayText ?? "<not found>")")
            XCTAssertGreaterThan(result?.options.count ?? 0, 1)
        }

        let design = try await dictionary.lookup(Candidate(text: "设计"))
        XCTAssertEqual(design?.text, "design")
        XCTAssertTrue(design?.displayText.contains("plan") == true)

        let run = try await dictionary.lookup(Candidate(text: "运行"))
        XCTAssertTrue(run?.options.contains { $0.text == "run" } == true)

        let complex = try await dictionary.lookup(Candidate(text: "复杂"))
        XCTAssertEqual(complex?.text, "complex")
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

    func testDatabaseSensePrecedesFallbackOverride() async throws {
        let (directory, overrides) = try temporaryOverrides(
            """
            {
              "overrides": {
                "设计": "forced override"
              }
            }
            """
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let dictionary = makeDictionary(overridesURL: overrides)

        let result = try await dictionary.lookup(
            Candidate(text: "设计", kind: .word)
        )

        XCTAssertNotEqual(result?.text, "forced override")
        XCTAssertTrue(
            result?.options.contains { $0.text == "forced override" } == true
        )
    }

    func testFallbackOverrideIsUsedOnDictionaryMiss() async throws {
        let (directory, overrides) = try temporaryOverrides(
            """
            {
              "overrides": {
                "不存在": "fallback answer"
              }
            }
            """
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let dictionary = makeDictionary(overridesURL: overrides)

        let result = try await dictionary.lookup(
            Candidate(text: "不存在", kind: .word)
        )

        XCTAssertEqual(result?.text, "fallback answer")
        XCTAssertEqual(result?.confidence, 0.75)
    }

    func testRuntimeSafeFallbackSurvivesDictionaryMiss() async throws {
        let dictionary = makeDictionary()

        let result = try await dictionary.lookup(
            Candidate(text: "颗粒度", kind: .word)
        )

        XCTAssertEqual(result?.text, "granularity")
        XCTAssertEqual(result?.confidence, 0.75)
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
