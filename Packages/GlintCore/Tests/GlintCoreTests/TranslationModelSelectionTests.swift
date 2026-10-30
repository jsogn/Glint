import Foundation
import XCTest
@testable import GlintCore

final class TranslationModelSelectionTests: XCTestCase {
    func testDefaultAndPersistedSelection() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            TranslationModelSelection.defaultModelID
        )

        TranslationModelSelection.select("llm-qwen3-1.7b", in: defaults)
        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            "llm-qwen3-1.7b"
        )
    }

    func testSystemTranslationSelectionUsesReservedModelIdentity() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            SystemTranslationModel.appleTranslationID,
            TranslationModelSelection.defaultModelID
        )

        TranslationModelSelection.select(
            SystemTranslationModel.appleTranslationID,
            in: defaults
        )

        let selected = TranslationModelSelection.selected(in: defaults)
        XCTAssertEqual(
            selected,
            SystemTranslationModel.appleTranslationID
        )
        XCTAssertTrue(
            TranslationModelSelection.isSystemTranslation(selected)
        )
        XCTAssertTrue(
            TranslationModelSelection.isSystemTranslation(
                TranslationModelSelection.defaultModelID
            )
        )
    }

    func testLegacyBundledOPUSSelectionMigratesToSystemOnlyOnce() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(
            TranslationModelSelection.opusMTModelID,
            forKey: TranslationModelSelection.defaultsKey
        )

        TranslationModelSelection.migrateBundledModelSelection(in: defaults)

        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            SystemTranslationModel.appleTranslationID
        )

        TranslationModelSelection.select(
            TranslationModelSelection.opusMTModelID,
            in: defaults
        )
        TranslationModelSelection.migrateBundledModelSelection(in: defaults)

        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            TranslationModelSelection.opusMTModelID
        )
    }
}
