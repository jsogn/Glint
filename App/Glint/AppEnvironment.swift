import GlintCore
import GlintDictionary
import GlintInference
import GlintMac
import GlintPlugins

@MainActor
final class AppEnvironment {
    let dictionary: any DictionaryEngine
    let pluginManager: PluginManager
    let openAICompatibleStore: OpenAICompatibleConfigurationStore
    let translationRuntime: TranslationRuntime
    let translation: any TranslationEngine
    let router: SmartRouter
    let monitoring: MonitoringController

    init() {
        let pluginManager = PluginManager()
        let openAICompatibleStore = OpenAICompatibleConfigurationStore()
        let builtInRoutes = [
            DictionaryRoute(id: "dict-cedict", priority: 0, engine: CedictDictionary()),
            DictionaryRoute(id: "dict-ecdict", priority: 1, engine: ECDICTDictionary()),
        ]
        let dictionary = DictionaryRouter(
            routes: builtInRoutes + DictionaryPluginLoader.routes(),
            blocked: ["打", "尼", "你号"]
        )
        let translationRuntime = TranslationRuntime { modelID in
            let providerID = TranslationModelSelection.openAIProviderID(
                fromSelectionID: modelID
            ) ?? (modelID == TranslationModelSelection.openAICompatibleModelID
                ? openAICompatibleStore.loadProviders().first?.id
                : nil)
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

    func configureOCR(
        engineID: String,
        enhancementMode: OCREnhancementMode
    ) async -> String? {
        let resolution = await OCRPluginLoader.resolve(
            engineID: engineID,
            enhancementMode: enhancementMode,
            manager: pluginManager
        )
        await monitoring.setOCRConfiguration(resolution.configuration)
        if let warning = resolution.warning {
            return warning
        }
        guard resolution.configuration.preferredBackend == .ppocr else {
            return nil
        }
        return OCRService(configuration: resolution.configuration)
            .validatePreferredBackend()
    }
}
