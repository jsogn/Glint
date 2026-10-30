import Foundation
import GlintCore
import SQLite3
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
        let schema = try databaseSchema(at: database)
        XCTAssertEqual(schema.userVersion, 3)
        XCTAssertTrue(
            schema.tables.isSuperset(
                of: ["metadata", "senses", "terms"]
            )
        )
        XCTAssertFalse(schema.tables.contains("entries"))
        XCTAssertTrue(schema.sensesDefinition.contains("WITHOUT ROWID"))
        XCTAssertTrue(schema.termsDefinition.contains("WITHOUT ROWID"))
        XCTAssertFalse(schema.sensesDefinition.contains("pinyin"))
        XCTAssertFalse(schema.termsDefinition.contains("pinyin"))
        XCTAssertEqual(schema.termCount, 4)
        XCTAssertEqual(schema.senseCount, 4)

        let dictionary = CedictDictionary(
            databaseURL: database,
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "发布", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "release")

        let traditionalResult = try await dictionary.lookup(
            Candidate(text: "發布", kind: .word)
        )
        XCTAssertEqual(
            traditionalResult?.options.first?.text,
            "release"
        )
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

    func testPreservesSourceDateContainingApostrophe() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cedict.gz")
        let database = directory.appendingPathComponent("cedict.sqlite3")
        let sourceDate = "2026-10-28T00:15:09Z'; DROP TABLE entries; --"
        try writeGzip(
            """
            #! date=\(sourceDate)
            做 做 [zuo4] /to do/
            """,
            to: source
        )

        let summary = try CedictDatabaseBuilder.build(
            fromGzipURL: source,
            to: database
        )

        XCTAssertEqual(summary.sourceDate, sourceDate)
        let dictionary = CedictDictionary(
            databaseURL: database,
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "做", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "do")
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

    private func databaseSchema(
        at url: URL
    ) throws -> (
        userVersion: Int,
        tables: Set<String>,
        termsDefinition: String,
        sensesDefinition: String,
        termCount: Int,
        senseCount: Int
    ) {
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                url.path,
                &database,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK,
            let database
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(database) }

        func string(_ sql: String) throws -> String {
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(
                    database,
                    sql,
                    -1,
                    &statement,
                    nil
                ) == SQLITE_OK,
                let statement
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return String(
                cString: UnsafeRawPointer(
                    sqlite3_column_text(statement, 0)
                ).assumingMemoryBound(to: CChar.self)
            )
        }

        let userVersion = Int(try string("PRAGMA user_version;")) ?? -1
        var tables: Set<String> = []
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT name FROM sqlite_master WHERE type = 'table';",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0) else {
                continue
            }
            tables.insert(
                String(
                    cString: UnsafeRawPointer(name)
                        .assumingMemoryBound(to: CChar.self)
                )
            )
        }

        return (
            userVersion: userVersion,
            tables: tables,
            termsDefinition: try string(
                "SELECT sql FROM sqlite_master WHERE name = 'terms';"
            ),
            sensesDefinition: try string(
                "SELECT sql FROM sqlite_master WHERE name = 'senses';"
            ),
            termCount: Int(
                try string("SELECT COUNT(*) FROM terms;")
            ) ?? -1,
            senseCount: Int(
                try string("SELECT COUNT(*) FROM senses;")
            ) ?? -1
        )
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
