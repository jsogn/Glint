import XCTest
@testable import GlintCore

final class DictionarySurfaceTests: XCTestCase {
    func testRemovesParentheticalMetadataAndUnclosedTail() {
        XCTAssertEqual(
            DictionarySurface.normalize(
                "(fig.) to look after (children)"
            ),
            "look after"
        )
        XCTAssertEqual(
            DictionarySurface.normalize(
                "exploit (a resource"
            ),
            "exploit"
        )
        XCTAssertEqual(
            DictionarySurface.normalize("English language (especially written)"),
            "English language"
        )
    }

    func testSplitsCompoundDictionarySurfaces() {
        XCTAssertEqual(
            DictionarySurface.split("scene; scenario; setting"),
            ["scene", "scenario", "setting"]
        )
    }

    func testRejectsMetadataAndChineseReferences() {
        XCTAssertNil(
            DictionarySurface.normalize("see 上聲|上声[shang3 sheng1]")
        )
        XCTAssertNil(DictionarySurface.normalize("variant of 龐|庞[pang2]"))
        XCTAssertNil(DictionarySurface.normalize("Taiwan pr. [da3]"))
    }

    func testLongerExplanationsReceiveStrongerPenalty() {
        XCTAssertGreaterThan(
            DictionarySurface.penalty(
                for: "to take in and send out in large quantities"
            ),
            DictionarySurface.penalty(for: "throughput")
        )
        XCTAssertGreaterThan(
            DictionarySurface.penalty(for: "surname Pang"),
            DictionarySurface.penalty(for: "enormous")
        )
    }
}
