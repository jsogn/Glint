import XCTest
@testable import GlintUI

final class HUDAppearanceTests: XCTestCase {
    func testBackgroundStyleTitlesStaySimple() {
        XCTAssertEqual(
            HUDBackgroundStyle.allCases.map(\.title),
            ["玻璃", "纯色"]
        )
    }

    func testColorComponentsAreClampedToValidRange() {
        let color = HUDColor(
            red: -1,
            green: 2,
            blue: .nan
        )

        XCTAssertEqual(color.red, 0)
        XCTAssertEqual(color.green, 1)
        XCTAssertEqual(color.blue, 0)
    }

    func testAutomaticTextColorUsesDefaultTextColor() {
        let darkGlass = HUDAppearance()

        XCTAssertEqual(
            darkGlass.effectiveTextColor,
            HUDAppearance.defaultTextColor
        )
    }

    func testFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(HUDAppearance(fontSize: 8).fontSize, 12)
        XCTAssertEqual(HUDAppearance(fontSize: 30).fontSize, 18)
    }
}
