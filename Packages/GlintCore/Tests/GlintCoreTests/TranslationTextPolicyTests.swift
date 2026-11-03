import XCTest

@testable import GlintCore

final class TranslationTextPolicyTests: XCTestCase {
    func testEnglishStillRejectsChineseEcho() {
        XCTAssertFalse(
            TranslationTextPolicy.isDisplayable(
                "这是一个测试",
                target: .english
            )
        )
    }

    func testJapaneseAllowsHanAndKana() {
        XCTAssertTrue(
            TranslationTextPolicy.isDisplayable(
                "学生",
                target: .japanese
            )
        )
        XCTAssertTrue(
            TranslationTextPolicy.isDisplayable(
                "天気がいい",
                target: .japanese
            )
        )
    }

    func testBothTargetsRejectNewlinesAndOverlongText() {
        for target in TranslationTarget.allCases {
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    "first\nsecond",
                    target: target
                )
            )
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    String(repeating: "a", count: 49),
                    target: target
                )
            )
        }
    }
}
