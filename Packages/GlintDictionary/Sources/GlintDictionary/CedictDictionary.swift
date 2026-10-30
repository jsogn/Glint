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
                    SELECT senses.gloss, terms.entry_id, senses.sense_order
                    FROM terms
                    JOIN senses ON senses.entry_id = terms.entry_id
                    WHERE terms.term = ?
                    ORDER BY terms.entry_id, senses.sense_order
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
            .map(Self.leadingQuotedHeadword)
    }

    private static func leadingQuotedHeadword(
        from value: String
    ) -> String {
        var remaining = value
        while remaining.first == "(" {
            guard let closing = remaining.firstIndex(of: ")") else {
                return value
            }
            remaining = String(remaining[remaining.index(after: closing)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let opening = remaining.first else { return value }
        let closingCharacter: Character
        switch opening {
        case "\"":
            closingCharacter = "\""
        case "“":
            closingCharacter = "”"
        default:
            return value
        }
        let contentStart = remaining.index(after: remaining.startIndex)
        guard
            let closing = remaining[contentStart...].firstIndex(
                of: closingCharacter
            ),
            closing > contentStart
        else {
            return value
        }
        return String(remaining[contentStart..<closing])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rankedSenseOptions(
        term: String,
        senses: [DictionarySense]
    ) -> [TranslationOption] {
        let rankings = (ranker?.rankings(for: term) ?? [])
            .filter {
                ($0.frequency <= 100_000 || $0.examTagged)
                    && $0.english.count > 1
            }
        var rankingByEnglish: [String: EnglishRanking] = [:]
        var rankingIndexByEnglish: [String: Int] = [:]
        for (index, ranking) in rankings.enumerated() {
            let key = EnglishWordNormalizer.normalize(ranking.english)
            if rankingByEnglish[key] == nil {
                rankingByEnglish[key] = ranking
                rankingIndexByEnglish[key] = index
            }
        }
        var options: [TranslationOption] = []
        var sourceSurfaces: [String] = []
        for sense in senses {
            let orderPenalty =
                Double(sense.lineOrder) * 0.00000001
                + Double(sense.senseOrder) * 0.03
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
                sourceSurfaces.append(compact)

                var score = 1.0 - Double(index) * 0.06 - orderPenalty
                if let ranking = rankingByEnglish[key] {
                    let frequency = Double(max(1, ranking.frequency))
                    score += max(0, 0.25 - log10(frequency) * 0.04)
                    score += Double(ranking.collins) * 0.012
                    score += Double(ranking.oxford) * 0.008
                    let rankingIndex = rankingIndexByEnglish[key] ?? 0
                    if rankingIndex > 0,
                        !Self.matchesRankingSurface(
                            compact,
                            rankingEnglish: ranking.english
                        )
                    {
                        score -= min(
                            0.20,
                            Double(rankingIndex) * 0.04
                        )
                    }
                }
                if compact.contains(" ") {
                    score -= 0.05
                }
                options.append(
                    TranslationOption(text: compact, score: score)
                )
            }
        }
        let representedKeys = Set(
            sourceSurfaces.map(EnglishWordNormalizer.normalize)
        )
        let sourceOptionCount = options.count
        guard
            let sourceScoreFloor = options.map(\.score).min()
        else {
            return options
        }
        var supplementCount = 0
        for (index, ranking) in rankings.prefix(6).enumerated() {
            guard
                let compact = DictionarySurface.normalize(ranking.english),
                !compact.isEmpty,
                !representedKeys.contains(
                    EnglishWordNormalizer.normalize(compact)
                )
            else {
                continue
            }
            let supportedBySource = Self.containsPhrase(
                compact,
                in: sourceSurfaces
            )
            let supportedByTag =
                ranking.examTagged
                && sourceOptionCount + supplementCount < 3
            guard supportedBySource || supportedByTag else { continue }
            let frequency = Double(max(1, ranking.frequency))
            let frequencyBoost = max(
                0,
                0.25 - log10(frequency) * 0.04
            )
            var score =
                0.82
                - Double(index) * 0.035
                + frequencyBoost
                + Double(ranking.collins) * 0.012
                + Double(ranking.oxford) * 0.008
            // Prefer a concise source-backed headword over a multi-word gloss.
            if !compact.contains(" ") {
                score += 0.04
            }
            if compact.contains(" ") {
                score -= 0.05
            }
            if !supportedBySource {
                score = min(
                    score,
                    sourceScoreFloor - 0.005
                        - Double(supplementCount) * 0.005
                )
                supplementCount += 1
            }
            options.append(
                TranslationOption(text: compact, score: score)
            )
        }
        return options
    }

    private static func containsPhrase(
        _ phrase: String,
        in surfaces: [String]
    ) -> Bool {
        let phrase = phraseTokens(phrase)
        guard !phrase.isEmpty else { return false }
        let needle = " \(phrase.joined(separator: " ")) "
        return surfaces.contains { surface in
            let value = phraseTokens(surface)
            return " \(value.joined(separator: " ")) ".contains(needle)
        }
    }

    private static func matchesRankingSurface(
        _ surface: String,
        rankingEnglish: String
    ) -> Bool {
        guard
            let rankingSurface = DictionarySurface.normalize(
                rankingEnglish
            )
        else {
            return false
        }
        return surface.compare(
            rankingSurface,
            options: [.caseInsensitive]
        ) == .orderedSame
    }

    private static func phraseTokens(_ value: String) -> [String] {
        value
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
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
