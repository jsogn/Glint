import CoreGraphics
import GlintCore

extension MonitoringController {
    struct CandidateObservation {
        let snapshot: AXCandidateSnapshot
        let selectedFrame: CGRect
        let displayFrame: CGRect
        let displayAnchor: CandidateRegion
        let candidateSurfaceFrame: CGRect?
        let candidateLayoutOrientation: CandidateLayoutOrientation
    }

    enum CandidateReadOutcome {
        case found(CandidateObservation)
        case miss(
            status: String,
            reason: AXCandidateReadMissReason
        )
    }

    enum TickGate<Value> {
        case poll(UInt64)
        case ready(Value)
    }

    struct CandidateSelectionContext {
        let candidates: [Candidate]
        let selectedIndex: Int
        let previousSelectedIndex: Int?
        let selectionIsExact: Bool
        let displayAnchor: CandidateRegion
        let trackingText: String
        let trackingFrame: CGRect
    }

    struct CandidateActivityContext {
        let selection: CandidateSelectionContext
        let activity: CandidateActivity
        let timestamp: UInt64
        let changed: Bool
        let inputCaretRect: CGRect?
        let inputFieldRect: CGRect?
        let candidateSurfaceRect: CGRect?
        let candidateLayoutOrientation: CandidateLayoutOrientation
    }

    struct CandidateLayoutSnapshot: Equatable {
        let highlight: CandidateRegion
        let inputCaretRect: CGRect?
        let inputFieldRect: CGRect?
        let candidateSurfaceRect: CGRect?
        let candidateLayoutOrientation: CandidateLayoutOrientation

        func approximatelyEquals(
            _ other: Self,
            tolerance: CGFloat
        ) -> Bool {
            let highlightMatches =
                abs(highlight.x - other.highlight.x) <= tolerance
                && abs(highlight.y - other.highlight.y) <= tolerance
                && abs(highlight.width - other.highlight.width)
                    <= tolerance
                && abs(highlight.height - other.highlight.height)
                    <= tolerance
            return highlightMatches
                && Self.rect(
                    inputCaretRect,
                    approximatelyEquals: other.inputCaretRect,
                    tolerance: tolerance
                )
                && Self.rect(
                    inputFieldRect,
                    approximatelyEquals: other.inputFieldRect,
                    tolerance: tolerance
                )
                && Self.rect(
                    candidateSurfaceRect,
                    approximatelyEquals:
                        other.candidateSurfaceRect,
                    tolerance: tolerance
                )
                && candidateLayoutOrientation
                    == other.candidateLayoutOrientation
        }

        private static func rect(
            _ lhs: CGRect?,
            approximatelyEquals rhs: CGRect?,
            tolerance: CGFloat
        ) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                return true
            case (let lhs?, let rhs?):
                return abs(lhs.minX - rhs.minX) <= tolerance
                    && abs(lhs.minY - rhs.minY) <= tolerance
                    && abs(lhs.width - rhs.width) <= tolerance
                    && abs(lhs.height - rhs.height) <= tolerance
            default:
                return false
            }
        }
    }

    struct HostAccessibilityAttempt {
        let timestamp: UInt64
        let outcome: HostAccessibilityActivation
    }
}
