import AppKit
import SwiftUI

public enum HUDLayoutStyle: Equatable, Sendable {
    case selectedTranslations
    case candidateRow
}

public enum HUDBackgroundStyle: String, CaseIterable, Sendable {
    case darkGlass
    case solid

    public var title: String {
        switch self {
        case .darkGlass: return "玻璃"
        case .solid: return "纯色"
        }
    }
}

public enum HUDDensity: String, CaseIterable, Sendable {
    case compact
    case standard
    case spacious

    public var title: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .spacious: return "宽松"
        }
    }
}

public struct HUDColor: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case red
        case green
        case blue
    }

    public let red: Double
    public let green: Double
    public let blue: Double

    public init(
        red: Double,
        green: Double,
        blue: Double
    ) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    public init(nsColor: NSColor) {
        let resolved = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent
        )
    }

    public init(_ color: Color) {
        self.init(nsColor: NSColor(color))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            red: try container.decode(Double.self, forKey: .red),
            green: try container.decode(Double.self, forKey: .green),
            blue: try container.decode(Double.self, forKey: .blue)
        )
    }

    public var color: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue
        )
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct HUDAppearance: Equatable, Sendable {
    public static let defaultTextColor = HUDColor(
        red: 0.95,
        green: 0.95,
        blue: 0.97
    )
    public static let defaultBackgroundColor = HUDColor(
        red: 0.11,
        green: 0.11,
        blue: 0.12
    )
    public static let fontSizeRange = 12.0...18.0
    public static let selectedTranslationSpacingRange = 8.0...24.0
    public static let `default` = HUDAppearance()

    public var backgroundStyle: HUDBackgroundStyle
    public var textColor: HUDColor
    public var backgroundColor: HUDColor
    public var usesCustomTextColor: Bool
    public var fontSize: Double
    public var density: HUDDensity
    public var selectedTranslationSpacing: Double

    public init(
        backgroundStyle: HUDBackgroundStyle = .darkGlass,
        textColor: HUDColor = Self.defaultTextColor,
        backgroundColor: HUDColor = Self.defaultBackgroundColor,
        usesCustomTextColor: Bool = false,
        fontSize: Double = 14,
        density: HUDDensity = .standard,
        selectedTranslationSpacing: Double = 14
    ) {
        let validFontSize = fontSize.isFinite ? fontSize : 14
        self.backgroundStyle = backgroundStyle
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.usesCustomTextColor = usesCustomTextColor
        self.fontSize = min(
            max(validFontSize, Self.fontSizeRange.lowerBound),
            Self.fontSizeRange.upperBound
        )
        self.density = density
        let validTranslationSpacing =
            selectedTranslationSpacing.isFinite
            ? selectedTranslationSpacing
            : 14
        self.selectedTranslationSpacing = min(
            max(
                validTranslationSpacing,
                Self.selectedTranslationSpacingRange.lowerBound
            ),
            Self.selectedTranslationSpacingRange.upperBound
        )
    }

    public var effectiveTextColor: HUDColor {
        if usesCustomTextColor {
            return textColor
        }
        return Self.defaultTextColor
    }

    public var resolvedTextColor: Color {
        effectiveTextColor.color
    }

    public var resolvedSecondaryTextColor: Color {
        effectiveTextColor.color.opacity(0.72)
    }

}

struct HUDLayoutMetrics: Equatable {
    let textFontSize: CGFloat
    let numberFontSize: CGFloat
    let minimumItemWidth: CGFloat
    let itemSpacing: CGFloat
    let selectedItemSpacing: CGFloat
    let selectedHorizontalPadding: CGFloat
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
        numberFontSize = max(9, (10 * scale).rounded())
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
        selectedHorizontalPadding =
            multiItemHorizontalPadding + itemHorizontalPadding
        numberSpacing = max(1, (2 * scale).rounded())
        singleItemVerticalPadding = max(
            4,
            (6 * scale).rounded() + density.verticalDelta
        )
        multiItemVerticalPadding = max(
            2,
            (3 * scale).rounded() + density.verticalDelta
        )
        itemVerticalPadding = max(
            1,
            (2 * scale).rounded() + density.verticalDelta
        )
        measurementSafetyPadding = 3
        let textFont = NSFont.systemFont(
            ofSize: fontSize,
            weight: .medium
        )
        let lineHeight = ceil(
            textFont.ascender - textFont.descender + textFont.leading
        )
        singleItemHeight = max(
            24,
            lineHeight + singleItemVerticalPadding * 2
        )
        multiItemHeight = max(
            24,
            lineHeight
                + multiItemVerticalPadding * 2
                + itemVerticalPadding * 2
        )
    }

    func panelHeight(for itemCount: Int) -> CGFloat {
        itemCount > 1 ? multiItemHeight : singleItemHeight
    }

    func minimumItemWidth(for layoutStyle: HUDLayoutStyle) -> CGFloat {
        layoutStyle == .selectedTranslations ? 0 : minimumItemWidth
    }

    func itemSpacing(for layoutStyle: HUDLayoutStyle) -> CGFloat {
        layoutStyle == .selectedTranslations
            ? selectedItemSpacing
            : itemSpacing
    }

    func itemHorizontalPadding(
        for layoutStyle: HUDLayoutStyle
    ) -> CGFloat {
        layoutStyle == .selectedTranslations ? 0 : itemHorizontalPadding
    }

    func horizontalPadding(
        for layoutStyle: HUDLayoutStyle,
        itemCount: Int
    ) -> CGFloat {
        let padding: CGFloat
        if itemCount > 1 {
            padding =
                layoutStyle == .selectedTranslations
                ? selectedHorizontalPadding
                : multiItemHorizontalPadding
        } else {
            padding = singleItemHorizontalPadding
        }
        return padding
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
