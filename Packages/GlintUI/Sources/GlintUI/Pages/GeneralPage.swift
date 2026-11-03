import Foundation
import GlintCore
import SwiftUI

struct GeneralPage: View {
    let model: MainWindowModel
    @State private var insertionShortcutError: String?
    @State private var speechShortcutError: String?

    var body: some View {
        PageContainer {
            SettingsCard("释义插入") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text("插入触发键")
                            Spacer(minLength: 24)
                            TranslationShortcutRecorder(
                                shortcut: model.generalPreferences
                                    .insertionShortcut,
                                accessibilityLabel: "插入触发键"
                            ) { shortcut in
                                insertionShortcutError =
                                    model.generalPreferences
                                    .setInsertionShortcut(shortcut)
                            }
                            Button("清除") {
                                insertionShortcutError =
                                    model.generalPreferences
                                    .setInsertionShortcut(nil)
                            }
                            .buttonStyle(.link)
                            .disabled(
                                model.generalPreferences
                                    .insertionShortcut == nil
                            )
                            .opacity(
                                model.generalPreferences
                                    .insertionShortcut == nil ? 0 : 1
                            )
                            .accessibilityHidden(
                                model.generalPreferences
                                    .insertionShortcut == nil
                            )
                        }

                        Text("按触发键加数字插入对应译文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let insertionShortcutError {
                            Text(insertionShortcutError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 10)
                }
            }

            SettingsCard("释义朗读") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            Text("朗读触发键")
                            Spacer(minLength: 24)
                            TranslationShortcutRecorder(
                                shortcut: model.generalPreferences
                                    .speechShortcut,
                                accessibilityLabel: "朗读触发键"
                            ) { shortcut in
                                speechShortcutError =
                                    model.generalPreferences
                                    .setSpeechShortcut(shortcut)
                            }
                            Button("清除") {
                                speechShortcutError =
                                    model.generalPreferences
                                    .setSpeechShortcut(nil)
                            }
                            .buttonStyle(.link)
                            .disabled(
                                model.generalPreferences.speechShortcut
                                    == nil
                            )
                            .opacity(
                                model.generalPreferences.speechShortcut
                                    == nil ? 0 : 1
                            )
                            .accessibilityHidden(
                                model.generalPreferences.speechShortcut
                                    == nil
                            )
                        }

                        Text("按触发键加数字朗读对应译文。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let speechShortcutError {
                            Text(speechShortcutError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 10)

                    Divider()

                    HStack(spacing: 20) {
                        Text("语速")
                        Spacer(minLength: 24)
                        Picker(
                            "朗读语速",
                            selection: Binding(
                                get: {
                                    model.generalPreferences.speechRate
                                },
                                set: {
                                    model.generalPreferences
                                        .setSpeechRate($0)
                                }
                            )
                        ) {
                            ForEach(
                                TranslationSpeechRate.allCases,
                                id: \.self
                            ) { rate in
                                Text(rate.title).tag(rate)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 300, alignment: .trailing)
                    }
                    .padding(.vertical, 10)

                    Divider()

                    HStack(spacing: 20) {
                        Text("自动朗读")
                        Spacer()
                        Toggle(
                            "自动朗读",
                            isOn: Binding(
                                get: {
                                    model.generalPreferences
                                        .autoSpeechEnabled
                                },
                                set: {
                                    model.generalPreferences
                                        .setAutoSpeechEnabled($0)
                                }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityHint(
                            "停止输入后朗读当前主译文"
                        )
                    }
                    .padding(.vertical, 10)

                    if model.generalPreferences.autoSpeechEnabled {
                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("停顿时间")
                                Spacer()
                                Text(
                                    String(
                                        format: "%.1f 秒",
                                        model.generalPreferences
                                            .autoSpeechDelay
                                    )
                                )
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            }
                            Slider(
                                value: Binding(
                                    get: {
                                        model.generalPreferences
                                            .autoSpeechDelay
                                    },
                                    set: {
                                        model.generalPreferences
                                            .setAutoSpeechDelay($0)
                                    }
                                ),
                                in: GeneralPreferences
                                    .autoSpeechDelayRange,
                                step: 0.1
                            )
                            Text("停止输入并停留该时长后，朗读当前主译文。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                    }
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
                        .controlSize(.small)
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
