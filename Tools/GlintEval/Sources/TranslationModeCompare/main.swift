import Foundation
import GlintCore
import GlintDictionary
import GlintInference

private struct EvaluationCase: Decodable {
    let text: String
    let category: String
    let expected: [String]
    let forbidden: [String]?
}

private struct ModeRow: Encodable {
    let model: String
    let mode: String
    let text: String
    let category: String
    let top1: Bool
    let top3: Bool
    let missing: Bool
    let forbiddenHit: Bool
    let latencyMilliseconds: Double
    let primary: String?
    let options: [String]
}

private struct CategorySummary: Encodable {
    let category: String
    let total: Int
    let top1: Int
    let top3: Int
    let missing: Int
    let forbiddenHits: Int
}

private struct ModeSummary: Encodable {
    let model: String
    let mode: String
    let total: Int
    let top1: Int
    let top3: Int
    let missing: Int
    let forbiddenHits: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let categories: [CategorySummary]
}

private struct EvaluationReport: Encodable {
    let generatedAt: String
    let caseCount: Int
    let summaries: [ModeSummary]
    let rows: [ModeRow]
}

@main
struct TranslationModeCompare {
    static func main() async throws {
        let options = try Options(arguments: CommandLine.arguments)
        if let metalLibrary = options.metalLibrary {
            MLXTranslationEngine.configureMetalLibrary(
                at: URL(fileURLWithPath: metalLibrary)
            )
        }
        let cases = try loadCases(paths: options.casesPaths)
        let dictionary = makeDictionary(resourcesPath: options.resourcesPath)
        var rows: [ModeRow] = []

        if let engine = try? CTranslate2Engine(
            modelDirectory: URL(fileURLWithPath: options.ct2Path)
        ) {
            let router = SmartRouter(
                dictionary: dictionary,
                translation: engine
            )
            rows.append(
                contentsOf: await evaluate(
                    model: "opus-mt",
                    cases: cases,
                    router: router
                )
            )
        } else {
            fputs("warning: OPUS-MT unavailable\n", stderr)
        }

        let mlx = MLXTranslationEngine(
            modelDirectory: URL(fileURLWithPath: options.mlxPath),
            modelID: options.mlxModelID
        )
        try await mlx.prepareForTranslation()
        try? await mlx.warmUp()
        let router = SmartRouter(
            dictionary: dictionary,
            translation: mlx
        )
        rows.append(
            contentsOf: await evaluate(
                model: options.mlxModelID,
                cases: cases,
                router: router
            )
        )

        let summaries = makeSummaries(rows)
        let report = EvaluationReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            caseCount: cases.count,
            summaries: summaries,
            rows: rows
        )
        print("cases=\(cases.count)")
        print(
            "model\tmode\ttop1\ttop3\tmissing\tforbidden\tp50_ms\tp95_ms"
        )
        for summary in summaries {
            print(
                "\(summary.model)\t\(summary.mode)\t"
                    + "\(summary.top1)/\(summary.total)\t"
                    + "\(summary.top3)/\(summary.total)\t"
                    + "\(summary.missing)\t\(summary.forbiddenHits)\t"
                    + "\(summary.p50Milliseconds)\t"
                    + "\(summary.p95Milliseconds)"
            )
            for category in summary.categories {
                print(
                    "  \(category.category)\t"
                        + "\(category.top1)/\(category.total)\t"
                        + "\(category.top3)/\(category.total)\t"
                        + "missing=\(category.missing)\t"
                        + "forbidden=\(category.forbiddenHits)"
                )
            }
        }
        print("")
        print("model\tmode\ttext\tprimary\toptions")
        for row in rows {
            print(
                "\(row.model)\t\(row.mode)\t\(row.text)\t"
                    + "\(row.primary ?? "<missing>")\t"
                    + row.options.joined(separator: " | ")
            )
        }
        if let output = options.outputPath {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(
                to: URL(fileURLWithPath: output),
                options: .atomic
            )
        }
    }

    private static func evaluate(
        model: String,
        cases: [EvaluationCase],
        router: SmartRouter
    ) async -> [ModeRow] {
        var rows: [ModeRow] = []
        for mode in TranslationMode.allCases {
            for item in cases {
                let candidate = Candidate(
                    text: item.text,
                    kind: CandidateClassifier.classify(item.text)
                )
                let started = ContinuousClock.now
                let result = try? await router.route(
                    candidate,
                    mode: mode,
                    includesAlternatives: true
                )
                let latency = milliseconds(
                    started.duration(to: .now)
                )
                let options = result?.options.map(\.text) ?? []
                let actual = options.map(normalize)
                let expected = Set(item.expected.map(normalize))
                let forbidden = Set((item.forbidden ?? []).map(normalize))
                rows.append(
                    ModeRow(
                        model: model,
                        mode: mode.rawValue,
                        text: item.text,
                        category: item.category,
                        top1: actual.first.map(expected.contains) ?? false,
                        top3: actual.prefix(3).contains(where: expected.contains),
                        missing: options.isEmpty,
                        forbiddenHit: actual.contains(where: forbidden.contains),
                        latencyMilliseconds: latency,
                        primary: options.first,
                        options: Array(options.prefix(6))
                    )
                )
            }
        }
        return rows
    }

    private static func makeSummaries(
        _ rows: [ModeRow]
    ) -> [ModeSummary] {
        let grouped = Dictionary(grouping: rows) {
            "\($0.model)\u{0}\($0.mode)"
        }
        return grouped.keys.sorted().compactMap { key -> ModeSummary? in
            guard let values = grouped[key], let first = values.first else {
                return nil
            }
            let groupedCategories = Dictionary(
                grouping: values,
                by: \.category
            )
            let categories = groupedCategories.keys
                .sorted()
                .compactMap { category -> CategorySummary? in
                    guard let categoryRows = groupedCategories[category] else {
                        return nil
                    }
                    return CategorySummary(
                        category: category,
                        total: categoryRows.count,
                        top1: categoryRows.count(where: \.top1),
                        top3: categoryRows.count(where: \.top3),
                        missing: categoryRows.count(where: \.missing),
                        forbiddenHits: categoryRows.count(
                            where: \.forbiddenHit
                        )
                    )
                }
            let latencies = values.map(\.latencyMilliseconds)
            return ModeSummary(
                model: first.model,
                mode: first.mode,
                total: values.count,
                top1: values.count(where: \.top1),
                top3: values.count(where: \.top3),
                missing: values.count(where: \.missing),
                forbiddenHits: values.count(where: \.forbiddenHit),
                p50Milliseconds: percentile(latencies, 0.5),
                p95Milliseconds: percentile(latencies, 0.95),
                categories: categories
            )
        }
    }

    private static func loadCases(
        paths: [String]
    ) throws -> [EvaluationCase] {
        var casesByText: [String: EvaluationCase] = [:]
        var order: [String] = []
        for path in paths {
            let data = try Data(
                contentsOf: URL(fileURLWithPath: path)
            )
            let decoded = try JSONDecoder().decode(
                [EvaluationCase].self,
                from: data
            )
            for item in decoded where !item.expected.isEmpty {
                if let existing = casesByText[item.text] {
                    let expected = Array(
                        Set(existing.expected + item.expected)
                    ).sorted()
                    let forbidden = Array(
                        Set((existing.forbidden ?? []) + (item.forbidden ?? []))
                    ).sorted()
                    casesByText[item.text] = EvaluationCase(
                        text: item.text,
                        category: existing.category,
                        expected: expected,
                        forbidden: forbidden.isEmpty ? nil : forbidden
                    )
                } else {
                    order.append(item.text)
                    casesByText[item.text] = item
                }
            }
        }
        return order.compactMap { casesByText[$0] }
    }

    private static func makeDictionary(
        resourcesPath: String
    ) -> DictionaryRouter {
        let resources = URL(fileURLWithPath: resourcesPath)
        let ecdictURL = resources.appendingPathComponent(
            "dict-ecdict/ecdict_rank.sqlite3"
        )
        let ranker = ECDICTRanker(databaseURL: ecdictURL)
        var routes = [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                role: .authoritative,
                engine: CedictDictionary(
                    databaseURL: resources.appendingPathComponent(
                        "dict-cedict/cedict.sqlite3"
                    ),
                    ranker: ranker
                )
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                role: .fallback,
                engine: ECDICTDictionary(ranker: ranker)
            ),
        ]
        if let wiktionary = GenericSQLiteDictionary(
            databaseURL: resources.appendingPathComponent(
                "dict-wiktionary-zh-en/dictionary.sqlite3"
            ),
            sourceLanguage: "zh-Hans",
            targetLanguage: "en"
        ) {
            routes.append(
                DictionaryRoute(
                    id: "dict-wiktionary-zh-en",
                    priority: 2,
                    role: .fallback,
                    engine: wiktionary
                )
            )
        }
        return DictionaryRouter(routes: routes)
    }

    private static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(
            text.lowercased().unicodeScalars.filter {
                allowed.contains($0)
            }
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds)
            / 1_000_000_000_000_000
    }

    private static func percentile(
        _ values: [Double],
        _ fraction: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let ordered = values.sorted()
        let index = min(
            ordered.count - 1,
            max(0, Int(((Double(ordered.count) - 1) * fraction).rounded()))
        )
        return (ordered[index] * 100).rounded() / 100
    }
}

