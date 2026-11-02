import AppKit
import CoreGraphics

enum HUDGeometry {
    static let initialPanelSize = NSSize(width: 440, height: 36)
    static let minimumPanelWidth: CGFloat = 120
    static let minimumCandidateRowPanelWidth: CGFloat = 220
}

struct HUDLayoutMetrics: Equatable {
    let textFontSize: CGFloat
    let numberFontSize: CGFloat
    let partOfSpeechFontSize: CGFloat
    let minimumItemWidth: CGFloat
    let itemSpacing: CGFloat
    let selectedItemSpacing: CGFloat
    let selectedLeadingHorizontalPadding: CGFloat
    let selectedTrailingHorizontalPadding: CGFloat
    let multiItemHorizontalPadding: CGFloat
    let singleItemHorizontalPadding: CGFloat
    let itemHorizontalPadding: CGFloat
    let numberSpacing: CGFloat
    let singleItemVerticalPadding: CGFloat
    let multiItemVerticalPadding: CGFloat
    let itemVerticalPadding: CGFloat
    let singleItemHeight: CGFloat
    let multiItemHeight: CGFloat
    let measurementSafetyPadding: CGFloat

    init(appearance: HUDAppearance = .default) {
        let fontSize = CGFloat(appearance.fontSize)
        let scale = CGFloat(appearance.fontSize / 14)
        let density = appearance.density

        textFontSize = fontSize
        numberFontSize = max(9, (9 * scale).rounded())
        partOfSpeechFontSize = max(
            9,
            (fontSize * 0.75 * 2).rounded() / 2
        )
        minimumItemWidth = max(40, (44 * scale).rounded())
        itemSpacing = max(3, (4 * scale).rounded())
        selectedItemSpacing = CGFloat(appearance.selectedTranslationSpacing)
        multiItemHorizontalPadding = max(
            2,
            (3 * scale).rounded() + density.multiItemHorizontalDelta
        )
        singleItemHorizontalPadding = max(
            8,
            (12 * scale).rounded() + density.singleItemHorizontalDelta
        )
        itemHorizontalPadding = max(
            3,
            (5 * scale).rounded() + density.itemHorizontalDelta
        )
        selectedLeadingHorizontalPadding = multiItemHorizontalPadding
        selectedTrailingHorizontalPadding = max(
            8,
            (10 * scale).rounded() + density.multiItemHorizontalDelta
        )
        numberSpacing = max(1, (2 * scale).rounded())
        multiItemVerticalPadding = max(
            2,
            (3 * scale).rounded() + density.verticalDelta
        )
        itemVerticalPadding = max(
            1,
            (2 * scale).rounded() + density.verticalDelta
        )
        singleItemVerticalPadding =
            multiItemVerticalPadding + itemVerticalPadding
        measurementSafetyPadding = 3
        let textFont = NSFont.systemFont(
            ofSize: fontSize,
            weight: .medium
        )
        let lineHeight = ceil(
            textFont.ascender - textFont.descender + textFont.leading
        )
        multiItemHeight = max(
            24,
            lineHeight
                + multiItemVerticalPadding * 2
                + itemVerticalPadding * 2
        )
        singleItemHeight = multiItemHeight
    }
}

struct HUDLayoutPlan {
    let itemCount: Int
    let layoutStyle: HUDLayoutStyle
    let metrics: HUDLayoutMetrics

    init(
        itemCount: Int,
        layoutStyle: HUDLayoutStyle,
        appearance: HUDAppearance = .default
    ) {
        self.itemCount = itemCount
        self.layoutStyle = layoutStyle
        self.metrics = HUDLayoutMetrics(appearance: appearance)
    }

    var leadingHorizontalPadding: CGFloat {
        if layoutStyle == .selectedTranslations {
            return metrics.selectedLeadingHorizontalPadding
        }
        return itemCount > 1
            ? metrics.multiItemHorizontalPadding
            : metrics.singleItemHorizontalPadding
    }

    var trailingHorizontalPadding: CGFloat {
        if layoutStyle == .selectedTranslations {
            return metrics.selectedTrailingHorizontalPadding
        }
        return leadingHorizontalPadding
    }

    var verticalPadding: CGFloat {
        itemCount > 1
            ? metrics.multiItemVerticalPadding
            : metrics.singleItemVerticalPadding
    }

    var panelHeight: CGFloat {
        itemCount > 1 ? metrics.multiItemHeight : metrics.singleItemHeight
    }

    var minimumItemWidth: CGFloat {
        layoutStyle == .selectedTranslations ? 0 : metrics.minimumItemWidth
    }

    var interItemSpacing: CGFloat {
        layoutStyle == .selectedTranslations
            ? metrics.selectedItemSpacing
            : metrics.itemSpacing
    }

    var itemHorizontalPadding: CGFloat {
        layoutStyle == .selectedTranslations
            ? 0
            : metrics.itemHorizontalPadding
    }

