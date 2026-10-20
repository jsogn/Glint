import XCTest
import GlintCore
@testable import GlintDictionary

final class CedictDictionaryTests: XCTestCase {
    func testKnownWord() async throws {
        let dictionary = CedictDictionary()
        let result = try await dictionary.lookup(Candidate(text: "你好", kind: .word))
        XCTAssertEqual(result?.text, "hello")
        XCTAssertEqual(result?.source, .dictionary)
    }

    func testAmbiguousWordIsBlocked() async throws {
        let dictionary = CedictDictionary()
        let result = try await dictionary.lookup(Candidate(text: "打", kind: .word))
        XCTAssertNil(result)
    }

    func testUnknownWordReturnsNil() async throws {
        let dictionary = CedictDictionary()
        let result = try await dictionary.lookup(Candidate(text: "不存在", kind: .word))
        XCTAssertNil(result)
    }

    func testMultipleSensesAreRanked() async throws {
        let dictionary = CedictDictionary()
        for word in ["设计", "程序", "运行", "复杂", "结构", "处理"] {
            let result = try await dictionary.lookup(
                Candidate(text: word, kind: .word)
            )
            print("\(word) -> \(result?.displayText ?? "<not found>")")
            XCTAssertGreaterThan(result?.options.count ?? 0, 1)
        }

        let design = try await dictionary.lookup(Candidate(text: "设计"))
        XCTAssertEqual(design?.text, "design")
        XCTAssertTrue(design?.displayText.contains("plan") == true)

        let run = try await dictionary.lookup(Candidate(text: "运行"))
        XCTAssertEqual(run?.text, "run")

        let complex = try await dictionary.lookup(Candidate(text: "复杂"))
        XCTAssertEqual(complex?.text, "complex")
    }

    func testECDICTFallbackReturnsMultipleOptions() async throws {
        let dictionary = ECDICTDictionary()
        let result = try await dictionary.lookup(Candidate(text: "需求"))

        XCTAssertEqual(result?.text, "demand")
        XCTAssertTrue(result?.displayText.contains("requirement") == true)
    }
}
