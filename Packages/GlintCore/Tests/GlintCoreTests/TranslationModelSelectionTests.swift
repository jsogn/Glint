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

    func testSpecializedModelsUseMLXRuntime() {
        XCTAssertTrue(TranslationModelSelection.usesMLX("llm-qwen3-1.7b"))
        XCTAssertTrue(TranslationModelSelection.usesMLX("mt-hy-mt2-1.8b"))
        XCTAssertTrue(TranslationModelSelection.usesMLX("mt-index-translate-2b"))
        XCTAssertFalse(TranslationModelSelection.usesMLX("mt-opus-zh-en"))
    }
}
