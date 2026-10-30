import Foundation
import GlintCore
import GlintEvalSupport
import GlintInference
@preconcurrency import Translation

struct AppleTranslationBenchmarkReport: Encodable, Sendable {
    let generatedAt: String
    let host: HostReport
    let sourceLanguage: String
    let targetLanguage: String
    let systemLanguageStatus: String
    let systemCanRequestDownloads: Bool?
    let caseCount: Int
    let measuredRounds: Int
    let appleTranslation: EngineReport
    let opusMT: EngineReport
    let rows: [CaseReport]
}

struct HostReport: Encodable, Sendable {
    let operatingSystem: String
    let architecture: String
}

struct EngineReport: Encodable, Sendable {
    let name: String
    let loadMilliseconds: Double?
    let preparationMilliseconds: Double?
    let firstCallMilliseconds: Double?
    let total: Int
    let top1: Int
    let top1Rate: Double
    let missing: Int
    let forbiddenHits: Int
    let p50Milliseconds: Double?
    let p95Milliseconds: Double?
    let failedRounds: Int
    let categories: [CategoryReport]
}

struct CategoryReport: Encodable, Sendable {
    let category: String
    let total: Int
    let top1: Int
    let missing: Int
    let forbiddenHits: Int
}

struct CaseReport: Encodable, Sendable {
    let text: String
    let category: String
    let candidateKind: String
    let expected: [String]
    let forbidden: [String]
    let appleOutput: String?
    let appleError: String?
    let appleMilliseconds: Double?
    let opusOutput: String?
    let opusError: String?
    let opusMilliseconds: Double?
}

enum AppleTranslationBenchmarkError: LocalizedError {
    case noCases
    case unsupportedLanguagePair

    var errorDescription: String? {
        switch self {
        case .noCases:
            "评测语料为空"
        case .unsupportedLanguagePair:
            "系统不支持简体中文到英文翻译"
        }
    }
}

@MainActor
enum AppleTranslationBenchmark {
    typealias Progress = @Sendable (_ message: String) async -> Void

    static func run(
        session: TranslationSession,
        options: AppleTranslationEvaluationOptions,
        progress: @escaping Progress
    ) async throws -> AppleTranslationBenchmarkReport {
        let source = Locale.Language(identifier: "zh-Hans")
        let target = Locale.Language(identifier: "en")
        let cases = try EvaluationCase.load(
            paths: options.casesPaths
        )
        guard !cases.isEmpty else {
            throw AppleTranslationBenchmarkError.noCases
        }

        let availability = LanguageAvailability()
        let languageStatus = await availability.status(
            from: source,
            to: target
        )
        if languageStatus == .unsupported {
            throw AppleTranslationBenchmarkError.unsupportedLanguagePair
        }

        let canRequestDownloads: Bool? =
            if #available(macOS 26.0, *) {
                session.canRequestDownloads
            } else {
                nil
            }

        await progress(
            "正在准备系统语言包；首次运行可能需要下载。"
        )
        let preparationStarted = ContinuousClock.now
        try await session.prepareTranslation()
        let preparationMilliseconds = milliseconds(
            preparationStarted.duration(to: .now)
        )

        let loadStarted = ContinuousClock.now
        let opus = try CTranslate2Engine(
            modelDirectory: URL(
                fileURLWithPath: options.ct2Path,
                isDirectory: true
            )
        )
        let loadMilliseconds = milliseconds(
            loadStarted.duration(to: .now)
        )

        await progress("正在首次调用两个翻译引擎…")
        let firstCase = cases[0]
        let appleFirstCall = await translate(
            text: firstCase.text,
            using: session
        )
        let opusFirstCall = await translate(
            candidate: Candidate(
                text: firstCase.text,
                kind: CandidateClassifier.classify(firstCase.text)
            ),
            using: opus
        )

        await progress("正在预热两个翻译引擎…")
        for item in cases {
            _ = await translate(text: item.text, using: session)
            _ = await translate(
                candidate: candidate(for: item),
                using: opus
            )
        }

        var apple = Observations(count: cases.count)
        var opusObservations = Observations(count: cases.count)
        for round in 0..<options.rounds {
            await progress(
                "第 \(round + 1)/\(options.rounds) 轮："
                    + "苹果系统翻译"
            )
            for (index, item) in cases.enumerated() {
                let observation = await translate(
                    text: item.text,
                    using: session
                )
                apple.record(observation, at: index)
            }

            await progress(
                "第 \(round + 1)/\(options.rounds) 轮：OPUS-MT"
            )
            for (index, item) in cases.enumerated() {
                let observation = await translate(
                    candidate: candidate(for: item),
                    using: opus
                )
                opusObservations.record(observation, at: index)
            }
        }

