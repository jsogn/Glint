import Foundation
import GlintCore
import XCTest
import zlib

@testable import GlintDictionary

final class CedictDatabaseBuilderTests: XCTestCase {
    func testBuildsAndInspectsSourceSnapshot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cedict.gz")
        let database = directory.appendingPathComponent("cedict.sqlite3")
        try writeGzip(
            """
            # CC-CEDICT
            #! date=2026-10-28T00:15:09Z
            打 打 [da2] /dozen/
            打 打 [da3] /to hit/
            发布 發布 [fa1 bu4] /to release/to issue/
            """,
            to: source
        )

        XCTAssertEqual(
            try CedictDatabaseBuilder.sourceDate(
                fromGzipURL: source
            ),
            "2026-10-28T00:15:09Z"
        )
        let summary = try CedictDatabaseBuilder.build(
            fromGzipURL: source,
            to: database
        )

        XCTAssertEqual(
            summary,
            CedictDatabaseSummary(
                sourceDate: "2026-10-28T00:15:09Z",
                entryCount: 3,
                senseCount: 4
            )
        )
        XCTAssertEqual(
            try CedictDatabaseBuilder.inspect(
                databaseURL: database,
                fullIntegrityCheck: true
            ),
            summary
        )
        XCTAssertTrue(
            CedictDatabaseBuilder.isCompatible(databaseURL: database)
        )

        let dictionary = CedictDictionary(
            databaseURL: database,
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "发布", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "release")
    }

    func testRejectsInvalidSourceAndRemovesPartialDatabase() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cedict.gz")
        let database = directory.appendingPathComponent("cedict.sqlite3")
        try writeGzip(
            """
            #! date=2026-10-28T00:15:09Z
            invalid entry
            """,
            to: source
        )

        XCTAssertThrowsError(
            try CedictDatabaseBuilder.build(
                fromGzipURL: source,
                to: database
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: database.path)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintCedictBuilderTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func writeGzip(
        _ text: String,
        to url: URL
    ) throws {
        guard let handle = gzopen(url.path, "wb") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes {
            gzwrite(
                handle,
                $0.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard written == bytes.count, gzclose(handle) == Z_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
