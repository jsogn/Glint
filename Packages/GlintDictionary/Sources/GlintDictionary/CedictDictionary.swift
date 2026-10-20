import Foundation
import GlintCore
import SQLite3

public final class CedictDictionary: DictionaryEngine, @unchecked Sendable {
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum OverrideValue: Decodable {
        case single(String)
        case multiple([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .single(value)
            } else {
                self = .multiple(try container.decode([String].self))
            }
        }

        var values: [String] {
            switch self {
            case .single(let value): return [value]
            case .multiple(let values): return values
            }
        }
    }

    private struct Overrides: Decodable {
        let overrides: [String: OverrideValue]
        let blocked: [String]
    }

    private var database: OpaquePointer?
    private var statement: OpaquePointer?
    private let lock = NSLock()
    private let ranker: ECDICTRanker?
    private let overrides: [String: [String]]
    private let blocked: Set<String>
    private let builtin: [String: String]

    public init(
        databaseURL: URL? = nil,
        overridesURL: URL? = nil,
        builtin: [String: String] = CedictDictionary.builtin,
        ranker: ECDICTRanker? = ECDICTRanker()
    ) {
        self.builtin = builtin
        self.ranker = ranker

        let resolvedDatabase = databaseURL ?? Self.locateResource(
            name: "cedict",
            extension: "sqlite3"
        )
        let resolvedOverrides = overridesURL ?? Self.locateResource(
            name: "overrides",
            extension: "json"
        )

        if let resolvedOverrides,
           let data = try? Data(contentsOf: resolvedOverrides),
           let decoded = try? JSONDecoder().decode(Overrides.self, from: data) {
            self.overrides = decoded.overrides.mapValues { $0.values }
            self.blocked = Set(decoded.blocked)
        } else {
            self.overrides = Self.defaultOverrides.mapValues { [$0] }
            self.blocked = ["打", "尼", "你号"]
        }

        if let resolvedDatabase {
            sqlite3_open_v2(
                resolvedDatabase.path,
                &database,
                SQLITE_OPEN_READONLY,
                nil
            )
            if database != nil {
                sqlite3_prepare_v2(
                    database,
                    "SELECT gloss FROM entries WHERE word = ? LIMIT 1",
                    -1,
                    &statement,
                    nil
                )
            }
        }
    }

    deinit {
        sqlite3_finalize(statement)
        sqlite3_close(database)
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !blocked.contains(text) else { return nil }

        let preferred = overrides[text]?.enumerated().map { index, value in
            TranslationOption(
                text: value,
                score: 2.0 - Double(index) * 0.04
            )
        } ?? []

        if let gloss = queryDatabase(text) {
            let dictionaryOptions = rankedGlossOptions(term: text, gloss: gloss)
            let options = preferred + dictionaryOptions
            guard !options.isEmpty else { return nil }
            return TranslationResult(
                options: options,
                source: .dictionary,
                confidence: preferred.isEmpty ? 0.85 : 0.99
            )
        }
        if !preferred.isEmpty {
            return TranslationResult(
                options: preferred,
                source: .dictionary,
                confidence: 0.99
            )
        }
        if let value = builtin[text] {
            return TranslationResult(text: value, source: .dictionary, confidence: 0.8)
        }
        return nil
    }

    private func queryDatabase(_ text: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let statement else { return nil }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, text, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(
            cString: UnsafeRawPointer(cString).assumingMemoryBound(to: CChar.self)
        )
    }

    /// Turn a CC-CEDICT gloss into compact English candidates.
    private func glossCandidates(from gloss: String) -> [String] {
        gloss
            .split(whereSeparator: { $0 == ";" || $0 == "/" })
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("CL:") }
    }

    private func rankedGlossOptions(
        term: String,
        gloss: String
    ) -> [TranslationOption] {
        var rankingByEnglish: [String: EnglishRanking] = [:]
        for ranking in ranker?.rankings(for: term) ?? [] {
            let key = Self.normalize(ranking.english)
            if rankingByEnglish[key] == nil {
                rankingByEnglish[key] = ranking
            }
        }

        return glossCandidates(from: gloss).enumerated().compactMap { index, value in
            let compact = compactEquivalent(value)
            let key = Self.normalize(compact)
            guard !key.isEmpty else { return nil }

            var score = 1.0 - Double(index) * 0.06
            if let ranking = rankingByEnglish[key] {
                let frequency = Double(max(1, ranking.frequency))
                score += max(0, 0.25 - log10(frequency) * 0.04)
                score += Double(ranking.collins) * 0.012
                score += Double(ranking.oxford) * 0.008
            }
            if compact.contains(" ") {
                score -= 0.05
            }
            return TranslationOption(text: compact, score: score)
        }
    }

    private func compactEquivalent(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("("), let closing = result.firstIndex(of: ")") {
            result = String(result[result.index(after: closing)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for prefix in ["to ", "the ", "a ", "an ", "be ", "of "] {
            if result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count))
                break
            }
        }
        return result.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
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
            ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Dictionary")
            ?? Bundle.main.url(
                forResource: name,
                withExtension: ext,
                subdirectory: "Resources/Dictionary"
            )
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Dictionary/\(name).\(ext)")
    }

    public static let builtin: [String: String] = [
        "你好": "hello",
        "你好吗": "How are you?",
        "算法": "algorithm",
        "计算": "calculate",
        "复盘": "retrospective",
        "中国": "China",
    ]

    private static let defaultOverrides: [String: String] = [
        "你好": "hello",
        "算法": "algorithm",
        "计算": "calculate",
        "复盘": "retrospective",
        "对齐": "align",
        "输入法": "input method",
        "迭代": "iterate",
        "需求": "requirement",
        "场景": "scenario",
        "指标": "metric",
        "落地": "implement",
        "拆分": "break down",
        "收敛": "converge",
        "兜底": "fallback",
        "权衡": "trade-off",
        "里程碑": "milestone",
        "语义": "semantics",
        "推理": "reasoning",
        "上下文": "context",
        "颗粒度": "granularity",
    ]
}
