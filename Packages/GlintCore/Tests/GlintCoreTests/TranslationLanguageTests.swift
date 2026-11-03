import XCTest

@testable import GlintCore

final class TranslationLanguageTests: XCTestCase {
    func testTargetRawValuesAreStable() {
        XCTAssertEqual(TranslationTarget.english.rawValue, "en")
        XCTAssertEqual(TranslationTarget.japanese.rawValue, "ja")
    }

    func testDirectionsAreDistinctAndRequestKeepsTarget() {
        let english = TranslationDirection.simplifiedChineseToEnglish
        let japanese = TranslationDirection.simplifiedChineseToJapanese
        XCTAssertNotEqual(english, japanese)

        let request = TranslationRequest(
            candidate: Candidate(text: "你好"),
            direction: japanese
        )
        XCTAssertEqual(request.direction.target, .japanese)
        XCTAssertEqual(request.direction.source, .simplifiedChinese)
    }
}
