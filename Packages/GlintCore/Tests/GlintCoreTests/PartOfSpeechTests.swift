import XCTest
@testable import GlintCore

final class PartOfSpeechTests: XCTestCase {
    func testCanonicalOrderDeduplicatesAndLimitsToTwo() {
        XCTAssertEqual(
            PartOfSpeech.normalized([
                .verb, .adjective, .noun, .verb,
            ]),
            [.noun, .verb]
        )
    }

    func testAccessibilityNamesAndDictionaryTokens() {
        XCTAssertEqual(
            PartOfSpeech.preposition.accessibilityName,
            "preposition"
        )
        XCTAssertEqual(PartOfSpeech("prep."), .preposition)
        XCTAssertEqual(PartOfSpeech("ADJECTIVE"), .adjective)
        XCTAssertNil(PartOfSpeech("unknown"))
    }
}
