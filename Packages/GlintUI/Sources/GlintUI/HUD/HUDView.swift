import AppKit
import SwiftUI

public struct HUDItem: Identifiable, Equatable, Sendable {
    public let id: Int
    public let number: Int?
    public let text: String
    public let isSelected: Bool

    public init(
        id: Int,
        number: Int? = nil,
        text: String,
        isSelected: Bool = false
    ) {
        self.id = id
        self.number = number
        self.text = text
        self.isSelected = isSelected
    }
}

public struct HUDView: View {
    private let items: [HUDItem]
    private let appearance: HUDAppearance
    private let backgroundOpacity: Double

    public init(
        text: String,
        appearance: HUDAppearance = .default,
        backgroundOpacity: Double = 0.92
    ) {
        self.items = [
            HUDItem(id: 0, text: text),
        ]
        self.appearance = appearance
        self.backgroundOpacity = backgroundOpacity
    }

    public init(
        items: [HUDItem],
        appearance: HUDAppearance = .default,
        backgroundOpacity: Double = 0.92
    ) {
        self.items = items
        self.appearance = appearance
        self.backgroundOpacity = backgroundOpacity
    }

    public var body: some View {
        HUDItemRow(
            items: items,
            appearance: appearance,
            backgroundOpacity: backgroundOpacity,
            animatesBackground: false,
            textOpacity: 1
        )
    }
}

struct HUDItemRow: View {
    let items: [HUDItem]
    let appearance: HUDAppearance
    let backgroundOpacity: Double
    let animatesBackground: Bool
    let textOpacity: Double

    var body: some View {
        let metrics = HUDLayoutMetrics(appearance: appearance)

        HStack(spacing: metrics.itemSpacing) {
            ForEach(items) { item in
                itemView(item, metrics: metrics)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        minWidth: items.count > 1
                            ? metrics.minimumItemWidth
                            : nil,
                        alignment: .leading
                    )
            }
        }
            .padding(
                .horizontal,
                items.count > 1
                    ? metrics.multiItemHorizontalPadding
                    : metrics.singleItemHorizontalPadding
            )
            .padding(
                .vertical,
                items.count > 1
                    ? metrics.multiItemVerticalPadding
                    : metrics.singleItemVerticalPadding
            )
            .background {
                Capsule()
                    .fill(
                        appearance.resolvedBackgroundColor
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
                Capsule().stroke(.separator, lineWidth: 1)
            }
    }

    static func minimumPanelWidth(
        for itemCount: Int,
        appearance: HUDAppearance = .default
    ) -> CGFloat {
        guard itemCount > 1 else { return 120 }
        let metrics = HUDLayoutMetrics(appearance: appearance)
        return metrics.multiItemHorizontalPadding * 2
            + CGFloat(itemCount) * metrics.minimumItemWidth
            + CGFloat(itemCount - 1) * metrics.itemSpacing
    }

    @MainActor
    static func naturalPanelWidth(
        for items: [HUDItem],
        appearance: HUDAppearance = .default
    ) -> CGFloat {
        guard !items.isEmpty else { return 120 }
        let metrics = HUDLayoutMetrics(appearance: appearance)
        let textFont = NSFont.systemFont(
            ofSize: metrics.textFontSize,
            weight: .medium
        )
        let numberFont = NSFont.systemFont(
            ofSize: metrics.numberFontSize,
            weight: .medium
        )
        let horizontalPadding = items.count > 1
            ? metrics.multiItemHorizontalPadding
            : metrics.singleItemHorizontalPadding
        var width = horizontalPadding * 2
        for item in items {
            var itemWidth = ceil(
                (item.text as NSString).size(
                    withAttributes: [.font: textFont]
                ).width
            )
            if let number = item.number {
                itemWidth += ceil(
                    ("\(number)" as NSString).size(
                        withAttributes: [.font: numberFont]
                    ).width
                ) + metrics.numberSpacing
            }
            if items.count > 1 {
                itemWidth += metrics.itemHorizontalPadding * 2
                itemWidth = max(itemWidth, metrics.minimumItemWidth)
            }
            width += itemWidth
        }
        if items.count > 1 {
            width += CGFloat(items.count - 1) * metrics.itemSpacing
        }
        return ceil(width + metrics.measurementSafetyPadding)
    }

    @MainActor
    static func requiresSelectedOnly(
        for items: [HUDItem],
        maximumWidth: CGFloat,
        appearance: HUDAppearance = .default
    ) -> Bool {
        naturalPanelWidth(
            for: items,
            appearance: appearance
        ) > max(120, maximumWidth)
    }

    private func itemView(
        _ item: HUDItem,
        metrics: HUDLayoutMetrics
    ) -> some View {
        HStack(spacing: metrics.numberSpacing) {
            if let number = item.number {
                Text("\(number)")
                    .font(
                        .system(
                            size: metrics.numberFontSize,
                            weight: .medium
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(
                        item.isSelected && items.count > 1
                            ? Color.white.opacity(0.9)
                            : appearance.resolvedSecondaryTextColor
                    )
            }
            Text(item.text)
                .font(
                    .system(
                        size: metrics.textFontSize,
                        weight: .medium
                    )
                )
                .lineLimit(1)
                .foregroundStyle(
                    item.isSelected && items.count > 1
                        ? Color.white
                        : appearance.resolvedTextColor
                )
        }
        .opacity(textOpacity)
        .padding(
            .horizontal,
            items.count > 1
                ? metrics.itemHorizontalPadding
                : 0
        )
        .padding(
            .vertical,
            items.count > 1 ? metrics.itemVerticalPadding : 0
        )
        .background {
            if item.isSelected, items.count > 1 {
                Capsule().fill(Color.accentColor)
            }
        }
    }
}

#Preview("HUD · 选中") {
    HUDView(text: "hello")
        .padding(32)
        .background(Color.black.opacity(0.85))
        .preferredColorScheme(.dark)
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
