import Foundation
import GlintCore
import GlintPlugins

@MainActor
final class LocalModelImportCoordinator {
    private let pluginLifecycle: PluginLifecycleService
    private var importTask: Task<Void, Never>?

    init(pluginLifecycle: PluginLifecycleService) {
        self.pluginLifecycle = pluginLifecycle
    }

    func importModel(
        from directory: URL,
        on model: MainWindowModel
    ) {
        guard importTask == nil, model.isInstalling == nil else { return }
        model.localImportError = nil
        model.localImportProgress = 0
        model.isImportingLocalModel = true
        importTask = Task { [weak self, weak model] in
            guard let self else { return }
            guard let model else {
                self.importTask = nil
                return
            }
            defer {
                model.isImportingLocalModel = false
                self.importTask = nil
            }
            await self.performImport(
                from: directory,
                on: model
            )
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func performImport(
        from directory: URL,
        on model: MainWindowModel
    ) async {
        do {
            let previousModelID = model.activeModelID
            let manifest = try await pluginLifecycle.importLocalModel(
                from: directory
            ) { [weak model] value in
                Task { @MainActor [weak model] in
                    model?.localImportProgress = value
                }
            }
            let hadPendingUpgrade =
                await pluginLifecycle.hasPendingUpgrade()
            await model.refreshInstalledPlugins()
            if Task.isCancelled {
                _ = await recoverFromFailure(
                    manifest: manifest,
                    previousModelID: previousModelID,
                    hadPendingUpgrade: hadPendingUpgrade,
                    error: "导入已取消",
                    on: model
                )
                return
            }
            if MainWindowModel.supports(
                manifest,
                target: model.translationTarget
            ) {
                model.translationModelStatusText = "正在验证本地模型…"
                model.translationModelStatusIsError = false
                model.translationModelStatusModelID = manifest.id

                let activationError =
                    await model.activateTranslationModelAction(manifest.id)
                if Task.isCancelled {
                    _ = await recoverFromFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: "导入已取消",
                        on: model
                    )
                    return
                }
                if let activationError {
                    let message = await recoverFromFailure(
                        manifest: manifest,
                        previousModelID: previousModelID,
                        hadPendingUpgrade: hadPendingUpgrade,
                        error: activationError,
                        on: model
                    )
                    model.localImportError = message
                    model.translationModelStatusText = message
                    model.translationModelStatusIsError = true
                    model.translationModelStatusModelID = previousModelID
                    return
                }
                await model.releaseTranslationModelAction(manifest.id)
                if let restoreError =
                    await model.activateTranslationModelAction(
                        previousModelID
                    )
                {
                    model.catalogError =
                        "模型已安装，但恢复原模型失败：\(restoreError)"
                }
            }

            do {
                try await pluginLifecycle.commitPendingUpgrade()
                model.localImportProgress = 1
                model.translationModelStatusText = nil
                model.translationModelStatusIsError = false
                model.translationModelStatusModelID = nil
                model.translationConfigurationChangedAction()
            } catch {
                let message = await recoverFromFailure(
                    manifest: manifest,
                    previousModelID: previousModelID,
                    hadPendingUpgrade: hadPendingUpgrade,
                    error: error.localizedDescription,
                    on: model
                )
                model.localImportError = message
                model.translationModelStatusText = message
                model.translationModelStatusIsError = true
                model.translationModelStatusModelID = previousModelID
            }
        } catch {
            if !TaskCancellation.isCancellation(error) {
                model.localImportError = error.localizedDescription
            }
        }
    }

    private func recoverFromFailure(
        manifest: PluginManifest,
        previousModelID: String,
        hadPendingUpgrade: Bool,
        error: String,
        on model: MainWindowModel
    ) async -> String {
        await model.releaseTranslationModelAction(manifest.id)
        var recoveryErrors: [String] = []

        if hadPendingUpgrade {
            do {
                try await pluginLifecycle.rollbackPendingUpgrade()
            } catch {
                recoveryErrors.append(
                    "恢复旧版本失败：\(error.localizedDescription)"
                )
            }
        } else {
            do {
                try await pluginLifecycle.uninstall(id: manifest.id)
            } catch {
                recoveryErrors.append(
                    "移除失败模型失败：\(error.localizedDescription)"
                )
            }
        }

        model.activeModelID = previousModelID
        model.persistActiveModelID()
        await model.refreshInstalledPlugins()
        if let recoveryError = await model.activateTranslationModelAction(
            previousModelID
        ) {
            recoveryErrors.append(
                "恢复原模型失败：\(recoveryError)"
            )
        }
        model.translationConfigurationChangedAction()

        if recoveryErrors.isEmpty {
            return "导入失败，已恢复原模型：\(error)"
        }
        return
            ("导入失败：\(error)"
            + "（\(recoveryErrors.joined(separator: "；"))）")
    }
}
