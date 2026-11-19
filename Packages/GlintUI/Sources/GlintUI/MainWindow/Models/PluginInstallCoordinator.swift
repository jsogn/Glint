import Foundation
import GlintCore
import GlintPlugins

@MainActor
final class PluginInstallCoordinator {
    private struct InstallationAttempt {
        let plugin: PluginManifest
        let wasInstalled: Bool
        let wasActiveTranslation: Bool
        let shouldValidateTranslation: Bool
    }

    private let pluginLifecycle: PluginLifecycleService
    private var installTask: Task<Void, Never>?
    private var modelMarketInstallTask: Task<Void, Never>?
    private var discardCancelledDownload = false

    init(pluginLifecycle: PluginLifecycleService) {
        self.pluginLifecycle = pluginLifecycle
    }

    func install(_ plugin: PluginManifest, on model: MainWindowModel) {
        guard installTask == nil, !model.isImportingLocalModel else {
            return
        }
        model.isInstalling = plugin.id
        model.isCancellingInstallation = false
        discardCancelledDownload = false
        model.installProgress[plugin.id] = PluginInstallProgress(
            fraction: 0,
            phase: .preparing
        )
        model.catalogError = nil
        installTask = Task { [weak self, weak model] in
            guard let self else { return }
            guard let model else {
                self.installTask = nil
                return
            }
            await self.performInstallation(plugin, on: model)
        }
    }

    func cancelInstallation(on model: MainWindowModel) {
        guard let installTask else { return }
        model.isCancellingInstallation = true
        discardCancelledDownload = true
        installTask.cancel()
    }

    func installModelFromMarket(
        _ model: UpstreamModelSummary,
        on host: MainWindowModel
    ) {
        guard host.isPreparingModelMarketInstallID == nil,
            host.modelMarketInstallPreview == nil,
            installTask == nil,
            !host.isImportingLocalModel
        else {
            return
        }
        let knownManifest = host.knownPlugin(forRepository: model.repository)
        host.isPreparingModelMarketInstallID = model.id
        host.modelMarketError = nil
        modelMarketInstallTask = Task { [weak self, weak host] in
            guard let self else { return }
            guard let host else {
                self.modelMarketInstallTask = nil
                return
            }
            defer {
                host.isPreparingModelMarketInstallID = nil
                self.modelMarketInstallTask = nil
            }
            do {
                let preparation =
                    try await host.actions.plugins.prepareModelMarketInstall(
                        model,
                        knownManifest
                    )
                try Task.checkCancellation()
                guard host.isCompatible(preparation.manifest) else {
                    host.modelMarketError =
                        "预计至少需要 \(host.minimumMemoryText(for: preparation.manifest)) 内存，当前设备可能无法运行"
                    return
                }
                let requiredSpace = preparation.snapshot.sizeBytes
                    .multipliedReportingOverflow(by: 2)
                if !requiredSpace.overflow,
                    let available =
                        host.actions.plugins.availableInstallationSpace(),
                    available < requiredSpace.partialValue
                {
                    host.modelMarketError =
                        "模型需要约 \(ByteCountFormatting.file(preparation.snapshot.sizeBytes)) 可用磁盘空间，当前可用 \(ByteCountFormatting.file(available))"
                    return
                }
                host.modelMarketInstallPreview = preparation
            } catch {
                if !Task.isCancelled {
                    host.modelMarketError = error.localizedDescription
                }
            }
        }
    }

    func cancelModelMarketInstall() {
        modelMarketInstallTask?.cancel()
    }

    func confirmModelMarketInstall(on model: MainWindowModel) {
        guard let preview = model.modelMarketInstallPreview else { return }
        model.modelMarketInstallPreview = nil
        model.modelMarketInstallRepository = preview.snapshot.repository
        model.modelMarketInstallPluginID = preview.manifest.id
        install(preview.manifest, on: model)
    }

    func cancelModelMarketInstallPreview(on model: MainWindowModel) {
        model.modelMarketInstallPreview = nil
    }

