import XCTest

@testable import GlintCore

final class TranslationTextPolicyTests: XCTestCase {
    func testNonJapaneseTargetsRejectChineseEcho() {
        for target in TranslationTarget.allCases
        where target != .japanese {
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    "这是一个测试",
                    target: target
                )
            )
        }
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

    func testAllTargetsRejectNewlines() {
        for target in TranslationTarget.allCases {
            XCTAssertFalse(
                TranslationTextPolicy.isDisplayable(
                    "first\nsecond",
                    target: target
                )
            )
        }
    }

    func testLongSentenceTranslationIsDisplayable() {
        let sentence =
            "The weather is nice today. What are you going to eat?"

        XCTAssertGreaterThan(sentence.count, 48)
        XCTAssertTrue(
            TranslationTextPolicy.isDisplayable(
                sentence,
                target: .english
            )
        )
    }

    func testSpanishFrenchGermanAndRussianOutputIsDisplayable() {
        let samples: [TranslationTarget: String] = [
            .spanish: "Hola, ¿cómo estás?",
            .french: "Bonjour, comment allez-vous ?",
            .german: "Hallo, wie geht es dir?",
            .russian: "Здравствуйте, как дела?",
        ]

        for (target, text) in samples {
            XCTAssertTrue(
                TranslationTextPolicy.isDisplayable(
                    text,
                    target: target
                )
            )
        }
    }
}
