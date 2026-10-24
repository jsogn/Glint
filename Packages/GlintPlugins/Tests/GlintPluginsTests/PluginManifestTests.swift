import XCTest
@testable import GlintPlugins

final class PluginManifestTests: XCTestCase {
    func testManifestDecoding() throws {
        let json = """
            {
              "id": "dict-cedict",
              "type": "dictionary",
              "name": "CC-CEDICT",
              "version": "2026.10",
              "runtime": "sqlite",
              "sizeBytes": 20000000,
              "sha256": "abc",
              "url": "https://example.invalid/dict-cedict.zip",
              "license": "CC-BY-SA-4.0",
              "minRAMBytes": 0,
              "source": "bundled",
              "revision": "abc123",
              "modelscopeURL": "https://modelscope.cn/models/example/dictionary"
            }
            """
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(manifest.id, "dict-cedict")
        XCTAssertEqual(manifest.type, .dictionary)
        XCTAssertEqual(manifest.source, .bundled)
        XCTAssertEqual(manifest.revision, "abc123")
        XCTAssertEqual(
            manifest.modelscopeURL,
            URL(string: "https://modelscope.cn/models/example/dictionary")
        )
    }

    func testPluginVersionComparison() {
        XCTAssertTrue(PluginVersion.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(PluginVersion.isNewer("1.0.0", than: "1.0"))
        XCTAssertTrue(PluginVersion.isNewer("1.0.0", than: "1.0.0-beta.2"))
        XCTAssertTrue(
            PluginVersion.isNewer(
                "2.0.0-beta.10",
                than: "2.0.0-beta.2"
            )
        )
        XCTAssertFalse(PluginVersion.isNewer("2.0.0-beta.2", than: "2.0.0"))
        XCTAssertTrue(PluginVersion.isNewer("2026.10", than: "2026.9"))
    }
}
