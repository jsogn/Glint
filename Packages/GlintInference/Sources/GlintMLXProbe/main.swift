import Foundation
import GlintCore
import GlintInference

@main
struct GlintMLXProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let directory = arguments.first.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? MLXTranslationEngine.availableModelDirectory()
        guard let directory else {
            fputs("MLX model directory not found\n", stderr)
            exit(2)
        }

        let input = arguments.count > 1
            ? arguments.dropFirst().joined(separator: " ")
            : "这个功能什么时候上线"
        let modelID = ProcessInfo.processInfo.environment["GLINT_MLX_MODEL_ID"]
            ?? "llm-qwen3-1.7b"
        let engine = MLXTranslationEngine(
            modelDirectory: directory,
            modelID: modelID
        )

        do {
            let started = ContinuousClock.now
            let result = try await engine.translate(
                Candidate(
                    text: input,
                    kind: CandidateClassifier.classify(input)
                )
            )
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds)
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
}
