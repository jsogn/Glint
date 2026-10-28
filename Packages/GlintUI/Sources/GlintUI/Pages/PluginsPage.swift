import Foundation
import GlintCore
import GlintPlugins
import SwiftUI

struct PluginsPage: View {
    let model: MainWindowModel
    @Binding var selectedTab: PluginTab
    @State private var pluginToRemove: PluginManifest?

    var body: some View {
        PageContainer {
            HStack(spacing: 12) {
                pluginTabControl
                Spacer()
                if model.isLoadingPlugins || model.isLoadingCatalog {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let error = model.catalogError {
                HStack(alignment: .top) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
            }
            pluginPanel(kind: selectedTab.kind)
        }
        .task {
            await model.refreshInstalledPlugins()
            await model.checkForCatalogUpdates()
        }
        .confirmationDialog(
            "卸载插件？",
            isPresented: Binding(
                get: { pluginToRemove != nil },
                set: { if !$0 { pluginToRemove = nil } }
            )
        ) {
            if let plugin = pluginToRemove {
                Button("卸载 \(plugin.name)", role: .destructive) {
                    Task {
                        await model.uninstallPlugin(plugin)
                        pluginToRemove = nil
                    }
                }
            }
            Button("取消", role: .cancel) {
                pluginToRemove = nil
            }
        } message: {
            Text("这会删除本地插件文件。")
        }
    }

    private var pluginTabControl: some View {
        GlintSegmentedTabs(
            selection: $selectedTab,
            values: PluginTab.allCases,
            accessibilityTitle: "插件类型",
            title: \.title
        )
    }

    @ViewBuilder
    private func pluginPanel(kind: PluginKind) -> some View {
        let installed: [PluginManifest] =
            switch kind {
            case .dictionary: model.dictionaryPlugins
            case .translation: model.translationPlugins
            }
        let available = model.availablePlugins.filter {
            guard $0.type == kind else { return false }
            guard model.installedVersion(for: $0.id) != nil else {
                return true
            }
            return model.update(for: $0) != nil
        }

        switch kind {
        case .dictionary:
            SettingsPanel(minHeight: 420) {
                pluginRows(installed: installed, available: available)
            }
        case .translation:
            VStack(spacing: 16) {
                if installed.isEmpty {
                    translationSetupGuide(available: available)
                }
                SettingsCard("本地模型") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text("下载官方模型，或导入标准 MLX 模型目录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if model.isImportingLocalModel {
                                ProgressView(value: model.localImportProgress)
                                    .progressViewStyle(.linear)
                                    .frame(width: 120)
                                Button("取消") {
                                    model.cancelLocalModelImport()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            } else {
                                Button("导入模型…") {
                                    if let directory =
                                        LocalModelDirectoryPicker
                                        .chooseModelDirectory()
                                    {
                                        model.importLocalTranslationModel(
                                            from: directory
                                        )
                                    }
                                }
                                .disabled(model.isInstalling != nil)
                            }
                        }
                        if let error = model.localImportError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.top, 6)
                        }
                        Divider()
                            .padding(.vertical, 12)
                        pluginRows(installed: installed, available: available)
                    }
                }
            }
        }
    }

    private func translationSetupGuide(
        available: [PluginManifest]
    ) -> some View {
        SettingsCard("启用句子翻译") {
            VStack(alignment: .leading, spacing: 10) {
                Text("安装离线翻译模型后，可显示句子翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let plugin = available.first(where: {
                        $0.id == TranslationModelSelection.defaultModelID
                    }) {
                        Button("安装 \(plugin.name)") {
                            model.installPlugin(plugin)
                        }
                        .disabled(
                            model.isInstalling != nil
                                || model.isImportingLocalModel
                        )
                    }
                    Text("也可以导入本地 MLX 模型。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pluginRows(
        installed: [PluginManifest],
        available: [PluginManifest]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if installed.isEmpty {
                Text(model.isLoadingPlugins ? "正在读取…" : "未安装")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(installed.enumerated()), id: \.element.id) { index, plugin in
                    if index > 0 {
                        Divider()
                    }
                    installedRow(plugin)
                        .padding(.vertical, 8)
                }
            }
            if !available.isEmpty {
                Divider()
                Text("可安装或更新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(Array(available.enumerated()), id: \.element.id) { index, plugin in
                    if index > 0 {
                        Divider()
                    }
                    catalogRow(plugin)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func installedRow(_ plugin: PluginManifest) -> some View {
        let isInUse = model.isActiveTranslationModel(plugin)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                Text(plugin.summary ?? fallbackSummary(for: plugin.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelMetadata(for: plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.translationModelStatusModelID == plugin.id,
                    let status = model.translationModelStatusText
                {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(
                            model.translationModelStatusIsError
                                ? Color.red
                                : Color.secondary
                        )
                }
                if plugin.coreUpdateKind != nil,
                    let state = model.coreDictionaryUpdateState(
                        for: plugin.id
                    )
                {
                    if state.isChecking {
                        Text("正在检查 \(plugin.name) 更新…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let status = state.statusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(
                                state.isError
                                    ? Color.red
                                    : Color.secondary
                            )
                    }
                }
            }
            Spacer()
            if let updateKind = plugin.coreUpdateKind,
                plugin.source == .bundled
            {
                if model.coreDictionaryUpdateState(
                    for: plugin.id
                )?.isChecking == true {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Button("取消") {
                            model.cancelCoreDictionaryUpdate(plugin.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Button("检查更新") {
                        model.checkCoreDictionaryUpdate(
                            plugin.id,
                            kind: updateKind
                        )
                    }
                    .disabled(
                        model.hasActiveCoreDictionaryUpdate
                            || model.isInstalling != nil
                            || model.isImportingLocalModel
                    )
                }
            }
            if plugin.type == .translation {
                if model.isActiveTranslationModel(plugin) {
                    Text("使用中")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.16), in: Capsule())
                        .foregroundStyle(.blue)
                } else {
                    Button("使用") {
                        model.activateTranslationModel(plugin)
                    }
                    .disabled(
                        model.isInstalling != nil || model.isImportingLocalModel
                    )
                }
            }
            if !isInUse && plugin.source != .bundled {
                Button("卸载", role: .destructive) {
                    pluginToRemove = plugin
                }
                .disabled(
                    model.isInstalling != nil || model.isImportingLocalModel
                )
            }
        }
    }

    private func catalogRow(_ plugin: PluginManifest) -> some View {
        let installedVersion = model.installedVersion(for: plugin.id)
        let update = model.update(for: plugin)
        let progress = model.installProgress[plugin.id]
        let actionTitle = installedVersion == nil ? "安装" : "更新"

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                    .fontWeight(.medium)
                Text(plugin.summary ?? fallbackSummary(for: plugin.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelMetadata(for: plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let update {
                    Text(
                        "当前 \(update.currentVersion) → 新版本 \(update.availableVersion)"
                    )
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
                if !model.isCompatible(plugin) {
                    Text("需要至少 \(model.minimumMemoryText(for: plugin)) 内存")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isInstalling == plugin.id {
                let currentProgress =
                    progress
                    ?? PluginInstallProgress(
                        fraction: 0,
                        phase: .preparing
                    )
                let progressDescription =
                    InstallProgressFormatting.description(
                        for: currentProgress
                    )
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: currentProgress.fraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("安装进度")
                            .accessibilityValue(
                                Text(progressDescription)
                            )
                        Text(progressDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(progressDescription)
                    }
                    .frame(width: 220, alignment: .leading)
                    Button(model.isCancellingInstallation ? "取消中…" : "取消") {
                        model.cancelInstallation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isCancellingInstallation)
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    if update != nil {
                        Text("可更新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(actionTitle) {
                        model.installPlugin(plugin)
                    }
                    .disabled(
                        model.isInstalling != nil
                            || model.isImportingLocalModel
                            || !model.isCompatible(plugin)
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fallbackSummary(for type: PluginKind) -> String {
        switch type {
        case .dictionary:
            return "本地词典，支持中英词汇和短语。"
        case .translation:
            return "离线翻译模型，适合短句翻译。"
        }
    }

    private func modelMetadata(for plugin: PluginManifest) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: plugin.sizeBytes,
            countStyle: .file
        )
        if plugin.source == .local {
            return "本地导入 · \(size)"
        }
        if plugin.source == .bundled {
            return "内置 · 版本 \(plugin.version) · \(plugin.license)"
        }
        return "版本 \(plugin.version) · \(size) · \(plugin.license)"
    }
}

enum PluginTab: String, CaseIterable, Hashable {
    case dictionary
    case translation

    var title: String {
        switch self {
        case .dictionary: "翻译词典"
        case .translation: "翻译模型"
        }
    }

    var kind: PluginKind {
        switch self {
        case .dictionary: .dictionary
        case .translation: .translation
        }
    }
}
