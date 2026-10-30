import AppKit
import XCTest
import GlintCore

final class AppSmokeTests: XCTestCase {
    private var appBundleURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Glint.app", isDirectory: true)
    }

    func testCandidateModel() {
        let candidate = Candidate(text: "你好", kind: .word)
        XCTAssertEqual(candidate.text, "你好")
        XCTAssertEqual(candidate.kind, .word)
    }

    func testMenuBarIconVariantsShareTemplateCanvas() throws {
        let resources = try XCTUnwrap(Bundle(url: appBundleURL))
        let enabled = try XCTUnwrap(
            resources.image(forResource: "BrandMark")
        )
        let disabled = try XCTUnwrap(
            resources.image(forResource: "BrandMarkOff")
        )

        XCTAssertTrue(enabled.isTemplate)
        XCTAssertTrue(disabled.isTemplate)
        XCTAssertEqual(enabled.size.width, disabled.size.width, accuracy: 0.001)
        XCTAssertEqual(enabled.size.height, disabled.size.height, accuracy: 0.001)
        XCTAssertNotEqual(enabled.tiffRepresentation, disabled.tiffRepresentation)
    }

    #if DEBUG
        func testDebugAppBundlesSquirrelBridgeAssets() throws {
            let helper = appBundleURL.appendingPathComponent(
                "Contents/Helpers/RimeCandidateBridge"
            )
            let luaDirectory = appBundleURL.appendingPathComponent(
                "Contents/Resources/RimeCandidateBridge",
                isDirectory: true
            )

            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: helper.path)
            )
            for fileName in ["candidate_bridge.lua", "json.lua"] {
                let file = luaDirectory.appendingPathComponent(fileName)
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: file.path)
                )
                XCTAssertGreaterThan(
                    try Data(contentsOf: file).count,
                    0
                )
            }
        }
    #endif
}
