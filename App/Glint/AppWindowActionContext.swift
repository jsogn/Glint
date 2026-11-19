import Foundation
import GlintCore
import GlintMac
import GlintPlugins
import GlintUI

@MainActor
final class AppWindowActionContext {
    weak var windowModel: MainWindowModel?

    var startMonitoring: (() -> Void)?
    var stopMonitoring: (() -> Void)?
    var refreshPermissions: (() -> Void)?
    var requestPermissions: (() -> Void)?
    var openAccessibilitySettings: (() -> Void)?
    var refreshLaunchAtLogin: (() -> Void)?
    var setLaunchAtLogin: ((Bool) -> Void)?
    var showMainWindow: (() -> Void)?
    var openSystemTranslationSettings: (() -> Void)?
    var syncTranslationConfiguration: (() -> Void)?

    private let environment: AppEnvironment
    private let translationLanguageCoordinator: TranslationLanguageCoordinator
    private let launchAtLoginController: LaunchAtLoginController
    private let translationSpeechController: TranslationSpeechController

    init(
        environment: AppEnvironment,
        translationLanguageCoordinator: TranslationLanguageCoordinator,
        launchAtLoginController: LaunchAtLoginController,
        translationSpeechController: TranslationSpeechController
    ) {
        self.environment = environment
        self.translationLanguageCoordinator = translationLanguageCoordinator
        self.launchAtLoginController = launchAtLoginController
        self.translationSpeechController = translationSpeechController
    }

    func makeActions() -> MainWindowActions {
        MainWindowActions(
            monitoring: .init(
                startMonitoring: { [weak self] in
                    self?.startMonitoring?()
                },
                stopMonitoring: { [weak self] in
                    self?.stopMonitoring?()
                }
            ),
            permissions: .init(
                refreshPermissions: { [weak self] in
                    self?.refreshPermissions?()
                },
                requestPermissions: { [weak self] in
                    self?.requestPermissions?()
                },
                openAccessibilitySettings: { [weak self] in
                    self?.openAccessibilitySettings?()
                },
                refreshLaunchAtLogin: { [weak self] in
                    self?.refreshLaunchAtLogin?()
                },
                setLaunchAtLogin: { [weak self] enabled in
                    self?.setLaunchAtLogin?(enabled)
                },
                openLoginItemsSettings: { [weak self] in
                    self?.launchAtLoginController.openSystemSettings()
                },
                refreshInputMethodSupport: { [weak self] in
                    guard let self else {
                        return Self.inputMethodSupportStatuses(nil)
                    }
                    return Self.inputMethodSupportStatuses(
                        await environment.squirrelIntegrationService.status()
                    )
                },
                installSquirrelSupport: { [weak self] in
                    guard let self else {
                        throw SquirrelIntegrationError.squirrelUnavailable
                    }
                    return Self.inputMethodSupportStatuses(
                        try await environment.squirrelIntegrationService
                            .install()
                    )
                },
                uninstallSquirrelSupport: { [weak self] in
                    guard let self else {
                        throw SquirrelIntegrationError.squirrelUnavailable
                    }
                    return Self.inputMethodSupportStatuses(
                        try await environment.squirrelIntegrationService
                            .uninstall()
                    )
                }
            ),
            translation: .init(
                activateModel: { [weak self] modelID in
                    guard
                        let self,
                        let windowModel = self.windowModel
                    else {
                        return "翻译运行时不可用"
                    }
                    return await self.environment.translationRuntime.prepare(
                        modelID: modelID,
                        direction: TranslationDirection(
                            target: windowModel.translationTarget
                        )
                    )
                },
                validateModel: { [weak self] modelID in
                    guard
                        let self,
                        let windowModel = self.windowModel
                    else {
                        return "翻译运行时不可用"
                    }
                    return await self.environment.translationRuntime.validate(
                        modelID: modelID,
                        direction: TranslationDirection(
                            target: windowModel.translationTarget
                        )
                    )
                },
                refreshSystemTranslation: { [weak self] in
                    guard
                        let self,
                        let windowModel = self.windowModel
                    else {
                        return .unsupported
                    }
                    let direction = TranslationDirection(
                        target: windowModel.translationTarget
                    )
                    await self.environment.systemTranslationCoordinator
                        .refreshAvailability(for: direction)
                    return self.environment.systemTranslationCoordinator
                        .availability ?? .unsupported
                },
                prepareSystemTranslation: { [weak self] in
                    guard
                        let self,
                        let windowModel = self.windowModel
                    else {
                        throw SystemTranslationError.sessionUnavailable
                    }
                    let direction = TranslationDirection(
                        target: windowModel.translationTarget
                    )
                    try await self.environment.systemTranslationCoordinator
                        .prepareLanguagePack(for: direction)
                    return self.environment.systemTranslationCoordinator
                        .availability ?? .failed("系统翻译状态未知")
                },
                presentSystemTranslation: { [weak self] in
                    self?.showMainWindow?()
                },
                openSystemTranslationSettings: { [weak self] in
                    self?.openSystemTranslationSettings?()
                },
                releaseModel: { [weak self] modelID in
                    guard let self else { return }
                    await self.environment.translationRuntime
                        .releaseResources(for: modelID)
                },
                previewSpeech: { [weak self] target in
                    self?.previewSpeech(target)
                },
                changeTarget: { [weak self] target in
                    guard let self else {
                        return .failed(target, "翻译运行时不可用")
                    }
                    return await self.translationLanguageCoordinator
                        .switchTarget(to: target)
                },
                selectModel: { [weak self] modelID, target in
                    guard let self else {
                        return .failed(target, "翻译运行时不可用")
                    }
                    return await self.translationLanguageCoordinator
                        .selectModel(modelID, for: target)
                },
                setMode: { [weak self] mode in
                    guard let self else { return }
                    Task {
                        await self.environment.monitoring.setMode(mode)
                    }
                },
                configurationChanged: { [weak self] in
                    self?.syncTranslationConfiguration?()
                }
            ),
            plugins: .init(
                checkCoreDictionaryUpdate: { [weak self] kind in
                    guard let self else {
                        throw CoreDictionaryUpdateError.unavailable
                    }
                    return try await self.environment.checkCoreDictionaryUpdate(
                        kind: kind
                    )
                },
                checkTranslationModelUpdate: { [weak self] manifest in
                    guard let self else {
                        throw ModelHubError.unavailable
                    }
                    return try await self.environment
                        .checkTranslationModelUpdate(manifest)
                },
                searchModelMarket: { [weak self] query in
                    guard let self else {
                        throw ModelHubError.unavailable
                    }
                    return try await self.environment.searchModelMarket(
                        query: query
                    )
                },
                prepareModelMarketInstall: {
                    [weak self] model, knownManifest in
                    guard let self else {
                        throw ModelHubError.unavailable
                    }
                    return try await self.environment
                        .prepareModelMarketInstall(
                            model,
                            matching: knownManifest
                        )
                },
                availableInstallationSpace: {
                    Self.availableInstallationSpace()
                },
                dictionaryConfigurationChanged: { [weak self] in
                    await self?.environment.refreshDictionaryRoutes()
                }
            )
        )
    }

