import Foundation
import GlintCore

/// Resolves the selected model into a concrete local or remote runtime.
public actor TranslationRuntime: TranslationEngine {
    public typealias ModelResolver =
        @Sendable (_ modelID: String) async -> ResolvedTranslationModel?

    private let defaults: UserDefaults
    private let modelResolver: ModelResolver
    private let openAISession: URLSession
    private var activeModel: ResolvedTranslationModel?
    private var activeEngine: (any TranslationEngine)?
    private var fallbackEngine: CTranslate2Engine?
    private var fallbackInitialized = false
    private(set) public var lastError: String?

    public init(
        defaults: UserDefaults = .standard,
        modelResolver: ModelResolver? = nil,
        openAISession: URLSession = .shared
    ) {
        self.defaults = defaults
        self.modelResolver = modelResolver ?? { modelID in
            Self.defaultModel(for: modelID)
        }
        self.openAISession = openAISession
    }

    public var selectedModelID: String {
        Self.selectedModelID(in: defaults)
    }

    public func prepareSelectedModel() async {
        let modelID = selectedModelID
        guard let descriptor = await modelResolver(modelID) else {
            activeModel = nil
            activeEngine = nil
            lastError = "未找到所选翻译模型"
            return
        }

        // Release the previous multi-gigabyte container before loading a new one.
        activeEngine = nil
        activeModel = nil
        do {
            let engine = try makeEngine(for: descriptor)
            if let mlx = engine as? MLXTranslationEngine {
                _ = try await mlx.prepare()
            }
            activeModel = descriptor
            activeEngine = engine
            lastError = nil
        } catch {
            activeModel = descriptor
            activeEngine = nil
            lastError = error.localizedDescription
        }
    }

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        if activeModel?.modelID != selectedModelID {
            await prepareSelectedModel()
        }

        if let activeEngine {
            do {
                if let result = try await activeEngine.translate(candidate) {
                    lastError = nil
                    return result
                }
            } catch {
                lastError = error.localizedDescription
            }
        }

        guard let fallbackEngine = fallback() else {
            if let lastError {
                throw NSError(
                    domain: "Glint.TranslationRuntime",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: lastError]
                )
            }
            throw GlintError.engineUnavailable
        }
        return try await fallbackEngine.translate(candidate)
    }

    public static func selectedModelID(in defaults: UserDefaults = .standard) -> String {
        TranslationModelSelection.selected(in: defaults)
    }

    public static func setSelectedModelID(
        _ modelID: String,
        in defaults: UserDefaults = .standard
    ) {
        TranslationModelSelection.select(modelID, in: defaults)
    }

    private func makeEngine(
        for model: ResolvedTranslationModel
    ) throws -> any TranslationEngine {
        switch model {
        case let .mlx(modelID, directory, promptProfile):
            return MLXTranslationEngine(
                modelDirectory: directory,
                modelID: modelID,
                promptProfile: promptProfile
            )
        case let .ctranslate2(_, directory):
            guard let engine = CTranslate2Engine(modelDirectory: directory) else {
                throw NSError(
                    domain: "Glint.TranslationRuntime",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "无法加载 CTranslate2 模型"
                    ]
                )
            }
            return engine
        case let .openAICompatible(_, configuration):
            return OpenAICompatibleTranslationEngine(
                configuration: configuration,
                session: openAISession
            )
        }
    }

    private func fallback() -> CTranslate2Engine? {
        if !fallbackInitialized {
            fallbackInitialized = true
            fallbackEngine = CTranslate2Engine()
        }
        return fallbackEngine
    }

    private static func defaultModel(
        for modelID: String
    ) -> ResolvedTranslationModel? {
        let store = OpenAICompatibleConfigurationStore()
        let providerID = TranslationModelSelection.openAIProviderID(
            fromSelectionID: modelID
        ) ?? (modelID == TranslationModelSelection.openAICompatibleModelID
            ? store.loadProviders().first?.id
            : nil)
        if let providerID,
           let configuration = store.configuration(for: providerID) {
            guard configuration.isConfigured else { return nil }
            return .openAICompatible(
                modelID: TranslationModelSelection.openAICompatibleSelectionID(
                    for: providerID
                ),
                configuration: configuration
            )
        }

        guard TranslationModelSelection.usesMLX(modelID),
              let directory = MLXTranslationEngine.availableModelDirectory(
                modelID: modelID
              ) else {
            return nil
        }
        return .mlx(
            modelID: modelID,
            directory: directory,
            promptProfile: .inferred(from: modelID)
        )
    }
}
