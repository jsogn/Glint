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

    func setDirection(
        _ direction: TranslationDirection
    ) async

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
    private let languageRuntime:
        any TranslationLanguageRuntimeProviding
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
        let shouldResume = wasMonitoring()
        pendingResume = shouldResume
        store.selectedTarget = target
        await stopActiveOutput()
        await clearTranslationCache()

        let readiness = await prepare(
            target: target,
            modelID: store.selectedModelID(for: target)
        )
        guard transaction == generation else {
            return .superseded
        }
        if readiness == .ready(target), shouldResume {
            await resumeMonitoring()
            pendingResume = false
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
        let shouldResume = pendingResume || wasMonitoring()
        pendingResume = shouldResume
        await stopActiveOutput()
        await clearTranslationCache()
        store.selectModel(modelID, for: target)

        let readiness = await prepare(
            target: target,
            modelID: modelID
        )
        guard transaction == generation else {
            return .superseded
        }
        if readiness == .ready(target), shouldResume {
            await resumeMonitoring()
            pendingResume = false
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
        modelID: String
    ) async -> TranslationReadiness {
        let direction = TranslationDirection(target: target)
        guard modelID != SystemTranslationModel.appleTranslationID else {
            await system.setDirection(direction)
            await system.refreshAvailability(for: direction)
            guard system.availability?.canSelect == true else {
                return .needsSetup(
                    target,
                    "需要安装 Apple 翻译语言包"
                )
            }
            guard await system.prepareInstalledSessionIfAvailable(
                for: direction
            ) else {
                return .failed(
                    target,
                    "系统翻译会话不可用"
                )
            }
            return .ready(target)
        }

        if let error = await languageRuntime.prepare(
            modelID: modelID,
            direction: direction
        ) {
            return .failed(target, error)
        }
        return .ready(target)
    }
}
