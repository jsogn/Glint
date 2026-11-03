import Foundation
import GlintCore
import GlintPlugins
import SwiftUI

struct PluginsPage: View {
    let model: MainWindowModel
    @Binding var selectedTab: PluginTab
    @State private var pluginToRemove: PluginManifest?
    @State private var marketQuery = ""
    @State private var pendingTranslationModelID: String?

    var body: some View {
        PageContainer {
            HStack(spacing: 12) {
                pluginTabControl
                Spacer()
                Text(
                    "当前语言：\(model.translationTarget.chineseDisplayName)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if model.isLoadingPlugins
                    || model.isLoadingCatalog
                    || model.isInstalling != nil
                    || model.isPreparingModelMarketInstallID != nil
                {
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
            pluginPanel(selectedTab)
        }
        .task {
            await model.refreshInstalledPlugins()
            await model.checkForCatalogUpdates()
        }
        .task(id: selectedTab) {
            guard selectedTab == .market,
                model.modelMarketResults.isEmpty
            else {
                return
            }
            await model.searchModelMarket(query: marketQuery)
        }
        .task(id: selectedTab) {
            guard selectedTab == .translation else { return }
            await model.refreshSystemTranslationSupport()
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
        .sheet(
            isPresented: Binding(
                get: { model.modelMarketInstallPreview != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelModelMarketInstallPreview()
                    }
                }
            )
        ) {
            if let preview = model.modelMarketInstallPreview {
                ModelInstallConfirmationSheet(
                    preparation: preview,
                    onCancel: {
                        model.cancelModelMarketInstallPreview()
                    },
                    onInstall: {
                        model.confirmModelMarketInstall()
                    }
                )
            }
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
    private func pluginPanel(_ tab: PluginTab) -> some View {
        switch tab {
        case .dictionary:
            pluginPanel(kind: .dictionary)
        case .translation:
            pluginPanel(kind: .translation)
        case .market:
            modelMarketPanel
        }
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
            let localInstalled = model.localTranslationPlugins
            let recommendedInstalled =
                model.recommendedTranslationPlugins
            VStack(spacing: 16) {
                systemTranslationCard
                SettingsCard("本地模型") {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text("从本地目录导入标准 MLX 模型。")
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
                                Button("导入模型") {
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
                        if !localInstalled.isEmpty {
                            Divider()
                                .padding(.vertical, 12)
                            pluginRows(
                                installed: localInstalled,
                                available: []
                            )
                        }
                    }
                }
                SettingsCard("推荐模型") {
                    pluginRows(
                        installed: recommendedInstalled,
                        available: available
                    )
                }
            }
        }
    }

    private var systemTranslationCard: some View {
        SettingsCard("Apple 翻译", systemImage: "translate") {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(
                        "系统内置翻译模型，首次使用可能需要下载语言包。"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    if model.systemTranslationSetupState
                        == .installationIncomplete
                    {
                        Text(
                            "安装尚未完成。如果系统仍在下载，完成后会自动更新。"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    if let error = model.systemTranslationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                systemTranslationStatusOrAction
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder
    private var systemTranslationStatusOrAction: some View {
        if model.isPreparingSystemTranslation {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在准备…")
                    .foregroundStyle(.secondary)
            }
        } else if model.isActiveSystemTranslationReady {
            Label("使用中", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
        } else if model.isRefreshingSystemTranslation {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("检查中…")
                    .foregroundStyle(.secondary)
            }
        } else {
            switch model.systemTranslationAvailability {
            case .installed:
                if pendingTranslationModelID
                    == SystemTranslationModel.appleTranslationID
                {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("使用") {
                        useTranslationModel(
                            SystemTranslationModel.appleTranslationID
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isChangingTranslationTarget)
                }
            case .available:
                Button(
                    model.systemTranslationSetupState
                        == .installationIncomplete
                        ? "继续安装"
                        : "安装语言包"
                ) {
                    Task {
                        await model.prepareSystemTranslationSupport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPreparingSystemTranslation)
            case .failed:
                Button("重试") {
                    Task {
                        await model.prepareSystemTranslationSupport()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isPreparingSystemTranslation)
            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备…")
                        .foregroundStyle(.secondary)
                }
            case .unsupported:
                Text(
                    "当前 Mac 不支持中文到\(model.translationTarget.chineseDisplayName)翻译"
                )
                    .foregroundStyle(.secondary)
            case nil:
                Button("检查支持") {
                    Task {
                        await model.refreshSystemTranslationSupport()
                    }
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
        let supportsCurrentTarget =
            plugin.type != .translation
            || MainWindowModel.supports(
                plugin,
                target: model.translationTarget
            )
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                Text(plugin.summary ?? fallbackSummary(for: plugin.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelMetadata(for: plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if plugin.type == .translation,
                    let label = pluginLanguageCapabilityLabel(for: plugin)
                {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(
                            supportsCurrentTarget
                                ? Color.secondary
                                : Color.secondary.opacity(0.7)
                        )
                } else if !model.translationTarget
                    .supportsDictionaryRouting,
                    plugin.type == .dictionary
                {
                    Text("仅英语参与翻译路由")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if plugin.type == .translation,
                    let state = model.translationModelUpdateState(
                        for: plugin.id
                    ),
                    let status = state.statusText
                {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(
                            state.isError
                                ? Color.red
                                : Color.secondary
                        )
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
                if plugin.source == .catalog, plugin.revision != nil {
                    let updateState =
                        model.translationModelUpdateState(
                            for: plugin.id
                        )
                    if updateState?.isChecking == true {
                        ProgressView()
                            .controlSize(.small)
                    } else if updateState?.update != nil {
                        Button("更新") {
                            model.installTranslationModelUpdate(plugin.id)
                        }
                        .disabled(
                            model.isInstalling != nil
                                || model.isImportingLocalModel
                        )
                    } else {
                        Button("检查更新") {
                            model.checkTranslationModelUpdate(
                                plugin,
                                force: true
                            )
                        }
                        .disabled(
                            model.isInstalling != nil
                                || model.isImportingLocalModel
                        )
                    }
                }
                if model.isActiveTranslationModel(plugin) {
                    Text("使用中")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.16), in: Capsule())
                        .foregroundStyle(.blue)
                } else if pendingTranslationModelID == plugin.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在使用…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("使用") {
                        useTranslationModel(plugin.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !supportsCurrentTarget
                            || model.isChangingTranslationTarget
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
        .opacity(supportsCurrentTarget ? 1 : 0.62)
    }

    private func useTranslationModel(_ modelID: String) {
        guard pendingTranslationModelID == nil else { return }
        let target = model.translationTarget
        pendingTranslationModelID = modelID
        Task {
            await model.setTranslationModel(modelID, for: target)
            if pendingTranslationModelID == modelID {
                pendingTranslationModelID = nil
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
                if plugin.type == .translation,
                    let label = pluginLanguageCapabilityLabel(for: plugin)
                {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private var modelMarketPanel: some View {
        SettingsPanel(minHeight: 420) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    TextField("搜索模型名称或仓库", text: $marketQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            searchModelMarket()
                        }
                    Button("搜索") {
                        searchModelMarket()
                    }
                    .disabled(model.isLoadingModelMarket)
                }
                Text("搜索并安装你需要的翻译模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.modelMarketError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Divider()
                if model.isLoadingModelMarket {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在搜索模型…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.modelMarketResults.isEmpty {
                    Text("没有找到可安装的 MLX 模型")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(
                            Array(model.modelMarketResults.enumerated()),
                            id: \.element.id
                        ) { index, result in
                            if index > 0 {
                                Divider()
                            }
                            modelMarketRow(result)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private func modelMarketRow(
        _ result: UpstreamModelSummary
    ) -> some View {
        let installed = model.installedPlugin(
            forRepository: result.repository
        )
        let isPreparing =
            model.isPreparingModelMarketInstallID == result.id
        let isDownloading =
            model.modelMarketInstallRepository == result.repository
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .fontWeight(.medium)
                Text(result.repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(modelMarketMetadata(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPreparing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("取消") {
                        model.cancelModelMarketInstall()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else if isDownloading {
                let progress =
                    model.modelMarketInstallPluginID.flatMap {
                        model.installProgress[$0]
                    }
                    ?? PluginInstallProgress(
                        fraction: 0,
                        phase: .preparing
                    )
                let progressDescription =
                    InstallProgressFormatting.description(
                        for: progress
                    )
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: progress.fraction)
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
                    Button(
                        model.isCancellingInstallation
                            ? "取消中…"
                            : "取消"
                    ) {
                        model.cancelInstallation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isCancellingInstallation)
                }
            } else if installed != nil {
                Text("已安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("安装") {
                    model.installModelFromMarket(result)
                }
                .disabled(
                    model.isInstalling != nil
                        || model.isImportingLocalModel
                        || model.isPreparingModelMarketInstallID != nil
                )
            }
        }
    }

    private func modelMarketMetadata(
        _ model: UpstreamModelSummary
    ) -> String {
        var values = [
            "\(model.downloads.formatted()) 次下载",
            "\(model.likes) 喜欢",
        ]
        if let license = model.license {
            values.append(license)
        }
        if let pipelineTag = model.pipelineTag {
            values.append(pipelineTag)
        }
        return values.joined(separator: " · ")
    }

    private func searchModelMarket() {
        let query = marketQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        Task {
            await model.searchModelMarket(query: query)
        }
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
        if plugin.id.hasPrefix("upstream-mlx-"),
            let revision = plugin.revision
        {
            return
                "上游 · \(size) · \(plugin.license) · "
                + String(revision.prefix(8))
        }
        return "版本 \(plugin.version) · \(size) · \(plugin.license)"
    }
}

func pluginLanguageCapabilityLabel(
    for plugin: PluginManifest
) -> String? {
    guard let names = declaredTranslationTargetNames(for: plugin)
    else {
        return nil
    }
    guard !names.isEmpty else {
        return "不支持可用目标语言"
    }
    if names == [TranslationTarget.english.chineseDisplayName] {
        return "仅支持英语"
    }
    return "语言能力：" + names.joined(separator: " / ")
}

private func declaredTranslationTargetNames(
    for plugin: PluginManifest
) -> [String]? {
    guard let targets = plugin.translationTargets else {
        return nil
    }
    let targetSet = Set(targets)
    return TranslationTarget.allCases
        .filter(targetSet.contains)
        .map(\.chineseDisplayName)
}

enum PluginTab: String, CaseIterable, Hashable {
    case dictionary
    case translation
    case market

    var title: String {
        switch self {
        case .dictionary: "翻译词典"
        case .translation: "翻译模型"
        case .market: "模型市场"
        }
    }
}

private struct ModelInstallConfirmationSheet: View {
    let preparation: ModelInstallPreparation
    let onCancel: () -> Void
    let onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("安装模型")
                .font(.title3.weight(.semibold))
            Text(preparation.manifest.name)
                .font(.headline)
            Grid(
                alignment: .leading,
                horizontalSpacing: 24,
                verticalSpacing: 8
            ) {
                detailRow(
                    "模型架构",
                    preparation.snapshot.modelType
                )
                detailRow(
                    "参数规模",
                    parameterText
                )
                detailRow(
                    "量化精度",
                    quantizationText
                )
                detailRow(
                    "下载大小",
                    byteCount(preparation.snapshot.sizeBytes)
                )
                detailRow(
                    "预计运行内存",
                    byteCount(preparation.manifest.minRAMBytes)
                )
                detailRow(
                    "许可证",
                    preparation.snapshot.license
                )
                detailRow(
                    "版本",
                    String(preparation.snapshot.revision.prefix(12))
                )
                if let names = declaredTranslationTargetNames(
                    for: preparation.manifest
                ), !names.isEmpty {
                    detailRow(
                        "目标语言",
                        names.joined(separator: " / ")
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("模型将在下载后执行加载验证。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("下载并安装") {
                    onInstall()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var parameterText: String {
        guard let count = preparation.snapshot.parameterCount else {
            return "未知"
        }
        if count >= 1_000_000_000 {
            return String(
                format: "%.1fB",
                Double(count) / 1_000_000_000
            )
        }
        if count >= 1_000_000 {
            return String(
                format: "%.0fM",
                Double(count) / 1_000_000
            )
        }
        return count.formatted()
    }

    private var quantizationText: String {
        guard let bits = preparation.snapshot.quantizationBits else {
            return "未知"
        }
        return bits.rounded() == bits
            ? "\(Int(bits))-bit"
            : "\(bits)-bit"
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .foregroundStyle(.primary)
                .gridColumnAlignment(.leading)
                .textSelection(.enabled)
        }
    }

    private func byteCount(_ value: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: value,
            countStyle: .file
        )
    }
}
