import Foundation
import GlintCore

/// Resolves an explicitly selected model into a concrete local runtime.
public actor TranslationRuntime: TranslationEngine {
    public typealias ModelResolver =
        @Sendable (_ modelID: String) async ->
            ResolvedTranslationModel?

    private let systemEngine: (any TranslationEngine)?
    private let modelResolver: ModelResolver
    private var activeModel: ResolvedTranslationModel?
    private var activeSystemModelID: String?
    private var activeEngine: (any TranslationEngine)?
    private(set) var activeDirection: TranslationDirection?
    private(set) var lastError: String?

    public init(
        systemEngine: (any TranslationEngine)? = nil,
        modelResolver: @escaping ModelResolver
    ) {
        self.systemEngine = systemEngine
        self.modelResolver = modelResolver
    }

    @discardableResult
    public func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        if modelID == SystemTranslationModel.appleTranslationID {
            guard let systemEngine,
                await systemEngine.supports(direction)
            else {
                clearActiveRuntime()
                lastError = "系统翻译不支持当前方向"
                return lastError
            }
            activeEngine = systemEngine
            activeDirection = direction
            activeSystemModelID = modelID
            activeModel = nil
            lastError = nil
            return nil
        }

        guard let descriptor = await modelResolver(modelID) else {
            clearActiveRuntime()
            lastError = "未找到所选翻译模型"
            return lastError
        }
        guard descriptor.supportedDirections.contains(direction) else {
            clearActiveRuntime()
            lastError = "当前模型不支持目标语言"
            return lastError
        }

        // Release the previous multi-gigabyte container before loading a new one.
        clearActiveRuntime()
        do {
            let engine = try makeEngine(
                for: descriptor,
                direction: direction
            )
            activeModel = descriptor
            activeDirection = direction
            activeEngine = engine
            lastError = nil
            return nil
        } catch {
            clearActiveRuntime()
            lastError = error.localizedDescription
            return lastError
        }
    }

    public func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        if let activeEngine,
            activeDirection == direction
        {
            return await activeEngine.supports(direction)
        }
        if let systemEngine,
            await systemEngine.supports(direction)
        {
            return true
        }
        return false
    }

    public func releaseResources(for modelID: String) {
        if activeSystemModelID == modelID {
            clearActiveRuntime()
            lastError = nil
            return
        }
        guard activeModel?.modelID == modelID else { return }
        clearActiveRuntime()
        lastError = nil
    }

    public func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()

        if activeDirection == request.direction,
            let activeEngine
        {
            do {
                if let result = try await activeEngine.translate(request) {
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
        guard activeDirection == request.direction else {
            throw GlintError.engineUnavailable
        }
        throw GlintError.engineUnavailable
    }

    private func clearActiveRuntime() {
        activeEngine = nil
        activeModel = nil
        activeSystemModelID = nil
        activeDirection = nil
    }

    private func makeEngine(
        for model: ResolvedTranslationModel,
        direction: TranslationDirection
    ) throws -> any TranslationEngine {
        switch model.storage {
        case let .mlx(directory, promptProfile):
            return MLXTranslationEngine(
                modelDirectory: directory,
                modelID: model.modelID,
                promptProfile: promptProfile
            )
        case let .ctranslate2(directory):
            return try CTranslate2Engine(
                direction: direction,
                modelDirectory: directory
            )
        }
    }
}
