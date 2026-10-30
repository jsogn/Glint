import Foundation
import GlintCore
import GlintPlugins
import SwiftUI

struct OverviewPage: View {
    let model: MainWindowModel
    @Binding var selection: SidebarItem?
    let openTranslationModels: () -> Void

    var body: some View {
        PageContainer {
            OverviewStatusCard(
                model: model,
                openGeneralSettings: {
                    selection = .general
                },
                openInputMethodSettings: inputMethodSettingsAction,
                openTranslationModels: openTranslationModels
            )

            SystemTranslationSetupCard(
                model: model,
                openModelSettings: openTranslationModels
            )

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16),
                ],
                alignment: .leading,
                spacing: 16
            ) {
                OverviewInfoCard(
                    symbol: "rectangle.on.rectangle",
                    title: "显示与触发",
                    actionTitle: "调整",
                    rows: [
                        OverviewInfoRow(
                            label: "停留",
                            value: OverviewFormatting.dwellDuration(
                                model.displayPreferences
                                    .candidateDwellDuration
                            )
                        ),
                        OverviewInfoRow(
                            label: "外观",
                            value: OverviewFormatting.appearance(
                                hudOpacity: model.displayPreferences
                                    .hudOpacity,
                                hudFontSize: model.displayPreferences
                                    .hudFontSize,
                                candidateSpacing: model.displayPreferences
                                    .candidateSpacing
                            )
                        ),
                        OverviewInfoRow(
                            label: "范围",
                            value: model.displayPreferences.translationScope.title
                        ),
                    ]
                ) {
                    selection = .display
                }

                OverviewInfoCard(
                    symbol: "shippingbox",
                    title: "翻译能力",
                    actionTitle: "管理",
                    rows: [
                        OverviewInfoRow(
                            label: "翻译模型",
                            value: model.translationSummary
                        ),
                        OverviewInfoRow(
                            label: "模型特点",
                            value: model.translationCharacterSummary
                        ),
                        OverviewInfoRow(
                            label: "词典覆盖",
                            value: OverviewFormatting.dictionaryCoverage
                        ),
                    ]
                ) {
                    openTranslationModels()
                }
            }

            Label(
                "仅识别输入法候选区域，不读取输入框正文。",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var inputMethodSettingsAction: (() -> Void)? {
        {
            selection = .inputMethods
        }
    }
}

private struct SystemTranslationSetupCard: View {
    let model: MainWindowModel
    let openModelSettings: () -> Void

    @ViewBuilder
    var body: some View {
        if let state = model.systemTranslationSetupState {
            fullContent(for: state)
        }
    }

    private func fullContent(
        for state: SystemTranslationSetupState
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.14))
                Image(systemName: state.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(state.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            actions(for: state)
        }
        .padding(16)
        .cardSurface()
    }

    @ViewBuilder
    private func actions(
        for state: SystemTranslationSetupState
    ) -> some View {
        switch state {
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在准备…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .unsupported:
            Button("查看模型") {
                openModelSettings()
            }
        case .failed:
            installButton(title: "重试")
        case .installationRequired, .installationCancelled:
            installButton(title: "安装语言包")
        }
    }

    private func installButton(title: String) -> some View {
        Button(title) {
            install()
        }
        .buttonStyle(.borderedProminent)
    }

    private func install() {
        Task {
            await model.prepareSystemTranslationSupport()
        }
    }
}

private extension SystemTranslationSetupState {
    var title: String {
        switch self {
        case .installationRequired:
            "请安装 Apple 翻译语言包"
        case .installationCancelled:
            "已取消语言包安装"
        case .installing:
            "正在准备 Apple 翻译"
        case .failed:
            "语言包安装失败"
        case .unsupported:
            "当前 Mac 不支持 Apple 翻译"
        }
    }

    var detail: String {
        switch self {
        case .installationRequired:
            "安装中文到英文语言包后，Apple 翻译才能处理短句。"
        case .installationCancelled:
            "短句翻译暂时不可用。你可以随时继续安装，不会自动重复弹窗。"
        case .installing:
            "完成后会自动打开概览。"
        case .failed(let message):
            message
        case .unsupported:
            "仍可使用词典或其他本地翻译模型。"
        }
    }

    var symbol: String {
        switch self {
        case .installing:
            "hourglass"
        case .failed, .unsupported:
            "exclamationmark.triangle"
        case .installationRequired, .installationCancelled:
            "translate"
        }
    }
}

