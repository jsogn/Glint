import XCTest
@testable import GlintUI

final class HUDAppearanceTests: XCTestCase {
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

    func testAutomaticTextColorMatchesSelectedGlassAppearance() {
        let darkGlass = HUDAppearance()
        let lightGlass = HUDAppearance(backgroundStyle: .lightGlass)

        XCTAssertEqual(
            darkGlass.effectiveTextColor,
            HUDAppearance.defaultTextColor
        )
        XCTAssertEqual(
            lightGlass.effectiveTextColor,
            HUDAppearance.defaultLightGlassTextColor
        )
    }

    func testFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(HUDAppearance(fontSize: 8).fontSize, 12)
        XCTAssertEqual(HUDAppearance(fontSize: 30).fontSize, 18)
    }
}
