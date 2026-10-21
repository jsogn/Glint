import AppKit
import SwiftUI

enum HUDLayoutMetrics {
    static let textFontSize: CGFloat = 14
    static let numberFontSize: CGFloat = 10
    static let minimumItemWidth: CGFloat = 44
    static let itemSpacing: CGFloat = 4
    static let multiItemHorizontalPadding: CGFloat = 3
    static let singleItemHorizontalPadding: CGFloat = 12
    static let itemHorizontalPadding: CGFloat = 5
    static let numberSpacing: CGFloat = 2
}

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
    private let backgroundOpacity: Double

    public init(text: String, backgroundOpacity: Double = 0.92) {
        self.items = [
            HUDItem(id: 0, text: text),
        ]
        self.backgroundOpacity = backgroundOpacity
    }

    public init(items: [HUDItem], backgroundOpacity: Double = 0.92) {
        self.items = items
        self.backgroundOpacity = backgroundOpacity
    }

    public var body: some View {
        HUDItemRow(
            items: items,
            backgroundOpacity: backgroundOpacity,
            animatesBackground: false,
            textOpacity: 1
        )
    }
}

struct HUDItemRow: View {
    static let minimumItemWidth = HUDLayoutMetrics.minimumItemWidth

    let items: [HUDItem]
    let backgroundOpacity: Double
    let animatesBackground: Bool
    let textOpacity: Double

    var body: some View {
        HStack(spacing: HUDLayoutMetrics.itemSpacing) {
            ForEach(items) { item in
                itemView(item)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        minWidth: items.count > 1
                            ? Self.minimumItemWidth
                            : nil,
                        alignment: .leading
                    )
            }
        }
            .padding(
                .horizontal,
                items.count > 1
                    ? HUDLayoutMetrics.multiItemHorizontalPadding
                    : HUDLayoutMetrics.singleItemHorizontalPadding
            )
            .padding(.vertical, items.count > 1 ? 3 : 6)
            .background {
                Capsule()
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                            .opacity(backgroundOpacity)
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

    static func minimumPanelWidth(for itemCount: Int) -> CGFloat {
        guard itemCount > 1 else { return 120 }
        return HUDLayoutMetrics.multiItemHorizontalPadding * 2
            + CGFloat(itemCount) * minimumItemWidth
            + CGFloat(itemCount - 1) * HUDLayoutMetrics.itemSpacing
    }

    @MainActor
    static func naturalPanelWidth(for items: [HUDItem]) -> CGFloat {
        guard !items.isEmpty else { return 120 }
        let textFont = NSFont.systemFont(
            ofSize: HUDLayoutMetrics.textFontSize,
            weight: .medium
        )
        let numberFont = NSFont.systemFont(
            ofSize: HUDLayoutMetrics.numberFontSize,
            weight: .medium
        )
        let horizontalPadding = items.count > 1
            ? HUDLayoutMetrics.multiItemHorizontalPadding
            : HUDLayoutMetrics.singleItemHorizontalPadding
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
                ) + HUDLayoutMetrics.numberSpacing
            }
            if items.count > 1 {
                itemWidth += HUDLayoutMetrics.itemHorizontalPadding * 2
                itemWidth = max(itemWidth, minimumItemWidth)
            }
            width += itemWidth
        }
        if items.count > 1 {
            width += CGFloat(items.count - 1) * HUDLayoutMetrics.itemSpacing
        }
        return ceil(width)
    }

    @MainActor
    static func requiresSelectedOnly(
        for items: [HUDItem],
        maximumWidth: CGFloat
    ) -> Bool {
        naturalPanelWidth(for: items) > max(120, maximumWidth)
    }

    private func itemView(_ item: HUDItem) -> some View {
        HStack(spacing: HUDLayoutMetrics.numberSpacing) {
            if let number = item.number {
                Text("\(number)")
                    .font(
                        .system(
                            size: HUDLayoutMetrics.numberFontSize,
                            weight: .medium
                        )
                    )
                    .monospacedDigit()
                    .foregroundStyle(
                        item.isSelected && items.count > 1
                            ? Color.white.opacity(0.9)
                            : Color.secondary.opacity(0.72)
                    )
            }
            Text(item.text)
                .font(
                    .system(
                        size: HUDLayoutMetrics.textFontSize,
                        weight: .medium
                    )
                )
                .lineLimit(1)
                .foregroundStyle(
                    item.isSelected && items.count > 1
                        ? Color.white
                        : Color.primary
                )
        }
        .opacity(textOpacity)
        .animation(
            animatesBackground
                ? .easeOut(duration: 0.06)
                : nil,
            value: textOpacity
        )
        .padding(
            .horizontal,
            items.count > 1
                ? HUDLayoutMetrics.itemHorizontalPadding
                : 0
        )
        .padding(.vertical, items.count > 1 ? 2 : 0)
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
