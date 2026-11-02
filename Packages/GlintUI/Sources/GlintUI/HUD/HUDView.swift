import AppKit
import GlintCore
import SwiftUI

private struct HUDMaterialBlendingModeKey: EnvironmentKey {
    static let defaultValue: NSVisualEffectView.BlendingMode = .behindWindow
}

extension EnvironmentValues {
    var hudMaterialBlendingMode: NSVisualEffectView.BlendingMode {
        get { self[HUDMaterialBlendingModeKey.self] }
        set { self[HUDMaterialBlendingModeKey.self] = newValue }
    }
}

public struct HUDItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let number: Int?
    public let text: String
    public let partsOfSpeech: [PartOfSpeech]
    public let isSelected: Bool

    public init(
        id: Int,
        number: Int? = nil,
        text: String,
        partsOfSpeech: [PartOfSpeech] = [],
        isSelected: Bool = false
    ) {
        self.id = id
        self.number = number
        self.text = text
        self.partsOfSpeech = PartOfSpeech.normalized(partsOfSpeech)
        self.isSelected = isSelected
    }

    var partsOfSpeechText: String {
        partsOfSpeech.map(\.abbreviation).joined(separator: "/")
    }

    var accessibilityText: String {
        var values: [String] = []
        if let number {
            values.append(String(number))
        }
        values.append(text)
        values.append(
            contentsOf: partsOfSpeech.map(\.accessibilityName)
        )
        return values.joined(separator: ", ")
    }

    func removingPartsOfSpeech() -> Self {
        Self(
            id: id,
            number: number,
            text: text,
            partsOfSpeech: [],
            isSelected: isSelected
        )
    }
}

struct HUDView: View {
    private let items: [HUDItem]
    private let layoutStyle: HUDLayoutStyle
    private let appearance: HUDAppearance
    private let backgroundOpacity: Double

    init(
        text: String,
        appearance: HUDAppearance = .default,
        backgroundOpacity: Double = 0.8
    ) {
        self.items = [
            HUDItem(id: 0, text: text)
        ]
        self.layoutStyle = .selectedTranslations
        self.appearance = appearance
        self.backgroundOpacity = backgroundOpacity
    }

    init(
        items: [HUDItem],
        layoutStyle: HUDLayoutStyle = .candidateRow,
        appearance: HUDAppearance = .default,
        backgroundOpacity: Double = 0.8
    ) {
        self.items = items
        self.layoutStyle = layoutStyle
        self.appearance = appearance
        self.backgroundOpacity = backgroundOpacity
    }

    var body: some View {
        HUDItemRow(
            items: items,
            layoutStyle: layoutStyle,
            appearance: appearance,
            backgroundOpacity: backgroundOpacity,
            animatesBackground: false,
            textOpacity: 1
        )
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
    }
}

struct HUDItemRow: View {
    let items: [HUDItem]
    let layoutStyle: HUDLayoutStyle
    let appearance: HUDAppearance
    let backgroundOpacity: Double
    let animatesBackground: Bool
    let textOpacity: Double

    private var primaryTextColor: Color {
        if usesSystemMaterialTextColors {
            return .primary
        }
        if usesFixedFrostedTextColors {
            return .white
        }
        return appearance.resolvedTextColor
    }

    private var secondaryTextColor: Color {
        if usesSystemMaterialTextColors {
            return .secondary
        }
        if usesFixedFrostedTextColors {
            return .white.opacity(0.72)
        }
        return appearance.resolvedSecondaryTextColor
    }

    private var usesSystemMaterialTextColors: Bool {
        guard
            !appearance.usesCustomTextColor,
            appearance.backgroundStyle == .darkGlass
        else {
            return false
        }
        return true
    }

    private var usesFixedFrostedTextColors: Bool {
        !appearance.usesCustomTextColor
            && appearance.backgroundStyle == .frostedGlass
    }

