import Foundation
import SQLite3
import zlib

public struct CedictDatabaseSummary: Sendable, Equatable {
    public let sourceDate: String?
    public let entryCount: Int
    public let senseCount: Int

    public init(
        sourceDate: String?,
        entryCount: Int,
        senseCount: Int
    ) {
        self.sourceDate = sourceDate
        self.entryCount = entryCount
        self.senseCount = senseCount
    }
}

public enum CedictDatabaseBuilderError: Error, LocalizedError {
    case gzipOpenFailed
    case gzipReadFailed
    case lineTooLong
    case invalidEntry(String)
    case sqlite(String)
    case invalidSchema
    case integrityCheckFailed

    public var errorDescription: String? {
        switch self {
        case .gzipOpenFailed:
            "无法打开 CC-CEDICT 压缩文件"
        case .gzipReadFailed:
            "无法读取 CC-CEDICT 压缩文件"
        case .lineTooLong:
            "CC-CEDICT 包含异常长的数据行"
        case .invalidEntry:
            "CC-CEDICT 数据格式无效"
        case .sqlite(let message):
            "词典数据库操作失败：\(message)"
        case .invalidSchema:
            "词典数据库版本不兼容"
        case .integrityCheckFailed:
            "词典数据库完整性校验失败"
        }
    }
}

public enum CedictDatabaseBuilder {
    private struct ParsedEntry {
        let traditional: String
        let simplified: String
        let senses: [String]
    }

    private static let schema = "cc-cedict-senses-v3"
    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    public static func sourceDate(
        fromGzipURL url: URL
    ) throws -> String? {
        var resolvedDate: String?
        try readLines(from: url) { line in
            if let date = parseSourceDate(line) {
                resolvedDate = date
                return false
            }
            return line.hasPrefix("#")
        }
        return resolvedDate
    }

