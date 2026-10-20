import Foundation
import XCTest
@testable import GlintCore

final class TranslationModeSelectionTests: XCTestCase {
    func testDefaultsToDictionaryFirstAndPersistsModelFirst() {
        let suite = "GlintModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            TranslationModeSelection.selected(in: defaults),
            .dictionaryFirst
        )

        TranslationModeSelection.select(.modelFirst, in: defaults)
        XCTAssertEqual(
            TranslationModeSelection.selected(in: defaults),
            .modelFirst
        )
    }
}
