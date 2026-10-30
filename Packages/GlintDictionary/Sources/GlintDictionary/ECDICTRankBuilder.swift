import Foundation
import SQLite3

public struct ECDICTRankSummary: Sendable, Equatable {
    public let sourceChecksum: String?
    public let sourceDate: String?
    public let sourceRevision: String?
    public let termCount: Int
    public let rankCount: Int

    public init(
        sourceChecksum: String?,
        sourceDate: String?,
        sourceRevision: String?,
        termCount: Int,
        rankCount: Int
    ) {
        self.sourceChecksum = sourceChecksum
        self.sourceDate = sourceDate
        self.sourceRevision = sourceRevision
        self.termCount = termCount
        self.rankCount = rankCount
    }
}

public enum ECDICTRankBuilderError: Error, LocalizedError, Equatable {
    case invalidHeader
    case invalidRecord(Int)
    case sqlite(String)
    case invalidSchema
    case integrityCheckFailed

    public var errorDescription: String? {
        switch self {
        case .invalidHeader:
            "ECDICT 文件缺少必要字段"
        case .invalidRecord(let row):
            "ECDICT 第 \(row) 行格式无效"
        case .sqlite(let message):
            "ECDICT 索引数据库操作失败：\(message)"
        case .invalidSchema:
            "ECDICT 索引数据库版本不兼容"
        case .integrityCheckFailed:
            "ECDICT 索引数据库完整性校验失败"
        }
    }
}

public enum ECDICTRankBuilder {
    private struct Ranking: Comparable {
        let frequency: Int
        let collins: Int
        let oxford: Int
        let examTagged: Bool

        static func < (lhs: Ranking, rhs: Ranking) -> Bool {
            if lhs.frequency != rhs.frequency {
                return lhs.frequency < rhs.frequency
            }
            if lhs.collins != rhs.collins {
                return lhs.collins > rhs.collins
            }
            if lhs.oxford != rhs.oxford {
                return lhs.oxford > rhs.oxford
            }
            return lhs.examTagged && !rhs.examTagged
        }
    }

    private struct RankedWord {
        let english: String
        let ranking: Ranking
    }

    private struct CSVStreamReader {
        let handle: FileHandle
        var fields: [String] = []
        var fieldBytes: [UInt8] = []
        var inQuotes = false
        var quotePending = false
        var recordNumber = 0

        mutating func forEach(
            _ body: ([String], Int) throws -> Void
        ) throws {
            while let chunk = try handle.read(upToCount: 65_536),
                !chunk.isEmpty
            {
                for byte in chunk {
                    try consume(byte, body: body)
                }
            }
            if quotePending {
                inQuotes = false
                quotePending = false
            }
            if !fieldBytes.isEmpty || !fields.isEmpty {
                finishField()
                try finishRecord(body: body)
            }
        }

        private mutating func consume(
            _ byte: UInt8,
            body: ([String], Int) throws -> Void
        ) throws {
            if inQuotes {
                if quotePending {
                    if byte == 0x22 {
                        fieldBytes.append(byte)
                        quotePending = false
                    } else {
                        inQuotes = false
                        quotePending = false
                        try consumeOutsideQuotes(byte, body: body)
                    }
                } else if byte == 0x22 {
                    quotePending = true
                } else if byte != 0x0D {
                    fieldBytes.append(byte)
                }
                return
            }
            try consumeOutsideQuotes(byte, body: body)
        }

        private mutating func consumeOutsideQuotes(
            _ byte: UInt8,
            body: ([String], Int) throws -> Void
        ) throws {
            switch byte {
            case 0x22 where fieldBytes.isEmpty:
                inQuotes = true
            case 0x2C:
                finishField()
            case 0x0A:
                finishField()
                try finishRecord(body: body)
            case 0x0D:
                break
            default:
                fieldBytes.append(byte)
            }
        }

        private mutating func finishField() {
            fields.append(
                String(decoding: fieldBytes, as: UTF8.self)
            )
            fieldBytes.removeAll(keepingCapacity: true)
        }

        private mutating func finishRecord(
            body: ([String], Int) throws -> Void
        ) throws {
            defer {
                fields.removeAll(keepingCapacity: true)
            }
            guard fields.contains(where: { !$0.isEmpty }) else {
                return
            }
            recordNumber += 1
            try body(fields, recordNumber)
        }
    }

