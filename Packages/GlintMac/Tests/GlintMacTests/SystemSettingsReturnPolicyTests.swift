import XCTest
@testable import GlintMac

final class SystemSettingsReturnPolicyTests: XCTestCase {
    func testDoesNotRestoreWithoutPriorGlintRequest() {
        var policy = SystemSettingsReturnPolicy()

        XCTAssertFalse(
            policy.shouldRestore(
                afterTerminating: "com.apple.systempreferences"
            )
        )
    }

    func testIgnoresUnrelatedApplicationTermination() {
        var policy = SystemSettingsReturnPolicy()
        policy.settingsOpened()

        XCTAssertFalse(
            policy.shouldRestore(afterTerminating: "com.example.other")
        )
        XCTAssertTrue(
            policy.shouldRestore(
                afterTerminating: "com.apple.systempreferences"
            )
        )
    }

    func testRestoresOnceAfterSystemSettingsTerminates() {
        var policy = SystemSettingsReturnPolicy()
        policy.settingsOpened()

        XCTAssertTrue(
            policy.shouldRestore(
                afterTerminating: "com.apple.systempreferences"
            )
        )
        XCTAssertFalse(
            policy.shouldRestore(
                afterTerminating: "com.apple.systempreferences"
            )
        )
    }
}