        let appleRows = benchmarkRows(
            model: "apple-translation",
            cases: cases,
            observations: apple
        )
        let opusRows = benchmarkRows(
            model: "opus-mt",
            cases: cases,
            observations: opusObservations
        )
        let rows = cases.indices.map {
            CaseReport(
                text: cases[$0].text,
                category: cases[$0].category,
                candidateKind: CandidateClassifier.classify(
                    cases[$0].text
                ).rawValue,
                expected: cases[$0].expected,
                forbidden: cases[$0].forbidden,
                appleOutput: apple.outputs[$0],
                appleError: apple.errors[$0],
                appleMilliseconds: rounded(
                    percentile(apple.latencies[$0], p: 0.5)
                ),
                opusOutput: opusObservations.outputs[$0],
                opusError: opusObservations.errors[$0],
                opusMilliseconds: rounded(
                    percentile(
                        opusObservations.latencies[$0],
                        p: 0.5
                    )
                )
            )
        }
        let report = AppleTranslationBenchmarkReport(
            generatedAt: ISO8601DateFormatter().string(
                from: Date()
            ),
            host: HostReport(
                operatingSystem:
                    ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: machineArchitecture()
            ),
            sourceLanguage: "zh-Hans",
            targetLanguage: "en",
            systemLanguageStatus: statusName(languageStatus),
            systemCanRequestDownloads: canRequestDownloads,
            caseCount: cases.count,
            measuredRounds: options.rounds,
            appleTranslation: engineReport(
                name: "apple-translation",
                rows: appleRows,
                loadMilliseconds: nil,
                preparationMilliseconds: preparationMilliseconds,
                firstCallMilliseconds:
                    appleFirstCall.milliseconds,
                failedRounds: apple.failedRounds
            ),
            opusMT: engineReport(
                name: "opus-mt",
                rows: opusRows,
                loadMilliseconds: loadMilliseconds,
                preparationMilliseconds: nil,
                firstCallMilliseconds:
                    opusFirstCall.milliseconds,
                failedRounds: opusObservations.failedRounds
            ),
            rows: rows
        )
        try write(report: report, to: options.outputPath)
        return report
    }

    private struct Observation: Sendable {
        let output: String?
        let error: String?
        let milliseconds: Double
    }

    private struct Observations: Sendable {
        var outputs: [String?]
        var errors: [String?]
        var latencies: [[Double]]
        var failedRounds = 0

        init(count: Int) {
            outputs = Array(repeating: nil, count: count)
            errors = Array(repeating: nil, count: count)
            latencies = Array(repeating: [], count: count)
        }

        mutating func record(
            _ observation: Observation,
            at index: Int
        ) {
            outputs[index] = observation.output
            errors[index] = observation.error
            latencies[index].append(observation.milliseconds)
            if observation.error != nil {
                failedRounds += 1
            }
        }
    }

    private static func translate(
        text: String,
        using session: TranslationSession
    ) async -> Observation {
        let started = ContinuousClock.now
        do {
            let response = try await session.translate(text)
            let output = response.targetText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return Observation(
                output: output.isEmpty ? nil : output,
                error: nil,
                milliseconds: milliseconds(
                    started.duration(to: .now)
                )
            )
        } catch {
            return Observation(
                output: nil,
                error: error.localizedDescription,
                milliseconds: milliseconds(
                    started.duration(to: .now)
                )
            )
        }
    }

    private static func translate(
        candidate: Candidate,
        using engine: CTranslate2Engine
    ) async -> Observation {
        let started = ContinuousClock.now
        do {
            let result = try await engine.translate(candidate)
            return Observation(
                output: result?.displayText,
                error: nil,
                milliseconds: milliseconds(
                    started.duration(to: .now)
                )
            )
        } catch {
            return Observation(
                output: nil,
                error: error.localizedDescription,
                milliseconds: milliseconds(
                    started.duration(to: .now)
                )
            )
        }
    }

    private static func candidate(
        for item: EvaluationCase
    ) -> Candidate {
        Candidate(
            text: item.text,
            kind: CandidateClassifier.classify(item.text)
        )
    }

    private static func benchmarkRows(
        model: String,
        cases: [EvaluationCase],
        observations: Observations
    ) -> [BenchmarkRow] {
        cases.indices.map { index in
            BenchmarkRow(
                model: model,
                text: cases[index].text,
                category: CandidateClassifier.classify(
                    cases[index].text
                ).rawValue,
                expected: cases[index].expected,
                forbidden: cases[index].forbidden,
                output: observations.outputs[index],
                latencyMilliseconds:
                    percentile(
                        observations.latencies[index],
                        p: 0.5
                    ) ?? 0
            )
        }
    }

    private static func engineReport(
        name: String,
        rows: [BenchmarkRow],
        loadMilliseconds: Double?,
        preparationMilliseconds: Double?,
        firstCallMilliseconds: Double?,
        failedRounds: Int
    ) -> EngineReport {
        let summary = BenchmarkMetrics.summary(rows: rows)
        return EngineReport(
            name: name,
            loadMilliseconds: rounded(loadMilliseconds),
            preparationMilliseconds: rounded(
                preparationMilliseconds
            ),
            firstCallMilliseconds: rounded(firstCallMilliseconds),
            total: summary.total,
            top1: summary.top1,
            top1Rate: rounded(
                Double(summary.top1) / Double(max(1, summary.total))
            ) ?? 0,
            missing: summary.missing,
            forbiddenHits: summary.forbiddenHits,
            p50Milliseconds: rounded(summary.p50Milliseconds),
            p95Milliseconds: rounded(summary.p95Milliseconds),
            failedRounds: failedRounds,
            categories: summary.categories.map {
                CategoryReport(
                    category: $0.category,
                    total: $0.total,
                    top1: $0.top1,
                    missing: $0.missing,
                    forbiddenHits: $0.forbiddenHits
                )
            }
        )
    }

    private static func write(
        report: AppleTranslationBenchmarkReport,
        to path: String
    ) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(
            to: url,
            options: .atomic
        )
    }

    private static func statusName(
        _ status: LanguageAvailability.Status
    ) -> String {
        switch status {
        case .installed:
            "installed"
        case .supported:
            "supported"
        case .unsupported:
            "unsupported"
        @unknown default:
            "unknown"
        }
    }

    private static func machineArchitecture() -> String {
        var value: utsname = .init()
        guard uname(&value) == 0 else { return "unknown" }
        let capacity = MemoryLayout.size(ofValue: value.machine)
        return withUnsafePointer(to: &value.machine) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: capacity
            ) {
                String(cString: $0)
            }
        }
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds)
        / 1_000_000_000_000_000
}

private func rounded(_ value: Double?) -> Double? {
    guard let value else { return nil }
    return (value * 1_000).rounded() / 1_000
}
