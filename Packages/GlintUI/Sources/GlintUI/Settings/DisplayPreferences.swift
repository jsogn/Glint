import Foundation
import GlintCore
import Observation

@MainActor
@Observable
public final class DisplayPreferences {
    public static let maximumTranslationCountRange = 1...9

    private enum Key {
        static let candidateDwellDuration = "display.candidateDwellDuration"
        static let candidateSpacing = "display.candidateSpacing"
        static let hudBackgroundStyle = "display.hudBackgroundStyle"
        static let hudUsesCustomTextColor = "display.hudUsesCustomTextColor"
        static let hudGlassOpacity = "display.hudGlassOpacity"
        static let hudSolidOpacity = "display.hudSolidOpacity"
        static let hudTextColor = "display.hudTextColor"
        static let hudBackgroundColor = "display.hudBackgroundColor"
        static let hudFontSize = "display.hudFontSize"
        static let hudDensity = "display.hudDensity"
        static let hudSelectedTranslationSpacing =
            "display.hudSelectedTranslationSpacing"
        static let translationScope = "display.translationScope"
        static let maximumTranslationCount =
            "display.maximumTranslationCount"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    @ObservationIgnored
    public var candidateDwellDurationDidChange: (@MainActor (Double) -> Void)?
    @ObservationIgnored
    public var translationScopeDidChange: (@MainActor (CandidateTranslationScope) -> Void)?
    @ObservationIgnored
    public var maximumTranslationCountDidChange: (@MainActor (Int) -> Void)?

    public var candidateDwellDuration: Double {
        didSet {
            let clamped = Self.clampedDwellDuration(candidateDwellDuration)
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
            let clamped = Self.clampedSpacing(candidateSpacing)
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

    public var hudSelectedTranslationSpacing: Double {
        didSet {
            let clamped = Self.clampedSelectedTranslationSpacing(
                hudSelectedTranslationSpacing
            )
            if clamped != hudSelectedTranslationSpacing {
                hudSelectedTranslationSpacing = clamped
                return
            }
            defaults.set(
                clamped,
                forKey: Key.hudSelectedTranslationSpacing
            )
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

    public var maximumTranslationCount: Int {
        didSet {
            let clamped = Self.clampedMaximumTranslationCount(
                maximumTranslationCount
            )
            if clamped != maximumTranslationCount {
                maximumTranslationCount = clamped
                return
            }
            defaults.set(
                clamped,
                forKey: Key.maximumTranslationCount
            )
            maximumTranslationCountDidChange?(clamped)
        }
    }

    public var hudAppearance: HUDAppearance {
        HUDAppearance(
            backgroundStyle: hudBackgroundStyle,
            textColor: hudTextColor,
            backgroundColor: hudBackgroundColor,
            usesCustomTextColor: hudUsesCustomTextColor,
            fontSize: hudFontSize,
            density: hudDensity,
            selectedTranslationSpacing: hudSelectedTranslationSpacing
        )
    }

    public func setHUDTextColor(_ color: HUDColor) {
        hudTextColor = color
        hudUsesCustomTextColor = true
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedDwellDuration =
            defaults.object(
                forKey: Key.candidateDwellDuration
            ) as? Double
        let dwellDuration = Self.clampedDwellDuration(
            storedDwellDuration ?? 0.12
        )
        if storedDwellDuration != dwellDuration {
            defaults.set(dwellDuration, forKey: Key.candidateDwellDuration)
        }
        self.candidateDwellDuration = dwellDuration

        let storedSpacing = defaults.object(forKey: Key.candidateSpacing) as? Double
        self.candidateSpacing = Self.clampedSpacing(storedSpacing ?? 8)

        let storedBackgroundStyle = defaults.string(
            forKey: Key.hudBackgroundStyle
        )
        self.hudBackgroundStyle =
            storedBackgroundStyle.flatMap(
                HUDBackgroundStyle.init(rawValue:)
            ) ?? .darkGlass

        let storedUsesCustomTextColor =
            defaults.object(
                forKey: Key.hudUsesCustomTextColor
            ) as? Bool
        self.hudUsesCustomTextColor = storedUsesCustomTextColor ?? false

        let storedGlassOpacity =
            defaults.object(
                forKey: Key.hudGlassOpacity
            ) as? Double
        let storedSolidOpacity =
            defaults.object(
                forKey: Key.hudSolidOpacity
            ) as? Double
        self.hudGlassOpacity = Self.clampedOpacity(
            storedGlassOpacity ?? 0.8
        )
        self.hudSolidOpacity = Self.clampedOpacity(
            storedSolidOpacity ?? 0.8
        )

        self.hudTextColor =
            Self.storedColor(
                forKey: Key.hudTextColor,
                defaults: defaults
            ) ?? HUDAppearance.defaultTextColor
        self.hudBackgroundColor =
            Self.storedColor(
                forKey: Key.hudBackgroundColor,
                defaults: defaults
            ) ?? HUDAppearance.defaultBackgroundColor
        let storedFontSize =
            defaults.object(
                forKey: Key.hudFontSize
            ) as? Double
        self.hudFontSize = Self.clampedFontSize(storedFontSize ?? 14)
        let storedDensity = defaults.string(forKey: Key.hudDensity)
        self.hudDensity =
            HUDDensity(
                rawValue: storedDensity ?? ""
            ) ?? .standard
        let storedSelectedTranslationSpacing =
            defaults.object(
                forKey: Key.hudSelectedTranslationSpacing
            ) as? Double
        self.hudSelectedTranslationSpacing =
            Self.clampedSelectedTranslationSpacing(
                storedSelectedTranslationSpacing ?? 14
            )

        let storedTranslationScope = defaults.string(
            forKey: Key.translationScope
        )
        self.translationScope =
            CandidateTranslationScope(
                rawValue: storedTranslationScope ?? ""
            ) ?? .selected
        let storedMaximumTranslationCount =
            defaults.object(
                forKey: Key.maximumTranslationCount
            ) as? Int
        self.maximumTranslationCount =
            Self.clampedMaximumTranslationCount(
                storedMaximumTranslationCount ?? 4
            )
    }

    public func resetHUDAppearance() {
        hudBackgroundStyle = .darkGlass
        hudUsesCustomTextColor = false
        hudTextColor = HUDAppearance.defaultTextColor
        hudBackgroundColor = HUDAppearance.defaultBackgroundColor
        hudGlassOpacity = 0.8
        hudSolidOpacity = 0.8
        hudFontSize = 14
        hudDensity = .standard
        hudSelectedTranslationSpacing = 14
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

    private static func clampedDwellDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 0.12 }
        return min(max(value, 0.08), 0.3)
    }

    private static func clampedSpacing(_ value: Double) -> Double {
        guard value.isFinite else { return 8 }
        return min(max(value, 0), 24)
    }

    private static func clampedSelectedTranslationSpacing(
        _ value: Double
    ) -> Double {
        guard value.isFinite else { return 14 }
        return min(
            max(
                value,
                HUDAppearance.selectedTranslationSpacingRange.lowerBound
            ),
            HUDAppearance.selectedTranslationSpacingRange.upperBound
        )
    }

    private static func clampedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.8 }
        return min(max(value, 0.4), 1.0)
    }

    private static func clampedMaximumTranslationCount(
        _ value: Int
    ) -> Int {
        min(
            max(value, maximumTranslationCountRange.lowerBound),
            maximumTranslationCountRange.upperBound
        )
    }
}
