import CoreGraphics
import XCTest
@testable import GlintCore

final class TypingActivityTrackerTests: XCTestCase {
    private let rect = CGRect(x: 100, y: 100, width: 42, height: 24)

    func testRapidCandidateChangesNeverDwell() {
        var tracker = TypingActivityTracker()
        let dwellDuration: UInt64 = 120_000_000

        for index in 0..<40 {
            let activity = tracker.observe(
                text: "候选\(index)",
                highlightRect: rect,
                timestamp: UInt64(index) * 50_000_000,
                dwellDurationNanoseconds: dwellDuration
            )
            if case .dwelling = activity {
                XCTFail("Rapid candidate changes must not dwell")
            }
        }

        XCTAssertFalse(tracker.isDwelling)
    }

    func testStableCandidateDwellsOnceAfterThreshold() {
        var tracker = TypingActivityTracker()
        let dwellDuration: UInt64 = 120_000_000

        XCTAssertEqual(
            tracker.observe(
                text: "你好",
                highlightRect: rect,
                timestamp: 1_000,
                dwellDurationNanoseconds: dwellDuration
            ),
            .changed(revision: 1)
        )
        XCTAssertEqual(
            tracker.observe(
                text: "你好",
                highlightRect: rect,
                timestamp: 61_000_000,
                dwellDurationNanoseconds: dwellDuration
            ),
            .observing(revision: 1)
        )
        XCTAssertEqual(
            tracker.observe(
                text: "你好",
                highlightRect: rect,
                timestamp: 121_000_000,
                dwellDurationNanoseconds: dwellDuration
            ),
            .dwelling(revision: 1)
        )
        XCTAssertEqual(
            tracker.observe(
                text: "你好",
                highlightRect: rect,
                timestamp: 181_000_000,
                dwellDurationNanoseconds: dwellDuration
            ),
            .observing(revision: 1)
        )
    }

    func testHighlightMovementStartsNewRevision() {
        var tracker = TypingActivityTracker(positionTolerance: 2)

        _ = tracker.observe(
            text: "你好",
            highlightRect: rect,
            timestamp: 0,
            dwellDurationNanoseconds: 100_000_000
        )

        XCTAssertEqual(
            tracker.observe(
                text: "你好",
                highlightRect: rect.offsetBy(dx: 3, dy: 0),
                timestamp: 60_000_000,
                dwellDurationNanoseconds: 100_000_000
            ),
            .changed(revision: 2)
        )
    }

    func testNanosecondsUntilDwellTargetsExactDeadline() {
        var tracker = TypingActivityTracker()
        let dwell: UInt64 = 50_000_000

        _ = tracker.observe(
            text: "学习",
            highlightRect: rect,
            timestamp: 0,
            dwellDurationNanoseconds: dwell
        )
        _ = tracker.observe(
            text: "学习",
            highlightRect: rect,
            timestamp: 24_000_000,
            dwellDurationNanoseconds: dwell
        )

        XCTAssertEqual(
            tracker.nanosecondsUntilDwell(
                at: 24_000_000,
                dwellDurationNanoseconds: dwell
            ),
            26_000_000
        )
        XCTAssertEqual(
            tracker.nanosecondsUntilDwell(
                at: 48_000_000,
                dwellDurationNanoseconds: dwell
            ),
            2_000_000
        )
        XCTAssertEqual(
            tracker.observe(
                text: "学习",
                highlightRect: rect,
                timestamp: 50_000_000,
                dwellDurationNanoseconds: dwell
            ),
            .dwelling(revision: 1)
        )
    }

    func testResetInvalidatesActiveRevision() {
        var tracker = TypingActivityTracker()
        _ = tracker.observe(
            text: "你好",
            highlightRect: rect,
            timestamp: 0,
            dwellDurationNanoseconds: 100_000_000
        )

        tracker.reset()

        XCTAssertEqual(tracker.revision, 2)
        XCTAssertFalse(tracker.isDwelling)
    }
}
