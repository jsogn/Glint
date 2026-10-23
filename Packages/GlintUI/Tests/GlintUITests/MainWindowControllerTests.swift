import AppKit
import XCTest

@testable import GlintUI

final class MainWindowControllerTests: XCTestCase {
    @MainActor
    func testWindowSizeCannotCollapseBelowOverviewMinimum() {
        let clamped = MainWindowController.clampedWindowSize(
            NSSize(width: 578, height: 660)
        )

        XCTAssertEqual(clamped.width, 1_040)
        XCTAssertEqual(clamped.height, 660)
    }
}
