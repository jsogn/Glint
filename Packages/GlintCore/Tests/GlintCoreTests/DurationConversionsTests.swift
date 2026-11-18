import XCTest

@testable import GlintCore

final class DurationConversionsTests: XCTestCase {
    func testConvertsSecondsAndAttoseconds() {
        XCTAssertEqual(Duration.zero.inMilliseconds, 0)
        XCTAssertEqual(
            Duration.microseconds(1_500).inMilliseconds,
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            (Duration.seconds(2) + .milliseconds(750)).inMilliseconds,
            2_750,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            Duration.milliseconds(1_500).inSeconds,
            1.5,
            accuracy: 0.000_001
        )
    }
}
