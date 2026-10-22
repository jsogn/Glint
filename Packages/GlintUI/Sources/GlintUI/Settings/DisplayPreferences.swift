import Foundation
import GlintCore
import Observation

public enum HUDPosition: String, CaseIterable, Sendable {
    case automatic
    case above
    case below

    public var title: String {
        switch self {
        case .automatic: return "自动"
        case .above: return "候选栏上方"
        case .below: return "候选栏下方"
        }
    }
}

@MainActor
@Observable
public final class DisplayPreferences {
    private enum Key {
        static let position = "display.position"
        static let candidateDwellDuration = "display.candidateDwellDuration"
        static let candidateSpacing = "display.candidateSpacing"
        static let legacyHUDOpacity = "display.hudOpacity"
        static let legacyHUDAppearanceMode = "display.hudAppearanceMode"
        static let hudAppearanceSchemaVersion =
            "display.hudAppearanceSchemaVersion"
        static let hudBackgroundStyle = "display.hudBackgroundStyle"
        static let hudUsesGlass = "display.hudUsesGlass"
        static let hudGlassAppearance = "display.hudGlassAppearance"
        static let hudUsesCustomTextColor = "display.hudUsesCustomTextColor"
        static let hudGlassOpacity = "display.hudGlassOpacity"
        static let hudSolidOpacity = "display.hudSolidOpacity"
        static let hudTextColor = "display.hudTextColor"
        static let hudBackgroundColor = "display.hudBackgroundColor"
        static let hudFontSize = "display.hudFontSize"
        static let hudDensity = "display.hudDensity"
        static let translationScope = "display.translationScope"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    public var candidateDwellDurationDidChange: (@MainActor (Double) -> Void)?
    public var translationScopeDidChange:
        (@MainActor (CandidateTranslationScope) -> Void)?

    public var position: HUDPosition {
        didSet {
            defaults.set(position.rawValue, forKey: Key.position)
        }
    }

    public var candidateDwellDuration: Double {
        didSet {
            let clamped = min(max(candidateDwellDuration, 0.08), 0.3)
            if clamped != candidateDwellDuration {
                candidateDwellDuration = clamped
                return
            }
            defaults.set(clamped, forKey: Key.candidateDwellDuration)
            candidateDwellDurationDidChange?(clamped)
        }
    }

    public var candidateSpacing: Double {
        didSet {
            let clamped = min(max(candidateSpacing, 0), 24)
            if clamped != candidateSpacing {
                candidateSpacing = clamped
                return
            }
            defaults.set(clamped, forKey: Key.candidateSpacing)
        }
    }

    public var hudBackgroundStyle: HUDBackgroundStyle {
        didSet {
            defaults.set(
                hudBackgroundStyle.rawValue,
                forKey: Key.hudBackgroundStyle
            )
        }
    }

    public var hudUsesCustomTextColor: Bool {
        didSet {
            defaults.set(
                hudUsesCustomTextColor,
                forKey: Key.hudUsesCustomTextColor
            )
        }
    }

    public var hudTextColor: HUDColor {
        didSet {
            persist(hudTextColor, forKey: Key.hudTextColor)
        }
    }

    public var hudBackgroundColor: HUDColor {
        didSet {
            persist(hudBackgroundColor, forKey: Key.hudBackgroundColor)
        }
    }

    public var hudGlassOpacity: Double {
        didSet {
            let clamped = Self.clampedOpacity(hudGlassOpacity)
            if clamped != hudGlassOpacity {
                hudGlassOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Key.hudGlassOpacity)
        }
    }

    public var hudSolidOpacity: Double {
        didSet {
            let clamped = Self.clampedOpacity(hudSolidOpacity)
            if clamped != hudSolidOpacity {
                hudSolidOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Key.hudSolidOpacity)
        }
    }

    public var hudOpacity: Double {
        get {
            hudBackgroundStyle == .solid
                ? hudSolidOpacity
                : hudGlassOpacity
        }
        set {
            if hudBackgroundStyle == .solid {
                hudSolidOpacity = newValue
            } else {
                hudGlassOpacity = newValue
            }
        }
    }

    public var hudFontSize: Double {
        didSet {
            let clamped = Self.clampedFontSize(hudFontSize)
            if clamped != hudFontSize {
                hudFontSize = clamped
                return
            }
            defaults.set(clamped, forKey: Key.hudFontSize)
        }
    }

    public var hudDensity: HUDDensity {
        didSet {
            defaults.set(hudDensity.rawValue, forKey: Key.hudDensity)
        }
    }

    public var translationScope: CandidateTranslationScope {
        didSet {
            defaults.set(
                translationScope.rawValue,
                forKey: Key.translationScope
            )
            translationScopeDidChange?(translationScope)
        }
    }

    public var hudAppearance: HUDAppearance {
        HUDAppearance(
            backgroundStyle: hudBackgroundStyle,
            textColor: hudTextColor,
            backgroundColor: hudBackgroundColor,
            usesCustomTextColor: hudUsesCustomTextColor,
            fontSize: hudFontSize,
            density: hudDensity
        )
    }

