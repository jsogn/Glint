import SwiftUI

struct PermissionsPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer {
            SettingsCard("系统权限") {
                PermissionStatusRow(
                    title: "辅助功能",
                    symbol: "accessibility",
                    detail: "读取输入法候选，不读取输入框正文。",
                    granted: model.accessibilityGranted
                )

                if hasMissingPermissions {
                    Divider()

                    HStack(spacing: 12) {
                        Button {
                            permissionAction.perform()
                        } label: {
                            Label(
                                permissionAction.title,
                                systemImage: permissionAction.symbol
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        if !model.hasRequestedAccessibilityPermission {
                            Button("直接打开系统设置…") {
                                model.openAccessibilitySettings()
                            }
                            .buttonStyle(.link)
                        }

                        Spacer()
                    }

                    Text(permissionGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            PrivacyNoticeCard()
        }
        .onAppear {
            model.refreshPermissions()
        }
    }

    private var permissionAction: AccessibilityPermissionAction {
        AccessibilityPermissionAction(model: model)
    }

    private var hasMissingPermissions: Bool {
        !model.accessibilityGranted
    }

    private var permissionGuidance: String {
        if model.hasRequestedAccessibilityPermission {
            return "在系统设置中开启 Glint，返回后会自动更新状态。"
        }
        return "macOS 会请求你允许 Glint 使用辅助功能。"
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let symbol: String
    let detail: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                granted ? "已授权" : "需要授权",
                systemImage: granted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .foregroundStyle(granted ? Color.secondary : Color.orange)
            .labelStyle(.titleAndIcon)
            .font(.callout)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct PrivacyNoticeCard: View {
    var body: some View {
        SettingsCard("隐私", systemImage: "lock.shield") {
            Text("Glint 不保存候选文本、翻译结果或输入历史。")
            Text("候选和翻译结果只在本地处理，不发送到网络服务。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
