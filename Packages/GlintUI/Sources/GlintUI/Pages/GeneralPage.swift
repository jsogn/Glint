import GlintCore
import SwiftUI

struct GeneralPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer {
            SettingsCard("翻译") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 24) {
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
                        .frame(width: 240, alignment: .trailing)
                        .accessibilityHint(model.translationMode.explanation)
                    }

                    Text(model.translationMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("基础") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 20) {
                        Text("开机自启动")
                        Spacer()
                        Toggle(
                            "开机自启动",
                            isOn: Binding(
                                get: { model.isLaunchAtLoginEnabled },
                                set: { model.setLaunchAtLoginEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityHint("登录 Mac 时自动启动 Glint")
                    }

                    if let launchAtLoginMessage {
                        Divider()

                        HStack(spacing: 12) {
                            Text(launchAtLoginMessage)
                                .font(.caption)
                                .foregroundStyle(
                                    launchAtLoginNeedsAttention
                                        ? Color.orange
                                        : Color.secondary
                                )
                            Spacer()
                            if model.launchAtLoginRequiresApproval
                                || model.launchAtLoginError != nil
                            {
                                Button("打开登录项设置…") {
                                    model.openLoginItemsSettings()
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            model.refreshLaunchAtLogin()
        }
    }

    private var launchAtLoginMessage: String? {
        if let error = model.launchAtLoginError {
            return error
        }
        switch model.launchAtLoginStatus {
        case .disabled, .enabled:
            return nil
        case .requiresApproval:
            return "登录项已注册，但需要在系统设置中允许 Glint。"
        case .unavailable:
            return "尚未添加登录项。打开开关即可添加。"
        }
    }

    private var launchAtLoginNeedsAttention: Bool {
        model.launchAtLoginRequiresApproval
            || model.launchAtLoginError != nil
    }
}
