import Foundation
import GlintCore
import GlintInference

@main
struct GlintMLXProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let metalLibraryPath = ProcessInfo.processInfo.environment[
            "GLINT_MLX_METALLIB"
        ], !metalLibraryPath.isEmpty {
            MLXTranslationEngine.configureMetalLibrary(
                at: URL(fileURLWithPath: metalLibraryPath)
            )
        }
        let directory =
            arguments.first.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? MLXTranslationEngine.availableModelDirectory()
        guard let directory else {
            fputs("MLX model directory not found\n", stderr)
            exit(2)
        }

        let input =
            arguments.count > 1
            ? arguments.dropFirst().joined(separator: " ")
            : "这个功能什么时候上线"
        let modelID =
            ProcessInfo.processInfo.environment["GLINT_MLX_MODEL_ID"]
            ?? "llm-qwen3-1.7b"
        let target =
            ProcessInfo.processInfo.environment["GLINT_MLX_TARGET"]
                .flatMap(TranslationTarget.init(rawValue:))
            ?? .english
        let engine = MLXTranslationEngine(
            modelDirectory: directory,
            modelID: modelID,
            supportedTargets: [target]
        )
        let direction = TranslationDirection(target: target)

        do {
            if arguments.count > 1,
                arguments[1] == "--batch"
            {
                try await runBatch(
                    engine: engine,
                    directory: directory,
                    payload: arguments.dropFirst(2).joined(separator: " "),
                    direction: direction
                )
                return
            }
            let started = ContinuousClock.now
            let result = try await engine.translate(
                TranslationRequest(
                    candidate: Candidate(
                        text: input,
                        kind: CandidateClassifier.classify(input)
                    ),
                    direction: direction
                )
            )
            let elapsed = started.duration(to: .now)
            let seconds =
                Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            let load = await engine.loadSeconds
            print("model=\(directory.path)")
            print("load=\(load.map { String(format: "%.2fs", $0) } ?? "unknown")")
            print("elapsed=\(String(format: "%.3fs", seconds))")
            print("\(input) -> \(result?.text ?? "<not found>")")
        } catch {
            fputs("translation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func runBatch(
        engine: MLXTranslationEngine,
        directory: URL,
        payload: String,
        direction: TranslationDirection
    ) async throws {
        let rawInputs =
            payload.isEmpty
            ? "学习|学校|学生|学|学术|学习用品"
            : payload
        let inputs =
            rawInputs
            .split(separator: "|")
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        let candidates = inputs.map {
            Candidate(
                text: $0,
                kind: CandidateClassifier.classify($0)
            )
        }
        try await engine.warmUp(target: direction.target)

        let batchStarted = ContinuousClock.now
        let batch = try await engine.translateBatch(
            candidates,
            target: direction.target
        )
        let batchMilliseconds = milliseconds(
            batchStarted.duration(to: .now)
        )

        let sequentialStarted = ContinuousClock.now
        var sequential: [String] = []
        for candidate in candidates {
            let result = try await engine.translate(
                TranslationRequest(
                    candidate: candidate,
                    direction: direction
                )
            )
            sequential.append(result?.text ?? "<not found>")
        }
        let sequentialMilliseconds = milliseconds(
            sequentialStarted.duration(to: .now)
        )
        let speedup =
            batchMilliseconds > 0
            ? sequentialMilliseconds / batchMilliseconds
            : 0
        let load = await engine.loadSeconds
        let warmUp = await engine.lastWarmUpSeconds

        print("model=\(directory.path)")
        print("load=\(load.map { String(format: "%.2fs", $0) } ?? "unknown")")
        print(
            "warmup=\(warmUp.map { String(format: "%.3fs", $0) } ?? "unknown")"
        )
        print("batch_candidates=\(candidates.count)")
        print("batch_ms=\(String(format: "%.3f", batchMilliseconds))")
        print(
            "sequential_ms=\(String(format: "%.3f", sequentialMilliseconds))"
        )
        print("speedup=\(String(format: "%.2f", speedup))")
        for (index, input) in inputs.enumerated() {
            let batched =
                batch.indices.contains(index)
                ? batch[index]?.text ?? "<not found>"
                : "<missing>"
            print("\(index + 1). \(input) -> \(batched)")
            print("   sequential: \(sequential[index])")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}
