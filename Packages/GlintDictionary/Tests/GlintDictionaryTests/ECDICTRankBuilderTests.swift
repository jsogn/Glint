import Foundation
import XCTest

@testable import GlintDictionary

final class ECDICTRankBuilderTests: XCTestCase {
    func testBundledDatabaseIsCompatible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let summary = try ECDICTRankBuilder.inspect(
            databaseURL: root.appendingPathComponent(
                "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
            ),
            fullIntegrityCheck: true
        )

        XCTAssertEqual(
            summary.sourceChecksum,
            "d1ecbdf9ee2b920afb6f430ca6b6bb9f559588cf0dff86e04bd255f9390843cc"
        )
        XCTAssertEqual(summary.sourceDate, "2026-10-20T02:25:07Z")
        XCTAssertEqual(
            summary.sourceRevision,
            "9c46923fb81a2eb6c264a3a1689562ea7bc56b6a"
        )
        XCTAssertEqual(summary.termCount, 101_755)
        XCTAssertEqual(summary.rankCount, 152_449)
    }

    func testBuildsQuotedCSVAndRanksTerms() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ecdict.csv")
        let database = directory.appendingPathComponent(
            "ecdict_rank.sqlite3"
        )
        try Data(
            """
            word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
            hello,,,"你好; 问候",,,1,,,100,,
            design,,,"设计, 计划",,,2,oxford,,200,,
            greet,,,"问候
            欢迎",,,0,,,50,,
            phrase,,,"一个; 关于; 你好世界",,,0,,,300,,
            """.utf8
        ).write(to: source)

        let summary = try ECDICTRankBuilder.build(
            fromCSVURL: source,
            to: database,
            sourceChecksum: "blob-sha",
            sourceDate: "2026-10-20T02:25:07Z"
        )

        XCTAssertEqual(summary.sourceChecksum, "blob-sha")
        XCTAssertEqual(summary.sourceDate, "2026-10-20T02:25:07Z")
        XCTAssertGreaterThanOrEqual(summary.termCount, 3)
        XCTAssertGreaterThanOrEqual(summary.rankCount, 4)
        XCTAssertTrue(ECDICTRankBuilder.isCompatible(databaseURL: database))

        let ranker = ECDICTRanker(databaseURL: database)
        XCTAssertEqual(
            ranker.fallbackCandidates(term: "你好", limit: 3),
            ["hello"]
        )
        XCTAssertEqual(
            ranker.fallbackCandidates(term: "问候", limit: 3),
            ["greet", "hello"]
        )
        XCTAssertEqual(ranker.rankings(for: "设计").first?.english, "design")
        XCTAssertTrue(ranker.rankings(for: "一个").isEmpty)
    }

    func testRejectsMissingTranslationColumnAndRemovesDatabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ecdict.csv")
        let database = directory.appendingPathComponent(
            "ecdict_rank.sqlite3"
        )
        try Data(
            """
            word,definition,frq
            hello,greeting,100
            """.utf8
        ).write(to: source)

        XCTAssertThrowsError(
            try ECDICTRankBuilder.build(
                fromCSVURL: source,
                to: database
            )
        ) { error in
            XCTAssertEqual(
                error as? ECDICTRankBuilderError,
                .invalidHeader
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: database.path)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintECDICTBuilderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
