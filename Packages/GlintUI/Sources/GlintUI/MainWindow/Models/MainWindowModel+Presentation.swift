import Foundation
import GlintCore
import GlintPlugins

extension MainWindowModel {
    public var compatibleTranslationPlugins: [PluginManifest] {
        translationPlugins.filter {
            Self.supports($0, target: translationTarget)
        }
    }

    public var dictionaryPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .dictionary }
    }

    public var translationPlugins: [PluginManifest] {
        installedPlugins.filter { $0.type == .translation }
    }

    public var localTranslationPlugins: [PluginManifest] {
        translationPlugins.filter { $0.source == .local }
    }

    public var recommendedTranslationPlugins: [PluginManifest] {
        translationPlugins.filter { $0.source != .local }
    }

    public var translationSummary: String {
        if isActiveSystemTranslationModel {
            return "Apple 翻译"
        }
        return activeTranslationPlugin?.name ?? "未安装"
    }

    public var translationCharacterSummary: String {
        if isActiveSystemTranslationModel {
            return "系统本地翻译，适合短语和短句。"
        }
        guard let plugin = activeTranslationPlugin else {
            return "未安装"
        }
        let summary =
            plugin.summary?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        return summary.isEmpty ? "本地翻译模型" : summary
    }

    public var translationAttentionMessage: String? {
        guard translationModelStatusIsError else { return nil }
        return "翻译模型需要检查，请在插件与模型中查看。"
    }

    public var translationAttentionDetail: String? {
        guard translationModelStatusIsError else { return nil }
        return translationModelStatusText
    }

    var activeTranslationPlugin: PluginManifest? {
        translationPlugins.first { $0.id == activeModelID }
    }

    public var candidateSummary: String {
        "输入候选词"
    }

    public var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled
    }

    public var isActiveSystemTranslationModel: Bool {
        activeModelID
            == SystemTranslationModel.appleTranslationID
    }

    var isActiveSystemTranslationReady: Bool {
        isActiveSystemTranslationModel
            && systemTranslationAvailability == .installed
    }

    var systemTranslationSetupState: SystemTranslationSetupState? {
        guard isActiveSystemTranslationModel,
            systemTranslationAvailability != .installed
        else {
            return nil
        }
        if isPreparingSystemTranslation {
            return .installing
        }
        switch systemTranslationAvailability {
        case .available:
            return systemTranslationPreparationIsIncomplete
                ? .installationIncomplete
                : .installationRequired
        case .installing:
            return .installing
        case .failed(let message):
            return .failed(message)
        case .unsupported:
            return .unsupported
        case .installed, nil:
            return nil
        }
    }

    public var launchAtLoginRequiresApproval: Bool {
        launchAtLoginStatus == .requiresApproval
    }

    public var squirrelSupportStatus: InputMethodSupportStatus? {
        inputMethodSupportStatuses.first { $0.id == "squirrel" }
    }

    public var inputMethodSupportPageStatuses: [InputMethodSupportStatus] {
        inputMethodSupportStatuses.filter { $0.id == "squirrel" }
    }

    public var hasActiveCoreDictionaryUpdate: Bool {
        coreDictionaryUpdateStates.values.contains {
            $0.isChecking
        }
    }
}
