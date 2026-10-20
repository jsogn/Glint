import Foundation
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
        static let stabilityDelay = "display.stabilityDelay"
        static let candidateSpacing = "display.candidateSpacing"
        static let hudOpacity = "display.hudOpacity"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    public var position: HUDPosition {
        didSet {
            defaults.set(position.rawValue, forKey: Key.position)
        }
    }

    public var stabilityDelay: Double {
        didSet {
            let clamped = min(max(stabilityDelay, 0.1), 0.8)
            if clamped != stabilityDelay {
                stabilityDelay = clamped
                return
            }
            defaults.set(clamped, forKey: Key.stabilityDelay)
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedPosition = defaults.string(forKey: Key.position)
        self.position = HUDPosition(rawValue: storedPosition ?? "") ?? .automatic

        let storedDelay = defaults.object(forKey: Key.stabilityDelay) as? Double
        self.stabilityDelay = min(max(storedDelay ?? 0.35, 0.1), 0.8)

        let storedSpacing = defaults.object(forKey: Key.candidateSpacing) as? Double
        self.candidateSpacing = min(max(storedSpacing ?? 8, 0), 24)

        let storedOpacity = defaults.object(forKey: Key.hudOpacity) as? Double
        self.hudOpacity = min(max(storedOpacity ?? 0.92, 0.4), 1.0)
    }
}
