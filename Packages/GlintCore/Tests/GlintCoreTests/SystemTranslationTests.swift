import XCTest
@testable import GlintCore

final class SystemTranslationTests: XCTestCase {
    func testOnlyInstalledAvailabilityCanBeSelected() {
        XCTAssertFalse(
            SystemTranslationAvailability.unsupported.canSelect
        )
        XCTAssertFalse(
            SystemTranslationAvailability.available.canSelect
        )
        XCTAssertFalse(
            SystemTranslationAvailability.installing.canSelect
        )
        XCTAssertTrue(
            SystemTranslationAvailability.installed.canSelect
        )
        XCTAssertFalse(
            SystemTranslationAvailability.failed("失败").canSelect
        )
    }
}
