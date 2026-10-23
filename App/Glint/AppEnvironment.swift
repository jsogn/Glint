import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

@MainActor
final class AppEnvironment {
    let pluginManager: PluginManager
    let translationRuntime: TranslationRuntime
    let monitoring: MonitoringController
    private let dictionary: PluginDictionaryRouter

    init() {
        let pluginManager = PluginManager()
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
        self.translationRuntime = translationRuntime
        let router = SmartRouter(dictionary: dictionary, translation: translationRuntime)
        self.monitoring = MonitoringController(router: router)
    }

    func refreshDictionaryRoutes() async {
        await dictionary.reload()
    }

}
