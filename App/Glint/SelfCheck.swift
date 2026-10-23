import Darwin
import Foundation
import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

enum SelfCheck {
    static func run() -> Never {
        Task {
            print("accessibility=\(FocusMonitor.isAccessibilityTrusted())")

            let dictionary = PluginDictionaryRouter()
            await dictionary.reload()

            for word in ["你好", "算法", "程序", "设计", "内卷"] {
                let result = await dictionary.lookup(
                    Candidate(text: word, kind: .word)
                )
                print("dict \(word) -> \(result?.displayText ?? "<not found>")")
            }

            if let engine = CTranslate2Engine() {
                let result = try? await engine.translate(
                    Candidate(text: "今天天气不错", kind: .sentence)
                )
                print("ct2 今天天气不错 -> \(result?.text ?? "<not found>")")
                let smartRouter = SmartRouter(
                    dictionary: dictionary,
                    translation: engine
                )
                let routed = try? await smartRouter.route(
                    Candidate(
                        text: "今天天气不错",
                        kind: CandidateClassifier.classify("今天天气不错")
                    ),
                    mode: .dictionaryFirst
                )
                print(
                    "smart \(CandidateClassifier.classify("今天天气不错")) "
                        + "今天天气不错 -> \(routed?.text ?? "<not found>")"
                )
            } else {
                print("ct2=<unavailable>")
            }

            let environment = ProcessInfo.processInfo.environment
            let mlxModel: (URL, String)?
            if let path = environment["GLINT_MLX_MODEL"],
               let modelID = environment["GLINT_MLX_MODEL_ID"] {
                mlxModel = (
                    URL(fileURLWithPath: path, isDirectory: true),
                    modelID
                )
            } else {
                mlxModel = [
                    TranslationModelSelection.selected(),
                    "mt-hy-mt2-1.8b",
                    "mt-index-translate-2b",
                    "llm-qwen3-1.7b",
                    "llm-qwen3-4b",
                    "llm-qwen3-0.6b",
                ].lazy.compactMap { modelID in
                    MLXTranslationEngine.availableModelDirectory(modelID: modelID)
                        .map { ($0, modelID) }
                }.first
            }
            if let (mlxDirectory, modelID) = mlxModel {
                let engine = MLXTranslationEngine(
                    modelDirectory: mlxDirectory,
                    modelID: modelID
                )
                let input = "这个功能什么时候上线"
                do {
                    let result = try await engine.translate(
                        Candidate(
                            text: input,
                            kind: CandidateClassifier.classify(input)
                        )
                    )
                    let load = await engine.loadSeconds
                    print(
                        "mlx[\(modelID)] \(input) -> \(result?.text ?? "<not found>") "
                            + "load=\(load.map { String(format: "%.2fs", $0) } ?? "?")"
                    )
                } catch {
                    print("mlx=<\(error.localizedDescription)>")
                }
            } else {
                print("mlx=<model not installed>")
            }

            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }
}
