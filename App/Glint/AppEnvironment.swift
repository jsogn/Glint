import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

@MainActor
final class AppEnvironment {
    let pluginManager: PluginManager
    let coreDictionaryUpdateService: CoreDictionaryUpdateService
    let translationRuntime: TranslationRuntime
    let monitoring: MonitoringController
    let monitoringSession: MonitoringSession
    private let dictionary: PluginDictionaryRouter

    init() {
        let pluginManager = PluginManager()
        let coreDictionaryUpdateService = CoreDictionaryUpdateService(
            pluginManager: pluginManager,
            bundledDirectory: BundledPluginResources.directory(
                for: CoreDictionaryUpdateService.dictionaryID
            )
        )
        let dictionary = PluginDictionaryRouter()
        let translationRuntime = TranslationRuntime { modelID in
            if let manifest = BundledPluginResources.manifest(
                for: modelID
            ),
                let pluginDirectory = BundledPluginResources.directory(
                    for: modelID
                )
            {
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
            default:
                return nil
            }
        }
        self.dictionary = dictionary
        self.pluginManager = pluginManager
        self.coreDictionaryUpdateService = coreDictionaryUpdateService
        self.translationRuntime = translationRuntime
        let router = SmartRouter(dictionary: dictionary, translation: translationRuntime)
        let monitoring = MonitoringController(router: router)
        self.monitoring = monitoring
        self.monitoringSession = MonitoringSession(controller: monitoring)
    }

    func refreshDictionaryRoutes() async {
        await dictionary.reload()
    }

}
