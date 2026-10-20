import AppKit
import GlintCore
import GlintPlugins
import SwiftUI

public struct MainWindowView: View {
    @State private var selection: SidebarItem? = .overview
    private let model: MainWindowModel

    public init(model: MainWindowModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 260)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(pageTitle)
        .task {
            await model.refreshPlugins()
        }
    }

    private var pageTitle: String {
        (selection ?? .overview).title
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewPage(model: model, selection: $selection)
        case .translation:
            TranslationSettingsPage(model: model)
        case .display:
            DisplayPage(model: model)
        case .plugins:
            PluginsPage(model: model)
        case .permissions:
            PermissionsPage(model: model)
        case .about:
            AboutPage()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case translation
    case display
    case plugins
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .translation: return "翻译设置"
        case .display: return "显示与触发"
        case .plugins: return "插件与模型"
        case .permissions: return "权限与隐私"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "sparkles"
        case .translation: return "text.bubble"
        case .display: return "rectangle.on.rectangle"
        case .plugins: return "shippingbox"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

private struct PageContainer<Content: View>: View {
    let subtitle: String?
    let content: Content

    init(subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .padding(.horizontal, 30)
            .padding(.top, 20)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    let minHeight: CGFloat?
    let content: Content

    init(minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
            .padding(16)
            .frame(
                maxWidth: .infinity,
                minHeight: minHeight,
                alignment: .topLeading
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.6), lineWidth: 1)
            }
    }
}

