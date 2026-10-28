import Foundation
import XCTest
@testable import GlintUI

final class HUDAppearanceTests: XCTestCase {
    func testSelectedTranslationSpacingIsClamped() {
        XCTAssertEqual(
            HUDAppearance(selectedTranslationSpacing: 2)
                .selectedTranslationSpacing,
            8
        )
        XCTAssertEqual(
            HUDAppearance(selectedTranslationSpacing: 30)
                .selectedTranslationSpacing,
            24
        )
    }

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

    func testDecodedColorComponentsAreClamped() throws {
        let data = Data(
            #"{"red":2,"green":-1,"blue":0.5}"#.utf8
        )

        let color = try JSONDecoder().decode(HUDColor.self, from: data)

        XCTAssertEqual(color.red, 1)
        XCTAssertEqual(color.green, 0)
        XCTAssertEqual(color.blue, 0.5)
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
