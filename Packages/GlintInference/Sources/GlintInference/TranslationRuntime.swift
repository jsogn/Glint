import Foundation
import GlintCore
import OSLog

private let runtimeLogger = Logger(
    subsystem: "com.local.glint",
    category: "TranslationRuntime"
)

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
    private var preparationGeneration: UInt64 = 0

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
        preparationGeneration &+= 1
        let generation = preparationGeneration

        if modelID == SystemTranslationModel.appleTranslationID {
            guard let systemEngine else {
                clearActiveRuntime()
                lastError = "系统翻译不支持当前方向"
                return lastError
            }
            let supportsDirection = await systemEngine.supports(
                direction
            )
            guard generation == preparationGeneration else {
                return nil
            }
            guard supportsDirection else {
                clearActiveRuntime()
                lastError = "系统翻译不支持当前方向"
                return lastError
            }
            activeEngine = systemEngine
            activeDirection = direction
            activeSystemModelID = modelID
            activeModel = nil
            lastError = nil
            runtimeLogger.notice(
                "prepare system target=\(direction.target.rawValue, privacy: .public)"
            )
            return nil
        }

        guard let descriptor = await modelResolver(modelID) else {
            guard generation == preparationGeneration else {
                return nil
            }
            clearActiveRuntime()
            lastError = "未找到所选翻译模型"
            return lastError
        }
        guard generation == preparationGeneration else {
            return nil
        }
        guard descriptor.supportedDirections.contains(direction) else {
            clearActiveRuntime()
            lastError = "当前模型不支持目标语言"
            runtimeLogger.error(
                "prepare rejected model=\(modelID, privacy: .public) target=\(direction.target.rawValue, privacy: .public)"
            )
            return lastError
        }

        let engine: any TranslationEngine
        do {
            engine = try makeEngine(
                for: descriptor,
                direction: direction
            )
        } catch {
            guard generation == preparationGeneration else {
                return nil
            }
            clearActiveRuntime()
            lastError = error.localizedDescription
            runtimeLogger.error(
                "prepare failed model=\(modelID, privacy: .public) target=\(direction.target.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return lastError
        }
        guard generation == preparationGeneration else {
            return nil
        }

        // Release the previous multi-gigabyte container before committing
        // the latest successfully prepared runtime.
        clearActiveRuntime()
        activeModel = descriptor
        activeDirection = direction
        activeEngine = engine
        lastError = nil
        runtimeLogger.notice(
            "prepare model=\(modelID, privacy: .public) target=\(direction.target.rawValue, privacy: .public)"
        )
        return nil
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
                runtimeLogger.error(
                    "translate failed target=\(request.direction.target.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if let lastError {
            runtimeLogger.error(
                "translate returning stored failure target=\(request.direction.target.rawValue, privacy: .public)"
            )
            throw NSError(
                domain: "Glint.TranslationRuntime",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: lastError]
            )
        }
        guard activeDirection == request.direction else {
            runtimeLogger.error(
                "translate direction mismatch request=\(request.direction.target.rawValue, privacy: .public) active=\(self.activeDirection?.target.rawValue ?? "none", privacy: .public)"
            )
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
                promptProfile: promptProfile,
                supportedTargets: Set(
                    model.supportedDirections.map(\.target)
                )
            )
        case let .ctranslate2(directory):
            return try CTranslate2Engine(
                direction: direction,
                modelDirectory: directory
            )
        }
    }
}
