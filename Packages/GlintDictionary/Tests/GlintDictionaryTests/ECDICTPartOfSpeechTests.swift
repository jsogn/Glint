import XCTest
@testable import GlintDictionary
import GlintCore

final class ECDICTPartOfSpeechTests: XCTestCase {
    func testParsesCommonDefinitionLabels() {
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("n. 设计, 图样").partOfSpeech,
            .noun
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("vt. 打开, 公开").partOfSpeech,
            .verb
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("a. 开着的").partOfSpeech,
            .adjective
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.parseLine("prep. 关于").partOfSpeech,
            .preposition
        )
    }

    func testUnknownAndUnlabelledLinesKeepBody() {
        let unknown = ECDICTPartOfSpeech.parseLine(
            "abbr. 缩写"
        )
        XCTAssertNil(unknown.partOfSpeech)
        XCTAssertEqual(unknown.body, "缩写")

        let plain = ECDICTPartOfSpeech.parseLine("[计] 打开指令")
        XCTAssertNil(plain.partOfSpeech)
        XCTAssertEqual(plain.body, "[计] 打开指令")
    }

    func testSelectionUsesFirstTwoThenCanonicalOrder() {
        XCTAssertEqual(
            ECDICTPartOfSpeech.select([.verb, .noun]),
            [.noun, .verb]
        )
        XCTAssertEqual(
            ECDICTPartOfSpeech.select([.verb, .noun, .adjective]),
            [.noun, .verb]
        )
    }

    func testEncodingRoundTripIsCompactAndStable() {
        let encoded = ECDICTPartOfSpeech.encode([.adjective, .noun])
        XCTAssertEqual(encoded, "noun/adjective")
        XCTAssertEqual(
            ECDICTPartOfSpeech.decode(encoded),
            [.noun, .adjective]
        )
        XCTAssertEqual(ECDICTPartOfSpeech.decode(""), [])
        XCTAssertEqual(ECDICTPartOfSpeech.decode("bad"), [])
    }

    func testEnglishKeysAreExactAndSingleWordOnly() {
        XCTAssertEqual(
            ECDICTPartOfSpeech.englishKey(for: " Well-Known "),
            "well-known"
        )
        XCTAssertNil(
            ECDICTPartOfSpeech.englishKey(for: "bullet screen")
        )
    }
}
