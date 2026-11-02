import XCTest

@testable import GlintUI

final class AppUpdateVersionTests: XCTestCase {
    func testReleaseVersionComparesNumericComponentsAndAcceptsVTagPrefix() {
        XCTAssertTrue(
            AppUpdateVersion.isNewer("v0.7.10", than: "0.7.9")
        )
        XCTAssertTrue(AppUpdateVersion.isNewer("0.8", than: "0.7.5"))
        XCTAssertFalse(AppUpdateVersion.isNewer("v0.7.5", than: "0.7.5"))
    }

    func testDisplayVersionRemovesReleaseTagPrefix() {
        XCTAssertEqual(
            AppUpdateVersion.displayVersion(" v0.8.0 "),
            "0.8.0"
        )
        XCTAssertEqual(AppUpdateVersion.displayVersion("0.8.0"), "0.8.0")
    }
}
