import AppKit
import GlintCore
import GlintMac
import GlintUI

extension AppDelegate {
    @objc func startMonitoring() {
        startMonitoring(requestPermissionIfNeeded: true)
    }

    func startMonitoring(
        requestPermissionIfNeeded: Bool
    ) {
        if startupPreparationTask != nil || windowModel.isPreparingMonitoring {
            shouldStartMonitoringAfterPreparation = true
            shouldRequestPermissionAfterPreparation =
                shouldRequestPermissionAfterPreparation
                || requestPermissionIfNeeded
            updateMonitoringMenuItem()
            return
        }
        guard
            windowModel.translationReadiness
                == .ready(windowModel.translationTarget)
        else {
            if requestPermissionIfNeeded {
                showMainWindow()
            }
            return
        }
        guard sessionState == .idle else { return }
        refreshPermissionState()
        if !windowModel.accessibilityGranted,
            requestPermissionIfNeeded
        {
            beginPermissionRequest()
        }
        let settings = monitoringSettings
        let session = environment.monitoringSession
        Task.detached(priority: .userInitiated) {
            await session.start(settings)
        }
    }

    @objc func stopMonitoring() {
        translationLanguageCoordinator.cancelPendingResume()
        prepareForMonitoringStop()
        let session = environment.monitoringSession
        Task.detached(priority: .userInitiated) {
            await session.stop()
        }
    }

    func stopMonitoringForLanguageSwitch() async {
        prepareForMonitoringStop()
        await environment.monitoringSession.stop()
        if sessionState != .idle {
            sessionState = .idle
            updateStatusItem(isMonitoring: false)
            updateMonitoringMenuItem()
        }
    }

    func prepareForMonitoringStop() {
        shouldStartMonitoringAfterPreparation = false
        shouldRequestPermissionAfterPreparation = false
        translationChoiceShortcutCoordinator.update(nil)
        translationSpeechShortcutCoordinator.update(nil)
        translationAutoSpeechScheduler.cancel()
        translationSpeechController.stop()
        hudEventCoordinator.hide(animated: false)
        windowModel.isMonitoring = false
        windowModel.statusText = ""
        updateStatusItem(isMonitoring: false)
        updateMonitoringMenuItem()
    }

    var monitoringSettings: MonitoringSettings {
        MonitoringSettings(
            mode: windowModel.translationMode,
            translationTarget: windowModel.translationTarget,
            candidateDwellDuration: windowModel.displayPreferences
                .candidateDwellDuration,
            translationScope: windowModel.displayPreferences.translationScope,
            maximumTranslationCount: windowModel.displayPreferences
                .maximumTranslationCount,
            showsPartsOfSpeech: windowModel.displayPreferences
                .showsPartsOfSpeech,
            configurationToken: translationConfigurationToken
        )
    }

    func startEventPump() {
        guard eventPumpTask == nil else { return }
        eventPumpTask = Task { [weak self] in
            guard let self else { return }
            let events = await self.environment.monitoringSession.events
            for await event in events {
                self.handleSessionEvent(event)
            }
        }
    }

    func handleSessionEvent(_ event: MonitoringSessionEvent) {
        switch event {
        case .state(let state):
            sessionState = state
            switch state {
            case .running:
                windowModel.isMonitoring = true
                markRuntimeReady()
            case .idle:
                windowModel.isMonitoring = false
                translationChoiceShortcutCoordinator.update(nil)
                translationSpeechShortcutCoordinator.update(nil)
                translationAutoSpeechScheduler.cancel()
                translationSpeechController.stop()
            case .starting, .stopping:
                break
            }
            updateStatusItem(isMonitoring: windowModel.isMonitoring)
            updateMonitoringMenuItem()
        case .monitoring(let monitoringEvent):
            handle(monitoringEvent)
        }
    }

