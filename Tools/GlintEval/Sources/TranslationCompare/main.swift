import Foundation
import GlintCore
import GlintInference

private struct EvaluationCase: Decodable {
    let id: String
    let input: String
    let kind: String
    let reference: String
}

private struct ModelMetrics: Encodable {
    let load_ms: Double
    let warmup_ms: Double
    let p50_ms: Double
    let p95_ms: Double
    let exact_rate: Double
    let token_f1: Double
}

private struct CaseResult: Encodable {
    let id: String
    let input: String
    let reference: String
    let mlx_output: String
    let ct2_output: String
    let mlx_ms: Double
    let ct2_ms: Double
}

private struct ComparisonReport: Encodable {
    let case_count: Int
    let rounds: Int
    let hy_mt2: ModelMetrics
    let opus_mt: ModelMetrics
    let rows: [CaseResult]
}

@main
struct TranslationCompare {
    static func main() async throws {
        let options = try Options(arguments: CommandLine.arguments)
        if let metalLibrary = options.metalLibrary {
            MLXTranslationEngine.configureMetalLibrary(
                at: URL(fileURLWithPath: metalLibrary)
            )
        }
        let cases = try loadCases(
            at: URL(fileURLWithPath: options.casesPath)
        )
        guard !cases.isEmpty else {
            throw ComparisonError.noCases
        }

        let mlx = MLXTranslationEngine(
            modelDirectory: URL(fileURLWithPath: options.mlxPath),
            modelID: options.mlxModelID
        )
        let mlxLoadStart = ContinuousClock.now
        _ = try await mlx.prepare()
        let mlxLoadMilliseconds = milliseconds(
            mlxLoadStart.duration(to: .now)
        )
        let mlxWarmupStart = ContinuousClock.now
        try await mlx.warmUp()
        let mlxWarmupMilliseconds = milliseconds(
            mlxWarmupStart.duration(to: .now)
        )

        let ct2Start = ContinuousClock.now
        let ct2 = try CTranslate2Engine(
            modelDirectory: URL(fileURLWithPath: options.ct2Path)
        )
        let ct2WarmupStart = ContinuousClock.now
        _ = try await ct2.translate(
            Candidate(
                text: "你好",
                kind: .word
            )
        )
        let ct2LoadMilliseconds = milliseconds(
            ct2Start.duration(to: ct2WarmupStart)
        )
        let ct2WarmupMilliseconds = milliseconds(
            ct2WarmupStart.duration(to: .now)
        )

        var mlxValues = [String](repeating: "", count: cases.count)
        var ct2Values = [String](repeating: "", count: cases.count)
        var mlxLatencies = [[Double]](
            repeating: [],
            count: cases.count
        )
        var ct2Latencies = [[Double]](
            repeating: [],
            count: cases.count
        )

        for round in 0..<options.rounds {
            for (index, evaluationCase) in cases.enumerated() {
                let candidate = Candidate(
                    text: evaluationCase.input,
                    kind: CandidateClassifier.classify(evaluationCase.input)
                )
                let mlxStarted = ContinuousClock.now
                let mlxResult = try? await mlx.translate(candidate)
                let mlxElapsed = milliseconds(
                    mlxStarted.duration(to: .now)
                )
                let ct2Started = ContinuousClock.now
                let ct2Result = try? await ct2.translate(candidate)
                let ct2Elapsed = milliseconds(
                    ct2Started.duration(to: .now)
                )
                guard round > 0 else { continue }
                mlxValues[index] = mlxResult?.displayText ?? "<error>"
                ct2Values[index] = ct2Result?.displayText ?? "<error>"
                mlxLatencies[index].append(mlxElapsed)
                ct2Latencies[index].append(ct2Elapsed)
            }
        }

        let mlxLatencyValues = mlxLatencies.compactMap(median)
        let ct2LatencyValues = ct2Latencies.compactMap(median)
        let mlxQuality = quality(
            predictions: mlxValues,
            references: cases.map(\.reference)
        )
        let ct2Quality = quality(
            predictions: ct2Values,
            references: cases.map(\.reference)
        )
        let rows = cases.indices.map { index in
            CaseResult(
                id: cases[index].id,
                input: cases[index].input,
                reference: cases[index].reference,
                mlx_output: mlxValues[index],
                ct2_output: ct2Values[index],
                mlx_ms: round(median(mlxLatencies[index]) ?? 0),
                ct2_ms: round(median(ct2Latencies[index]) ?? 0)
            )
        }
        let report = ComparisonReport(
            case_count: cases.count,
            rounds: options.rounds,
            hy_mt2: ModelMetrics(
                load_ms: round(mlxLoadMilliseconds),
                warmup_ms: round(mlxWarmupMilliseconds),
                p50_ms: round(percentile(mlxLatencyValues, 0.5)),
                p95_ms: round(percentile(mlxLatencyValues, 0.95)),
                exact_rate: round(mlxQuality.exact),
                token_f1: round(mlxQuality.f1)
            ),
            opus_mt: ModelMetrics(
                load_ms: round(ct2LoadMilliseconds),
                warmup_ms: round(ct2WarmupMilliseconds),
                p50_ms: round(percentile(ct2LatencyValues, 0.5)),
                p95_ms: round(percentile(ct2LatencyValues, 0.95)),
                exact_rate: round(ct2Quality.exact),
                token_f1: round(ct2Quality.f1)
            ),
            rows: rows
        )

        print(
            "cases=\(report.case_count) measured_rounds=\(options.rounds - 1)"
        )
        printMetrics("hy_mt2", report.hy_mt2)
        printMetrics("opus_mt", report.opus_mt)
        print("id\tkind\tinput\tmlx_ms\tct2_ms\tmlx\tct2")
        for (index, row) in rows.enumerated() {
            print(
                "\(row.id)\t\(cases[index].kind)\t\(row.input)\t"
                    + "\(row.mlx_ms)\t\(row.ct2_ms)\t"
                    + "\(row.mlx_output)\t\(row.ct2_output)"
            )
        }
        if options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private static func loadCases(at url: URL) throws -> [EvaluationCase] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([EvaluationCase].self, from: data)
            .filter {
                ["word", "phrase", "sentence"].contains($0.kind)
                    && $0.reference != "NO_DISPLAY"
            }
    }

