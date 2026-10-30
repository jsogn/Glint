import SwiftUI

struct InputMethodsPage: View {
    let model: MainWindowModel
    @State private var pendingAction: PendingInputMethodAction?

    var body: some View {
        PageContainer {
            if model.isLoadingInputMethodSupport {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检测输入法支持…")
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.inputMethodSupportError {
                SettingsCard("无法完成操作", systemImage: "exclamationmark.triangle") {
                    Text(error)
                        .foregroundStyle(.red)
                    Text("未完成的配置修改已自动回滚。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.inputMethodSupportPageStatuses) { status in
                statusCard(status)
            }
        }
        .task {
            await model.refreshInputMethodSupport()
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            )
        ) {
            if let pendingAction {
                Button(pendingAction.confirmationButton) {
                    let action = pendingAction
                    self.pendingAction = nil
                    Task {
                        switch action {
                        case .install:
                            await model.installSquirrelSupport()
                        case .reinstall:
                            await model.installSquirrelSupport()
                        case .uninstall:
                            await model.uninstallSquirrelSupport()
                        }
                    }
                }
            }
            Button("取消", role: .cancel) {
                pendingAction = nil
            }
        } message: {
            Text(pendingAction?.message ?? "")
        }
    }

    private var confirmationTitle: String {
        switch pendingAction {
        case .install:
            "安装候选读取支持？"
        case .reinstall:
            "重新安装候选读取支持？"
        case .uninstall:
            "移除候选读取支持？"
        case nil:
            ""
        }
    }

    @ViewBuilder
    private func statusCard(_ status: InputMethodSupportStatus) -> some View {
        let presentation = status.presentation
        SettingsCard(status.name, systemImage: "keyboard") {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(presentation.headline)
                            .font(.headline)
                        if status.isExperimental {
                            Text("实验")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    .quaternary,
                                    in: Capsule()
                                )
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(presentation.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                statusBadge(
                    presentation.statusTitle,
                    state: status.state
                )
            }

            if hasTechnicalDetails(status, presentation: presentation) {
                technicalDetails(status, presentation: presentation)
            }

            if let actionTitle = presentation.primaryActionTitle {
                Divider()
                HStack(spacing: 10) {
                    Button(actionTitle) {
                        pendingAction =
                            status.state == .available
                            ? .install
                            : .reinstall
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isUpdatingInputMethodSupport)

                    if status.state == .installed
                        || status.state == .repairRequired
                    {
                        Button("卸载") {
                            pendingAction = .uninstall
                        }
                        .disabled(model.isUpdatingInputMethodSupport)
                    }

                    if model.isUpdatingInputMethodSupport {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
            } else if status.state == .manualSetupRequired {
                Divider()
                Link(
                    "查看手动配置说明",
                    destination: URL(
                        string:
                            "https://github.com/jsogn/Glint/blob/main/docs/SQUIRREL-CANDIDATE-BRIDGE.md"
                    )!
                )
                .font(.callout)
            }
        }
    }

    private func hasTechnicalDetails(
        _ status: InputMethodSupportStatus,
        presentation: InputMethodSupportPresentation
    ) -> Bool {
        !status.schemaIDs.isEmpty
            || status.protocolVersion != nil
            || status.detail != presentation.description
    }

    @ViewBuilder
    private func technicalDetails(
        _ status: InputMethodSupportStatus,
        presentation: InputMethodSupportPresentation
    ) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                if status.detail != presentation.description {
                    Text("状态：\(status.detail)")
                }
                if !status.schemaIDs.isEmpty {
                    Text(
                        "输入方案："
                            + status.schemaIDs.joined(separator: "、")
                    )
                }
                if let version = status.protocolVersion,
                    status.state != .native
                {
                    Text("协议版本 \(version)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        } label: {
            Text("技术详情")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func statusBadge(
        _ title: String,
        state: InputMethodSupportState
    ) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(state.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                state.color.opacity(0.12),
                in: Capsule()
            )
    }
}

private enum PendingInputMethodAction {
    case install
    case reinstall
    case uninstall

    var confirmationButton: String {
        switch self {
        case .install:
            "安装"
        case .reinstall:
            "重新安装"
        case .uninstall:
            "卸载"
        }
    }

    var message: String {
        switch self {
        case .install:
            "将安装候选读取支持，用于读取 Rime 当前高亮的候选内容。修改前会创建备份，失败时自动回滚。"
        case .reinstall:
            "将重新安装候选读取支持，并重新部署 Rime。修改前会创建备份，失败时自动回滚。"
        case .uninstall:
            "将移除候选读取支持，并恢复安装前的配置。"
        }
    }
}

private extension InputMethodSupportState {
    var color: Color {
        switch self {
        case .native, .installed:
            .green
        case .available:
            .secondary
        case .repairRequired, .manualSetupRequired:
            .orange
        case .unavailable:
            .secondary
        }
    }
}
