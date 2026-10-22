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

    public var translationScope: CandidateTranslationScope {
        didSet {
            defaults.set(
                translationScope.rawValue,
                forKey: Key.translationScope
            )
            translationScopeDidChange?(translationScope)
        }
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

        let storedTranslationScope = defaults.string(
            forKey: Key.translationScope
        )
        self.translationScope = CandidateTranslationScope(
            rawValue: storedTranslationScope ?? ""
        ) ?? .selected
    }
}
