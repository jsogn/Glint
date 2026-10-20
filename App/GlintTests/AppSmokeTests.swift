import XCTest
import GlintCore

final class AppSmokeTests: XCTestCase {
    func testCandidateModel() {
        let candidate = Candidate(text: "你好", kind: .word)
        XCTAssertEqual(candidate.text, "你好")
        XCTAssertEqual(candidate.kind, .word)
    }
}
