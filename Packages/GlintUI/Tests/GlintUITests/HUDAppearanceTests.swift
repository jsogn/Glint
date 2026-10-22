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

    func testDefaultCustomColorsMeetContrastTarget() {
        let appearance = HUDAppearance(
            mode: .custom,
            textColor: HUDAppearance.defaultTextColor,
            backgroundColor: HUDAppearance.defaultBackgroundColor
        )

        XCTAssertGreaterThanOrEqual(
            appearance.textColor.contrastRatio(
                with: appearance.backgroundColor
            ),
            4.5
        )
        XCTAssertFalse(appearance.customColorsHaveLowContrast)
    }

    func testLowContrastCustomColorsAreDetected() {
        let appearance = HUDAppearance(
            mode: .custom,
            textColor: HUDColor(red: 0.5, green: 0.5, blue: 0.5),
            backgroundColor: HUDColor(red: 0.6, green: 0.6, blue: 0.6)
        )

        XCTAssertTrue(appearance.customColorsHaveLowContrast)
    }

    func testFontSizeIsClampedToSupportedRange() {
        XCTAssertEqual(HUDAppearance(fontSize: 8).fontSize, 12)
        XCTAssertEqual(HUDAppearance(fontSize: 30).fontSize, 18)
    }
}
