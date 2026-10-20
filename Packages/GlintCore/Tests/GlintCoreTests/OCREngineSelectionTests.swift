import XCTest
@testable import GlintCore

final class OCREngineSelectionTests: XCTestCase {
    func testDefaultsToAppleVision() throws {
        let suiteName = "OCREngineSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            OCREngineSelection.selected(in: defaults),
            OCREngineSelection.visionEngineID
        )
    }

    func testSelectionPersists() throws {
        let suiteName = "OCREngineSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OCREngineSelection.select("ocr-ppocrv6-small", in: defaults)
        XCTAssertEqual(
            OCREngineSelection.selected(in: defaults),
            "ocr-ppocrv6-small"
        )
    }

    func testEnhancementDefaultsToAutomaticAndPersists() throws {
        let suiteName = "OCREnhancementSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            OCREnhancementSelection.selected(in: defaults),
            .automatic
        )

        OCREnhancementSelection.select(.off, in: defaults)
        XCTAssertEqual(
            OCREnhancementSelection.selected(in: defaults),
            .off
        )
    }
}