    private static let schema = "ecdict-rank-v3"
    private static let sqliteTransient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
    private static let stopTerms: Set<String> = [
        "一个", "一种", "一些", "所有", "每个", "自己", "其他", "以及",
        "对于", "关于", "根据", "由于", "可以", "进行", "表示", "用于",
        "通过", "没有", "不是", "就是", "因为", "所以", "如果", "但是",
        "而且", "然后", "其中", "这个", "那个", "什么", "怎么", "这样",
        "那样", "我们", "他们", "她们", "你们", "这些", "那些", "等等",
        "或者", "并且",
    ]
    private static let termSeparators: Set<Character> = [
        ";", "；", "\n", ",", "，", "/",
    ]
    private static let metadataMarkers = [
        "[人名]", "[地名]", "[电影]", "[书名]", "[影视]", "[歌曲]", "[品牌]",
    ]
    private static let sentencePunctuation: Set<Character> = [
        "!", "！", "?", "？",
    ]

    @discardableResult
    public static func build(
        fromCSVURL sourceURL: URL,
        to databaseURL: URL,
        sourceChecksum: String? = nil,
        sourceDate: String? = nil,
        sourceRevision: String? = nil
    ) throws -> ECDICTRankSummary {
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
            throw ECDICTRankBuilderError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        do {
            try execute(
                database,
                """
                PRAGMA journal_mode = OFF;
                PRAGMA synchronous = OFF;
                CREATE TABLE ranks (
                    term TEXT NOT NULL,
                    english TEXT NOT NULL,
                    frequency INTEGER NOT NULL,
                    collins INTEGER NOT NULL,
                    oxford INTEGER NOT NULL,
                    exam_tag INTEGER NOT NULL,
                    PRIMARY KEY (term, english)
                ) WITHOUT ROWID;
                CREATE TABLE metadata (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """
            )

            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            var reader = CSVStreamReader(handle: handle)
            var indexes: [String: Int]?
            var candidates: [String: [String: Ranking]] = [:]
            var parsedRows = 0
            try reader.forEach { fields, rowNumber in
                if indexes == nil {
                    indexes = try headerIndexes(fields)
                    return
                }
                guard let indexes else {
                    throw ECDICTRankBuilderError.invalidHeader
                }
                if rowNumber.isMultiple(of: 1_000) {
                    try Task.checkCancellation()
                }
                guard
                    let word = value(
                        "word",
                        from: fields,
                        indexes: indexes
                    ),
                    let translation = value(
                        "translation",
                        from: fields,
                        indexes: indexes
                    )
                else {
                    throw ECDICTRankBuilderError.invalidRecord(rowNumber)
                }
                parsedRows += 1
                try appendCandidate(
                    word: word,
                    translation: translation,
                    collins: intValue(
                        "collins",
                        fields: fields,
                        indexes: indexes
                    ),
                    oxford: value(
                        "oxford",
                        from: fields,
                        indexes: indexes
                    )?.isEmpty == false,
                    frequency: frequency(
                        fields: fields,
                        indexes: indexes
                    ),
                    examTagged: value(
                        "tag",
                        from: fields,
                        indexes: indexes
                    )?.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty == false,
                    candidates: &candidates
                )
            }
            try Task.checkCancellation()
            guard parsedRows > 0 else {
                throw ECDICTRankBuilderError.invalidHeader
            }

            let insertRank = try prepare(
                database,
                """
                INSERT INTO ranks(
                    term,
                    english,
                    frequency,
                    collins,
                    oxford,
                    exam_tag
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            )
            defer { sqlite3_finalize(insertRank) }
            try execute(database, "BEGIN IMMEDIATE;")
            do {
                for (term, bucket) in candidates {
                    let top =
                        bucket
                        .map { RankedWord(english: $0.key, ranking: $0.value) }
                        .sorted {
                            if $0.ranking != $1.ranking {
                                return $0.ranking < $1.ranking
                            }
                            if $0.english.count != $1.english.count {
                                return $0.english.count < $1.english.count
                            }
                            return $0.english < $1.english
                        }
                        .prefix(8)
                    for item in top {
                        sqlite3_reset(insertRank)
                        sqlite3_clear_bindings(insertRank)
                        bind(term, to: 1, in: insertRank)
                        bind(item.english, to: 2, in: insertRank)
                        sqlite3_bind_int64(
                            insertRank,
                            3,
                            Int64(item.ranking.frequency)
                        )
                        sqlite3_bind_int(
                            insertRank,
                            4,
                            Int32(item.ranking.collins)
                        )
                        sqlite3_bind_int(
                            insertRank,
                            5,
                            Int32(item.ranking.oxford)
                        )
                        sqlite3_bind_int(
                            insertRank,
                            6,
                            item.ranking.examTagged ? 1 : 0
                        )
                        guard sqlite3_step(insertRank) == SQLITE_DONE else {
                            throw ECDICTRankBuilderError.sqlite(
                                String(cString: sqlite3_errmsg(database))
                            )
                        }
                    }
                }
                try insertMetadata(
                    [
                        ("schema", schema),
                        ("source", "ECDICT"),
                        ("license", "MIT"),
                        ("source_checksum", sourceChecksum ?? ""),
                        ("source_date", sourceDate ?? ""),
                        ("source_revision", sourceRevision ?? ""),
                    ],
                    into: database
                )
                try execute(database, "PRAGMA user_version = 3;")
                try execute(database, "COMMIT;")
            } catch {
                try? execute(database, "ROLLBACK;")
                throw error
            }

            let summary = try inspect(
                databaseURL: databaseURL,
                fullIntegrityCheck: true
            )
            return summary
        } catch {
            try? FileManager.default.removeItem(at: databaseURL)
            throw error
        }
    }

    public static func inspect(
        databaseURL: URL,
        fullIntegrityCheck: Bool = false
    ) throws -> ECDICTRankSummary {
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
            throw ECDICTRankBuilderError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        let integritySQL =
            fullIntegrityCheck
            ? "PRAGMA integrity_check;"
            : "PRAGMA quick_check;"
        guard stringValue(database, sql: integritySQL) == "ok" else {
            throw ECDICTRankBuilderError.integrityCheckFailed
        }
        let storedSchema = stringValue(
            database,
            sql: "SELECT value FROM metadata WHERE key = 'schema'"
        )
        guard storedSchema == schema else {
            throw ECDICTRankBuilderError.invalidSchema
        }
        guard hasRankSchema(database) else {
            throw ECDICTRankBuilderError.invalidSchema
        }
        let termCount =
            intValue(
                database,
                sql: "SELECT COUNT(DISTINCT term) FROM ranks"
            ) ?? 0
        let rankCount =
            intValue(
                database,
                sql: "SELECT COUNT(*) FROM ranks"
            ) ?? 0
        guard termCount > 0, rankCount > 0 else {
            throw ECDICTRankBuilderError.invalidSchema
        }
        return ECDICTRankSummary(
            sourceChecksum: nonEmptyStringValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'source_checksum'"
            ),
            sourceDate: nonEmptyStringValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'source_date'"
            ),
            sourceRevision: nonEmptyStringValue(
                database,
                sql: "SELECT value FROM metadata WHERE key = 'source_revision'"
            ),
            termCount: termCount,
            rankCount: rankCount
        )
    }

    public static func isCompatible(databaseURL: URL) -> Bool {
        (try? inspect(databaseURL: databaseURL)) != nil
    }

    private static func appendCandidate(
        word: String,
        translation: String,
        collins: Int,
        oxford: Bool,
        frequency: Int,
        examTagged: Bool,
        candidates: inout [String: [String: Ranking]]
    ) throws {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translation.replacingOccurrences(
            of: "\\n",
            with: "\n"
        )
        guard !word.isEmpty,
            !translation.isEmpty,
            word.count <= 32,
            !word.contains(where: isHan),
            frequency <= 200_000
        else {
            return
        }
        let ranking = Ranking(
            frequency: frequency,
            collins: collins,
            oxford: oxford ? 1 : 0,
            examTagged: examTagged
        )
        for term in terms(in: translation) {
            let previous = candidates[term]?[word]
            if previous == nil || ranking < previous! {
                candidates[term, default: [:]][word] = ranking
            }
        }
    }

    private static func terms(in translation: String) -> Set<String> {
        var result: Set<String> = []
        for part in translation.split(
            whereSeparator: { termSeparators.contains($0) }
        ) {
            let value = removingParentheticals(String(part))
            guard !isMetadataFragment(value),
                !value.contains(where: sentencePunctuation.contains)
            else {
                continue
            }
            var run: [Character] = []
            for character in value {
                if isHan(character) {
                    run.append(character)
                } else {
                    appendTerms(from: run, to: &result)
                    run.removeAll(keepingCapacity: true)
                }
            }
            appendTerms(from: run, to: &result)
        }
        return result
    }

    private static func isMetadataFragment(_ value: String) -> Bool {
        metadataMarkers.contains { value.contains($0) }
    }

    private static func removingParentheticals(
        _ value: String
    ) -> String {
        var result = ""
        var depth = 0
        for character in value {
            switch character {
            case "(", "（":
                depth += 1
            case ")", "）":
                depth = max(0, depth - 1)
            default:
                if depth == 0 {
                    result.append(character)
                }
            }
        }
        return result
    }

    private static func appendTerms(
        from characters: [Character],
        to result: inout Set<String>
    ) {
        var remaining = characters[...]
        while remaining.count >= 2 {
            let count = min(6, remaining.count)
            let term = String(remaining.prefix(count))
            if !stopTerms.contains(term) {
                result.insert(term)
            }
            remaining = remaining.dropFirst(count)
        }
    }

    private static func isHan(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first
        else {
            return false
        }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    private static func headerIndexes(
        _ fields: [String]
    ) throws -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, field) in fields.enumerated() {
            indexes[field.lowercased()] = index
        }
        indexes["word"] =
            indexes["word"].map { $0 }
            ?? indexes["\u{FEFF}word"]
        guard indexes["word"] != nil, indexes["translation"] != nil else {
            throw ECDICTRankBuilderError.invalidHeader
        }
        return indexes
    }

    private static func value(
        _ name: String,
        from fields: [String],
        indexes: [String: Int]
    ) -> String? {
        guard let index = indexes[name], fields.indices.contains(index) else {
            return nil
        }
        return fields[index]
    }

    private static func intValue(
        _ name: String,
        fields: [String],
        indexes: [String: Int]
    ) -> Int {
        Int(
            value(name, from: fields, indexes: indexes)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ) ?? 0
    }

    private static func frequency(
        fields: [String],
        indexes: [String: Int]
    ) -> Int {
        for name in ["frq", "bnc"] {
            let value = intValue(
                name,
                fields: fields,
                indexes: indexes
            )
            if value > 0 {
                return value
            }
        }
        return 500_000
    }

    private static func hasRankSchema(
        _ database: OpaquePointer?
    ) -> Bool {
        let required = Set([
            "term", "english", "frequency", "collins", "oxford",
            "exam_tag",
        ])
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "PRAGMA table_info(ranks);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK
        else {
            return false
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
        return required.isSubset(of: columns)
    }

    private static func insertMetadata(
        _ values: [(String, String)],
        into database: OpaquePointer?
    ) throws {
        let statement = try prepare(
            database,
            "INSERT INTO metadata(key, value) VALUES (?, ?)"
        )
        defer { sqlite3_finalize(statement) }
        for (key, value) in values {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            bind(key, to: 1, in: statement)
            bind(value, to: 2, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ECDICTRankBuilderError.sqlite(
                    String(cString: sqlite3_errmsg(database))
                )
            }
        }
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
        _ database: OpaquePointer?,
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
            throw ECDICTRankBuilderError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
        return statement
    }

    private static func execute(
        _ database: OpaquePointer?,
        _ sql: String
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw ECDICTRankBuilderError.sqlite(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private static func stringValue(
        _ database: OpaquePointer?,
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

    private static func nonEmptyStringValue(
        _ database: OpaquePointer?,
        sql: String
    ) -> String? {
        stringValue(database, sql: sql).flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    private static func intValue(
        _ database: OpaquePointer?,
        sql: String
    ) -> Int? {
        guard let statement = try? prepare(database, sql) else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
