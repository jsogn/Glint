import Foundation
import GlintCore
import GlintMac
import GlintUI

@MainActor
final class AppWindowPreferencesContext {
    weak var windowModel: MainWindowModel?
    var updateStatusItemVisibility: (() -> Void)?
    var updateActivationPolicy: (() -> Void)?

    private let environment: AppEnvironment
    private let translationChoiceShortcutCoordinator: TranslationChoiceShortcutCoordinator
    private let translationSpeechShortcutCoordinator: TranslationChoiceShortcutCoordinator
    private let translationSpeechController: TranslationSpeechController
    private let translationAutoSpeechScheduler: TranslationAutoSpeechScheduler

    init(
        environment: AppEnvironment,
        translationChoiceShortcutCoordinator:
            TranslationChoiceShortcutCoordinator,
        translationSpeechShortcutCoordinator:
            TranslationChoiceShortcutCoordinator,
        translationSpeechController: TranslationSpeechController,
        translationAutoSpeechScheduler: TranslationAutoSpeechScheduler
    ) {
        self.environment = environment
        self.translationChoiceShortcutCoordinator =
            translationChoiceShortcutCoordinator
        self.translationSpeechShortcutCoordinator =
            translationSpeechShortcutCoordinator
        self.translationSpeechController = translationSpeechController
        self.translationAutoSpeechScheduler = translationAutoSpeechScheduler
    }

    func configure() {
        guard let windowModel else { return }
        windowModel.generalPreferences.shortcutAvailabilityCheck = {
            shortcut in
            TranslationChoiceHotKeyProbe.canRegister(
                modifiers: shortcut.modifiers
            )
        }
        environment.systemTranslationCoordinator.onAvailabilityChange = {
            [weak self] direction, availability in
            guard let self, let windowModel = self.windowModel else {
                return
            }
            let currentDirection = TranslationDirection(
                target: windowModel.translationTarget
            )
            guard direction == currentDirection else { return }
            windowModel.updateSystemTranslationAvailability(availability)
        }
        windowModel.displayPreferences.candidateDwellDurationDidChange = {
            [weak self] duration in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setCandidateDwellDuration(
                    duration
                )
            }
        }
        windowModel.displayPreferences.translationScopeDidChange = {
            [weak self] scope in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setTranslationScope(scope)
            }
        }
        windowModel.displayPreferences.showsPartsOfSpeechDidChange = {
            [weak self] enabled in
            guard let self else { return }
            Task {
                await self.environment.monitoring.setShowsPartsOfSpeech(
                    enabled
                )
            }
        }
        windowModel.displayPreferences.maximumTranslationCountDidChange = {
            [weak self] count in
            guard let self else { return }
            Task {
                await self.environment.monitoring
                    .setMaximumTranslationCount(count)
            }
        }
        windowModel.generalPreferences.insertionShortcutDidChange = {
            [weak self] shortcut in
            guard let self else { return }
            if let shortcut {
                self.translationChoiceShortcutCoordinator.updateShortcut(
                    shortcut
                )
                self.translationChoiceShortcutCoordinator.setEnabled(true)
            } else {
                self.translationChoiceShortcutCoordinator.setEnabled(false)
            }
        }
        windowModel.generalPreferences.speechShortcutDidChange = {
            [weak self] shortcut in
            guard let self else { return }
            if let shortcut {
                self.translationSpeechShortcutCoordinator.updateShortcut(
                    shortcut
                )
                self.translationSpeechShortcutCoordinator.setEnabled(true)
            } else {
                self.translationSpeechShortcutCoordinator.setEnabled(false)
                self.translationSpeechController.stopManual()
            }
        }
        windowModel.generalPreferences.speechAccentDidChange = {
            [weak self] _ in
            self?.translationSpeechController.stop()
        }
        windowModel.generalPreferences.speechVoiceDidChange = {
            [weak self] in
            self?.translationSpeechController.stop()
        }
        windowModel.generalPreferences.speechRateDidChange = {
            [weak self] _ in
            self?.translationSpeechController.stop()
        }
        windowModel.generalPreferences.autoSpeechEnabledDidChange = {
            [weak self] enabled in
            guard let self, !enabled else { return }
            self.translationAutoSpeechScheduler.cancel()
            self.translationSpeechController.stopAutomatic()
        }
        windowModel.generalPreferences.autoSpeechDelayDidChange = {
            [weak self] delay in
            self?.translationAutoSpeechScheduler.setDelay(delay)
        }
        windowModel.generalPreferences.menuBarIconVisibilityDidChange = {
            [weak self] _ in
            self?.updateStatusItemVisibility?()
        }
        windowModel.generalPreferences.dockIconVisibilityDidChange = {
            [weak self] _ in
            self?.updateActivationPolicy?()
        }
    }
}
