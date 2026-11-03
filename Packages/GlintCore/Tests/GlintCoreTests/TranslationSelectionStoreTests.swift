import Foundation
import XCTest

@testable import GlintCore

@MainActor
final class TranslationSelectionStoreTests: XCTestCase {
    func testDefaultsToEnglishAndAppleTranslation() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = TranslationSelectionStore(defaults: defaults)

        XCTAssertEqual(store.selectedTarget, .english)
        XCTAssertEqual(
            store.selectedModelID(for: .english),
            SystemTranslationModel.appleTranslationID
        )
        XCTAssertEqual(
            store.selectedModelID(for: .japanese),
            SystemTranslationModel.appleTranslationID
        )
        XCTAssertEqual(
            store.selectedModelID(for: .spanish),
            SystemTranslationModel.appleTranslationID
        )
    }

    func testLegacyModelMigratesToEnglishOnlyOnce() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("llm-qwen3-1.7b", forKey: "translation.modelID")

        let store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()

        XCTAssertEqual(store.selectedTarget, .english)
        XCTAssertEqual(
            store.selectedModelID(for: .english),
            "llm-qwen3-1.7b"
        )
        XCTAssertEqual(
            store.selectedModelID(for: .japanese),
            SystemTranslationModel.appleTranslationID
        )

        store.selectModel("local-japanese", for: .japanese)
        store.migrateIfNeeded()

        XCTAssertEqual(
            store.selectedModelID(for: .japanese),
            "local-japanese"
        )
    }

    func testTargetsRememberModelsIndependently() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSelectionStore(defaults: defaults)

        store.selectModel("english-local", for: .english)
        store.selectModel("japanese-local", for: .japanese)
        store.selectModel("spanish-local", for: .spanish)
        store.selectedTarget = .spanish

        XCTAssertEqual(
            store.selectedModelID(for: .english),
            "english-local"
        )
        XCTAssertEqual(
            store.selectedModelID(for: .japanese),
            "japanese-local"
        )
        XCTAssertEqual(
            store.selectedModelID(for: .spanish),
            "spanish-local"
        )
        XCTAssertEqual(store.selectedTarget, .spanish)
    }

    func testLegacyBundledOPUSMigratesToAppleOnEnglishOnly() {
        let suite = "GlintTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "mt-opus-zh-en",
            forKey: "translation.modelID"
        )

        let store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()

        XCTAssertEqual(
            store.selectedModelID(for: .english),
            SystemTranslationModel.appleTranslationID
        )
    }
}