private struct OverviewStatusCard: View {
    let model: MainWindowModel
    let openGeneralSettings: () -> Void
    let openInputMethodSettings: (() -> Void)?
    let openTranslationModels: () -> Void

    private var state: OverviewRuntimeState {
        let missingPermissions = missingPermissionText
        if let missingPermissions {
            return .permissions(missingPermissions)
        }
        if model.isPreparingMonitoring {
            return .preparing
        }
        if let attentionMessage {
            return .attention(attentionMessage)
        }
        return model.isMonitoring ? .running : .paused
    }

    private var missingPermissionText: String? {
        model.accessibilityGranted ? nil : permissionAction.guidance
    }

    private var attentionMessage: String? {
        if let message = model.translationAttentionMessage {
            return message
        }
        return model.statusText.isEmpty ? nil : model.statusText
    }

    private var attentionDetail: String? {
        model.translationAttentionDetail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                    Image(systemName: state.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.statusColor)
                            .frame(width: 8, height: 8)
                            .shadow(
                                color: state.statusColor.opacity(0.45),
                                radius: 3
                            )
                            .accessibilityHidden(true)
                        Text(state.title)
                            .font(.title3.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    statusDetail
                }

                Spacer(minLength: 12)

                if missingPermissionText == nil && model.isPreparingMonitoring {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在准备翻译模型")
                } else {
                    Button(action: primaryAction) {
                        Label(actionTitle, systemImage: actionSymbol)
                    }
                    .tint(actionTint)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel(actionTitle)
                }
            }

            Divider()

            OverviewPipeline(
                model: model,
                openGeneralSettings: openGeneralSettings,
                openInputMethodSettings: openInputMethodSettings,
                openTranslationModels: openTranslationModels
            )
        }
        .padding(16)
        .cardSurface()
    }

    private func primaryAction() {
        if missingPermissionText != nil {
            permissionAction.perform()
        } else if model.isMonitoring {
            model.stopMonitoring()
        } else {
            model.startMonitoring()
        }
    }

    private var permissionAction: AccessibilityPermissionAction {
        AccessibilityPermissionAction(model: model)
    }

    @ViewBuilder
    private var statusDetail: some View {
        if !state.detail.isEmpty {
            let detail = Text(state.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let attentionDetail {
                detail.help(attentionDetail)
            } else {
                detail
            }
        }
    }

    private var actionTitle: String {
        if missingPermissionText != nil {
            return permissionAction.title
        }
        return model.isMonitoring ? "关闭翻译显示" : "开启翻译显示"
    }

    private var actionSymbol: String {
        if missingPermissionText != nil {
            return permissionAction.symbol
        }
        return model.isMonitoring ? "stop.circle" : "play.circle"
    }

    private var actionTint: Color {
        model.isMonitoring && missingPermissionText == nil
            ? Color(nsColor: .systemGray)
            : .accentColor
    }

}

private struct OverviewPipeline: View {
    let model: MainWindowModel
    let openGeneralSettings: () -> Void
    let openInputMethodSettings: (() -> Void)?
    let openTranslationModels: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            stage(
                symbol: "keyboard",
                label: "输入",
                value: model.activeInputMethodName,
                action: openInputMethodSettings,
                actionHint: "打开输入法支持"
            )
            arrow
            stage(
                symbol: "text.cursor",
                label: "识别",
                value: model.candidateSummary
            )
            arrow
            stage(
                symbol: "arrow.triangle.branch",
                label: "策略",
                value: model.translationMode.title,
                action: openGeneralSettings,
                actionHint: "打开通用配置"
            )
            arrow
            stage(
                symbol: "text.bubble",
                label: "翻译",
                value: translationModelName,
                action: openTranslationModels,
                actionHint: "打开翻译模型"
            )
        }
    }

    private var translationModelName: String {
        OverviewFormatting.compactModelName(model.translationSummary)
    }

    private func stage(
        symbol: String,
        label: String,
        value: String,
        action: (() -> Void)? = nil,
        actionHint: String = "打开设置"
    ) -> some View {
        Group {
            if let action {
                Button(action: action) {
                    stageContent(symbol: symbol, label: label, value: value)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label)，\(value)")
                .accessibilityHint(actionHint)
                .help("\(label)：\(value)。\(actionHint)")
            } else {
                stageContent(symbol: symbol, label: label, value: value)
                    .accessibilityElement(children: .combine)
                    .help("\(label)：\(value)")
            }
        }
    }

    private func stageContent(
        symbol: String,
        label: String,
        value: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct OverviewInfoRow {
    let label: String
    let value: String
}

private struct OverviewInfoCard: View {
    let symbol: String
    let title: String
    let actionTitle: String
    let rows: [OverviewInfoRow]
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .accessibilityLabel("\(actionTitle)\(title)")
            }

            VStack(spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.value)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .help(row.value)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}

