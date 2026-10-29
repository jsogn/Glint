import Darwin
import Foundation
import GlintCore
import GlintDictionary

private struct BenchmarkCase: Decodable {
    let text: String
    let category: String
    let expected: [String]
    let forbidden: [String]?
}

private struct CaseResult: Encodable {
    let text: String
    let category: String
    let expected: [String]
    let forbidden: [String]
    let primary: String?
    let displayed: String?
    let latencyMilliseconds: Double
    let top1: Bool
    let top3: Bool
    let violations: [String]
    let forbiddenPass: Bool
}

private struct BenchmarkReport: Encodable {
    let total: Int
    let top1: Int
    let top3: Int
    let missing: Int
    let p95Milliseconds: Double
    let dictionaryTotal: Int
    let dictionaryTop1: Int
    let dictionaryTop3: Int
    let modelTotal: Int
    let modelTop1: Int
    let modelTop3: Int
    let forbiddenViolations: Int
    let cases: [CaseResult]
}

@main
struct BenchmarkMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root =
            value(after: "--root", in: arguments)
            ?? FileManager.default.currentDirectoryPath
        let casesPath =
            value(after: "--cases", in: arguments)
            ?? "\(root)/Resources/Evaluation/dictionary-benchmark.json"
        let outputPath =
            value(after: "--output", in: arguments)
            ?? "\(root)/build/dictionary-benchmark.json"

        let data = try Data(contentsOf: URL(fileURLWithPath: casesPath))
        let cases = try JSONDecoder().decode([BenchmarkCase].self, from: data)

        let rootURL = URL(fileURLWithPath: root)
        let ecdictURL = rootURL.appendingPathComponent(
            "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
        )
        let ecdictRanker = ECDICTRanker(databaseURL: ecdictURL)
        var routes: [DictionaryRoute] = [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                role: .authoritative,
                engine: CedictDictionary(
                    databaseURL: rootURL.appendingPathComponent(
                        "Resources/Plugins/dict-cedict/cedict.sqlite3"
                    ),
                    ranker: ecdictRanker
                )
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                role: .fallback,
                engine: ECDICTDictionary(ranker: ecdictRanker)
            ),
        ]
        if let wiktionary = GenericSQLiteDictionary(
            databaseURL: rootURL.appendingPathComponent(
                "Resources/Plugins/dict-wiktionary-zh-en/dictionary.sqlite3"
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
        let router = DictionaryRouter(routes: routes)

        var results: [CaseResult] = []
        var latencies: [Double] = []
        for benchmarkCase in cases {
            let start = Date()
            let result = await router.lookup(
                Candidate(
                    text: benchmarkCase.text,
                    kind: CandidateClassifier.classify(benchmarkCase.text)
                )
            )
            let milliseconds = Date().timeIntervalSince(start) * 1_000
            latencies.append(milliseconds)

            let options = result?.options.map(\.text) ?? []
            let expected = benchmarkCase.expected.map(normalize)
            let actual = options.map(normalize)
            let forbiddenValues = benchmarkCase.forbidden ?? []
            let forbidden = forbiddenValues.map(normalize)
            let top1 =
                !expected.isEmpty
                && !actual.isEmpty
                && expected.contains(actual[0])
            let top3 =
                !expected.isEmpty
                && !actual.isEmpty
                && actual.prefix(3).contains { expected.contains($0) }
            let blockedPass = expected.isEmpty && actual.isEmpty
            let violations = actual.filter(forbidden.contains)
            results.append(
                CaseResult(
                    text: benchmarkCase.text,
                    category: benchmarkCase.category,
                    expected: benchmarkCase.expected,
                    forbidden: forbiddenValues,
                    primary: options.first,
                    displayed: result?.displayText,
                    latencyMilliseconds: milliseconds,
                    top1: top1 || blockedPass,
                    top3: top3 || blockedPass,
                    violations: violations,
                    forbiddenPass: violations.isEmpty
                )
            )
        }

        latencies.sort()
        let p95 =
            latencies.isEmpty
            ? 0
            : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
        let dictionaryResults = results.filter {
            $0.category != "phrase"
                && $0.category != "model"
        }
        let modelResults = results.filter {
            $0.category == "phrase"
                || $0.category == "model"
        }
        let report = BenchmarkReport(
            total: results.count,
            top1: results.filter(\.top1).count,
            top3: results.filter(\.top3).count,
            missing: results.filter { $0.primary == nil }.count,
            p95Milliseconds: p95,
            dictionaryTotal: dictionaryResults.count,
            dictionaryTop1: dictionaryResults.filter(\.top1).count,
            dictionaryTop3: dictionaryResults.filter(\.top3).count,
            modelTotal: modelResults.count,
            modelTop1: modelResults.filter(\.top1).count,
            modelTop3: modelResults.filter(\.top3).count,
            forbiddenViolations: results.filter {
                !$0.forbiddenPass
            }.count,
            cases: results
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(report)
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.write(to: outputURL)

        print("total=\(report.total)")
        print("top1=\(report.top1) (\(percent(report.top1, report.total)))")
        print("top3=\(report.top3) (\(percent(report.top3, report.total)))")
        print("missing=\(report.missing)")
        print(String(format: "p95=%.2fms", report.p95Milliseconds))
        print(
            "dictionary_top1=\(report.dictionaryTop1)"
                + "/\(report.dictionaryTotal)"
        )
        print(
            "dictionary_top3=\(report.dictionaryTop3)"
                + "/\(report.dictionaryTotal)"
        )
        print(
            "model_top1=\(report.modelTop1)/\(report.modelTotal)"
        )
        print(
            "model_top3=\(report.modelTop3)/\(report.modelTotal)"
        )
        print("forbidden_violations=\(report.forbiddenViolations)")
        print("report=\(outputPath)")

        let minimumDictionaryTop1 =
            doubleValue(
                after: "--min-dictionary-top1",
                in: arguments
            ) ?? 0.98
        let minimumDictionaryTop3 =
            doubleValue(
                after: "--min-dictionary-top3",
                in: arguments
            ) ?? 0.98
        let dictionaryTop1Rate = rate(
            report.dictionaryTop1,
            report.dictionaryTotal
        )
        let dictionaryTop3Rate = rate(
            report.dictionaryTop3,
            report.dictionaryTotal
        )
        guard dictionaryTop1Rate >= minimumDictionaryTop1,
            dictionaryTop3Rate >= minimumDictionaryTop3,
            report.forbiddenViolations == 0
        else {
            let message = String(
                format:
                    "Dictionary quality gate failed: top1=%.1f%% top3=%.1f%% forbidden=%d\n",
                dictionaryTop1Rate * 100,
                dictionaryTop3Rate * 100,
                report.forbiddenViolations
            )
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func normalize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return String(
            text.lowercased().unicodeScalars.filter {
                allowed.contains($0)
            }
        )
    }

    private static func percent(_ count: Int, _ total: Int) -> String {
        guard total > 0 else { return "0.0%" }
        return String(format: "%.1f%%", Double(count) / Double(total) * 100)
    }

    private static func doubleValue(
        after flag: String,
        in arguments: [String]
    ) -> Double? {
        value(after: flag, in: arguments).flatMap(Double.init)
    }

    private static func rate(_ count: Int, _ total: Int) -> Double {
        total > 0 ? Double(count) / Double(total) : 1
    }
}
