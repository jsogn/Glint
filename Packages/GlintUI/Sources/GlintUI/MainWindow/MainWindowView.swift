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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                PageTitleCapsule(title: pageTitle)
            }
        }
        .task {
            await model.refreshInstalledPlugins()
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

private struct PageTitleCapsule: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .modifier(PageTitleBackground())
            .accessibilityAddTraits(.isHeader)
    }
}

private struct PageTitleBackground: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // The toolbar supplies its shared Liquid Glass background.
            content
        } else {
            content.background(.regularMaterial, in: Capsule())
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
    let systemImage: String?
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
            }
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
        PageContainer {
            SettingsCard("翻译策略") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(
                        alignment: .leading,
                        horizontalSpacing: 24,
                        verticalSpacing: 10
                    ) {
                        GridRow {
                            Text("优先来源")
                            Color.clear
                                .frame(height: 1)
                                .gridCellUnsizedAxes(.vertical)
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
                            .gridCellAnchor(.trailing)
                            .accessibilityHint(model.translationMode.explanation)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Text(model.translationMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DisplayPage: View {
    @Bindable private var preferences: DisplayPreferences

    init(model: MainWindowModel) {
        self._preferences = Bindable(model.displayPreferences)
    }

    init(preferences: DisplayPreferences) {
        self._preferences = Bindable(preferences)
    }

    var body: some View {
        PageContainer {
            SettingsCard("位置与触发") {
                VStack(spacing: 0) {
                    segmentedSetting(
                        title: "翻译",
                        selection: $preferences.translationScope,
                        caption: preferences.translationScope.explanation
                    ) {
                        ForEach(
                            CandidateTranslationScope.allCases,
                            id: \.self
                        ) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }

                    Divider()

                    segmentedSetting(
                        title: "显示位置",
                        selection: $preferences.position
                    ) {
                        ForEach(HUDPosition.allCases, id: \.self) {
                            position in
                            Text(position.title).tag(position)
                        }
                    }

                    Divider()

                    sliderSetting(
                        title: "候选停留",
                        value: String(
                            format: "%.0f ms",
                            preferences.candidateDwellDuration * 1000
                        ),
                        binding: $preferences.candidateDwellDuration,
                        range: 0.08...0.3,
                        step: 0.01,
                        caption: "连续输入时不翻译，候选停留达到该时长后触发。"
                    )
                }
            }
            SettingsCard("外观") {
                VStack(spacing: 0) {
                    segmentedSetting(
                        title: "背景",
                        selection: $preferences.hudBackgroundStyle,
                        caption: preferences.hudBackgroundStyle == .solid
                            ? "纯色背景默认黑色、80% 不透明度。"
                            : nil
                    ) {
                        ForEach(HUDBackgroundStyle.allCases, id: \.self) {
                            style in
                            Text(style.title).tag(style)
                        }
                    }

                    Divider()

                    if preferences.hudBackgroundStyle == .solid {
                        colorSetting(
                            title: "背景颜色",
                            color: Binding(
                                get: {
                                    preferences.hudBackgroundColor.color
                                },
                                set: {
                                    preferences.hudBackgroundColor = HUDColor($0)
                                }
                            )
                        )
                    }

                    colorSetting(
                        title: "文字颜色",
                        color: Binding(
                            get: {
                                preferences.hudAppearance
                                    .effectiveTextColor.color
                            },
                            set: {
                                preferences.setHUDTextColor(HUDColor($0))
                            }
                        )
                    )

                    sliderSetting(
                        title: "背景不透明度",
                        value: String(
                            format: "%.0f%%",
                            preferences.hudOpacity * 100
                        ),
                        binding: $preferences.hudOpacity,
                        range: 0.4...1.0,
                        step: 0.02,
                        caption: "只调整显示背景，不改变文字清晰度。"
                    )

                    sliderSetting(
                        title: "文字大小",
                        value: String(
                            format: "%.0f pt",
                            preferences.hudFontSize
                        ),
                        binding: $preferences.hudFontSize,
                        range: HUDAppearance.fontSizeRange,
                        step: 1,
                        caption: "字号会同步调整背景高度和候选槽位。"
                    )
                    segmentedSetting(
                        title: "栏内留白",
                        selection: $preferences.hudDensity
                    ) {
                        ForEach(HUDDensity.allCases, id: \.self) {
                            density in
                            Text(density.title).tag(density)
                        }
                    }
                    Divider()
                    sliderSetting(
                        title: "与候选栏间距",
                        value: String(
                            format: "%.0f pt",
                            preferences.candidateSpacing
                        ),
                        binding: $preferences.candidateSpacing,
                        range: 0...24,
                        step: 1
                    )
                    HStack {
                        Spacer()
                        Button("恢复默认外观") {
                            preferences.resetHUDAppearance()
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 8)
                }
            }
            SettingsCard("预览") {
                HUDPreview(preferences: preferences)
            }
        }
    }

    private func sliderSetting(
        title: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        caption: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: binding, in: range, step: step)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func colorSetting(
        title: String,
        color: Binding<Color>
    ) -> some View {
        HStack(spacing: 24) {
            Text(title)
            Spacer()
            ColorPicker(
                title,
                selection: color,
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func segmentedSetting<Value, Options>(
        title: String,
        selection: Binding<Value>,
        caption: String? = nil,
        @ViewBuilder options: () -> Options
    ) -> some View where Value: Hashable, Options: View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                Text(title)
                Spacer(minLength: 24)
                Picker(title, selection: selection) {
                    options()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 340, alignment: .trailing)
            }
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct DisplayPagePreview: View {
    @State private var preferences: DisplayPreferences

    init(scope: CandidateTranslationScope) {
        let suite = "Glint.DisplayPagePreview"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.translationScope = scope
        self._preferences = State(initialValue: preferences)
    }

    var body: some View {
        DisplayPage(preferences: preferences)
            .frame(width: 1_100, height: 760)
    }
}

#Preview("显示与触发 · 选中") {
    DisplayPagePreview(scope: .selected)
        .preferredColorScheme(.dark)
}

#Preview("显示与触发 · 一栏") {
    DisplayPagePreview(scope: .row)
        .preferredColorScheme(.light)
}

private struct PluginsPage: View {
    let model: MainWindowModel
    @State private var pluginToRemove: PluginManifest?
    @State private var selectedTab: PluginTab = .dictionary

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
        let installed: [PluginManifest] = switch kind {
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
        }
    }

    private func translationSetupGuide(
        available: [PluginManifest]
    ) -> some View {
        SettingsCard("启用句子翻译") {
            VStack(alignment: .leading, spacing: 10) {
                Text("安装离线翻译模型或配置在线接口后，可显示句子翻译。")
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
                    Text("也可以导入本地模型，或使用下方的在线接口。")
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
        if plugin.source == .local || plugin.version == "local" {
            return "本地导入 · \(size)"
        }
        if plugin.source == .bundled {
            return "内置 · 版本 \(plugin.version) · \(plugin.license)"
        }
        return "版本 \(plugin.version) · \(size) · \(plugin.license)"
    }
}

private enum PluginTab: String, CaseIterable, Hashable {
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

extension CandidateTranslationScope {
    var title: String {
        switch self {
        case .selected:
            "选中"
        case .row:
            "一栏"
        }
    }

    var explanation: String {
        switch self {
        case .selected:
            "只显示当前高亮候选的英文，展开更多候选后隐藏。"
        case .row:
            "仅在单行候选栏显示首栏英文，展开更多候选后隐藏。"
        }
    }
}

private struct PermissionsPage: View {
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
                            performPermissionAction()
                        } label: {
                            Label(
                                permissionActionTitle,
                                systemImage: permissionActionSymbol
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

    private func performPermissionAction() {
        if model.hasRequestedAccessibilityPermission {
            model.openAccessibilitySettings()
        } else {
            model.requestPermissions()
        }
    }

    private var hasMissingPermissions: Bool {
        !model.accessibilityGranted
    }

    private var permissionActionTitle: String {
        model.hasRequestedAccessibilityPermission
            ? "打开辅助功能设置"
            : "授权辅助功能"
    }

    private var permissionActionSymbol: String {
        model.hasRequestedAccessibilityPermission ? "gearshape" : "lock.open"
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
            Text(
                "本地翻译不会联网。只有启用 OpenAI 兼容接口时，"
                    + "候选文本才会发送到你配置的服务。"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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
        PageContainer {
            SettingsCard("Glint") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("在输入时显示对应的英文，将学习融入日常。")
                                .font(.title3.weight(.semibold))
                            Text("版本 \(version)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(
                                "在中文拼音候选旁显示简洁的英文提示，"
                                    + "查词不必切换应用，也不会打断思路。"
                            )
                            .foregroundStyle(.secondary)
                            Link("查看 GitHub 项目", destination: repositoryURL)
                                .font(.callout)
                        }
                    }

                    Divider()

                    HStack {
                        Text("系统要求")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("macOS 14+ · Apple 芯片")
                    }
                    .font(.callout)
                }
            }
            PrivacyNoticeCard()
        }
    }
}

private struct HUDPreview: View {
    let preferences: DisplayPreferences

    private var effectivePosition: HUDPosition {
        preferences.position == .above ? .above : .below
    }

    private var previewItems: [HUDItem] {
        switch preferences.translationScope {
        case .selected:
            return [
                HUDItem(id: 0, text: "hello"),
            ]
        case .row:
            return [
                HUDItem(
                    id: 0,
                    number: 1,
                    text: "hello",
                    isSelected: true
                ),
                HUDItem(id: 1, number: 2, text: "how are you?"),
                HUDItem(id: 2, number: 3, text: "you"),
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if effectivePosition == .above {
                HUDView(
                    items: previewItems,
                    appearance: preferences.hudAppearance,
                    backgroundOpacity: preferences.hudOpacity
                )
                    .padding(.bottom, preferences.candidateSpacing)
            }

            candidateBar

            if effectivePosition == .below {
                HUDView(
                    items: previewItems,
                    appearance: preferences.hudAppearance,
                    backgroundOpacity: preferences.hudOpacity
                )
                    .padding(.top, preferences.candidateSpacing)
            }
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: preferences.translationScope
        )
        .animation(.easeInOut(duration: 0.18), value: preferences.position)
        .animation(.easeInOut(duration: 0.18), value: preferences.candidateSpacing)
        .animation(.easeInOut(duration: 0.18), value: preferences.hudOpacity)
        .animation(.easeInOut(duration: 0.18), value: preferences.hudAppearance)
    }

    private var candidateBar: some View {
        HStack(spacing: 10) {
            Text("你好")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: Capsule())
            Text("你好吗")
            Text("你号")
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            HUDNativeMaterialBackground()
                .clipShape(Capsule())
        }
        .overlay {
            Capsule().strokeBorder(.separator, lineWidth: 1)
        }
    }
}
