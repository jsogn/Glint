import Foundation

@MainActor
public protocol TranslationLanguageRuntimeProviding {
    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String?

    func releaseResources(for modelID: String) async
}

@MainActor
public protocol SystemTranslationLanguageProviding {
    var availability: SystemTranslationAvailability? { get }

    func refreshAvailability(
        for direction: TranslationDirection
    ) async

    func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool
}

@MainActor
public final class TranslationLanguageCoordinator {
    private let store: TranslationSelectionStore
    private let languageRuntime: any TranslationLanguageRuntimeProviding
    private let system: any SystemTranslationLanguageProviding
    private var generation: UInt64 = 0
    private var pendingResume = false

    public var wasMonitoring: @MainActor () -> Bool = { false }
    public var stopActiveOutput: @MainActor () async -> Void = {}
    public var clearTranslationCache: @MainActor () async -> Void = {}
    public var resumeMonitoring: @MainActor () async -> Void = {}

    public init(
        store: TranslationSelectionStore,
        languageRuntime:
            any TranslationLanguageRuntimeProviding,
        system: any SystemTranslationLanguageProviding
    ) {
        self.store = store
        self.languageRuntime = languageRuntime
        self.system = system
    }

    public func switchTarget(
        to target: TranslationTarget
    ) async -> TranslationReadiness {
        guard target != store.selectedTarget else {
            return .ready(target)
        }

        generation &+= 1
        let transaction = generation
        pendingResume = pendingResume || wasMonitoring()
        store.selectedTarget = target
        await stopActiveOutput()
        await clearTranslationCache()

        let readiness = await prepare(
            target: target,
            modelID: store.selectedModelID(for: target),
            transaction: transaction
        )
        guard transaction == generation else {
            return .superseded
        }
        if readiness == .ready(target), pendingResume {
            pendingResume = false
            await resumeMonitoring()
        }
        return readiness
    }

    public func selectModel(
        _ modelID: String,
        for target: TranslationTarget
    ) async -> TranslationReadiness {
        guard target == store.selectedTarget else {
            return .failed(target, "请先切换到目标语言")
        }

        generation &+= 1
        let transaction = generation
        pendingResume = pendingResume || wasMonitoring()
        await stopActiveOutput()
        await clearTranslationCache()
        store.selectModel(modelID, for: target)

        let readiness = await prepare(
            target: target,
            modelID: modelID,
            transaction: transaction
        )
        guard transaction == generation else {
            return .superseded
        }
        if readiness == .ready(target), pendingResume {
            pendingResume = false
            await resumeMonitoring()
        }
        return readiness
    }

    public func prepareCurrentConfiguration()
        async -> TranslationReadiness
    {
        generation &+= 1
        let transaction = generation
        let target = store.selectedTarget
        let readiness = await prepare(
            target: target,
            modelID: store.selectedModelID(for: target),
            transaction: transaction
        )
        guard transaction == generation else {
            return .superseded
        }
        return readiness
    }

    public func retryCurrentConfiguration()
        async -> TranslationReadiness
    {
        let target = store.selectedTarget
        return await selectModel(
            store.selectedModelID(for: target),
            for: target
        )
    }

    public func cancelPendingResume() {
        pendingResume = false
    }

    private func prepare(
        target: TranslationTarget,
        modelID: String,
        transaction: UInt64
    ) async -> TranslationReadiness {
        guard transaction == generation else {
            return .superseded
        }
        let direction = TranslationDirection(target: target)
        await system.refreshAvailability(for: direction)
        guard transaction == generation else {
            return .superseded
        }

        if modelID == SystemTranslationModel.appleTranslationID {
            switch system.availability {
            case .unsupported?:
                return .unsupported(target)
            case .failed(let message)?:
                return .failed(target, message)
            case .installed?:
                break
            case .available?, .installing?, nil:
                return .needsSetup(
                    target,
                    "需要安装 Apple 翻译语言包"
                )
            }
            guard
                await system.prepareInstalledSessionIfAvailable(
                    for: direction
                )
            else {
                return .failed(
                    target,
                    "系统翻译会话不可用"
                )
            }
            guard transaction == generation else {
                return .superseded
            }
        }

        if let error = await languageRuntime.prepare(
            modelID: modelID,
            direction: direction
        ) {
            return .failed(target, error)
        }
        guard transaction == generation else {
            return .superseded
        }
        return .ready(target)
    }
}
