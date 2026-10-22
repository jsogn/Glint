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
        _ = await prepare(modelID: selectedModelID)
    }

    @discardableResult
    public func prepare(modelID: String) async -> String? {
        guard let descriptor = await modelResolver(modelID) else {
            activeModel = nil
            activeEngine = nil
            lastError = "未找到所选翻译模型"
            return lastError
        }

        // Release the previous multi-gigabyte container before loading a new one.
        activeEngine = nil
        activeModel = nil
        do {
            let engine = try makeEngine(for: descriptor)
            if let mlx = engine as? MLXTranslationEngine {
                _ = try await mlx.prepare()
                try? await mlx.warmUp()
            }
            activeModel = descriptor
            activeEngine = engine
            lastError = nil
        } catch {
            activeModel = nil
            activeEngine = nil
            lastError = error.localizedDescription
        }
        return lastError
    }

    public func releaseResources(for modelID: String) {
        guard activeModel?.modelID == modelID else { return }
        activeEngine = nil
        activeModel = nil
        lastError = nil
    }

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        try Task.checkCancellation()
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

        if let lastError {
            throw NSError(
                domain: "Glint.TranslationRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: lastError]
            )
        }
        throw GlintError.engineUnavailable
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
            return try CTranslate2Engine(modelDirectory: directory)
        case let .openAICompatible(_, configuration):
            return OpenAICompatibleTranslationEngine(
                configuration: configuration,
                session: openAISession
            )
        }
    }

    private static func defaultModel(
        for modelID: String
    ) -> ResolvedTranslationModel? {
        let store = OpenAICompatibleConfigurationStore()
        let providerID = TranslationModelSelection.openAIProviderID(
            fromSelectionID: modelID
        )
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

        if modelID == TranslationModelSelection.defaultModelID {
            if let bundled = Bundle.main.url(
                forResource: "mt-opus-zh-en",
                withExtension: nil
            )?.appendingPathComponent("model", isDirectory: true),
               FileManager.default.fileExists(atPath: bundled.path) {
                return .ctranslate2(
                    modelID: modelID,
                    directory: bundled
                )
            }
            if let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first {
                let directory = support.appendingPathComponent(
                    "Glint/plugins/mt-opus-zh-en/model",
                    isDirectory: true
                )
                if FileManager.default.fileExists(atPath: directory.path) {
                    return .ctranslate2(
                        modelID: modelID,
                        directory: directory
                    )
                }
            }
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
