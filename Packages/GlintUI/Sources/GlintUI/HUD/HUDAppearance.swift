import AppKit
import SwiftUI

public enum HUDAppearanceMode: String, CaseIterable, Sendable {
    case system
    case custom

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .custom: return "自定义"
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
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    public init(nsColor: NSColor) {
        let resolved = nsColor.usingColorSpace(.sRGB) ?? .black
        self.init(
            red: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }

    public init(_ color: Color) {
        self.init(nsColor: NSColor(color))
    }

    public var color: Color {
        Color(
            .sRGB,
            red: red,
            green: green,
            blue: blue,
            opacity: alpha
        )
    }

    public func contrastRatio(with other: HUDColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        0.2126 * Self.linearized(red)
            + 0.7152 * Self.linearized(green)
            + 0.0722 * Self.linearized(blue)
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
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
    public static let `default` = HUDAppearance()

    public var mode: HUDAppearanceMode
    public var textColor: HUDColor
    public var backgroundColor: HUDColor
    public var fontSize: Double
    public var density: HUDDensity

    public init(
        mode: HUDAppearanceMode = .system,
        textColor: HUDColor = Self.defaultTextColor,
        backgroundColor: HUDColor = Self.defaultBackgroundColor,
        fontSize: Double = 14,
        density: HUDDensity = .standard
    ) {
        let validFontSize = fontSize.isFinite ? fontSize : 14
        self.mode = mode
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.fontSize = min(
            max(validFontSize, Self.fontSizeRange.lowerBound),
            Self.fontSizeRange.upperBound
        )
        self.density = density
    }

    public var resolvedTextColor: Color {
        mode == .custom ? textColor.color : Color.primary
    }

    public var resolvedSecondaryTextColor: Color {
        mode == .custom ? textColor.color.opacity(0.72) : Color.secondary
    }

    public var resolvedBackgroundColor: Color {
        mode == .custom
            ? backgroundColor.color
            : Color(nsColor: .controlBackgroundColor)
    }

    public var customColorsHaveLowContrast: Bool {
        mode == .custom
            && textColor.contrastRatio(with: backgroundColor) < 4.5
    }
}

struct HUDLayoutMetrics: Equatable {
    let textFontSize: CGFloat
    let numberFontSize: CGFloat
    let minimumItemWidth: CGFloat
    let itemSpacing: CGFloat
    let multiItemHorizontalPadding: CGFloat
    let singleItemHorizontalPadding: CGFloat
    let itemHorizontalPadding: CGFloat
    let numberSpacing: CGFloat
    let singleItemVerticalPadding: CGFloat
    let multiItemVerticalPadding: CGFloat
    let itemVerticalPadding: CGFloat
    let panelHeight: CGFloat
    let measurementSafetyPadding: CGFloat

    init(appearance: HUDAppearance = .default) {
        let fontSize = CGFloat(appearance.fontSize)
        let scale = CGFloat(appearance.fontSize / 14)
        let density = appearance.density

        textFontSize = fontSize
        numberFontSize = max(9, (10 * scale).rounded())
        minimumItemWidth = max(40, (44 * scale).rounded())
        itemSpacing = max(3, (4 * scale).rounded())
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
        panelHeight = max(
            32,
            (fontSize + 22 + density.panelHeightDelta).rounded()
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

    var panelHeightDelta: CGFloat {
        switch self {
        case .compact: return -2
        case .standard: return 0
        case .spacious: return 4
        }
    }
}