    @discardableResult
    public static func build(
        fromGzipURL sourceURL: URL,
        to databaseURL: URL
    ) throws -> CedictDatabaseSummary {
        try? FileManager.default.removeItem(at: databaseURL)

        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
                nil
            ) == SQLITE_OK,
            let database
        else {
            let message =
                database.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "unknown"
            sqlite3_close(database)
            throw CedictDatabaseBuilderError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        do {
            try execute(
                database,
                """
                PRAGMA journal_mode = OFF;
                PRAGMA synchronous = OFF;
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE terms (
                    term TEXT NOT NULL,
                    entry_id INTEGER NOT NULL,
                    PRIMARY KEY (term, entry_id)
                ) WITHOUT ROWID;
                CREATE TABLE senses (
                    entry_id INTEGER NOT NULL,
                    sense_order INTEGER NOT NULL,
                    gloss TEXT NOT NULL,
                    PRIMARY KEY (entry_id, sense_order)
                ) WITHOUT ROWID;
                """
            )

            let insertTerm = try prepare(
                database,
                "INSERT OR IGNORE INTO terms(term, entry_id) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(insertTerm) }
            let insertSense = try prepare(
                database,
                """
                INSERT INTO senses(entry_id, sense_order, gloss)
                VALUES (?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertSense) }

            var sourceDate: String?
            var entryCount = 0
            var senseCount = 0
            try execute(database, "BEGIN IMMEDIATE;")
            do {
                try readLines(from: sourceURL) { line in
                    if entryCount.isMultiple(of: 1_000) {
                        try Task.checkCancellation()
                    }
                    if let date = parseSourceDate(line) {
                        sourceDate = date
                        return true
                    }
                    if line.hasPrefix("#") || line.isEmpty {
                        return true
                    }
                    guard let entry = parseEntry(line) else {
                        throw CedictDatabaseBuilderError.invalidEntry(line)
                    }
                    entryCount += 1
                    for term in [entry.simplified, entry.traditional] {
                        sqlite3_reset(insertTerm)
                        sqlite3_clear_bindings(insertTerm)
                        bind(term, to: 1, in: insertTerm)
                        sqlite3_bind_int64(
                            insertTerm,
                            2,
                            Int64(entryCount)
                        )
                        guard sqlite3_step(insertTerm) == SQLITE_DONE else {
                            throw CedictDatabaseBuilderError.sqlite(
                                String(cString: sqlite3_errmsg(database))
                            )
                        }
                    }
                    for (senseOrder, gloss) in entry.senses.enumerated() {
                        sqlite3_reset(insertSense)
                        sqlite3_clear_bindings(insertSense)
                        sqlite3_bind_int64(
                            insertSense,
                            1,
                            Int64(entryCount)
                        )
                        sqlite3_bind_int(
                            insertSense,
                            2,
                            Int32(senseOrder)
                        )
                        bind(gloss, to: 3, in: insertSense)
                        guard sqlite3_step(insertSense) == SQLITE_DONE else {
                            throw CedictDatabaseBuilderError.sqlite(
                                String(cString: sqlite3_errmsg(database))
                            )
                        }
                        senseCount += 1
                    }
                    return true
                }
                try execute(database, "COMMIT;")
            } catch {
                try? execute(database, "ROLLBACK;")
                throw error
            }

            let metadata = [
                ("schema", schema),
                ("source", "CC-CEDICT"),
                ("license", "CC-BY-SA-4.0"),
                ("source_date", sourceDate ?? ""),
                ("entry_count", String(entryCount)),
                ("sense_count", String(senseCount)),
            ]
            let insertMetadata = try prepare(
                database,
                "INSERT INTO metadata(key, value) VALUES (?, ?)"
            )
            defer { sqlite3_finalize(insertMetadata) }
            for (key, value) in metadata {
                sqlite3_reset(insertMetadata)
                sqlite3_clear_bindings(insertMetadata)
                bind(key, to: 1, in: insertMetadata)
                bind(value, to: 2, in: insertMetadata)
                guard
                    sqlite3_step(insertMetadata) == SQLITE_DONE
                else {
                    throw CedictDatabaseBuilderError.sqlite(
                        String(cString: sqlite3_errmsg(database))
                    )
                }
            }
            try execute(database, "PRAGMA user_version = 3;")
            let summary = CedictDatabaseSummary(
                sourceDate: sourceDate,
                entryCount: entryCount,
                senseCount: senseCount
            )
            guard
                try inspect(
                    databaseURL: databaseURL,
                    fullIntegrityCheck: true
                ) == summary
            else {
                throw CedictDatabaseBuilderError.integrityCheckFailed
            }
            return summary
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            throw error
        }
    }

    public static func inspect(
        databaseURL: URL,
        fullIntegrityCheck: Bool = false
    ) throws -> CedictDatabaseSummary {
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READONLY,
                nil
            ) == SQLITE_OK,
            let database
        else {
            let message =
                database.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "unknown"
            sqlite3_close(database)
            throw CedictDatabaseBuilderError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        guard
            stringValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'schema'"
            ) == schema
        else {
            throw CedictDatabaseBuilderError.invalidSchema
        }
        guard hasLookupSchema(database) else {
            throw CedictDatabaseBuilderError.invalidSchema
        }
        let integritySQL =
            fullIntegrityCheck
            ? "PRAGMA integrity_check;"
            : "PRAGMA quick_check;"
        guard stringValue(database, sql: integritySQL) == "ok" else {
            throw CedictDatabaseBuilderError.integrityCheckFailed
        }
        let sourceDate = stringValue(
            database,
            sql: "SELECT value FROM metadata WHERE key = 'source_date'"
        ).flatMap { $0.isEmpty ? nil : $0 }
        let entryCount =
            intValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'entry_count'"
            )
            ?? intValue(
                database,
                sql: "SELECT COUNT(DISTINCT entry_id) FROM senses"
            )
            ?? 0
        let senseCount =
            intValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'sense_count'"
            )
            ?? intValue(
                database,
                sql: "SELECT COUNT(*) FROM senses"
            )
            ?? 0
        return CedictDatabaseSummary(
            sourceDate: sourceDate,
            entryCount: entryCount,
            senseCount: senseCount
        )
    }

    public static func isCompatible(databaseURL: URL) -> Bool {
        (try? inspect(databaseURL: databaseURL)) != nil
    }

    private static func readLines(
        from sourceURL: URL,
        body: (String) throws -> Bool
    ) throws {
        guard let handle = gzopen(sourceURL.path, "rb") else {
            throw CedictDatabaseBuilderError.gzipOpenFailed
        }
        defer { gzclose(handle) }

        var buffer = [CChar](repeating: 0, count: 65_536)
        while true {
            let result = buffer.withUnsafeMutableBufferPointer {
                gzgets(handle, $0.baseAddress, Int32($0.count))
            }
            guard let result else {
                if gzeof(handle) == 1 {
                    return
                }
                throw CedictDatabaseBuilderError.gzipReadFailed
            }
            let rawLine = String(cString: result)
            let line = rawLine.trimmingCharacters(in: .newlines)
            if !rawLine.hasSuffix("\n"),
                rawLine.utf8.count >= buffer.count - 1
            {
                throw CedictDatabaseBuilderError.lineTooLong
            }
            guard try body(line) else { return }
        }
    }

    private static func parseSourceDate(_ line: String) -> String? {
        let prefix = "#! date="
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func parseEntry(_ line: String) -> ParsedEntry? {
        guard
            let firstSpace = line.firstIndex(of: " "),
            let secondSpace = line[
                line.index(after: firstSpace)...
            ].firstIndex(of: " "),
            let openBracket = line[
                line.index(after: secondSpace)...
            ].firstIndex(of: "["),
            let closeBracket = line[openBracket...].firstIndex(of: "]")
        else {
            return nil
        }
        let traditional = String(line[..<firstSpace])
        let simplified = String(
            line[
                line.index(after: firstSpace)..<secondSpace
            ]
        )
        let glossStart = line.index(after: closeBracket)
        let rawGloss = line[glossStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            rawGloss.hasPrefix("/"),
            rawGloss.hasSuffix("/")
        else {
            return nil
        }
        let senses = rawGloss.dropFirst().dropLast()
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !senses.isEmpty else { return nil }
        return ParsedEntry(
            traditional: traditional,
            simplified: simplified,
            senses: senses
        )
    }

    private static func hasLookupSchema(
        _ database: OpaquePointer
    ) -> Bool {
        tableColumns("terms", in: database).isSuperset(
            of: ["term", "entry_id"]
        )
            && tableColumns("senses", in: database).isSuperset(
                of: ["entry_id", "sense_order", "gloss"]
            )
    }

    private static func tableColumns(
        _ table: String,
        in database: OpaquePointer
    ) -> Set<String> {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "PRAGMA table_info(\(table));",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else {
                continue
            }
            columns.insert(
                String(
                    cString: UnsafeRawPointer(name)
                        .assumingMemoryBound(to: CChar.self)
                )
            )
        }
        return columns
    }

    private static func bind(
        _ value: String,
        to index: Int32,
        in statement: OpaquePointer?
    ) {
        sqlite3_bind_text(
            statement,
            index,
            value,
            -1,
            sqliteTransient
        )
    }

    private static func prepare(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                sql,
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            throw CedictDatabaseBuilderError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        return statement
    }

    private static func execute(
        _ database: OpaquePointer,
        _ sql: String
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CedictDatabaseBuilderError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func stringValue(
        _ database: OpaquePointer,
        sql: String
    ) -> String? {
        guard let statement = try? prepare(database, sql) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(
            cString: UnsafeRawPointer(value)
                .assumingMemoryBound(to: CChar.self)
        )
    }

    private static func intValue(
        _ database: OpaquePointer,
        sql: String
    ) -> Int? {
        guard let statement = try? prepare(database, sql) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let text = sqlite3_column_text(statement, 0) {
            return Int(
                String(
                    cString: UnsafeRawPointer(text)
                        .assumingMemoryBound(to: CChar.self)
                )
            )
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