private struct Options {
    let casesPaths: [String]
    let resourcesPath: String
    let ct2Path: String
    let mlxPath: String
    let mlxModelID: String
    let metalLibrary: String?
    let outputPath: String?

    init(arguments: [String]) throws {
        let values = Array(arguments.dropFirst())
        func value(after name: String) -> String? {
            guard let index = values.firstIndex(of: name),
                values.indices.contains(index + 1)
            else {
                return nil
            }
            return values[index + 1]
        }
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        let defaultCases = [
            "Resources/Evaluation/translation-mode-benchmark.json",
            "Resources/Evaluation/dictionary-benchmark.json",
        ].joined(separator: ",")
        let configuredCases =
            value(after: "--cases") ?? defaultCases
        casesPaths =
            configuredCases
            .split(separator: ",")
            .map(String.init)
        resourcesPath =
            value(after: "--resources")
            ?? "build/Build/Products/Debug/Glint.app/Contents/Resources"
        let resources = URL(fileURLWithPath: resourcesPath)
        ct2Path =
            value(after: "--ct2")
            ?? resources.appendingPathComponent(
                "mt-opus-zh-en/model",
                isDirectory: true
            ).path
        mlxPath =
            value(after: "--mlx")
            ?? applicationSupport.appendingPathComponent(
                "Glint/plugins/mt-hy-mt2-1.8b/model",
                isDirectory: true
            ).path
        mlxModelID =
            value(after: "--mlx-model-id")
            ?? "mt-hy-mt2-1.8b"
        metalLibrary =
            value(after: "--metallib")
            ?? resources.appendingPathComponent(
                "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
            ).path
        outputPath = value(after: "--output")
    }
}
