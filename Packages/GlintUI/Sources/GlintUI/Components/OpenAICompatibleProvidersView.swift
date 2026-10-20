import GlintCore
import SwiftUI

@MainActor
struct OpenAICompatibleProvidersView: View {
    @Bindable var model: MainWindowModel
    @State private var isEditorPresented = false
    @State private var editingProvider: OpenAICompatibleProvider?

    var body: some View {
        SettingsCard("OpenAI 兼容接口") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("可保存多个接口，并随时切换当前使用的模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("添加接口…") {
                        editingProvider = nil
                        isEditorPresented = true
                    }
                }
                .padding(.bottom, 10)

                if model.openAIProviders.isEmpty {
                    Text("尚未添加接口")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(
                        Array(model.openAIProviders.enumerated()),
                        id: \.element.id
                    ) { index, provider in
                        if index > 0 {
                            Divider()
                        }
                        providerRow(provider)
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .sheet(isPresented: $isEditorPresented) {
            OpenAICompatibleProviderEditorSheet(
                model: model,
                provider: editingProvider
            )
        }
    }

    private func providerRow(
        _ provider: OpenAICompatibleProvider
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .fontWeight(.medium)
                    if activeProviderID == provider.id {
                        Text("使用中")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.16), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text(provider.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(displayEndpoint(provider.baseURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if activeProviderID == provider.id,
                   let status = model.translationModelStatusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(
                            model.translationModelStatusIsError
                                ? Color.red
                                : Color.secondary
                        )
                }
            }
            Spacer()

            if activeProviderID != provider.id {
                Button("使用") {
                    model.activateOpenAICompatibleProvider(provider)
                }
                .disabled(
                    model.isInstalling != nil || model.isImportingLocalModel
                )
            }
            Button("编辑") {
                editingProvider = provider
                isEditorPresented = true
            }
        }
    }

    private var activeProviderID: String? {
        TranslationModelSelection.openAIProviderID(
            fromSelectionID: model.activeModelID
        )
    }

    private func displayEndpoint(_ value: String) -> String {
        guard let components = URLComponents(string: value),
              let host = components.host else {
            return value
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(components.scheme ?? "https")://\(host)\(port)\(components.path)"
    }
}
