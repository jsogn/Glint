import GlintCore
import GlintPlugins
import XCTest

@testable import GlintUI

final class PluginsPagePresentationTests: XCTestCase {
    func testUnrestrictedModelHasNoLanguageLabel() {
        XCTAssertNil(
            pluginLanguageCapabilityLabel(
                for: manifest(targets: nil)
            )
        )
    }

    func testEnglishOnlyModelIsLabeled() {
        XCTAssertEqual(
            pluginLanguageCapabilityLabel(
                for: manifest(targets: [.english])
            ),
            "仅支持英语"
        )
    }

    func testExplicitMultiTargetModelListsDeclaredTargets() {
        XCTAssertEqual(
            pluginLanguageCapabilityLabel(
                for: manifest(targets: [.english, .japanese])
            ),
            "语言能力：英语 / 日语"
        )
    }

    private func manifest(
        targets: [TranslationTarget]?
    ) -> PluginManifest {
        PluginManifest(
            id: "translation-test",
            type: .translation,
            name: "Test Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.invalid/model")!,
            license: "MIT",
            minRAMBytes: 1,
            translationTargets: targets
        )
    }
}
