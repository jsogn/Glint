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
            SettingsCard("翻译方式", systemImage: "arrow.triangle.branch") {
                TranslationStrategySection(model: model)
            }
            SettingsCard("当前翻译模型", systemImage: "cpu") {
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
            HStack(spacing: 20) {
                Text("当前目标语言")
                Spacer(minLength: 24)
                Picker(
                    "当前目标语言",
                    selection: Binding(
                        get: { model.translationTarget },
                        set: { target in
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
                .pickerStyle(.segmented)
                .frame(width: 220, alignment: .trailing)
                .disabled(model.isChangingTranslationTarget)
            }

            HStack(spacing: 10) {
                directionBox(title: "输入", value: "中文")
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                directionBox(
                    title: "输出",
                    value: model.translationTarget.chineseDisplayName
                )
            }

            Text("切换后会影响 HUD 译文、可用模型、词性和朗读。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TranslationReadinessStatus(
                readiness: model.translationReadiness
            )
        }
    }

    private func directionBox(
        title: String,
        value: String
    ) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
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
            if model.isEnglishTarget {
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
            } else {
                HStack {
                    Text("当前能力")
                    Spacer()
                    Label("模型翻译", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                }
                Text("日语初期不接入词典，当前只使用所选模型返回单条译文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Text("翻译模型")
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

            if let choice = choices.first(where: {
                $0.id == model.activeModelID
            }) {
                Text(choice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.isActiveSystemTranslationModel {
                Divider()
                systemTranslationStatus
            }

            if let message = model.translationModelStatusText,
                model.translationModelStatusIsError
            {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("管理模型", action: onManageModels)
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var systemTranslationStatus: some View {
        HStack(spacing: 12) {
            switch model.systemTranslationSetupState {
            case .installationRequired, .installationIncomplete:
                Text(
                    "需要安装中文到\(model.translationTarget.chineseDisplayName)语言包"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button("安装语言包") {
                    Task {
                        await model.prepareSystemTranslationSupport()
                    }
                }
                .buttonStyle(.borderedProminent)
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("正在准备…")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") {
                    Task {
                        await model.prepareSystemTranslationSupport()
                    }
                }
            case .unsupported:
                Text("当前 Mac 不支持该翻译方向")
                    .foregroundStyle(.secondary)
            case nil:
                Label("可用", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
            }
        }
    }
}

private struct TranslationVoiceSection: View {
    let model: MainWindowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isEnglishTarget {
                HStack(spacing: 20) {
                    Text("英语口音")
                    Spacer(minLength: 24)
                    Picker(
                        "英语口音",
                        selection: Binding(
                            get: {
                                model.generalPreferences.speechAccent
                            },
                            set: {
                                model.generalPreferences
                                    .setSpeechAccent($0)
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
                HStack {
                    Text("日语语音")
                    Spacer()
                    Text("系统日语")
                        .foregroundStyle(.secondary)
                }
                Text("使用系统可用的日语语音，不回退英语音色。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TranslationReadinessStatus: View {
    let readiness: TranslationReadiness

    @ViewBuilder
    var body: some View {
        switch readiness {
        case .preparing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在准备翻译…")
                    .foregroundStyle(.secondary)
            }
        case .needsSetup(_, let message):
            Label(message, systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
        case .failed(_, let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
        case .unsupported:
            Label("当前 Mac 不支持该方向", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .idle, .ready, .superseded:
            EmptyView()
        }
    }
}

private struct TranslationPluginChoice: Identifiable {
    let id: String
    let name: String
    let detail: String
}
