import GlintCore
import SwiftUI

@MainActor
struct OpenAICompatibleProviderEditorSheet: View {
    let model: MainWindowModel
    let provider: OpenAICompatibleProvider?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var modelName: String
    @State private var apiKey: String
    @State private var statusText: String?
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var isConfirmingDelete = false

    init(model: MainWindowModel, provider: OpenAICompatibleProvider?) {
        self.model = model
        self.provider = provider
        self._name = State(initialValue: provider?.name ?? "")
        self._baseURL = State(initialValue: provider?.baseURL ?? "")
        self._modelName = State(initialValue: provider?.model ?? "")
        self._apiKey = State(
            initialValue: provider.map { model.apiKey(for: $0) } ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(provider == nil ? "添加接口" : "编辑接口")
                    .font(.title3.weight(.semibold))
                Text("支持 Ollama、LM Studio、OpenAI 及任意兼容服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            field("名称", placeholder: "例如 本机 Ollama", text: $name)
            field(
                "接口地址",
                placeholder: "例如 http://localhost:11434/v1",
                text: $baseURL
            )
            field("模型名称", placeholder: "例如 qwen3:8b", text: $modelName)

            VStack(alignment: .leading, spacing: 5) {
                Text("API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("可选，保存在系统钥匙串", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            HStack(spacing: 10) {
                if provider != nil {
                    Button("删除接口", role: .destructive) {
                        isConfirmingDelete = true
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isTesting ? "正在测试…" : "测试连接") {
                    testConnection()
                }
                .disabled(isTesting || configuration.chatCompletionsURL == nil)
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(configuration.chatCompletionsURL == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: name) {
            clearTransientStatus()
        }
        .onChange(of: baseURL) {
            clearTransientStatus()
        }
        .onChange(of: modelName) {
            clearTransientStatus()
        }
        .onChange(of: apiKey) {
            clearTransientStatus()
        }
        .confirmationDialog(
            "删除这个接口？",
            isPresented: $isConfirmingDelete
        ) {
            if let provider {
                Button("删除 \(provider.name)", role: .destructive) {
                    delete()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("对应的 API Key 也会从系统钥匙串中删除。")
        }
    }

    private var configuration: OpenAICompatibleConfiguration {
        OpenAICompatibleConfiguration(
            baseURL: baseURL,
            model: modelName,
            apiKey: apiKey
        )
    }

    private func clearTransientStatus() {
        statusText = nil
        errorMessage = nil
    }

    private func field(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        statusText = "正在测试…"
        errorMessage = nil
        let configuration = configuration
        Task {
            do {
                try await model.testOpenAICompatibleConfiguration(configuration)
                statusText = "连接成功"
            } catch {
                statusText = nil
                errorMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func save() {
        do {
            _ = try model.saveOpenAICompatibleProvider(
                id: provider?.id,
                name: name,
                baseURL: baseURL,
                model: modelName,
                apiKey: apiKey
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let provider else { return }
        do {
            try model.removeOpenAICompatibleProvider(provider)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
