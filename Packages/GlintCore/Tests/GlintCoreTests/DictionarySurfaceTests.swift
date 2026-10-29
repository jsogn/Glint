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

    func testPreservesTerminalAbbreviationPeriods() {
        XCTAssertEqual(
            DictionarySurface.normalize("Washington, D.C."),
            "Washington, D.C."
        )
        XCTAssertEqual(
            DictionarySurface.normalize("Martin Luther King, Jr."),
            "Martin Luther King, Jr."
        )
        XCTAssertEqual(
            DictionarySurface.normalize("to eat."),
            "eat"
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

    func testRejectsExplanatoryDictionaryProse() {
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "one of the five boroughs of New York City"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "Shangdu, also known as Xanadu"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "Aachen, city in Nordrhein-Westfalen"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "character used as a substitute for a real name"
            )
        )
    }

    func testRejectsAdditionalExplanatoryFormsWithoutSplittingPhrases() {
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "nickname of Cristiano Ronaldo"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "system where actors take turns"
            )
        )

        XCTAssertTrue(DictionarySurface.isDisplayable("Washington, D.C."))
        XCTAssertTrue(
            DictionarySurface.isDisplayable("Martin Luther King, Jr.")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("one China, one Taiwan")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("half outside, half inside")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("surly, irascible person")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("to cut blocks, to engrave")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("school, university")
        )
        XCTAssertTrue(
            DictionarySurface.isDisplayable("one step, one footprint")
        )
    }

    func testRejectsExplicitDefinitionMarkersWithoutHidingOrdinaryPhrases() {
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "used as a security token"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "name of a search engine"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "refers to a family group"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "lit. a bird in the hand"
            )
        )

        XCTAssertTrue(
            DictionarySurface.isDisplayable("capital of China")
        )
        XCTAssertTrue(DictionarySurface.isDisplayable("one of us"))
        XCTAssertTrue(DictionarySurface.isDisplayable("where are you"))
        XCTAssertTrue(DictionarySurface.isDisplayable("system administrator"))
        XCTAssertTrue(DictionarySurface.isDisplayable("used car"))
    }

    func testRejectsAppositiveDescriptions() {
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "Longshan, a county in Hunan"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "Triad, Chinese crime gang"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "George Washington, first US president"
            )
        )
        XCTAssertFalse(
            DictionarySurface.isDisplayable(
                "Washington, US State"
            )
        )
    }
}
