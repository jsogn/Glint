import XCTest
import GlintCore

final class AppSmokeTests: XCTestCase {
    func testCandidateModel() {
        let candidate = Candidate(text: "你好", kind: .word)
        XCTAssertEqual(candidate.text, "你好")
        XCTAssertEqual(candidate.kind, .word)
    }

    #if DEBUG
        func testDebugAppBundlesSquirrelBridgeAssets() throws {
            let app = Bundle(for: Self.self).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("Glint.app", isDirectory: true)
            let helper = app.appendingPathComponent(
                "Contents/Helpers/RimeCandidateBridge"
            )
            let luaDirectory = app.appendingPathComponent(
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
