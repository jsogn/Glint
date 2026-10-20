import XCTest
@testable import GlintCore

final class TranslationResultTests: XCTestCase {
    func testOptionsAreSortedAndDeduplicated() {
        let result = TranslationResult(
            options: [
                TranslationOption(text: "plan", score: 0.6),
                TranslationOption(text: "design", score: 0.9),
                TranslationOption(text: "Design", score: 0.5),
                TranslationOption(text: "layout", score: 0.7),
            ],
            source: .dictionary,
            confidence: 0.9
        )

        XCTAssertEqual(result.text, "design")
        XCTAssertEqual(result.displayText, "design · layout · plan")
        XCTAssertEqual(result.options.count, 3)
    }
}
