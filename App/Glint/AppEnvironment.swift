import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

@MainActor
final class AppEnvironment {
    let dictionary: PluginDictionaryRouter
    let pluginManager: PluginManager
    let openAICompatibleStore: OpenAICompatibleConfigurationStore
    let translationRuntime: TranslationRuntime
    let translation: any TranslationEngine
    let router: SmartRouter
    let monitoring: MonitoringController

    init() {
        let pluginManager = PluginManager()
        let openAICompatibleStore = OpenAICompatibleConfigurationStore()
        let dictionary = PluginDictionaryRouter()
        let translationRuntime = TranslationRuntime { modelID in
            let providerID = TranslationModelSelection.openAIProviderID(
                fromSelectionID: modelID
            )
            if let providerID {
                let configuration = openAICompatibleStore.configuration(
                    for: providerID
                )
                guard let configuration,
                      configuration.isConfigured else {
                    return nil
                }
                return .openAICompatible(
                    modelID: TranslationModelSelection
                        .openAICompatibleSelectionID(for: providerID),
                    configuration: configuration
                )
            }
            if let manifest = BundledPluginResources.manifest(
                for: modelID
            ),
               let pluginDirectory = BundledPluginResources.directory(
                   for: modelID
               ) {
                let directory = pluginDirectory.appendingPathComponent(
                    "model",
                    isDirectory: true
                )
                switch manifest.runtime {
                case "mlx":
                    return .mlx(
                        modelID: modelID,
                        directory: directory,
                        promptProfile: manifest.promptProfile
                            ?? .inferred(from: modelID)
                    )
                case "ctranslate2":
                    return .ctranslate2(
                        modelID: modelID,
                        directory: directory
                    )
                default:
                    return nil
                }
            }
            guard let manifest = await pluginManager.installedPlugin(id: modelID) else {
                return nil
            }
            let pluginDirectory = await pluginManager.pluginDirectory(
                for: modelID
            )
            let directory = pluginDirectory.appendingPathComponent(
                "model",
                isDirectory: true
            )
            switch manifest.runtime {
            case "mlx":
                return .mlx(
                    modelID: modelID,
                    directory: directory,
                    promptProfile: manifest.promptProfile
                        ?? .inferred(from: modelID)
                )
            case "ctranslate2":
                return .ctranslate2(
                    modelID: modelID,
                    directory: directory
                )
            default:
                return nil
            }
        }
        self.dictionary = dictionary
        self.pluginManager = pluginManager
        self.openAICompatibleStore = openAICompatibleStore
        self.translationRuntime = translationRuntime
        self.translation = translationRuntime
        let router = SmartRouter(dictionary: dictionary, translation: translationRuntime)
        self.router = router
        self.monitoring = MonitoringController(router: router)
    }

    func validateOpenAICompatibleConfiguration(
        _ configuration: OpenAICompatibleConfiguration
    ) async throws {
        let engine = OpenAICompatibleTranslationEngine(
            configuration: configuration
        )
        let candidate = Candidate(
            text: "你好",
            kind: .word,
            confidence: 1
        )
        guard let result = try await engine.translate(candidate),
              !result.text.isEmpty else {
            throw OpenAICompatibleTranslationError.emptyOutput
        }
    }

    func refreshDictionaryRoutes() async {
        await dictionary.reload()
    }

    func removeLegacyBundledPluginCopies() async {
        for id in BundledPluginResources.pluginIDs {
            guard await pluginManager.installedPlugin(id: id) != nil else {
                continue
            }
            try? await pluginManager.remove(id: id)
        }
    }
}
