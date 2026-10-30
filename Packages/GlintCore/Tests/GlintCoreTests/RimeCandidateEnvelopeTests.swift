import Foundation
import GlintCore
import XCTest

final class RimeCandidateEnvelopeTests: XCTestCase {
    func testDecodesActiveUnicodeCandidatePage() throws {
        let line = Data(
            #"{"version":3,"sessionID":"test-session","sequence":1,"heartbeat":false,"active":true,"schemaID":"luna_pinyin_simp","selectedText":"妳好","selectedIndex":1,"candidates":["你好","妳好"]}"#
                .utf8
        )

        let envelope = try RimeCandidateEnvelope.decode(line: line)

        XCTAssertTrue(envelope.isValid)
        XCTAssertEqual(envelope.sessionID, "test-session")
        XCTAssertEqual(envelope.sequence, 1)
        XCTAssertFalse(envelope.heartbeat)
        XCTAssertEqual(envelope.schemaID, "luna_pinyin_simp")
        XCTAssertEqual(envelope.selectedText, "妳好")
        XCTAssertEqual(envelope.selectedIndex, 1)
        XCTAssertEqual(envelope.candidates, ["你好", "妳好"])
    }

    func testAcceptsSelectedTextWithoutCandidateListIndex() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 1,
            heartbeat: false,
            active: true,
            schemaID: "luna_pinyin_simp",
            selectedText: "你好",
            selectedIndex: nil,
            candidates: []
        )

        XCTAssertTrue(envelope.isValid)
    }

    func testRejectsInvalidSelectedIndex() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 2,
            heartbeat: false,
            active: true,
            schemaID: "luna_pinyin_simp",
            selectedText: "你好",
            selectedIndex: 2,
            candidates: ["你好", "妳好"]
        )

        XCTAssertFalse(envelope.isValid)
    }

    func testRejectsSelectedTextThatDoesNotMatchIndex() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 3,
            heartbeat: false,
            active: true,
            schemaID: "luna_pinyin_simp",
            selectedText: "你好",
            selectedIndex: 1,
            candidates: ["你好", "妳好"]
        )

        XCTAssertFalse(envelope.isValid)
    }

    func testRejectsInactiveEnvelopeWithSelectedText() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 4,
            heartbeat: false,
            active: false,
            schemaID: nil,
            selectedText: "你好",
            selectedIndex: nil,
            candidates: []
        )

        XCTAssertFalse(envelope.isValid)
    }

    func testRejectsEmptySessionID() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "",
            sequence: 1,
            heartbeat: false,
            active: true,
            schemaID: "luna_pinyin_simp",
            selectedText: "你好",
            selectedIndex: 0,
            candidates: ["你好"]
        )

        XCTAssertFalse(envelope.isValid)
    }

    func testInactiveEnvelopeMustBeEmpty() {
        let envelope = RimeCandidateEnvelope(
            sessionID: "test-session",
            sequence: 5,
            heartbeat: false,
            active: false,
            schemaID: nil,
            selectedText: nil,
            selectedIndex: nil,
            candidates: []
        )

        XCTAssertTrue(envelope.isValid)
    }
}
