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
          "capabilities": ["word", "phrase"],
          "languages": ["zh-Hans", "en"],
          "sizeBytes": 20000000,
          "sha256": "abc",
          "url": "https://example.invalid/dict-cedict.zip",
          "license": "CC-BY-SA-4.0",
          "minRAMBytes": 0,
          "quality": "basic",
          "recommended": true,
          "revision": "abc123"
        }
        """
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(manifest.id, "dict-cedict")
        XCTAssertEqual(manifest.type, .dictionary)
        XCTAssertEqual(manifest.recommended, true)
        XCTAssertEqual(manifest.revision, "abc123")
    }

    func testOCRManifestDecoding() throws {
        let json = """
        {
          "id": "ocr-ppocrv6-small",
          "type": "ocr",
          "name": "PP-OCRv6 Small",
          "version": "2026.10",
          "runtime": "huggingface-onnx",
          "capabilities": ["candidate"],
          "languages": ["zh-Hans", "en"],
          "sizeBytes": 55000000,
          "sha256": "abc",
          "url": "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx",
          "license": "Apache-2.0",
          "minRAMBytes": 0,
          "quality": "accurate",
          "recommended": true,
          "revision": "abc123",
          "artifactFile": "inference.onnx"
        }
        """
        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(manifest.type, .ocr)
        XCTAssertEqual(manifest.runtime, "huggingface-onnx")
        XCTAssertEqual(manifest.artifactFile, "inference.onnx")
    }
}
