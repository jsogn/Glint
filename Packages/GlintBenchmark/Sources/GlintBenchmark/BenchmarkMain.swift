import Foundation
import GlintCore
import GlintDictionary

private struct BenchmarkCase: Decodable {
    let text: String
    let category: String
    let expected: [String]
}

private struct CaseResult: Encodable {
    let text: String
    let category: String
    let expected: [String]
    let primary: String?
    let displayed: String?
    let latencyMilliseconds: Double
    let top1: Bool
    let top3: Bool
}

private struct BenchmarkReport: Encodable {
    let total: Int
    let top1: Int
    let top3: Int
    let missing: Int
    let p95Milliseconds: Double
    let cases: [CaseResult]
}

@main
struct BenchmarkMain {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let root = value(after: "--root", in: arguments)
            ?? FileManager.default.currentDirectoryPath
        let casesPath = value(after: "--cases", in: arguments)
            ?? "\(root)/Resources/Evaluation/dictionary-benchmark.json"
        let outputPath = value(after: "--output", in: arguments)
            ?? "\(root)/build/dictionary-benchmark.json"

        let data = try Data(contentsOf: URL(fileURLWithPath: casesPath))
        let cases = try JSONDecoder().decode([BenchmarkCase].self, from: data)

        let rootURL = URL(fileURLWithPath: root)
        var routes: [DictionaryRoute] = [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                engine: CedictDictionary(
                    databaseURL: rootURL.appendingPathComponent(
                        "Resources/Dictionary/cedict.sqlite3"
                    ),
                    overridesURL: rootURL.appendingPathComponent(
                        "Resources/Dictionary/overrides.json"
                    )
                )
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                engine: ECDICTDictionary(
                    databaseURL: rootURL.appendingPathComponent(
                        "Resources/Plugins/dict-ecdict/ecdict_rank.sqlite3"
                    )
                )
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
                    engine: wiktionary
                )
            )
        }
        let router = DictionaryRouter(routes: routes)

        var results: [CaseResult] = []
        var latencies: [Double] = []
        for benchmarkCase in cases {
            let start = Date()
            let result = try? await router.lookup(
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
            let top1 = !expected.isEmpty
                && !actual.isEmpty
                && expected.contains(actual[0])
            let top3 = !expected.isEmpty
                && !actual.isEmpty
                && actual.prefix(3).contains { expected.contains($0) }
            let blockedPass = expected.isEmpty && actual.isEmpty
            results.append(
                CaseResult(
                    text: benchmarkCase.text,
                    category: benchmarkCase.category,
                    expected: benchmarkCase.expected,
                    primary: options.first,
                    displayed: result?.displayText,
                    latencyMilliseconds: milliseconds,
                    top1: top1 || blockedPass,
                    top3: top3 || blockedPass
                )
            )
        }

        latencies.sort()
        let p95 = latencies.isEmpty
            ? 0
            : latencies[min(latencies.count - 1, Int(Double(latencies.count) * 0.95))]
        let report = BenchmarkReport(
            total: results.count,
            top1: results.filter(\.top1).count,
            top3: results.filter(\.top3).count,
            missing: results.filter { $0.primary == nil }.count,
            p95Milliseconds: p95,
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
        print("report=\(outputPath)")
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static func percent(_ count: Int, _ total: Int) -> String {
        guard total > 0 else { return "0.0%" }
        return String(format: "%.1f%%", Double(count) / Double(total) * 100)
    }
}