    func handle(_ event: MonitoringEvent) {
        switch event {
        case .status(let status):
            windowModel.statusText = isActionableStatus(status) ? status : ""
            if status == "安全输入场景已跳过" {
                translationSpeechShortcutCoordinator.update(nil)
                translationAutoSpeechScheduler.cancel()
                translationSpeechController.stop()
            }
        case .inputSourceChanged(let identity):
            windowModel.updateActiveInputMethod(identity)
            translationAutoSpeechScheduler.cancel()
            translationSpeechController.stop()
        case .candidateChanged(let revision):
            translationChoiceShortcutCoordinator.update(nil)
            translationSpeechShortcutCoordinator.update(nil)
            translationSpeechController.stopAutomatic()
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.candidateChanged(
                    revision: revision,
                    delay: windowModel.generalPreferences
                        .autoSpeechDelay
                )
            } else {
                translationAutoSpeechScheduler.cancel()
            }
            hudEventCoordinator.candidateChanged()
        case .selectionChanged(let index, let revision):
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.selectionChanged(
                    index: index,
                    revision: revision,
                    delay: windowModel.generalPreferences
                        .autoSpeechDelay
                )
            }
            hudEventCoordinator.updateSelection(
                index: index,
                revision: revision
            )
        case .layoutChanged(
            let highlight,
            let inputCaretRect,
            let inputFieldRect,
            let candidateSurfaceRect,
            let candidateLayoutOrientation
        ):
            hudEventCoordinator.layoutChanged(
                highlight: highlight,
                inputCaretRect: inputCaretRect,
                inputFieldRect: inputFieldRect,
                candidateSurfaceRect: candidateSurfaceRect,
                candidateLayoutOrientation:
                    candidateLayoutOrientation
            )
        case .candidateEnded(let immediate):
            translationChoiceShortcutCoordinator.update(nil)
            translationSpeechShortcutCoordinator.update(nil)
            translationAutoSpeechScheduler.cancel()
            hudEventCoordinator.candidateEnded(immediate: immediate)
        case .results(
            let translations,
            let highlight,
            let inputCaretRect,
            let inputFieldRect,
            let candidateSurfaceRect,
            let candidateLayoutOrientation,
            let revision,
            let isProgressive
        ):
            hudEventCoordinator.show(
                translations: translations,
                highlight: highlight,
                inputCaretRect: inputCaretRect,
                inputFieldRect: inputFieldRect,
                candidateSurfaceRect: candidateSurfaceRect,
                candidateLayoutOrientation:
                    candidateLayoutOrientation,
                revision: revision,
                isProgressive: isProgressive
            )
            if windowModel.generalPreferences.autoSpeechEnabled {
                translationAutoSpeechScheduler.updateTranslations(
                    primaryTranslations(from: translations),
                    revision: revision,
                    selectedIndex: selectedTranslationIndex(
                        from: translations
                    )
                )
            }
        case .insertionOffer(let offer):
            translationChoiceShortcutCoordinator.update(offer)
            translationSpeechShortcutCoordinator.update(offer)
        }
    }

    func primaryTranslations(
        from translations: [CandidateTranslationPresentation]
    ) -> [Int: String] {
        var values: [Int: String] = [:]
        for item in translations {
            guard
                let text =
                    item.insertionOptions.first
                    ?? item.translation
            else {
                continue
            }
            values[item.index] = text
        }
        return values
    }

    func selectedTranslationIndex(
        from translations: [CandidateTranslationPresentation]
    ) -> Int? {
        translations.first(where: \.isSelected)?.index
    }

    func isActionableStatus(_ status: String) -> Bool {
        status == "需要辅助功能权限"
    }

    func syncTranslationConfiguration() {
        let token = translationConfigurationToken
        Task { [weak self] in
            guard let self else { return }
            await environment.monitoring.setTranslationConfigurationToken(
                token
            )
        }
    }

    var translationConfigurationToken: String {
        let pluginVersions = windowModel.installedPlugins
            .filter {
                $0.type == .dictionary || $0.type == .translation
            }
            .map {
                "\($0.id)@\($0.version)#\($0.revision ?? $0.sha256)"
            }
            .sorted()
        return
            ([
                "target=\(windowModel.translationTarget.rawValue)",
                "model=\(windowModel.activeModelID)",
                "prompt=2",
            ]
            + pluginVersions).joined(separator: "|")
    }
}