    @MainActor
    static func naturalPanelWidth(
        for items: [HUDItem],
        layoutStyle: HUDLayoutStyle = .candidateRow,
        appearance: HUDAppearance = .default
    ) -> CGFloat {
        guard !items.isEmpty else { return HUDGeometry.minimumPanelWidth }
        let plan = HUDLayoutPlan(
            itemCount: items.count,
            layoutStyle: layoutStyle,
            appearance: appearance
        )
        let textFont = NSFont.systemFont(
            ofSize: plan.metrics.textFontSize,
            weight: .medium
        )
        let numberFont = NSFont.systemFont(
            ofSize: plan.metrics.numberFontSize,
            weight: .medium
        )
        let partOfSpeechFont = NSFont.systemFont(
            ofSize: plan.metrics.partOfSpeechFontSize,
            weight: .medium
        )
        var width =
            plan.leadingHorizontalPadding + plan.trailingHorizontalPadding
        for item in items {
            var itemWidth = ceil(
                (item.text as NSString).size(
                    withAttributes: [.font: textFont]
                ).width
            )
            if let number = item.number {
                itemWidth +=
                    ceil(
                        ("\(number)" as NSString).size(
                            withAttributes: [.font: numberFont]
                        ).width
                    ) + plan.metrics.numberSpacing
            }
            if !item.partsOfSpeechText.isEmpty {
                let suffix = " " + item.partsOfSpeechText
                itemWidth += ceil(
                    (suffix as NSString).size(
                        withAttributes: [.font: partOfSpeechFont]
                    ).width
                )
            }
            if items.count > 1 {
                itemWidth += plan.itemHorizontalPadding * 2
                itemWidth = max(itemWidth, plan.minimumItemWidth)
            }
            width += itemWidth
        }
        if items.count > 1 {
            width +=
                CGFloat(items.count - 1)
                * plan.interItemSpacing
        }
        return ceil(width + plan.metrics.measurementSafetyPadding)
    }

    @MainActor
    static func itemsFittingPartsOfSpeech(
        _ items: [HUDItem],
        maximumWidth: CGFloat,
        layoutStyle: HUDLayoutStyle,
        appearance: HUDAppearance = .default
    ) -> [HUDItem] {
        guard items.contains(where: { !$0.partsOfSpeech.isEmpty }) else {
            return items
        }
        let width = naturalPanelWidth(
            for: items,
            layoutStyle: layoutStyle,
            appearance: appearance
        )
        guard width > max(HUDGeometry.minimumPanelWidth, maximumWidth) else {
            return items
        }
        return items.map { $0.removingPartsOfSpeech() }
    }

    static func minimumPanelWidth(
        for itemCount: Int,
        layoutStyle: HUDLayoutStyle = .candidateRow,
        appearance: HUDAppearance = .default
    ) -> CGFloat {
        guard itemCount > 1 else { return HUDGeometry.minimumPanelWidth }
        let plan = HUDLayoutPlan(
            itemCount: itemCount,
            layoutStyle: layoutStyle,
            appearance: appearance
        )
        return plan.leadingHorizontalPadding
            + plan.trailingHorizontalPadding
            + CGFloat(itemCount) * plan.minimumItemWidth
            + CGFloat(itemCount - 1) * plan.interItemSpacing
    }

    @MainActor
    static func requiresSelectedOnly(
        for items: [HUDItem],
        maximumWidth: CGFloat,
        layoutStyle: HUDLayoutStyle = .candidateRow,
        appearance: HUDAppearance = .default
    ) -> Bool {
        guard items.contains(where: \.isSelected) else {
            return false
        }
        return naturalPanelWidth(
            for: items,
            layoutStyle: layoutStyle,
            appearance: appearance
        ) > max(HUDGeometry.minimumPanelWidth, maximumWidth)
    }

    @MainActor
    static func panelSize(
        for items: [HUDItem],
        maximumWidth: CGFloat,
        selectedOnly: Bool = false,
        layoutStyle: HUDLayoutStyle = .candidateRow,
        appearance: HUDAppearance = .default
    ) -> NSSize {
        let plan = HUDLayoutPlan(
            itemCount: selectedOnly ? 1 : items.count,
            layoutStyle: layoutStyle,
            appearance: appearance
        )
        let widthLimit = max(HUDGeometry.minimumPanelWidth, maximumWidth)
        let width: CGFloat
        if selectedOnly {
            width =
                items.map {
                    naturalPanelWidth(
                        for: [$0],
                        layoutStyle: layoutStyle,
                        appearance: appearance
                    )
                }.max() ?? HUDGeometry.minimumPanelWidth
        } else {
            width = naturalPanelWidth(
                for: items,
                layoutStyle: layoutStyle,
                appearance: appearance
            )
        }
        let minimumWidth: CGFloat
        if selectedOnly
            || items.count <= 1
            || layoutStyle == .selectedTranslations
        {
            minimumWidth = HUDGeometry.minimumPanelWidth
        } else {
            minimumWidth = max(
                HUDGeometry.minimumCandidateRowPanelWidth,
                minimumPanelWidth(
                    for: items.count,
                    layoutStyle: layoutStyle,
                    appearance: appearance
                )
            )
        }
        return NSSize(
            width: min(widthLimit, max(minimumWidth, width)),
            height: plan.panelHeight
        )
    }
}

private extension HUDDensity {
    var singleItemHorizontalDelta: CGFloat {
        switch self {
        case .compact: return -2
        case .standard: return 0
        case .spacious: return 2
        }
    }

    var multiItemHorizontalDelta: CGFloat {
        switch self {
        case .compact: return -1
        case .standard: return 0
        case .spacious: return 1
        }
    }

    var itemHorizontalDelta: CGFloat {
        switch self {
        case .compact: return -1
        case .standard: return 0
        case .spacious: return 1
        }
    }

    var verticalDelta: CGFloat {
        switch self {
        case .compact: return -1
        case .standard: return 0
        case .spacious: return 1
        }
    }
}