    private static func printMetrics(
        _ name: String,
        _ metrics: ModelMetrics
    ) {
        print(
            "\(name) load_ms=\(metrics.load_ms) "
                + "warmup_ms=\(metrics.warmup_ms) "
                + "p50_ms=\(metrics.p50_ms) p95_ms=\(metrics.p95_ms) "
                + "exact=\(metrics.exact_rate) f1=\(metrics.token_f1)"
        )
    }
}

private struct Options {
    let casesPath: String
    let mlxPath: String
    let ct2Path: String
    let mlxModelID: String
    let metalLibrary: String?
    let rounds: Int
    let json: Bool

    init(arguments: [String]) throws {
        let values = Array(arguments.dropFirst())
        func value(after name: String) -> String? {
            guard let index = values.firstIndex(of: name),
                  values.indices.contains(index + 1) else {
                return nil
            }
            return values[index + 1]
        }
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let support = applicationSupport.appendingPathComponent(
            "Glint/plugins",
            isDirectory: true
        )
        casesPath = value(after: "--cases")
            ?? "Tools/ModelLab/eval/cases.json"
        mlxPath = value(after: "--mlx")
            ?? support.appendingPathComponent(
                "mt-hy-mt2-1.8b/model",
                isDirectory: true
            ).path
        ct2Path = value(after: "--ct2")
            ?? support.appendingPathComponent(
                "mt-opus-zh-en/model",
                isDirectory: true
            ).path
        mlxModelID = value(after: "--mlx-model-id")
            ?? "mt-hy-mt2-1.8b"
        metalLibrary = value(after: "--metallib")
        rounds = max(2, Int(value(after: "--rounds") ?? "3") ?? 3)
        json = values.contains("--json")
    }
}

private enum ComparisonError: LocalizedError {
    case noCases

    var errorDescription: String? {
        "No translation cases found"
    }
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let ordered = values.sorted()
    let middle = ordered.count / 2
    if ordered.count.isMultiple(of: 2) {
        return (ordered[middle - 1] + ordered[middle]) / 2
    }
    return ordered[middle]
}

private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let ordered = values.sorted()
    let index = min(
        ordered.count - 1,
        max(0, Int(((Double(ordered.count) - 1) * p).rounded()))
    )
    return ordered[index]
}

private func quality(
    predictions: [String],
    references: [String]
) -> (exact: Double, f1: Double) {
    guard predictions.count == references.count,
          !predictions.isEmpty else {
        return (0, 0)
    }
    var exactCount = 0
    var f1Sum = 0.0
    for (prediction, reference) in zip(predictions, references) {
        let predicted = tokens(prediction)
        let expected = tokens(reference)
        if predicted == expected {
            exactCount += 1
        }
        let predictedCounts = counts(predicted)
        let expectedCounts = counts(expected)
        let overlap = predictedCounts.reduce(0) {
            $0 + min($1.value, expectedCounts[$1.key, default: 0])
        }
        let denominator = predicted.count + expected.count
        f1Sum += denominator == 0
            ? 1
            : 2 * Double(overlap) / Double(denominator)
    }
    return (
        Double(exactCount) / Double(predictions.count),
        f1Sum / Double(predictions.count)
    )
}

private func tokens(_ text: String) -> [String] {
    let ignored: Set<String> = [
        "a", "an", "the", "to", "of", "for", "and",
    ]
    return text.lowercased()
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { !ignored.contains($0) }
}

private func counts(_ values: [String]) -> [String: Int] {
    values.reduce(into: [:]) {
        $0[$1, default: 0] += 1
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func round(_ value: Double) -> Double {
    (value * 1_000).rounded() / 1_000
}