    var body: some View {
        let plan = HUDLayoutPlan(
            itemCount: items.count,
            layoutStyle: layoutStyle,
            appearance: appearance
        )

        HStack(spacing: plan.interItemSpacing) {
            ForEach(items) { item in
                itemView(item, plan: plan)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        minWidth: items.count > 1
                            ? plan.minimumItemWidth
                            : nil,
                        alignment: .leading
                    )
            }
        }
        .padding(
            .leading,
            plan.leadingHorizontalPadding
        )
        .padding(
            .trailing,
            plan.trailingHorizontalPadding
        )
        .padding(.vertical, plan.verticalPadding)
        // Keep the visible capsule on the same exact geometry as NSPanel.
        // Otherwise intrinsic SwiftUI height can leave a transparent strip on
        // the side facing the candidate row when HUD placement flips above it.
        .frame(height: plan.panelHeight)
        .modifier(
            HUDSurfaceStyle(
                appearance: appearance,
                backgroundOpacity: backgroundOpacity,
                animatesBackground: animatesBackground
            )
        )
    }

    private func itemView(
        _ item: HUDItem,
        plan: HUDLayoutPlan
    ) -> some View {
        HStack(spacing: plan.metrics.numberSpacing) {
            if let number = item.number {
                Text("\(number)")
                    .font(
                        .system(
                            size: plan.metrics.numberFontSize,
                            weight: .medium
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(
                        item.isSelected && items.count > 1
                            ? Color.white.opacity(0.9)
                            : secondaryTextColor
                    )
            }
            let primary = Text(item.text)
                .font(
                    .system(
                        size: plan.metrics.textFontSize,
                        weight: .medium
                    )
                )
                .foregroundColor(
                    item.isSelected && items.count > 1
                        ? Color.white
                        : primaryTextColor
                )
            let label =
                item.partsOfSpeechText.isEmpty
                ? primary
                : primary
                    + Text(" ")
                    .font(
                        .system(
                            size: plan.metrics.partOfSpeechFontSize,
                            weight: .medium
                        )
                    )
                    + Text(item.partsOfSpeechText)
                    .font(
                        .system(
                            size: plan.metrics.partOfSpeechFontSize,
                            weight: .medium
                        )
                    )
                    .foregroundColor(
                        secondaryTextColor
                    )
            label.lineLimit(1)
        }
        .opacity(textOpacity)
        .padding(
            .horizontal,
            items.count > 1 ? plan.itemHorizontalPadding : 0
        )
        .padding(
            .vertical,
            items.count > 1 ? plan.metrics.itemVerticalPadding : 0
        )
        .background {
            if item.isSelected, items.count > 1 {
                Capsule().fill(Color.accentColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }
}

private struct HUDSurfaceStyle: ViewModifier {
    @Environment(\.hudMaterialBlendingMode) private var materialBlendingMode

    let appearance: HUDAppearance
    let backgroundOpacity: Double
    let animatesBackground: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearance.backgroundStyle == .solid {
            content
                .background {
                    Capsule()
                        .fill(
                            appearance.backgroundColor.color
                                .opacity(backgroundOpacity)
                        )
                        .animation(
                            animatesBackground
                                ? .easeOut(duration: 0.1)
                                : nil,
                            value: appearance
                        )
                        .animation(
                            animatesBackground
                                ? .easeOut(duration: 0.1)
                                : nil,
                            value: backgroundOpacity
                        )
                }
                .overlay {
                    Capsule().strokeBorder(.separator, lineWidth: 1)
                }
        } else if appearance.backgroundStyle == .frostedGlass {
            content
                .background {
                    HUDNativeMaterialBackground(
                        material: .popover,
                        blendingMode: materialBlendingMode,
                        appearance: NSAppearance(named: .darkAqua),
                        state: .active
                    )
                    .clipShape(Capsule())
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            Color.white.opacity(0.09),
                            lineWidth: 0.5
                        )
                }
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background {
                    HUDNativeMaterialBackground(
                        blendingMode: materialBlendingMode
                    )
                    .clipShape(Capsule())
                }
        }
    }
}

struct HUDNativeMaterialBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let appearance: NSAppearance?
    let state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        appearance: NSAppearance? = nil,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.appearance = appearance
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = false
        view.appearance = appearance
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.appearance = appearance
        nsView.state = state
    }
}

#Preview("HUD · 选中") {
    HUDView(
        items: [
            HUDItem(
                id: 0,
                number: 1,
                text: "design",
                partsOfSpeech: [.noun, .verb]
            ),
            HUDItem(
                id: 1,
                number: 2,
                text: "about",
                partsOfSpeech: [.preposition]
            ),
            HUDItem(
                id: 2,
                number: 3,
                text: "devise",
                partsOfSpeech: [.verb]
            ),
        ], layoutStyle: .selectedTranslations
    )
    .padding(32)
    .background(Color.black.opacity(0.85))
    .preferredColorScheme(.dark)
}

#Preview("HUD · 选中 · 浅色") {
    HUDView(
        items: [
            HUDItem(
                id: 0,
                number: 1,
                text: "design",
                partsOfSpeech: [.noun, .verb]
            ),
            HUDItem(
                id: 1,
                number: 2,
                text: "about",
                partsOfSpeech: [.preposition]
            ),
        ],
        layoutStyle: .selectedTranslations
    )
    .padding(32)
    .background(Color.white.opacity(0.9))
    .preferredColorScheme(.light)
}

#Preview("HUD · 一栏") {
    HUDView(items: [
        HUDItem(id: 0, number: 1, text: "hello", isSelected: true),
        HUDItem(id: 1, number: 2, text: "how are you?"),
        HUDItem(id: 2, number: 3, text: "you"),
        HUDItem(id: 3, number: 4, text: "your account"),
    ])
    .padding(32)
    .background(Color.black.opacity(0.85))
    .preferredColorScheme(.dark)
}

#Preview("HUD · 一栏长译文") {
    HUDView(items: [
        HUDItem(id: 0, number: 1, text: "to eat; to consume", isSelected: true),
        HUDItem(id: 1, number: 2, text: "to hold; to grasp"),
        HUDItem(id: 2, number: 3, text: "late; delayed"),
        HUDItem(id: 3, number: 4, text: "pond; pool"),
        HUDItem(id: 4, number: 5, text: "infatuated; obsessed"),
        HUDItem(id: 5, number: 6, text: "red; bare"),
    ])
    .frame(width: 440)
    .padding(32)
    .background(Color.black.opacity(0.85))
    .preferredColorScheme(.dark)
}
