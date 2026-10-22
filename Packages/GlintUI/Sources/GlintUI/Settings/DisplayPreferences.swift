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
        static let hudOpacity = "display.hudOpacity"
        static let hudAppearanceMode = "display.hudAppearanceMode"
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
            let clamped = min(max(candidateDwellDuration, 0.05), 0.3)
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

    public var hudOpacity: Double {
        didSet {
            let clamped = min(max(hudOpacity, 0.4), 1.0)
            if clamped != hudOpacity {
                hudOpacity = clamped
                return
            }
            defaults.set(clamped, forKey: Key.hudOpacity)
        }
    }

    public var hudAppearanceMode: HUDAppearanceMode {
        didSet {
            defaults.set(
                hudAppearanceMode.rawValue,
                forKey: Key.hudAppearanceMode
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
            mode: hudAppearanceMode,
            textColor: hudTextColor,
            backgroundColor: hudBackgroundColor,
            fontSize: hudFontSize,
            density: hudDensity
        )
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPosition = defaults.string(forKey: Key.position)
        self.position = HUDPosition(rawValue: storedPosition ?? "") ?? .automatic

        let storedDwellDuration = defaults.object(
            forKey: Key.candidateDwellDuration
        ) as? Double
        self.candidateDwellDuration = min(
            max(storedDwellDuration ?? 0.12, 0.05),
            0.3
        )

        let storedSpacing = defaults.object(forKey: Key.candidateSpacing) as? Double
        self.candidateSpacing = min(max(storedSpacing ?? 8, 0), 24)

        let storedOpacity = defaults.object(forKey: Key.hudOpacity) as? Double
        self.hudOpacity = min(max(storedOpacity ?? 0.92, 0.4), 1.0)

        let storedAppearanceMode = defaults.string(
            forKey: Key.hudAppearanceMode
        )
        self.hudAppearanceMode = HUDAppearanceMode(
            rawValue: storedAppearanceMode ?? ""
        ) ?? .system
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
    }

    public func resetHUDAppearance() {
        hudAppearanceMode = .system
        hudTextColor = HUDAppearance.defaultTextColor
        hudBackgroundColor = HUDAppearance.defaultBackgroundColor
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
}