    private func performInstallation(
        _ plugin: PluginManifest,
        on model: MainWindowModel
    ) async {
        let attempt = installationAttempt(for: plugin, on: model)
        var hadPendingUpgrade = false
        defer {
            finishInstallationAttempt(for: plugin.id, on: model)
        }

        do {
            hadPendingUpgrade = try await installPackage(plugin, on: model)
            try Task.checkCancellation()
            if attempt.shouldValidateTranslation {
                let succeeded = try await validateTranslationInstallation(
                    attempt,
                    hadPendingUpgrade: hadPendingUpgrade,
                    on: model
                )
                guard succeeded else { return }
            } else {
                try await pluginLifecycle.commitPendingUpgrade()
                if plugin.type == .translation {
                    model.recordSuccessfulTranslationModelUpdateCheck(
                        pluginID: plugin.id,
                        update: nil
                    )
                }
            }
            model.installProgress[plugin.id] = PluginInstallProgress(
                fraction: 1,
                phase: .installing
            )
        } catch {
            let shouldDiscardDownload = discardCancelledDownload
            discardCancelledDownload = false
            if shouldDiscardDownload {
                await model.discardDownloadAction(attempt.plugin.id)
                if !attempt.wasInstalled, !hadPendingUpgrade {
                    try? await pluginLifecycle.uninstall(
                        id: attempt.plugin.id
                    )
                }
            }
            await recoverInstallationFailure(
                attempt,
                hadPendingUpgrade: hadPendingUpgrade,
                error: error,
                on: model
            )
        }
    }

    private func installationAttempt(
        for plugin: PluginManifest,
        on model: MainWindowModel
    ) -> InstallationAttempt {
        InstallationAttempt(
            plugin: plugin,
            wasInstalled: model.installedPlugins.contains {
                $0.id == plugin.id
            },
            wasActiveTranslation:
                plugin.type == .translation
                && model.activeModelID == plugin.id,
            shouldValidateTranslation:
                plugin.type == .translation
                && MainWindowModel.supports(
                    plugin,
                    target: model.translationTarget
                )
                && (model.activeModelID == plugin.id
                    || model.modelMarketInstallPluginID == plugin.id)
        )
    }

    private func finishInstallationAttempt(
        for pluginID: String,
        on model: MainWindowModel
    ) {
        installTask = nil
        model.isInstalling = nil
        model.isCancellingInstallation = false
        discardCancelledDownload = false
        model.installProgress.removeValue(forKey: pluginID)
        if model.modelMarketInstallPluginID == pluginID {
            model.modelMarketInstallRepository = nil
            model.modelMarketInstallPluginID = nil
        }
    }

    private func installPackage(
        _ plugin: PluginManifest,
        on model: MainWindowModel
    ) async throws -> Bool {
        _ = try await pluginLifecycle.install(
            plugin
        ) { [weak self, weak model] value in
            Task { @MainActor [weak self, weak model] in
                guard let self, let model else { return }
                self.applyInstallProgress(
                    value,
                    for: plugin.id,
                    on: model
                )
            }
        }
        let hadPendingUpgrade = await pluginLifecycle.hasPendingUpgrade()
        await model.refreshInstalledPlugins()
        if plugin.type == .dictionary {
            await model.actions.plugins.dictionaryConfigurationChanged()
        }
        return hadPendingUpgrade
    }

    private func validateTranslationInstallation(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool,
        on model: MainWindowModel
    ) async throws -> Bool {
        let plugin = attempt.plugin
        if attempt.wasActiveTranslation {
            model.translationModelStatusText = "正在加载新版本…"
            model.translationModelStatusIsError = false
            model.translationModelStatusModelID = plugin.id
        }
        let validationError =
            await model.actions.translation.validateModel(plugin.id)
        try Task.checkCancellation()
        if let validationError {
            try await recoverTranslationValidationFailure(
                attempt,
                hadPendingUpgrade: hadPendingUpgrade,
                error: validationError,
                on: model
            )
            return false
        }
        if attempt.wasActiveTranslation,
            model.activeModelID == plugin.id
        {
            let activationError =
                await model.actions.translation.activateModel(plugin.id)
            try Task.checkCancellation()
            if let activationError {
                try await recoverTranslationValidationFailure(
                    attempt,
                    hadPendingUpgrade: hadPendingUpgrade,
                    error: activationError,
                    on: model
                )
                return false
            }
        }
        try Task.checkCancellation()
        try await pluginLifecycle.commitPendingUpgrade()
        if attempt.wasActiveTranslation,
            model.translationModelStatusModelID == plugin.id
        {
            model.translationModelStatusText = nil
            model.translationModelStatusIsError = false
            model.translationModelStatusModelID = nil
        }
        model.recordSuccessfulTranslationModelUpdateCheck(
            pluginID: plugin.id,
            update: nil
        )
        model.actions.translation.configurationChanged()
        return true
    }

