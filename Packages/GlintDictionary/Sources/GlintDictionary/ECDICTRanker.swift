import Foundation
import SQLite3

struct EnglishRanking: Sendable, Equatable {
    let english: String
    let frequency: Int
    let collins: Int
    let oxford: Int
}

public final class ECDICTRanker: @unchecked Sendable {
    private var database: OpaquePointer?
    private var statement: OpaquePointer?
    private let lock = NSLock()
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL? = nil) {
        guard let url = databaseURL ?? Self.locateDatabase() else { return }
        sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard database != nil else { return }
        sqlite3_prepare_v2(
            database,
            """
            SELECT english, frequency, collins, oxford
            FROM ranks
            WHERE term = ?
            ORDER BY frequency ASC, collins DESC, oxford DESC
            LIMIT 12
            """,
            -1,
            &statement,
            nil
        )
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    /// Pick an ECDICT headword that is already one of the CEDICT candidates.
    public func rankCandidates(term: String, candidates: [String]) -> String? {
        var normalizedCandidates: [String: String] = [:]
        for candidate in candidates {
            normalizedCandidates[Self.normalize(candidate)] = candidate
        }
        for row in rows(for: term) {
            if let original = normalizedCandidates[Self.normalize(row.english)] {
                return original
            }
        }
        return nil
    }

    /// Coverage fallback for terms missing from CEDICT. Avoid rare/unknown
    /// ECDICT entries by requiring a real corpus frequency.
    public func fallbackEnglish(term: String, maxFrequency: Int = 100_000) -> String? {
        fallbackCandidates(
            term: term,
            maxFrequency: maxFrequency,
            limit: 1
        ).first
    }

    public func fallbackCandidates(
        term: String,
        maxFrequency: Int = 100_000,
        limit: Int = 3
    ) -> [String] {
        rows(for: term)
            .filter {
                $0.frequency <= maxFrequency
                    && $0.english.count > 1
            }
            .prefix(max(0, limit))
            .map(\.english)
    }

    func rankings(for term: String) -> [EnglishRanking] {
        rows(for: term)
    }

    private func rows(for term: String) -> [EnglishRanking] {
        lock.lock()
        defer { lock.unlock() }
        guard let statement else { return [] }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, term, -1, sqliteTransient)

        var result: [EnglishRanking] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            let english = String(
                cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self)
            )
            result.append(
                EnglishRanking(
                    english: english,
                    frequency: Int(sqlite3_column_int(statement, 1)),
                    collins: Int(sqlite3_column_int(statement, 2)),
                    oxford: Int(sqlite3_column_int(statement, 3))
                )
            )
        }
        return result
    }

    private static func normalize(_ text: String) -> String {
        var value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["to ", "the ", "a ", "an ", "be ", "of "] {
            if value.hasPrefix(prefix) {
                value = String(value.dropFirst(prefix.count))
                break
            }
        }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        value = String(value.unicodeScalars.filter { allowed.contains($0) })
        if value.count > 3, value.hasSuffix("s") {
            value = String(value.dropLast())
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func locateDatabase() -> URL? {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent(
                "Glint/plugins/dict-ecdict/ecdict_rank.sqlite3"
            )
        if let support, FileManager.default.fileExists(atPath: support.path) {
            return support
        }
        let candidates = [
            Bundle.main.url(
                forResource: "ecdict_rank",
                withExtension: "sqlite3",
                subdirectory: "Plugins/dict-ecdict"
            ),
            Bundle.main.url(
                forResource: "ecdict_rank",
                withExtension: "sqlite3",
                subdirectory: "Resources/Plugins/dict-ecdict"
            ),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(
                    "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
                ),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
