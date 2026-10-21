import CoreGraphics
import Foundation

public enum CandidateActivity: Equatable, Sendable {
    case observing(revision: UInt64)
    case changed(revision: UInt64)
    case dwelling(revision: UInt64)
}

/// Tracks whether the focused input-method candidate has stopped changing.
///
/// Timestamps use a monotonic clock supplied by the caller. Keeping time as an
/// injected value makes the dwell rules deterministic in tests.
public struct TypingActivityTracker: Sendable {
    private struct CandidateSample: Equatable, Sendable {
        let text: String
        let highlightRect: CGRect
    }

    public private(set) var revision: UInt64 = 0
    public private(set) var isDwelling = false

    private let positionTolerance: CGFloat
    private var sample: CandidateSample?
    private var changeTimestamp: UInt64 = 0
    private var consecutiveMatches = 0

    public init(positionTolerance: CGFloat = 2) {
        self.positionTolerance = max(0, positionTolerance)
    }

    @discardableResult
    public mutating func observe(
        text: String,
        highlightRect: CGRect,
        timestamp: UInt64,
        dwellDurationNanoseconds: UInt64
    ) -> CandidateActivity {
        let nextSample = CandidateSample(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            highlightRect: highlightRect
        )

        guard let sample else {
            return beginRevision(
                nextSample,
                timestamp: timestamp
            )
        }

        guard Self.matches(
            sample,
            nextSample,
            tolerance: positionTolerance
        ) else {
            return beginRevision(
                nextSample,
                timestamp: timestamp
            )
        }

        self.sample = nextSample
        consecutiveMatches += 1
        let elapsed = timestamp >= changeTimestamp
            ? timestamp - changeTimestamp
            : 0

        if !isDwelling,
           consecutiveMatches >= 2,
           elapsed >= dwellDurationNanoseconds {
            isDwelling = true
            return .dwelling(revision: revision)
        }
        return .observing(revision: revision)
    }

    public mutating func reset() {
        if sample != nil {
            revision &+= 1
        }
        sample = nil
        changeTimestamp = 0
        consecutiveMatches = 0
        isDwelling = false
    }

    private mutating func beginRevision(
        _ sample: CandidateSample,
        timestamp: UInt64
    ) -> CandidateActivity {
        revision &+= 1
        self.sample = sample
        changeTimestamp = timestamp
        consecutiveMatches = 1
        isDwelling = false
        return .changed(revision: revision)
    }

    private static func matches(
        _ lhs: CandidateSample,
        _ rhs: CandidateSample,
        tolerance: CGFloat
    ) -> Bool {
        lhs.text == rhs.text
            && abs(lhs.highlightRect.minX - rhs.highlightRect.minX) <= tolerance
            && abs(lhs.highlightRect.minY - rhs.highlightRect.minY) <= tolerance
            && abs(lhs.highlightRect.width - rhs.highlightRect.width) <= tolerance
            && abs(lhs.highlightRect.height - rhs.highlightRect.height) <= tolerance
    }
}