    private func recoverTranslationValidationFailure(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool,
        error: String,
        on model: MainWindowModel
    ) async throws {
        let plugin = attempt.plugin
        let wasCancelled = Task.isCancelled
        if hadPendingUpgrade {
            try await pluginLifecycle.rollbackPendingUpgrade()
            await model.refreshInstalledPlugins()
            if !wasCancelled, attempt.wasActiveTranslation {
                model.translationModelStatusText =
                    "更新失败，已恢复旧版本：\(error)"
            }
        } else {
            await model.actions.translation.releaseModel(plugin.id)
            try await pluginLifecycle.uninstall(id: plugin.id)
            await model.refreshInstalledPlugins()
            if !wasCancelled, attempt.wasActiveTranslation {
                model.translationModelStatusText =
                    "模型加载失败：\(error)"
            }
        }
        if hadPendingUpgrade,
            attempt.wasActiveTranslation,
            model.activeModelID == plugin.id
        {
            let restoreError =
                await model.actions.translation.activateModel(
                    plugin.id
                )
            if let restoreError, !wasCancelled {
                model.translationModelStatusText =
                    "模型验证失败，且原模型恢复失败：\(restoreError)"
            }
        }
        if wasCancelled {
            if attempt.wasActiveTranslation,
                model.translationModelStatusModelID == plugin.id
            {
                model.translationModelStatusText = nil
                model.translationModelStatusIsError = false
                model.translationModelStatusModelID = nil
            }
        } else {
            if attempt.wasActiveTranslation {
                model.translationModelStatusIsError = true
                model.translationModelStatusModelID = plugin.id
            }
            model.catalogError = error
        }
        model.actions.translation.configurationChanged()
    }

    private func recoverInstallationFailure(
        _ attempt: InstallationAttempt,
        hadPendingUpgrade: Bool,
        error: Error,
        on model: MainWindowModel
    ) async {
        let plugin = attempt.plugin
        try? await pluginLifecycle.rollbackPendingUpgrade()
        if attempt.wasActiveTranslation, hadPendingUpgrade {
            await model.actions.translation.releaseModel(plugin.id)
        }
        await model.refreshInstalledPlugins()
        if plugin.type == .dictionary {
            await model.actions.plugins.dictionaryConfigurationChanged()
        }
        if attempt.wasActiveTranslation, hadPendingUpgrade {
            let recoveryError =
                await model.actions.translation.activateModel(plugin.id)
            if TaskCancellation.isCancellation(error) {
                model.translationModelStatusText = nil
                model.translationModelStatusIsError = false
                model.translationModelStatusModelID = nil
            } else if let recoveryError {
                model.translationModelStatusText =
                    "更新失败，模型恢复失败：\(recoveryError)"
                model.translationModelStatusIsError = true
                model.translationModelStatusModelID = plugin.id
            } else {
                model.translationModelStatusText =
                    "更新失败，已恢复当前版本：\(error)"
                model.translationModelStatusIsError = true
                model.translationModelStatusModelID = plugin.id
            }
            model.actions.translation.configurationChanged()
        }
        if !TaskCancellation.isCancellation(error) {
            model.catalogError = error.localizedDescription
        }
    }

    private func applyInstallProgress(
        _ progress: PluginInstallProgress,
        for pluginID: String,
        on model: MainWindowModel
    ) {
        guard model.isInstalling == pluginID else { return }
        if let current = model.installProgress[pluginID],
            current.phase == progress.phase,
            current.sourceHost == progress.sourceHost,
            progress.fraction < current.fraction
        {
            return
        }
        model.installProgress[pluginID] = progress
    }
}
