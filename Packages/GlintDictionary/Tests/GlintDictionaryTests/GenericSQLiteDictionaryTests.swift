import Foundation
import GlintCore
import SQLite3
import XCTest
@testable import GlintDictionary

final class GenericSQLiteDictionaryTests: XCTestCase {
    func testStandardSchemaAndLookupRanking() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintGeneric-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(databaseURL.path, &database),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE entries (
                  source TEXT NOT NULL,
                  target TEXT NOT NULL,
                  source_lang TEXT NOT NULL,
                  target_lang TEXT NOT NULL,
                  part_of_speech TEXT,
                  frequency INTEGER,
                  source_order INTEGER
                );
                INSERT INTO entries VALUES
                  ('设计', 'plan', 'zh-Hans', 'en', 'noun', 50, 2),
                  ('设计', 'design', 'zh-Hans', 'en', 'noun', 10, 1),
                  ('design', '设计', 'en', 'zh-Hans', 'noun', 10, 1);
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        XCTAssertTrue(
            GenericSQLiteDictionary.isCompatible(databaseURL: databaseURL)
        )
        let dictionary = try XCTUnwrap(
            GenericSQLiteDictionary(
                databaseURL: databaseURL,
                sourceLanguage: "zh-Hans",
                targetLanguage: "en"
            )
        )
        let result = try await dictionary.lookup(Candidate(text: "设计"))
        XCTAssertEqual(result?.displayText, "design · plan")
    }

    func testSchemaWithoutRankingColumnsIsRejected() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintGenericInvalid-\(UUID().uuidString).sqlite3"
            )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(databaseURL.path, &database),
            SQLITE_OK
        )
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE entries (
                  source TEXT NOT NULL,
                  target TEXT NOT NULL,
                  source_lang TEXT NOT NULL,
                  target_lang TEXT NOT NULL
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        XCTAssertFalse(
            GenericSQLiteDictionary.isCompatible(databaseURL: databaseURL)
        )
    }
}
