import Foundation
import GlintCore
import os
import SQLite3

public final class GenericSQLiteDictionary: DictionaryEngine, @unchecked Sendable {
    public static let runtime = "sqlite-v1"
    public static let databaseName = "dictionary.sqlite3"

    private struct Entry {
        let text: String
        let partsOfSpeech: [PartOfSpeech]
    }

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
        let partOfSpeechColumn =
            Self.hasColumn(
                "part_of_speech",
                in: database
            )
            ? "part_of_speech"
            : "NULL"
        let query = """
            SELECT target, frequency, source_order, \(partOfSpeechColumn)
            FROM entries
            WHERE source = ? AND source_lang = ? AND target_lang = ?
            ORDER BY
              COALESCE(frequency, 2147483647),
              COALESCE(source_order, 2147483647),
              target
            LIMIT 8
            """
        let prepareResult = sqlite3_prepare_v2(
            database,
            query,
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
        guard
            sqlite3_prepare_v2(
                db,
                "PRAGMA table_info(entries)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
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

    public func lookup(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        let source = request.candidate.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
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
            var values: [Entry] = []
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
                        let rawParts =
                            Self.columnText(statement, 3)
                            ?? ""
                        let parts = rawParts.split {
                            [",", "/", ";"].contains($0)
                        }
                        .compactMap {
                            PartOfSpeech(
                                $0.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                            )
                        }
                        values.append(
                            Entry(
                                text: value,
                                partsOfSpeech: parts
                            )
                        )
                    }
                }
                if !values.isEmpty {
                    break
                }
            }
            guard !values.isEmpty else { return nil }

            let options = values.enumerated().map { index, value in
                TranslationOption(
                    text: value.text,
                    score: 1.0 - Double(index) * 0.05,
                    partsOfSpeech: value.partsOfSpeech
                )
            }
            return TranslationResult(options: options)
        }
    }

    private static func hasColumn(
        _ column: String,
        in database: OpaquePointer?
    ) -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "PRAGMA table_info(entries)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, 1) == column {
                return true
            }
        }
        return false
    }

    private static func columnText(
        _ statement: OpaquePointer?,
        _ index: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(
            cString: UnsafeRawPointer(value)
                .assumingMemoryBound(to: CChar.self)
        )
    }
}
