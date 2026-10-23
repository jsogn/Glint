import Foundation
import GlintCore

/// Resolves the selected model into a concrete local runtime.
public actor TranslationRuntime: TranslationEngine {
    public typealias ModelResolver =
        @Sendable (_ modelID: String) async -> ResolvedTranslationModel?

    private let defaults: UserDefaults
    private let modelResolver: ModelResolver
    private var activeModel: ResolvedTranslationModel?
    private var activeEngine: (any TranslationEngine)?
    private var failedSelectedModelID: String?
    private(set) var lastError: String?

    public init(
        defaults: UserDefaults = .standard,
        modelResolver: @escaping ModelResolver
    ) {
        self.defaults = defaults
        self.modelResolver = modelResolver
    }

    public var selectedModelID: String {
        TranslationModelSelection.selected(in: defaults)
    }

    public func prepareSelectedModel() async {
        _ = await prepare(modelID: selectedModelID)
    }

    @discardableResult
    public func prepare(modelID: String) async -> String? {
        let error = await load(modelID: modelID)
        if error != nil,
           modelID != TranslationModelSelection.defaultModelID {
            failedSelectedModelID = modelID
            let originalError = error
            let fallbackError = await load(
                modelID: TranslationModelSelection.defaultModelID
            )
            if fallbackError == nil {
                lastError =
                    "\(originalError ?? "所选模型不可用")（已回退到内置模型）"
                return lastError
            }
            lastError = (
                "\(originalError ?? "所选模型不可用")"
                    + "（内置模型回退失败：\(fallbackError ?? "unknown")）"
            )
            return lastError
        } else if error == nil {
            failedSelectedModelID = nil
        }
        return error
    }

    private func load(modelID: String) async -> String? {
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
        if activeModel?.modelID != selectedModelID,
           failedSelectedModelID != selectedModelID {
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
        }
    }
}
