import AppKit
import ApplicationServices
import Darwin
import Foundation
import GlintCore
import GlintDictionary
import GlintInference
import GlintMac
import GlintPlugins

enum SelfCheck {
    static func run() -> Never {
        Task {
            print("screenRecording=\(CGPreflightScreenCaptureAccess())")
            print("accessibility=\(FocusMonitor.isAccessibilityTrusted())")
            let ocrResolution = await OCRPluginLoader.resolve(
                engineID: OCREngineSelection.selected(),
                enhancementMode: OCREnhancementSelection.selected(),
                manager: PluginManager()
            )
            let ocrService = OCRService(
                configuration: ocrResolution.configuration
            )
            let ocrWarning = ocrResolution.warning
                ?? ocrService.validatePreferredBackend()
            print(
                "ocr preferred=\(ocrResolution.configuration.preferredBackend.rawValue) "
                    + "ppocrAvailable=\(ocrService.isPPOCRAvailable) "
                    + "warning=\(ocrWarning ?? "<none>")"
            )

            let dictionary = DictionaryRouter(routes: [
                DictionaryRoute(id: "dict-cedict", priority: 0, engine: CedictDictionary()),
                DictionaryRoute(id: "dict-ecdict", priority: 1, engine: ECDICTDictionary()),
            ])

            for word in ["你好", "算法", "程序", "设计", "内卷"] {
                let result = try? await dictionary.lookup(
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

            if ProcessInfo.processInfo.environment["GLINT_SCAN_LIVE"] == "1",
               let snapshot = FocusMonitor().snapshot(),
               let caret = snapshot.caretRect ?? snapshot.elementFrame {
                let region = MonitoringController.captureRegion(
                    caret: caret,
                    elementFrame: snapshot.elementFrame
                )
                do {
                    let image = try await CandidateCapture().capture(region: region)
                    let anchor = CGPoint(
                        x: (caret.midX - region.x) * CGFloat(image.width)
                            / CGFloat(region.width),
                        y: (caret.midY - region.y) * CGFloat(image.height)
                            / CGFloat(region.height)
                    )
                    if let detection = ocrService.detect(in: image, anchor: anchor) {
                        print(
                            "live candidate=\(detection.text) "
                                + "confidence=\(detection.confidence) "
                                + "caret=\(caret) region=\(region.cgRect) "
                                + "highlight=\(detection.highlightRect)"
                        )
                    } else {
                        print(
                            "live candidate=<not detected> "
                                + "caret=\(caret) region=\(region.cgRect)"
                        )
                    }
                } catch {
                    print("live capture=<\(error.localizedDescription)>")
                }
            }

            if let image = loadSampleImage() {
                if let detection = ocrService.detect(in: image) {
                    print("ocr candidate=\(detection.text) confidence=\(detection.confidence)")
                    let candidate = Candidate(
                        text: detection.text,
                        kind: CandidateClassifier.classify(detection.text),
                        confidence: Double(detection.confidence)
                    )
                    if let result = try? await dictionary.lookup(candidate) {
                        print("ocr dictionary=\(result.displayText)")
                    }
                } else {
                    print("ocr=<not detected>")
                }
            } else {
                print("ocr sample=<not found>")
            }

            exit(0)
        }
        RunLoop.main.run()
        exit(1)
    }

    private static func loadSampleImage() -> CGImage? {
        let candidates = [
            Bundle.main.url(
                forResource: "sample-candidate-bar",
                withExtension: "png",
                subdirectory: "Samples"
            ),
            Bundle.main.url(
                forResource: "sample-candidate-bar",
                withExtension: "png",
                subdirectory: "Resources/Samples"
            ),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Samples/sample-candidate-bar.png"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let image = NSImage(contentsOf: url),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImage
            }
        }
        return nil
    }
}
