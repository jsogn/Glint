import SwiftUI

public struct MainWindowView: View {
    @State private var selection: SidebarItem? = .overview
    @State private var pluginTab: PluginTab = .dictionary
    private let model: MainWindowModel
    private let auxiliaryContent: AnyView?

    public init(
        model: MainWindowModel,
        auxiliaryContent: AnyView? = nil
    ) {
        self.model = model
        self.auxiliaryContent = auxiliaryContent
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            NavigationSplitView {
                List(SidebarItem.visibleItems, selection: $selection) { item in
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
                    PageTitle(title: pageTitle)
                }
            }

            if let auxiliaryContent {
                auxiliaryContent
            }
        }
        .task {
            await model.refreshInstalledPlugins()
            await model.checkForCatalogUpdatesAfterLaunch()
            model.checkActiveTranslationModelUpdateAfterLaunch()
        }
        .onChange(of: model.systemTranslationPresentationEvent) {
            selection = .overview
        }
    }

    private var pageTitle: String {
        (selection ?? .overview).title
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewPage(
                model: model,
                selection: $selection,
                openTranslationModels: {
                    pluginTab = .translation
                    selection = .plugins
                }
            )
        case .general:
            GeneralPage(model: model)
        case .inputMethods:
            InputMethodsPage(model: model)
        case .display:
            DisplayPage(model: model)
        case .plugins:
            PluginsPage(model: model, selectedTab: $pluginTab)
        case .permissions:
            PermissionsPage(model: model)
        case .about:
            AboutPage()
        }
    }
}

private struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .accessibilityAddTraits(.isHeader)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview
    case general
    case inputMethods
    case display
    case plugins
    case permissions
    case about

    var id: String { rawValue }

    static var visibleItems: [SidebarItem] {
        allCases
    }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .general: return "通用配置"
        case .inputMethods: return "输入法支持"
        case .display: return "显示与触发"
        case .plugins: return "插件与模型"
        case .permissions: return "权限与隐私"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "sparkles"
        case .general: return "gearshape"
        case .inputMethods: return "keyboard"
        case .display: return "rectangle.on.rectangle"
        case .plugins: return "shippingbox"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}
