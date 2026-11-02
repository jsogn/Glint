import AppKit
import SwiftUI

struct ManualRimeSetupGuide: View {
    let model: MainWindowModel
    let schemaIDs: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false
    @State private var installError: String?

    private var fileNames: [String] {
        ManualRimeSetupContent.fileNames(for: schemaIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    explanation
                    openFolderStep
                    selectFileStep
                    pasteConfigurationStep
                    finishStep
                    advancedHelp
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(model.isUpdatingInputMethodSupport)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("完成 Rime 接入")
                    .font(.title2.weight(.semibold))
                Text("按下面四步操作一次即可，不需要了解 Rime 的内部原理。")
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(model.isUpdatingInputMethodSupport)
            .accessibilityLabel("关闭")
        }
        .padding(24)
    }

    private var explanation: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(
                "你的 Rime 配置有特殊写法，Glint 无法确定自动修改是否安全。"
                    + "因此需要你指定要启用的输入方案，避免破坏原有设置。"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var openFolderStep: some View {
        GuideStep(number: 1, title: "打开 Rime 配置文件夹") {
            Text("这里保存的是输入法设置，不包含你在应用里输入的文字。")
                .foregroundStyle(.secondary)
            Button("在 Finder 中打开") {
                openRimeFolder()
            }
        }
    }

    private var selectFileStep: some View {
        GuideStep(number: 2, title: fileNames.isEmpty ? "找到方案的自定义文件" : "找到下面这些文件") {
            if fileNames.isEmpty {
                Text(
                    "找到你正在使用的输入方案对应的 `.custom.yaml` 文件。"
                        + "文件名通常由方案 ID 加上 `.custom.yaml` 组成。"
                )
                .foregroundStyle(.secondary)
            } else {
                Text("在刚打开的文件夹中找到：")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(fileNames, id: \.self) { fileName in
                        HStack(spacing: 8) {
                            Text(fileName)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                reveal(fileName: fileName)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("在 Finder 中显示 \(fileName)")
                            .accessibilityLabel("在 Finder 中显示 \(fileName)")
                        }
                    }
                }
            }
        }
    }

    private var pasteConfigurationStep: some View {
        GuideStep(number: 3, title: "把配置粘贴到文件最后") {
            Text(
                "保留文件中已有的全部内容，把下面这段代码追加到最后。"
                    + "保存文件后再继续。"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal) {
                    Text(ManualRimeSetupContent.configurationBlock)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack {
                    Spacer()
                    Button(didCopy ? "已复制" : "复制配置") {
                        copyConfiguration()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }

    private var finishStep: some View {
        GuideStep(number: 4, title: "回到 Glint 完成安装") {
            Text("保存配置文件后，点击下面的按钮。Glint 会安装剩余文件并重新加载 Rime。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let installError {
                Text(installError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advancedHelp: some View {
        DisclosureGroup("高级说明与排错") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Rime 使用 `.custom.yaml` 文件覆盖输入方案设置。"
                        + "上面的 `__patch` 块只把 Glint 添加到候选读取流程，"
                        + "不会删除或重写你已有的设置。"
                )
                .foregroundStyle(.secondary)
                Link(
                    "查看完整技术文档",
                    destination: URL(
                        string:
                            "https://github.com/jsogn/Glint/blob/main/docs/SQUIRREL-CANDIDATE-BRIDGE.md#%E6%89%8B%E5%8A%A8%E5%A4%87%E7%94%A8%E5%AE%89%E8%A3%85"
                    )!
                )
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("配置只会写入你选择的 Rime 方案，并可在“卸载”时恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("稍后再说") {
                dismiss()
            }
            .disabled(model.isUpdatingInputMethodSupport)
            Button("已完成，继续安装") {
                finishManualSetup()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isUpdatingInputMethodSupport)
            if model.isUpdatingInputMethodSupport {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(18)
    }

    private func openRimeFolder() {
        NSWorkspace.shared.open(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Rime", isDirectory: true)
        )
    }

    private func reveal(fileName: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Rime", isDirectory: true)
        let file = directory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.selectFile(
                file.path,
                inFileViewerRootedAtPath: directory.path
            )
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    private func copyConfiguration() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            ManualRimeSetupContent.configurationBlock,
            forType: .string
        )
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }

    private func finishManualSetup() {
        installError = nil
        Task {
            await model.installSquirrelSupport()
            if model.squirrelSupportStatus?.state == .installed {
                dismiss()
            } else if let error = model.inputMethodSupportError {
                installError = error
            } else {
                installError =
                    "仍未检测到完整配置。请确认文件已保存，并重新检查配置内容。"
            }
        }
    }
}

struct ManualRimeSetupContent {
    static func fileNames(for schemaIDs: [String]) -> [String] {
        schemaIDs.map { "\($0).custom.yaml" }
    }

    static let configurationBlock = """
        # BEGIN GLINT RIME CANDIDATE BRIDGE
        __patch:
          patch/+:
            engine/filters/@before 0: lua_filter@*glint.candidate_bridge
        # END GLINT RIME CANDIDATE BRIDGE
        """
}

private struct GuideStep<Content: View>: View {
    let number: Int
    let title: String
    let content: Content

    init(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.number = number
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.headline)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
