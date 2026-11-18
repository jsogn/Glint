import Foundation
import GlintCore

@MainActor
final class TranslationCoordinator {
    private let selectionStore: TranslationSelectionStore
    private var requestGeneration: UInt64 = 0
    private var systemRequestGeneration: UInt64 = 0
    private var changeCount = 0

    init(selectionStore: TranslationSelectionStore) {
        self.selectionStore = selectionStore
    }

    func setTranslationTarget(
        _ target: TranslationTarget,
        on model: MainWindowModel
    ) async {
        guard target != model.translationTarget else {
            return
        }
        let generation = beginRequest()
        invalidateSystemOperations(on: model)
        beginChange(on: model)
        defer { endChange(on: model) }
        model.translationReadiness = .preparing(target)
        model.translationTarget = target
        model.translationModelStatusText = nil
        model.translationModelStatusIsError = false
        model.translationModelStatusModelID = nil
        model.activeModelID = resolvedModelID(
            for: target,
            on: model
        )

        let readiness = await model.changeTranslationTargetAction(target)
        guard generation == requestGeneration else {
            return
        }
        guard target == model.translationTarget else { return }
        model.translationReadiness = readiness
        switch readiness {
        case .preparing, .ready, .needsSetup, .failed, .unsupported:
            model.activeModelID = resolvedModelID(
                for: target,
                on: model
            )
            model.translationConfigurationChangedAction()
        case .idle, .superseded:
            break
        }
    }

    func updateTranslationReadiness(
        _ readiness: TranslationReadiness,
        on model: MainWindowModel
    ) {
        model.translationReadiness = readiness
    }

    func retryTranslationConfiguration(
        on model: MainWindowModel
    ) async {
        await setTranslationModel(
            model.activeModelID,
            for: model.translationTarget,
            on: model
        )
    }

    func setTranslationModel(
        _ modelID: String,
        for target: TranslationTarget,
        on model: MainWindowModel
    ) async {
        guard target == model.translationTarget else {
            return
        }
        let generation = beginRequest()
        beginChange(on: model)
        defer { endChange(on: model) }
        model.translationReadiness = .preparing(target)
        model.translationModelStatusText = nil
        model.translationModelStatusIsError = false
        model.translationModelStatusModelID = nil
        model.systemTranslationError = nil

        let readiness = await model.selectTranslationModelAction(
            modelID,
            target
        )
        guard generation == requestGeneration else {
            return
        }
        guard target == model.translationTarget else { return }
        model.translationReadiness = readiness
        guard readiness != .superseded else { return }
        model.activeModelID = modelID
        selectionStore.selectModel(modelID, for: target)
        model.translationConfigurationChangedAction()
    }

    func previewTranslationSpeech(on model: MainWindowModel) {
        model.previewTranslationSpeechAction(model.translationTarget)
    }

    func persistActiveModelID(
        _ modelID: String,
        target: TranslationTarget
    ) {
        selectionStore.selectModel(modelID, for: target)
    }

    func updateSystemTranslationAvailability(
        _ availability: SystemTranslationAvailability,
        on model: MainWindowModel
    ) {
        let previousAvailability = model.systemTranslationAvailability
        model.systemTranslationAvailability = availability
        if previousAvailability == .installing,
            availability == .available
        {
            model.systemTranslationPreparationIsIncomplete = true
        }
        if availability.canSelect {
            model.systemTranslationPreparationIsIncomplete = false
        }
    }

    func refreshSystemTranslationSupport(
        on model: MainWindowModel
    ) async {
        guard !model.isRefreshingSystemTranslation else { return }
        let generation = systemRequestGeneration
        model.isRefreshingSystemTranslation = true
        model.systemTranslationError = nil
        defer {
            if generation == systemRequestGeneration {
                model.isRefreshingSystemTranslation = false
            }
        }
        let availability =
            await model.refreshSystemTranslationAction()
        guard generation == systemRequestGeneration else {
            return
        }
        updateSystemTranslationAvailability(
            availability,
            on: model
        )
    }

    func prepareSystemTranslationSupport(
        on model: MainWindowModel
    ) async {
        guard model.systemTranslationAvailability != .installing else {
            return
        }
        guard !model.isPreparingSystemTranslation else { return }
        let generation = systemRequestGeneration
        let wasInstalled =
            model.systemTranslationAvailability?.canSelect == true
        model.isPreparingSystemTranslation = true
        model.systemTranslationError = nil
        model.systemTranslationPreparationIsIncomplete = false
        defer {
            if generation == systemRequestGeneration {
                model.isPreparingSystemTranslation = false
            }
        }
        do {
            let availability =
                try await model.prepareSystemTranslationAction()
            guard generation == systemRequestGeneration else {
                return
            }
            updateSystemTranslationAvailability(
                availability,
                on: model
            )
            if availability == .available {
                model.systemTranslationPreparationIsIncomplete = true
            }
            if availability.canSelect, !wasInstalled {
                model.systemTranslationPresentationEvent &+= 1
                model.systemTranslationPresentationAction()
            }
            await retryTranslationConfiguration(on: model)
        } catch {
            if TaskCancellation.isCancellation(error) {
                guard generation == systemRequestGeneration else {
                    return
                }
                model.systemTranslationPreparationIsIncomplete = true
                return
            }
            guard generation == systemRequestGeneration else {
                return
            }
            let message = error.localizedDescription
            updateSystemTranslationAvailability(
                .failed(message),
                on: model
            )
            model.systemTranslationError = message
        }
    }

    func openSystemTranslationSettings(on model: MainWindowModel) {
        model.openSystemTranslationSettingsAction()
    }

    private func beginRequest() -> UInt64 {
        requestGeneration &+= 1
        return requestGeneration
    }

    private func resolvedModelID(
        for target: TranslationTarget,
        on model: MainWindowModel
    ) -> String {
        let stored = selectionStore.selectedModelID(for: target)
        guard stored != TranslationSelectionStore.defaultModelID else {
            return stored
        }
        guard
            let plugin = model.translationPlugins.first(where: {
                $0.id == stored
            }),
            MainWindowModel.supports(plugin, target: target)
        else {
            selectionStore.selectModel(
                TranslationSelectionStore.defaultModelID,
                for: target
            )
            return TranslationSelectionStore.defaultModelID
        }
        return stored
    }

    private func invalidateSystemOperations(
        on model: MainWindowModel
    ) {
        systemRequestGeneration &+= 1
        model.isPreparingSystemTranslation = false
        model.isRefreshingSystemTranslation = false
        model.systemTranslationAvailability = nil
        model.systemTranslationError = nil
        model.systemTranslationPreparationIsIncomplete = false
    }

    private func beginChange(on model: MainWindowModel) {
        changeCount += 1
        model.isChangingTranslationTarget = true
    }

    private func endChange(on model: MainWindowModel) {
        changeCount = max(0, changeCount - 1)
        model.isChangingTranslationTarget = changeCount > 0
    }

}
