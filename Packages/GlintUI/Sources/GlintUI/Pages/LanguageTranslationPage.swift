import GlintCore
import GlintPlugins
import SwiftUI

struct LanguageTranslationPage: View {
    let model: MainWindowModel
    let onManageModels: () -> Void

    var body: some View {
        PageContainer {
            SettingsCard(
                "学习语言",
                systemImage: "character.bubble"
            ) {
                LanguageTargetSection(model: model)
            }
            if model.translationTarget.supportsDictionaryRouting {
                SettingsCard(
                    "翻译方式",
                    systemImage: "arrow.triangle.branch"
                ) {
                    TranslationStrategySection(model: model)
                }
            }
            SettingsCard("翻译模型", systemImage: "cpu") {
                ActiveTranslationModelSection(
                    model: model,
                    onManageModels: onManageModels
                )
            }
            SettingsCard("朗读语音", systemImage: "speaker.wave.2") {
                TranslationVoiceSection(model: model)
            }
        }
    }
}

private struct LanguageTargetSection: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                inputDirectionBox
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                targetDirectionBox
            }

            languagePackGuidance
        }
    }

    @ViewBuilder
    private var languagePackGuidance: some View {
        if let state = model.systemTranslationSetupState {
            switch state {
            case .installationRequired:
                languagePackNotice(
                    "\(model.translationTarget.chineseDisplayName)需要安装 Apple 翻译语言包",
                    actionTitle: "安装语言包",
                    action: prepareLanguagePack
                )
            case .installationIncomplete:
                languagePackNotice(
                    "\(model.translationTarget.chineseDisplayName)语言包安装未完成",
                    actionTitle: "继续安装",
                    action: prepareLanguagePack
                )
            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        "正在安装\(model.translationTarget.chineseDisplayName)语言包…"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            case .failed:
                languagePackNotice(
                    "\(model.translationTarget.chineseDisplayName)语言包安装失败",
                    actionTitle: "重试",
                    action: prepareLanguagePack
                )
            case .unsupported:
                Label(
                    "当前 Mac 不支持中文到\(model.translationTarget.chineseDisplayName)翻译",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        } else {
            Text("切换语言时会恢复该语言上次使用的翻译模型和朗读音色。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func languagePackNotice(
        _ text: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func prepareLanguagePack() {
        Task {
            await model.prepareSystemTranslationSupport()
        }
    }

    private var targetDirectionBox: some View {
        LanguageDirectionCard {
            VStack(spacing: 5) {
                Text("目标语言")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(
                    "目标语言",
                    selection: Binding(
                        get: { model.translationTarget },
                        set: { target in
                            guard target != model.translationTarget else {
                                return
                            }
                            Task {
                                await model.setTranslationTarget(target)
                            }
                        }
                    )
                ) {
                    ForEach(TranslationTarget.allCases, id: \.self) {
                        target in
                        Text(target.chineseDisplayName).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 118)
            }
        }
    }

    private var inputDirectionBox: some View {
        LanguageDirectionCard {
            VStack(spacing: 5) {
                Text("原文语言")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("中文")
                    .font(.headline)
            }
        }
    }
}

private struct LanguageDirectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

private struct TranslationStrategySection: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 20) {
                Text("优先来源")
                Spacer(minLength: 24)
                Picker(
                    "优先来源",
                    selection: Binding(
                        get: { model.translationMode },
                        set: { model.setTranslationMode($0) }
                    )
                ) {
                    ForEach(TranslationMode.allCases, id: \.self) {
                        mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300, alignment: .trailing)
            }

            Text(model.translationMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActiveTranslationModelSection: View {
    let model: MainWindowModel
    let onManageModels: () -> Void

    private var choices: [TranslationPluginChoice] {
        [
            TranslationPluginChoice(
                id: SystemTranslationModel.appleTranslationID,
                name: "Apple 翻译",
                detail: "系统本地翻译"
            )
        ]
            + model.compatibleTranslationPlugins.map {
                TranslationPluginChoice(
                    id: $0.id,
                    name: $0.name,
                    detail: $0.source == .local
                        ? "本地导入模型"
                        : "已安装模型"
                )
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                Text("使用模型")
                Spacer(minLength: 24)
                Picker(
                    "翻译模型",
                    selection: Binding(
                        get: { model.activeModelID },
                        set: { modelID in
                            Task {
                                await model.setTranslationModel(
                                    modelID,
                                    for: model.translationTarget
                                )
                            }
                        }
                    )
                ) {
                    ForEach(choices) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .labelsHidden()
                .frame(width: 280, alignment: .trailing)
                .disabled(model.isChangingTranslationTarget)
            }

            if let choice = activeChoice {
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
            translationStatus
        }
    }

    private var activeChoice: TranslationPluginChoice? {
        choices.first { $0.id == model.activeModelID }
    }

    private var activeModelStatusText: String? {
        guard model.translationModelStatusModelID == model.activeModelID
        else {
            return nil
        }
        return model.translationModelStatusText
    }

    @ViewBuilder
    private var translationStatus: some View {
        if let activeModelStatusText {
            if model.translationModelStatusIsError {
                translationStatusRow(
                    title: "当前翻译模型不可用",
                    detail: activeModelStatusText,
                    systemImage: "xmark.circle.fill",
                    tint: .red,
                    actionTitle: "重试",
                    action: {
                        Task {
                            await model.retryTranslationConfiguration()
                        }
                    }
                )
            } else {
                progressStatus(activeModelStatusText)
            }
        } else if model.isActiveSystemTranslationModel {
            systemTranslationStatus
        } else {
            localTranslationStatus
        }
    }

    @ViewBuilder
    private var systemTranslationStatus: some View {
        if let state = model.systemTranslationSetupState {
            switch state {
            case .installationRequired:
                translationStatusRow(
                    title:
                        "需要安装中文到\(model.translationTarget.chineseDisplayName)语言包",
                    detail: "安装后可使用 Apple 翻译处理短语和短句。",
                    systemImage: "translate",
                    tint: .orange,
                    actionTitle: "安装语言包",
                    action: {
                        Task {
                            await model.prepareSystemTranslationSupport()
                        }
                    }
                )
            case .installationIncomplete:
                translationStatusRow(
                    title:
                        "中文到\(model.translationTarget.chineseDisplayName)语言包安装未完成",
                    detail: "继续安装后即可使用 Apple 翻译。",
                    systemImage: "arrow.down.circle",
                    tint: .orange,
                    actionTitle: "继续安装",
                    action: {
                        Task {
                            await model.prepareSystemTranslationSupport()
                        }
                    }
                )
            case .installing:
                progressStatus(
                    "正在准备中文到\(model.translationTarget.chineseDisplayName)翻译…"
                )
            case .failed(let message):
                translationStatusRow(
                    title:
                        "中文到\(model.translationTarget.chineseDisplayName)翻译设置未完成",
                    detail: message,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red,
                    actionTitle: "重试",
                    action: {
                        Task {
                            await model.prepareSystemTranslationSupport()
                        }
                    }
                )
            case .unsupported:
                translationStatusRow(
                    title:
                        "当前 Mac 不支持中文到\(model.translationTarget.chineseDisplayName)翻译",
                    detail: "请选择已安装的本地翻译模型。",
                    systemImage: "exclamationmark.triangle",
                    tint: Color(nsColor: .secondaryLabelColor)
                )
            }
        } else if model.isActiveSystemTranslationReady {
            readyStatus
        } else {
            progressStatus("正在检查 Apple 翻译语言包…")
        }
    }

    @ViewBuilder
    private var localTranslationStatus: some View {
        switch model.translationReadiness {
        case .preparing:
            progressStatus(
                "正在准备中文到\(model.translationTarget.chineseDisplayName)翻译…"
            )
        case .ready:
            readyStatus
        case .needsSetup(_, let message):
            translationStatusRow(
                title: "翻译模型还需要准备",
                detail: message,
                systemImage: "exclamationmark.triangle",
                tint: .orange
            )
        case .failed(_, let message):
            translationStatusRow(
                title: "当前翻译模型不可用",
                detail: message,
                systemImage: "xmark.circle.fill",
                tint: .red,
                actionTitle: "重试",
                action: {
                    Task {
                        await model.retryTranslationConfiguration()
                    }
                }
            )
        case .unsupported:
            translationStatusRow(
                title:
                    "当前 Mac 不支持中文到\(model.translationTarget.chineseDisplayName)翻译",
                detail: "请选择其他已安装的翻译模型。",
                systemImage: "exclamationmark.triangle",
                tint: Color(nsColor: .secondaryLabelColor)
            )
        case .idle, .superseded:
            progressStatus("正在检查翻译模型…")
        }
    }

    private func translationStatusRow(
        title: String,
        detail: String,
        systemImage: String,
        tint: Color,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                manageModelsButton
            }
        }
    }

    private func progressStatus(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            manageModelsButton
        }
    }

    private var readyStatus: some View {
        HStack(spacing: 10) {
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Spacer()
            manageModelsButton
        }
    }

    private var manageModelsButton: some View {
        Button("管理模型", action: onManageModels)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

private struct TranslationVoiceSection: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.translationTarget.supportsSpeechAccents {
                HStack(spacing: 20) {
                    Text("口音")
                    Spacer(minLength: 24)
                    Picker(
                        "口音",
                        selection: Binding(
                            get: {
                                model.generalPreferences.speechAccent
                            },
                            set: { accent in
                                guard
                                    model.generalPreferences.speechAccent
                                        != accent
                                else {
                                    return
                                }
                                model.generalPreferences.setSpeechAccent(
                                    accent
                                )
                                model.previewTranslationSpeech()
                            }
                        )
                    ) {
                        ForEach(
                            TranslationSpeechAccent.allCases,
                            id: \.self
                        ) { accent in
                            Text(accent.title).tag(accent)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 300, alignment: .trailing)
                }
                Text("具体音色由系统英文语音决定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 20) {
                    Text("音色")
                    Spacer(minLength: 24)
                    Picker(
                        "音色",
                        selection: Binding(
                            get: {
                                model.generalPreferences
                                    .speechVoiceIdentifier(
                                        for: model.translationTarget
                                    )
                            },
                            set: { voiceIdentifier in
                                guard
                                    model.generalPreferences
                                        .speechVoiceIdentifier(
                                            for: model.translationTarget
                                        )
                                        != voiceIdentifier
                                else {
                                    return
                                }
                                model.generalPreferences
                                    .setSpeechVoiceIdentifier(
                                        voiceIdentifier,
                                        for: model.translationTarget
                                    )
                                model.previewTranslationSpeech()
                            }
                        )
                    ) {
                        Text("系统默认")
                            .tag(String?.none)
                        ForEach(speechVoices) { voice in
                            Text(voice.name)
                                .tag(Optional(voice.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
            }
        }
        .onChange(of: model.translationTarget, initial: true) {
            normalizeSpeechVoiceSelection()
        }
    }

    private var speechVoices: [TranslationSpeechVoiceOption] {
        TranslationSpeechVoiceCatalog.voices(
            for: model.translationTarget
        )
    }

    private func normalizeSpeechVoiceSelection() {
        guard !model.translationTarget.supportsSpeechAccents else {
            return
        }
        let target = model.translationTarget
        guard
            let selected =
                model.generalPreferences.speechVoiceIdentifier(
                    for: target
                ),
            !speechVoices.contains(where: { $0.id == selected })
        else {
            return
        }
        model.generalPreferences.setSpeechVoiceIdentifier(
            nil,
            for: target
        )
    }
}

private struct TranslationPluginChoice: Identifiable {
    let id: String
    let name: String
    let detail: String
}
