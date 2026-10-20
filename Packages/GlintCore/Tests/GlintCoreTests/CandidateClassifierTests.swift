import XCTest
@testable import GlintCore

final class CandidateClassifierTests: XCTestCase {
    func testShortChineseSentenceWithoutPunctuationIsSentence() {
        XCTAssertEqual(
            CandidateClassifier.classify("今天天气不错"),
            .sentence
        )
    }

    func testTwoCharacterTermIsPhrase() {
        XCTAssertEqual(CandidateClassifier.classify("设计"), .phrase)
    }

    func testPunctuationForcesSentence() {
        XCTAssertEqual(CandidateClassifier.classify("你好吗？"), .sentence)
    }

    func testQuestionCueMakesShortTextASentence() {
        XCTAssertEqual(CandidateClassifier.classify("可以吗"), .sentence)
        XCTAssertEqual(CandidateClassifier.classify("这个方案"), .sentence)
    }

    func testWhitespaceSeparatedTextIsASentence() {
        XCTAssertEqual(CandidateClassifier.classify("hello world"), .sentence)
    }

    func testSingleCharacterIsAWord() {
        XCTAssertEqual(CandidateClassifier.classify("好"), .word)
    }

    func testBlankInputIsUnknown() {
        XCTAssertEqual(CandidateClassifier.classify("  \n"), .unknown)
    }
}
