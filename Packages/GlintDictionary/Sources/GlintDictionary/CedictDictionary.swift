import Foundation
import GlintCore
import SQLite3

public final class CedictDictionary: DictionaryEngine, @unchecked Sendable {
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private struct DictionarySense {
        let gloss: String
        let lineOrder: Int
        let senseOrder: Int
    }

    private var database: OpaquePointer?
    private var senseStatement: OpaquePointer?
    private let lock = NSLock()
    private let ranker: ECDICTRanker?

    public init(
        databaseURL: URL? = nil,
        ranker: ECDICTRanker? = nil
    ) {
        self.ranker = ranker

        let resolvedDatabase =
            databaseURL
            ?? Self.locateResource(
                name: "cedict",
                extension: "sqlite3"
            )

        if let resolvedDatabase {
            let openResult = sqlite3_open_v2(
                resolvedDatabase.path,
                &database,
                SQLITE_OPEN_READONLY,
                nil
            )
            if openResult == SQLITE_OK, database != nil {
                let prepareResult = sqlite3_prepare_v2(
                    database,
                    """
                    SELECT gloss, line_order, sense_order
                    FROM entries
                    WHERE simplified = ? OR traditional = ?
                    ORDER BY line_order, sense_order
                    LIMIT 64
                    """,
                    -1,
                    &senseStatement,
                    nil
                )
                if prepareResult != SQLITE_OK {
                    sqlite3_finalize(senseStatement)
                    senseStatement = nil
                    sqlite3_close(database)
                    database = nil
                }
            } else {
                sqlite3_close(database)
                database = nil
            }
        }
    }

    deinit {
        sqlite3_finalize(senseStatement)
        sqlite3_close(database)
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
            !DictionaryPolicy.blockedTerms.contains(text)
        else {
            return nil
        }

        let senses = querySenses(text)
        if !senses.isEmpty {
            let options = rankedSenseOptions(
                term: text,
                senses: senses
            )
            guard !options.isEmpty else { return nil }
            return TranslationResult(options: options)
        }
        return nil
    }

    private func querySenses(_ text: String) -> [DictionarySense] {
        lock.lock()
        defer { lock.unlock() }

        guard let statement = senseStatement else { return [] }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, text, -1, sqliteTransient)

        var result: [DictionarySense] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let gloss = Self.columnText(statement, 0) else {
                continue
            }
            result.append(
                DictionarySense(
                    gloss: gloss,
                    lineOrder: Int(
                        sqlite3_column_int(statement, 1)
                    ),
                    senseOrder: Int(
                        sqlite3_column_int(statement, 2)
                    )
                )
            )
        }
        return result
    }

    /// Turn a CC-CEDICT gloss into compact English candidates.
    private func glossCandidates(from gloss: String) -> [String] {
        gloss
            .split(whereSeparator: { $0 == ";" || $0 == "/" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("CL:") }
    }

    private func rankedSenseOptions(
        term: String,
        senses: [DictionarySense]
    ) -> [TranslationOption] {
        var rankingByEnglish: [String: EnglishRanking] = [:]
        for ranking in ranker?.rankings(for: term) ?? [] {
            let key = EnglishWordNormalizer.normalize(ranking.english)
            if rankingByEnglish[key] == nil {
                rankingByEnglish[key] = ranking
            }
        }
        var options: [TranslationOption] = []
        for sense in senses {
            let orderPenalty =
                Double(sense.lineOrder) * 0.00000001
                + Double(sense.senseOrder) * 0.000000001
            for (index, value) in glossCandidates(
                from: sense.gloss
            ).enumerated() {
                guard let compact = DictionarySurface.normalize(value) else {
                    continue
                }
                let key = EnglishWordNormalizer.normalize(compact)
                guard !key.isEmpty else {
                    continue
                }

                var score = 1.0 - Double(index) * 0.06 - orderPenalty
                if let ranking = rankingByEnglish[key] {
                    let frequency = Double(max(1, ranking.frequency))
                    score += max(0, 0.25 - log10(frequency) * 0.04)
                    score += Double(ranking.collins) * 0.012
                    score += Double(ranking.oxford) * 0.008
                }
                if compact.contains(" ") {
                    score -= 0.05
                }
                options.append(
                    TranslationOption(text: compact, score: score)
                )
            }
        }
        return options
    }

    private static func columnText(
        _ statement: OpaquePointer,
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

    private static func locateResource(name: String, extension ext: String) -> URL? {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
        .appendingPathComponent("Glint/plugins/dict-cedict", isDirectory: true)
        let pluginURL = support?.appendingPathComponent("\(name).\(ext)")
        if let pluginURL, FileManager.default.fileExists(atPath: pluginURL.path) {
            return pluginURL
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
            ?? Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "dict-cedict"
            )
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(
                "Resources/Plugins/dict-cedict/\(name).\(ext)"
            )
    }

}
