import Foundation
import GlintCore
import os
import SQLite3

public final class GenericSQLiteDictionary: DictionaryEngine, @unchecked Sendable {
    public static let runtime = "sqlite-v1"
    public static let databaseName = "dictionary.sqlite3"

    private var database: OpaquePointer?
    private var statement: OpaquePointer?
    private let lock = OSAllocatedUnfairLock()
    private let sourceLanguage: String
    private let targetLanguage: String
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init?(
        databaseURL: URL,
        sourceLanguage: String,
        targetLanguage: String
    ) {
        guard Self.isCompatible(databaseURL: databaseURL) else { return nil }
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, database != nil else {
            sqlite3_close(database)
            database = nil
            return nil
        }
        let prepareResult = sqlite3_prepare_v2(
            database,
            """
            SELECT target, frequency, source_order
            FROM entries
            WHERE source = ? AND source_lang = ? AND target_lang = ?
            ORDER BY
              COALESCE(frequency, 2147483647),
              COALESCE(source_order, 2147483647),
              target
            LIMIT 8
            """,
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, statement != nil else {
            sqlite3_finalize(statement)
            sqlite3_close(database)
            database = nil
            return nil
        }
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    public static func isCompatible(databaseURL: URL) -> Bool {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "PRAGMA table_info(entries)",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return false
        }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            columns.insert(
                String(
                    cString: UnsafeRawPointer(name)
                        .assumingMemoryBound(to: CChar.self)
                )
            )
        }
        return columns.isSuperset(of: [
            "source",
            "target",
            "frequency",
            "source_order",
            "source_lang",
            "target_lang",
        ])
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        let source = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }

        let traditional = source.applyingTransform(
            StringTransform("Simplified-Traditional"),
            reverse: false
        )
        let sourceVariants: [String]
        if let traditional, traditional != source {
            sourceVariants = [source, traditional]
        } else {
            sourceVariants = [source]
        }

        return lock.withLock {
            guard let statement else { return nil }
            var values: [String] = []
            for variant in sourceVariants {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, variant, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, sourceLanguage, -1, sqliteTransient)
                sqlite3_bind_text(statement, 3, targetLanguage, -1, sqliteTransient)

                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let text = sqlite3_column_text(statement, 0) else { continue }
                    let value = String(
                        cString: UnsafeRawPointer(text)
                            .assumingMemoryBound(to: CChar.self)
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        values.append(value)
                    }
                }
                if !values.isEmpty {
                    break
                }
            }
            guard !values.isEmpty else { return nil }

            let options = values.enumerated().map { index, value in
                TranslationOption(
                    text: value,
                    score: 1.0 - Double(index) * 0.05
                )
            }
            return TranslationResult(options: options)
        }
    }
}
