import XCTest

@testable import GlintCore

final class TranslationLanguageTests: XCTestCase {
    func testTargetRawValuesAreStable() {
        XCTAssertEqual(
            TranslationTarget.allCases.map(\.rawValue),
            ["en", "ja", "es", "fr", "de", "ru"]
        )
        XCTAssertEqual(
            TranslationTarget.allCases.map(\.chineseDisplayName),
            ["英语", "日语", "西班牙语", "法语", "德语", "俄语"]
        )
    }

    func testTargetCapabilitiesStayExplicit() {
        for target in TranslationTarget.allCases {
            let isEnglish = target == .english
            XCTAssertEqual(
                target.supportsDictionaryRouting,
                isEnglish
            )
            XCTAssertEqual(
                target.supportsPartsOfSpeech,
                isEnglish
            )
            XCTAssertEqual(
                target.supportsMultipleMeanings,
                isEnglish
            )
            XCTAssertEqual(
                target.supportsSpeechAccents,
                isEnglish
            )
            XCTAssertEqual(
                target.allowsHanOutput,
                target == .japanese
            )
        }
    }

    func testDirectionsAreDistinctAndRequestKeepsTarget() {
        let directions = TranslationTarget.allCases.map {
            TranslationDirection(target: $0)
        }
        XCTAssertEqual(Set(directions).count, TranslationTarget.allCases.count)

        for (target, direction) in zip(
            TranslationTarget.allCases,
            directions
        ) {
            let request = TranslationRequest(
                candidate: Candidate(text: "你好"),
                direction: direction
            )
            XCTAssertEqual(request.direction.target, target)
            XCTAssertEqual(
                request.direction.source,
                .simplifiedChinese
            )
        }
    }

    func testNewTargetsProvideLocaleAndPromptNames() {
        XCTAssertEqual(
            TranslationTarget.allCases.map(\.speechLocaleIdentifier),
            [
                "en-US",
                "ja-JP",
                "es-ES",
                "fr-FR",
                "de-DE",
                "ru-RU",
            ]
        )
        XCTAssertEqual(
            TranslationTarget.allCases.map(\.englishDisplayName),
            [
                "English",
                "Japanese",
                "Spanish",
                "French",
                "German",
                "Russian",
            ]
        )
    }

    func testReadinessRetainsTargetSpecificState() {
        XCTAssertEqual(
            TranslationReadiness.ready(.japanese),
            .ready(.japanese)
        )
        XCTAssertEqual(
            TranslationReadiness.needsSetup(
                .japanese,
                "需要安装语言包"
            ),
            .needsSetup(.japanese, "需要安装语言包")
        )
    }
}
