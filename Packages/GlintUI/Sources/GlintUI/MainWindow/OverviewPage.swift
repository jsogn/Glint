import GlintCore
import SwiftUI

struct OverviewPage: View {
    let model: MainWindowModel
    @Binding var selection: SidebarItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OverviewStatusCard(model: model, selection: $selection)

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
                                label: "位置",
                                value: model.displayPreferences.position.title
                            ),
                            OverviewInfoRow(
                                label: "停留",
                                value: String(
                                    format: "%.0f ms",
                                    model.displayPreferences
                                        .candidateDwellDuration * 1_000
                                )
                            ),
                            OverviewInfoRow(
                                label: "外观",
                                value: String(
                                    format: "透明度 %.0f%% · 间距 %.0f pt",
                                    model.displayPreferences.hudOpacity * 100,
                                    model.displayPreferences.candidateSpacing
                                )
                            ),
                        ]
                    ) {
                        selection = .display
                    }

                    OverviewInfoCard(
                        symbol: "shippingbox",
                        title: "本地能力",
                        actionTitle: "管理",
                        rows: [
                            OverviewInfoRow(
                                label: "识别",
                                value: model.candidateSummary
                            ),
                            OverviewInfoRow(
                                label: "翻译",
                                value: model.translationSummary
                            ),
                            OverviewInfoRow(
                                label: "词典",
                                value: "\(model.dictionaryPlugins.count) 个"
                            ),
                        ]
                    ) {
                        selection = .plugins
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
            .frame(maxWidth: 1_200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 30)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
    }
}

private struct OverviewStatusCard: View {
    let model: MainWindowModel
    @Binding var selection: SidebarItem?

    private var state: OverviewRuntimeState {
        let missingPermissions = missingPermissionText
        if let missingPermissions {
            return .permissions(missingPermissions)
        }
        if let attentionMessage {
            return .attention(attentionMessage)
        }
        return model.isMonitoring ? .running : .paused
    }

    private var missingPermissionText: String? {
        model.accessibilityGranted ? nil : "需要辅助功能权限。"
    }

    private var attentionMessage: String? {
        if model.translationModelStatusIsError,
           let message = model.translationModelStatusText {
            return message
        }
        return model.statusText.isEmpty ? nil : model.statusText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.accentColor.opacity(0.16))
                    Image(systemName: state.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.statusColor)
                            .frame(width: 8, height: 8)
                            .shadow(
                                color: state.statusColor.opacity(0.45),
                                radius: 3
                            )
                        Text(state.title)
                            .font(.title3.weight(.semibold))
                    }
                    Text(state.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button(action: primaryAction) {
                    Label(actionTitle, systemImage: actionSymbol)
                }
                .tint(actionTint)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Divider()

            OverviewPipeline(model: model)

            Text(model.translationMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }

    private func primaryAction() {
        if missingPermissionText != nil {
            if model.hasRequestedAccessibilityPermission {
                model.openAccessibilitySettings()
            } else {
                model.requestPermissions()
            }
        } else if model.isMonitoring {
            model.stopMonitoring()
        } else {
            model.startMonitoring()
        }
    }

    private var actionTitle: String {
        if missingPermissionText != nil {
            return model.hasRequestedAccessibilityPermission
                ? "打开系统设置"
                : "授权辅助功能"
        }
        return model.isMonitoring ? "关闭翻译显示" : "开启翻译显示"
    }

    private var actionSymbol: String {
        if missingPermissionText != nil {
            return model.hasRequestedAccessibilityPermission
                ? "gearshape"
                : "lock.open"
        }
        return model.isMonitoring ? "stop.circle" : "play.circle"
    }

    private var actionTint: Color {
        model.isMonitoring && missingPermissionText == nil
            ? .red
            : .accentColor
    }
}

private struct OverviewPipeline: View {
    let model: MainWindowModel

    var body: some View {
        HStack(spacing: 8) {
            stage(symbol: "keyboard", label: "输入", value: "拼音输入")
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
                value: model.translationMode.title
            )
            arrow
            stage(
                symbol: "text.bubble",
                label: "翻译",
                value: model.translationSummary
            )
        }
    }

    private func stage(
        symbol: String,
        label: String,
        value: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private var arrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

private struct OverviewInfoRow: Identifiable {
    let label: String
    let value: String

    var id: String { label }
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
                Text(title)
                    .font(.headline)
                Spacer()
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(actionTitle)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(row.value)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

private enum OverviewRuntimeState {
    case running
    case paused
    case permissions(String)
    case attention(String)

    var title: String {
        switch self {
        case .running: "翻译显示已开启"
        case .paused: "翻译显示未开启"
        case .permissions: "需要完成权限设置"
        case .attention: "运行状态需要检查"
        }
    }

    var detail: String {
        switch self {
        case .running:
            "在输入法候选栏旁显示单行英文提示。"
        case .paused:
            "开启后，输入中文时会显示单行英文提示。"
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
        case .permissions: "lock.shield"
        case .attention: "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch self {
        case .running: .blue
        case .paused: .secondary
        case .permissions, .attention: .orange
        }
    }

}