private struct TranslationSettingsPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer(subtitle: "控制词典和翻译模型的优先顺序。") {
            SettingsCard("翻译策略") {
                Picker(
                    "优先来源",
                    selection: Binding(
                        get: { model.translationMode },
                        set: { model.setTranslationMode($0) }
                    )
                ) {
                    ForEach(TranslationMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.translationMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DisplayPage: View {
    let model: MainWindowModel
    @Bindable private var preferences: DisplayPreferences

    init(model: MainWindowModel) {
        self.model = model
        self._preferences = Bindable(model.displayPreferences)
    }

    var body: some View {
        PageContainer(subtitle: "控制翻译显示何时出现、出现在哪里。") {
            SettingsCard("位置") {
                Picker("显示位置", selection: $preferences.position) {
                    ForEach(HUDPosition.allCases, id: \.self) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent(
                    "显示延迟",
                    value: String(format: "%.0f ms", preferences.stabilityDelay * 1000)
                )
                Slider(
                    value: $preferences.stabilityDelay,
                    in: 0.1...0.8,
                    step: 0.05
                )
                Text("连续输入时自动隐藏，候选稳定后显示。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard("外观") {
                LabeledContent(
                    "与候选栏间距",
                    value: String(format: "%.0f pt", preferences.candidateSpacing)
                )
                Slider(
                    value: $preferences.candidateSpacing,
                    in: 0...24,
                    step: 1
                )
                LabeledContent(
                    "背景透明度",
                    value: String(format: "%.0f%%", preferences.hudOpacity * 100)
                )
                Slider(
                    value: $preferences.hudOpacity,
                    in: 0.4...1.0,
                    step: 0.02
                )
                Text("透明度只影响显示背景，文字保持清晰。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SettingsCard("预览") {
                HUDPreview(preferences: preferences)
            }
        }
    }
}

private struct PluginsPage: View {
    let model: MainWindowModel
    @State private var pluginToRemove: PluginManifest?
    @State private var selectedTab: PluginTab = .dictionary

    var body: some View {
        PageContainer {
            pluginTabControl
            if let error = model.catalogError {
                HStack(alignment: .top) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("重新加载") {
                        Task { await model.refreshPlugins() }
                    }
                }
            }
            pluginPanel(kind: selectedTab.kind)
        }
        .task { await model.refreshPlugins() }
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
        let installed: [PluginManifest] = switch kind {
        case .dictionary: model.dictionaryPlugins
        case .translation: model.translationPlugins
        case .ocr: model.ocrPlugins
        }
        let available = model.availablePlugins.filter {
            $0.type == kind && model.installedVersion(for: $0.id) != $0.version
        }

        switch kind {
        case .dictionary:
            SettingsPanel(minHeight: 420) {
                pluginRows(installed: installed, available: available)
            }
        case .translation:
            VStack(spacing: 16) {
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
                                    if let directory = LocalModelDirectoryPicker
                                        .chooseModelDirectory() {
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
                OpenAICompatibleProvidersView(model: model)
            }
        case .ocr:
            SettingsPanel(minHeight: 420) {
                VStack(alignment: .leading, spacing: 0) {
                    builtInVisionRow
                    Divider()
                        .padding(.vertical, 8)
                    pluginRows(installed: installed, available: available)
                    if let status = model.ocrEngineStatusText {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(
                                model.ocrEngineStatusIsError
                                    ? Color.red
                                    : Color.secondary
                            )
                            .padding(.top, 8)
                    }
                }
            }
        }
    }

    private var builtInVisionRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple Vision")
                Text("系统内置，无需下载；识别失败时自动使用已安装的增强模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("系统内置 · macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isVisionOCREngineActive {
                Text("使用中")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.16), in: Capsule())
                    .foregroundStyle(.blue)
            } else {
                Button("使用") {
                    model.activateOCREngine(
                        id: OCREngineSelection.visionEngineID
                    )
                }
                .disabled(model.isInstalling != nil)
            }
        }
        .padding(.vertical, 8)
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
                Text("可下载")
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
        let isActiveModel = model.isActiveTranslationModel(plugin)
            || model.isActiveOCREngine(plugin)
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.name)
                Text(plugin.summary ?? fallbackSummary(for: plugin.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelMetadata(for: plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isActiveTranslationModel(plugin),
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
            } else if plugin.type == .ocr {
                if model.isActiveOCREngine(plugin) {
                    Text("使用中")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.16), in: Capsule())
                        .foregroundStyle(.blue)
                } else {
                    Button("使用") {
                        model.activateOCREngine(id: plugin.id)
                    }
                    .disabled(model.isInstalling != nil)
                }
            }
            if !isActiveModel {
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
        let isCurrent = installedVersion == plugin.version
        let progress = model.installProgress[plugin.id]
        let actionTitle: String = {
            if installedVersion == nil { return "安装" }
            return isCurrent ? "重新安装" : "更新"
        }()

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .fontWeight(.medium)
                    if plugin.recommended {
                        Text("推荐")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.18), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text(plugin.summary ?? fallbackSummary(for: plugin.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(modelMetadata(for: plugin))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isCompatible(plugin) {
                    Text("需要至少 \(model.minimumMemoryText(for: plugin)) 内存")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isInstalling == plugin.id {
                HStack(spacing: 10) {
                    ProgressView(value: progress ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                        .accessibilityLabel("安装进度")
                    Button(model.isCancellingInstallation ? "取消中…" : "取消") {
                        model.cancelInstallation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(model.isCancellingInstallation)
                }
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    if installedVersion != nil, !isCurrent {
                        Text("有新版本")
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
        case .ocr:
            return "本地候选识别模型，适合小字号和复杂背景。"
        }
    }

    private func modelMetadata(for plugin: PluginManifest) -> String {
        ByteCountFormatter.string(
            fromByteCount: plugin.sizeBytes,
            countStyle: .file
        ) + " · " + plugin.license
    }
}

private enum PluginTab: String, CaseIterable, Hashable {
    case dictionary
    case translation
    case ocr

    var title: String {
        switch self {
        case .dictionary: "翻译词典"
        case .translation: "翻译模型"
        case .ocr: "文字识别"
        }
    }

    var kind: PluginKind {
        switch self {
        case .dictionary: .dictionary
        case .translation: .translation
        case .ocr: .ocr
        }
    }
}

extension TranslationMode {
    var title: String {
        switch self {
        case .dictionaryFirst:
            "词典优先"
        case .modelFirst:
            "模型优先"
        }
    }

    var explanation: String {
        switch self {
        case .dictionaryFirst:
            "先查词典，未命中或失败时自动使用当前翻译模型。"
        case .modelFirst:
            "先使用当前翻译模型，失败或无结果时自动查词典。"
        }
    }
}

private struct PermissionsPage: View {
    let model: MainWindowModel

    var body: some View {
        PageContainer(subtitle: "全局生效只截取候选栏，不读取文本正文。") {
            SettingsCard("系统权限") {
                LabeledContent(
                    "屏幕录制",
                    value: model.screenRecordingGranted ? "已授权" : "待授权"
                )
                LabeledContent(
                    "辅助功能",
                    value: model.accessibilityGranted ? "已授权" : "待授权"
                )
                HStack {
                    Button("打开屏幕录制设置") { openPrivacyPane("Privacy_ScreenCapture") }
                    Button("打开辅助功能设置") { openPrivacyPane("Privacy_Accessibility") }
                    Button("重新检查") { model.refreshPermissions() }
                }
            }
            SettingsCard("隐私") {
                Text("不保存候选文本、翻译结果或输入历史；推理不联网。")
                Text("引导页会显示真实截取范围，让用户确认只截候选栏。")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model.refreshPermissions()
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct AboutPage: View {
    private let repositoryURL = URL(string: "https://github.com/jsogn/Glint")!

    private var version: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.1.0"
    }

    var body: some View {
        PageContainer(subtitle: "macOS 14+ · Apple Silicon · \(version)") {
            SettingsCard("Glint") {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11)
                            .fill(Color.accentColor.opacity(0.16))
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("在你的输入旁，看到英文。")
                            .font(.title3.weight(.semibold))
                        Text(
                            "Glint 读取苹果拼音候选中的焦点内容，"
                                + "在旁边显示一行英文，让日常打字自然成为英语学习。"
                        )
                        .foregroundStyle(.secondary)
                        Link("查看 GitHub 项目", destination: repositoryURL)
                            .font(.callout)
                    }
                }
            }
            SettingsCard("隐私") {
                Label(
                    "不保存候选文本、翻译结果或输入历史。",
                    systemImage: "lock.shield"
                )
                Text(
                    "默认使用本地词典、本地 OCR 和本地翻译模型；"
                        + "启用 OpenAI 兼容接口时，候选文本会发送到所配置的服务。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SettingsCard("第三方组件") {
                AboutComponentRow(
                    title: "词典",
                    detail: "CC-CEDICT · ECDICT · Wiktionary"
                )
                AboutComponentRow(
                    title: "文字识别",
                    detail: "Apple Vision · PaddleOCR PP-OCRv6"
                )
                AboutComponentRow(
                    title: "本地推理",
                    detail: "ONNX Runtime · MLX"
                )
                Text("各组件与模型的许可证随插件目录一并提供。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct AboutComponentRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(detail)
            Spacer()
        }
    }
}

private struct HUDPreview: View {
    let preferences: DisplayPreferences

    private var effectivePosition: HUDPosition {
        preferences.position == .above ? .above : .below
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if effectivePosition == .above {
                HUDView(text: "hello", backgroundOpacity: preferences.hudOpacity)
                    .padding(.bottom, preferences.candidateSpacing)
            }

            candidateBar

            if effectivePosition == .below {
                HUDView(text: "hello", backgroundOpacity: preferences.hudOpacity)
                    .padding(.top, preferences.candidateSpacing)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: preferences.position)
        .animation(.easeInOut(duration: 0.18), value: preferences.candidateSpacing)
        .animation(.easeInOut(duration: 0.18), value: preferences.hudOpacity)
    }

    private var candidateBar: some View {
        HStack(spacing: 10) {
            Text("你好")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(.blue, in: Capsule())
            Text("你好吗")
            Text("你号")
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.separator, lineWidth: 1)
        }
    }
}