    private func previewSpeech(_ target: TranslationTarget) {
        guard let windowModel else { return }
        let preferences = windowModel.generalPreferences
        translationSpeechController.speakPreview(
            target: target,
            accent: preferences.speechAccent,
            voiceIdentifier:
                preferences.speechVoiceIdentifier(for: target),
            rate: preferences.speechRate
        )
    }

    private static func availableInstallationSpace() -> Int64? {
        let directory =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        return try? directory?.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
    }

    private static func inputMethodSupportStatuses(
        _ status: SquirrelIntegrationStatus?
    ) -> [InputMethodSupportStatus] {
        guard let status else {
            return [
                .applePinyin,
                InputMethodSupportStatus(
                    id: "squirrel",
                    name: "Rime 输入法",
                    detail: "未检测到可用的输入法。",
                    state: .unavailable,
                    schemaIDs: [],
                    protocolVersion: nil
                ),
            ]
        }
        let uiState: InputMethodSupportState
        switch status.state {
        case .unavailable:
            uiState = .unavailable
        case .available:
            uiState = .available
        case .installed:
            uiState = .installed
        case .repairRequired:
            uiState = .repairRequired
        case .manualSetupRequired:
            uiState = .manualSetupRequired
        }
        return [
            .applePinyin,
            InputMethodSupportStatus(
                id: "squirrel",
                name: "Rime 输入法",
                detail: status.detail ?? defaultDetail(for: uiState),
                state: uiState,
                schemaIDs: status.schemaIDs,
                protocolVersion: status.protocolVersion
            ),
        ]
    }

    private static func defaultDetail(
        for state: InputMethodSupportState
    ) -> String {
        switch state {
        case .native:
            "原生读取当前候选。"
        case .available:
            "候选读取支持未安装。"
        case .installed:
            "候选读取支持已安装。"
        case .repairRequired:
            "候选读取支持需要重新安装。"
        case .manualSetupRequired:
            "当前配置无法自动合并，请按手动说明操作。"
        case .unavailable:
            "未检测到可用的输入法。"
        }
    }
}
