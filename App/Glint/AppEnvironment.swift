import Foundation
import GlintCore
import GlintInference
import GlintMac
import GlintPlugins

@MainActor
final class AppEnvironment {
    let pluginManager: PluginManager
    let modelHubService: ModelHubService
    let coreDictionaryUpdateService: CoreDictionaryUpdateService
    let ecdictUpdateService: ECDICTUpdateService
    let translationRuntime: TranslationRuntime
    let monitoring: MonitoringController
    let monitoringSession: MonitoringSession
    let squirrelIntegrationService: SquirrelIntegrationService?
    private let dictionary: PluginDictionaryRouter
    private let rimeCandidateBridgeReceiver: RimeCandidateBridgeReceiver?

    init() {
        let pluginManager = PluginManager()
        let coreDictionaryUpdateService = CoreDictionaryUpdateService(
            pluginManager: pluginManager,
            bundledDirectory: BundledPluginResources.directory(
                for: CoreDictionaryUpdateService.dictionaryID
            )
        )
        let ecdictUpdateService = ECDICTUpdateService(
            pluginManager: pluginManager,
            bundledDirectory: BundledPluginResources.directory(
                for: ECDICTUpdateService.dictionaryID
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
        self.modelHubService = ModelHubService()
        self.coreDictionaryUpdateService = coreDictionaryUpdateService
        self.ecdictUpdateService = ecdictUpdateService
        self.translationRuntime = translationRuntime
        let router = SmartRouter(dictionary: dictionary, translation: translationRuntime)
        #if DEBUG
            self.squirrelIntegrationService =
                Self.makeSquirrelIntegrationService()
            let rimeBridge = RimeCandidateBridgeReceiver()
            let rimeBridgeStarted = rimeBridge.start()
            self.rimeCandidateBridgeReceiver =
                rimeBridgeStarted ? rimeBridge : nil
            let monitoring = MonitoringController(
                router: router,
                rimeCandidateStore:
                    rimeBridgeStarted ? rimeBridge.store : nil
            )
        #else
            self.squirrelIntegrationService = nil
            self.rimeCandidateBridgeReceiver = nil
            let monitoring = MonitoringController(router: router)
        #endif
        self.monitoring = monitoring
        self.monitoringSession = MonitoringSession(controller: monitoring)
    }

    #if DEBUG
        static func makeSquirrelIntegrationService(
            bundle: Bundle = .main
        ) -> SquirrelIntegrationService {
            let homeDirectory =
                FileManager.default.homeDirectoryForCurrentUser
            let appBundle = bundle.bundleURL
            return SquirrelIntegrationService(
                rimeDirectory: homeDirectory.appendingPathComponent(
                    "Library/Rime",
                    isDirectory: true
                ),
                supportDirectory: homeDirectory.appendingPathComponent(
                    "Library/Application Support/Glint/RimeCandidateLab",
                    isDirectory: true
                ),
                squirrelApplication: URL(
                    fileURLWithPath:
                        "/Library/Input Methods/Squirrel.app",
                    isDirectory: true
                ),
                luaSourceDirectory:
                    bundle.resourceURL?
                    .appendingPathComponent(
                        "RimeCandidateBridge",
                        isDirectory: true
                    )
                    ?? appBundle.appendingPathComponent(
                        "Contents/Resources/RimeCandidateBridge",
                        isDirectory: true
                    ),
                relaySource: appBundle.appendingPathComponent(
                    "Contents/Helpers/RimeCandidateBridge"
                )
            )
        }
    #endif

    func refreshDictionaryRoutes() async {
        await dictionary.reload()
    }

    func checkCoreDictionaryUpdate(
        kind: CoreDictionaryUpdateKind
    ) async throws -> String {
        switch kind {
        case .cedict:
            try await coreDictionaryUpdateService
                .checkForUpdate()
                .statusText
        case .ecdict:
            try await ecdictUpdateService
                .checkForUpdate()
                .statusText
        }
    }

    func checkTranslationModelUpdate(
        _ manifest: PluginManifest
    ) async throws -> UpstreamModelUpdate? {
        try await modelHubService.update(for: manifest)
    }

    func searchModelMarket(
        query: String
    ) async throws -> [UpstreamModelSummary] {
        try await modelHubService.search(query: query)
    }

    func prepareModelMarketInstall(
        _ model: UpstreamModelSummary,
        matching knownManifest: PluginManifest?
    ) async throws -> ModelInstallPreparation {
        let snapshot = try await modelHubService.inspect(
            repository: model.repository
        )
        guard
            await MLXModelCompatibility.supports(
                modelType: snapshot.modelType
            )
        else {
            throw ModelHubError.unsupportedModelType(snapshot.modelType)
        }
        return ModelInstallPreparation(
            manifest: ModelHubService.manifest(
                for: snapshot,
                matching: knownManifest
            ),
            snapshot: snapshot
        )
    }

}
