import XCTest
import GlintCore
@testable import GlintInference

final class PlaceholderTranslationEngineTests: XCTestCase {
    func testPlaceholderReturnsNoResult() async throws {
        let engine = PlaceholderTranslationEngine()
        let result = try await engine.translate(Candidate(text: "你好吗", kind: .sentence))
        XCTAssertNil(result)
    }
}