    public func setHUDTextColor(_ color: HUDColor) {
        hudTextColor = color
        hudUsesCustomTextColor = true
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPosition = defaults.string(forKey: Key.position)
        self.position = HUDPosition(rawValue: storedPosition ?? "") ?? .automatic

        let storedDwellDuration = defaults.object(
            forKey: Key.candidateDwellDuration
        ) as? Double
        let dwellDuration = min(
            max(storedDwellDuration ?? 0.12, 0.08),
            0.3
        )
        if storedDwellDuration != dwellDuration {
            defaults.set(dwellDuration, forKey: Key.candidateDwellDuration)
        }
        self.candidateDwellDuration = dwellDuration

        let storedSpacing = defaults.object(forKey: Key.candidateSpacing) as? Double
        self.candidateSpacing = min(max(storedSpacing ?? 8, 0), 24)

        let legacyAppearanceMode = defaults.string(
            forKey: Key.legacyHUDAppearanceMode
        )
        let wasLegacyCustom = legacyAppearanceMode == "custom"
        let appearanceSchemaVersion = defaults.integer(
            forKey: Key.hudAppearanceSchemaVersion
        )
        let storedUsesGlass = defaults.object(
            forKey: Key.hudUsesGlass
        ) as? Bool
        let storedGlassAppearance = defaults.string(
            forKey: Key.hudGlassAppearance
        )
        let storedBackgroundStyle = defaults.string(
            forKey: Key.hudBackgroundStyle
        )
        let backgroundStyle: HUDBackgroundStyle = if appearanceSchemaVersion >= 2,
            let storedBackgroundStyle,
            let style = HUDBackgroundStyle(rawValue: storedBackgroundStyle) {
            style
        } else if wasLegacyCustom || storedUsesGlass == false {
            .solid
        } else if storedGlassAppearance == "light" {
            .systemCandidate
        } else {
            .darkGlass
        }
        self.hudBackgroundStyle = backgroundStyle

        let storedUsesCustomTextColor = defaults.object(
            forKey: Key.hudUsesCustomTextColor
        ) as? Bool
        self.hudUsesCustomTextColor = storedUsesCustomTextColor
            ?? wasLegacyCustom

        let storedOpacity = defaults.object(
            forKey: Key.legacyHUDOpacity
        ) as? Double
        let storedGlassOpacity = defaults.object(
            forKey: Key.hudGlassOpacity
        ) as? Double
        let storedSolidOpacity = defaults.object(
            forKey: Key.hudSolidOpacity
        ) as? Double
        self.hudGlassOpacity = Self.clampedOpacity(
            storedGlassOpacity
                ?? (backgroundStyle == .solid ? 0.9 : storedOpacity ?? 0.9)
        )
        self.hudSolidOpacity = Self.clampedOpacity(
            storedSolidOpacity
                ?? (wasLegacyCustom ? storedOpacity ?? 0.8 : 0.8)
        )

        self.hudTextColor = Self.storedColor(
            forKey: Key.hudTextColor,
            defaults: defaults
        ) ?? HUDAppearance.defaultTextColor
        self.hudBackgroundColor = Self.storedColor(
            forKey: Key.hudBackgroundColor,
            defaults: defaults
        ) ?? HUDAppearance.defaultBackgroundColor
        let storedFontSize = defaults.object(
            forKey: Key.hudFontSize
        ) as? Double
        self.hudFontSize = Self.clampedFontSize(storedFontSize ?? 14)
        let storedDensity = defaults.string(forKey: Key.hudDensity)
        self.hudDensity = HUDDensity(
            rawValue: storedDensity ?? ""
        ) ?? .standard

        let storedTranslationScope = defaults.string(
            forKey: Key.translationScope
        )
        self.translationScope = CandidateTranslationScope(
            rawValue: storedTranslationScope ?? ""
        ) ?? .selected

        defaults.set(2, forKey: Key.hudAppearanceSchemaVersion)
        defaults.set(
            self.hudBackgroundStyle.rawValue,
            forKey: Key.hudBackgroundStyle
        )
        defaults.set(
            self.hudBackgroundStyle != .solid,
            forKey: Key.hudUsesGlass
        )
        defaults.set(
            self.hudBackgroundStyle == .systemCandidate ? "light" : "dark",
            forKey: Key.hudGlassAppearance
        )
        defaults.set(
            self.hudUsesCustomTextColor,
            forKey: Key.hudUsesCustomTextColor
        )
        defaults.set(self.hudGlassOpacity, forKey: Key.hudGlassOpacity)
        defaults.set(self.hudSolidOpacity, forKey: Key.hudSolidOpacity)
    }

    public func resetHUDAppearance() {
        hudBackgroundStyle = .darkGlass
        hudUsesCustomTextColor = false
        hudTextColor = HUDAppearance.defaultTextColor
        hudBackgroundColor = HUDAppearance.defaultBackgroundColor
        hudGlassOpacity = 0.9
        hudSolidOpacity = 0.8
        hudFontSize = 14
        hudDensity = .standard
    }

    private func persist(_ color: HUDColor, forKey key: String) {
        guard let data = try? JSONEncoder().encode(color) else { return }
        defaults.set(data, forKey: key)
    }

    private static func storedColor(
        forKey key: String,
        defaults: UserDefaults
    ) -> HUDColor? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HUDColor.self, from: data)
    }

    private static func clampedFontSize(_ value: Double) -> Double {
        guard value.isFinite else { return 14 }
        return min(
            max(value, HUDAppearance.fontSizeRange.lowerBound),
            HUDAppearance.fontSizeRange.upperBound
        )
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.9 }
        return min(max(value, 0.4), 1.0)
    }
}