private enum OverviewRuntimeState {
    case running
    case paused
    case preparing
    case permissions(String)
    case attention(String)

    var title: String {
        switch self {
        case .running: "翻译显示已开启"
        case .paused: "翻译显示未开启"
        case .preparing: "正在准备翻译模型"
        case .permissions: "需要完成权限设置"
        case .attention: "运行状态需要检查"
        }
    }

    var detail: String {
        switch self {
        case .running:
            ""
        case .preparing:
            "完成后会自动开始读取输入法候选。"
        case .paused:
            ""
        case .permissions(let message):
            message
        case .attention(let message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .running: "sparkles"
        case .paused: "pause.circle"
        case .preparing: "hourglass"
        case .permissions: "lock.shield"
        case .attention: "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch self {
        case .running: .accentColor
        case .paused: .secondary
        case .preparing: .secondary
        case .permissions, .attention: .orange
        }
    }

}

private enum OverviewPreviewState: Equatable {
    case running
    case paused
    case preparing
    case permission
    case attention
}

private struct OverviewPagePreview: View {
    @State private var model: MainWindowModel
    private let width: CGFloat

    init(_ state: OverviewPreviewState, width: CGFloat = 729) {
        self.width = width

        let suite = "Glint.OverviewPagePreview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.hudOpacity = 0.8
        preferences.candidateSpacing = 5

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Glint.OverviewPagePreview",
                isDirectory: true
            )
        let model = MainWindowModel(
            displayPreferences: preferences,
            pluginManager: PluginManager(baseDirectory: root),
            builtInPlugins: [
                OverviewPreviewManifests.translation,
                OverviewPreviewManifests.dictionary(
                    id: "dict-cedict",
                    name: "CC-CEDICT"
                ),
                OverviewPreviewManifests.dictionary(
                    id: "dict-ecdict",
                    name: "ECDICT Rank Index"
                ),
            ],
            catalogURL: nil,
            defaults: defaults
        )
        model.accessibilityGranted = state != .permission
        model.isMonitoring = state == .running || state == .attention
        model.isPreparingMonitoring = state == .preparing
        if state == .attention {
            model.statusText = "翻译模型暂时不可用，请检查插件与模型。"
        }
        model.setTranslationMode(.dictionaryFirst)
        _model = State(initialValue: model)
    }

    var body: some View {
        OverviewPage(
            model: model,
            selection: .constant(.overview),
            openTranslationModels: {}
        )
        .frame(width: width, height: 640)
    }
}

private enum OverviewPreviewManifests {
    static let translation = PluginManifest(
        id: TranslationModelSelection.defaultModelID,
        type: .translation,
        name: "OPUS-MT Chinese-English",
        version: "0.1.0",
        runtime: "ctranslate2",
        sizeBytes: 0,
        sha256: "PREVIEW",
        url: URL(fileURLWithPath: "/preview/mt-opus-zh-en"),
        license: "CC-BY-4.0",
        minRAMBytes: 0,
        summary: "速度快、占用低，适合轻量日常翻译。",
        source: .bundled
    )

    static func dictionary(id: String, name: String) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .dictionary,
            name: name,
            version: "0.1.0",
            runtime: "sqlite-v1",
            sizeBytes: 0,
            sha256: "PREVIEW",
            url: URL(fileURLWithPath: "/preview/\(id)"),
            license: "CC-BY-4.0",
            minRAMBytes: 0,
            source: .bundled
        )
    }
}

#Preview("概览 · 运行中") {
    OverviewPagePreview(.running)
        .preferredColorScheme(.dark)
}

#Preview("概览 · 未开启") {
    OverviewPagePreview(.paused)
        .preferredColorScheme(.light)
}

#Preview("概览 · 正在准备") {
    OverviewPagePreview(.preparing)
        .preferredColorScheme(.light)
}

#Preview("概览 · 需要权限") {
    OverviewPagePreview(.permission)
        .preferredColorScheme(.light)
}

#Preview("概览 · 需要检查") {
    OverviewPagePreview(.attention)
        .preferredColorScheme(.dark)
}

#Preview("概览 · 最窄内容宽") {
    OverviewPagePreview(.running, width: 700)
        .preferredColorScheme(.dark)
}
