import Darwin
import Foundation
import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

enum SelfCheck {
    #if DEBUG
        static func runInputMethodStatus() -> Never {
            Task { @MainActor in
                let service = AppEnvironment.makeSquirrelIntegrationService()
                let status = await service.status()
                let homeDirectory =
                    FileManager.default.homeDirectoryForCurrentUser
                let supportDirectory =
                    AppEnvironment.rimeSupportDirectory()
                let sourceRelay = Bundle.main.bundleURL.appendingPathComponent(
                    "Contents/Helpers/RimeCandidateBridge"
                )
                let installedRelay = supportDirectory.appendingPathComponent(
                    "RimeCandidateBridge"
                )
                let luaSource = Bundle.main.resourceURL?
                    .appendingPathComponent(
                        "RimeCandidateBridge",
                        isDirectory: true
                    )
                let rimeDirectory = homeDirectory.appendingPathComponent(
                    "Library/Rime",
                    isDirectory: true
                )
                let sourceRelayData = try? Data(contentsOf: sourceRelay)
                let installedRelayData = try? Data(contentsOf: installedRelay)
                let relayPermissions =
                    (try? FileManager.default.attributesOfItem(
                        atPath: installedRelay.path
                    )[.posixPermissions] as? NSNumber)?.intValue
                print("state=\(status.state)")
                print("schemas=\(status.schemaIDs.joined(separator: ","))")
                print("protocol=\(status.protocolVersion)")
                print("detail=\(status.detail ?? "-")")
                print(
                    "sourceRelay.exists="
                        + String(
                            FileManager.default.fileExists(
                                atPath: sourceRelay.path
                            )
                        )
                )
                print(
                    "installedRelay.exists="
                        + String(
                            FileManager.default.fileExists(
                                atPath: installedRelay.path
                            )
                        )
                )
                print(
                    "luaSource.exists="
                        + String(
                            luaSource.map {
                                FileManager.default.fileExists(atPath: $0.path)
                            } ?? false)
                )
                print(
                    "relay.matches="
                        + String(
                            sourceRelayData != nil
                                && sourceRelayData == installedRelayData
                        )
                )
                print(
                    "relay.permissions="
                        + (relayPermissions.map {
                            String($0, radix: 8)
                        } ?? "-")
                )
                for schemaID in status.schemaIDs {
                    let custom = rimeDirectory.appendingPathComponent(
                        "\(schemaID).custom.yaml"
                    )
                    let source = try? String(
                        contentsOf: custom,
                        encoding: .utf8
                    )
                    print(
                        "schema.\(schemaID).custom.exists="
                            + String(source != nil)
                    )
                    print(
                        "schema.\(schemaID).filter="
                            + String(
                                source?.contains(
                                    "lua_filter@*glint.candidate_bridge"
                                ) == true
                            )
                    )
                }
                print(
                    "manifest.exists="
                        + String(
                            FileManager.default.fileExists(
                                atPath:
                                    supportDirectory
                                    .appendingPathComponent(
                                        "install-manifest.json"
                                    )
                                    .path
                            )
                        )
                )
                exit(EXIT_SUCCESS)
            }
            RunLoop.main.run()
            exit(EXIT_FAILURE)
        }

        static func runDictionaryPOSReloadCheck(
            oldPluginDirectory: URL,
            newPluginDirectory: URL,
            oldWord: String,
            newWord: String
        ) -> Never {
            Task {
                do {
                    let result = try await dictionaryPOSReloadResult(
                        oldPluginDirectory: oldPluginDirectory,
                        newPluginDirectory: newPluginDirectory,
                        oldWord: oldWord,
                        newWord: newWord
                    )
                    print(
                        "before=\(partOfSpeechSummary(result.before))"
                    )
                    print(
                        "after=\(partOfSpeechSummary(result.after))"
                    )
                    exit(EXIT_SUCCESS)
                } catch {
                    print("error=\(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            }
            RunLoop.main.run()
            exit(EXIT_FAILURE)
        }

        private static func dictionaryPOSReloadResult(
            oldPluginDirectory: URL,
            newPluginDirectory: URL,
            oldWord: String,
            newWord: String
        ) async throws -> (
            before: [PartOfSpeech],
            after: [PartOfSpeech]
        ) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "GlintDictionaryReloadSelfCheck-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let installedPlugin = root.appendingPathComponent(
                "dict-ecdict",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: oldPluginDirectory,
                to: installedPlugin
            )
            let router = PluginDictionaryRouter(baseDirectory: root)
            let before = await router.partsOfSpeech(forEnglish: oldWord)

            try FileManager.default.removeItem(at: installedPlugin)
            try FileManager.default.copyItem(
                at: newPluginDirectory,
                to: installedPlugin
            )
            await router.reload()
            let after = await router.partsOfSpeech(forEnglish: newWord)
            return (before, after)
        }

        private static func partOfSpeechSummary(
            _ values: [PartOfSpeech]
        ) -> String {
            values.map(\.rawValue).joined(separator: ",")
        }
    #endif

    static func run() -> Never {
        Task {
            print("accessibility=\(FocusMonitor.isAccessibilityTrusted())")

            let dictionary = PluginDictionaryRouter()
            await dictionary.reload()

            for word in ["你好", "算法", "程序", "设计", "内卷"] {
                let result = await dictionary.lookup(
                    TranslationRequest(
                        candidate: Candidate(
                            text: word,
                            kind: .word
                        ),
                        direction: .simplifiedChineseToEnglish
                    )
                )
                print("dict \(word) -> \(result?.displayText ?? "<not found>")")
            }

            if let engine = CTranslate2Engine() {
                let result = try? await engine.translate(
                    TranslationRequest(
                        candidate: Candidate(
                            text: "今天天气不错",
                            kind: .sentence
                        ),
                        direction: .simplifiedChineseToEnglish
                    )
                )
                print("ct2 今天天气不错 -> \(result?.text ?? "<not found>")")
                let smartRouter = SmartRouter(
                    dictionary: dictionary,
                    translation: engine,
                    partOfSpeechProvider: dictionary
                )
                let routed = try? await smartRouter.route(
                    TranslationRequest(
                        candidate: Candidate(
                            text: "今天天气不错",
                            kind: CandidateClassifier.classify(
                                "今天天气不错"
                            )
                        ),
                        direction: .simplifiedChineseToEnglish
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
                let modelID = environment["GLINT_MLX_MODEL_ID"]
            {
                mlxModel = (
                    URL(fileURLWithPath: path, isDirectory: true),
                    modelID
                )
            } else {
                mlxModel =
                    [
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
                        TranslationRequest(
                            candidate: Candidate(
                                text: input,
                                kind: CandidateClassifier.classify(input)
                            ),
                            direction: .simplifiedChineseToEnglish
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
