import XCTest
@testable import GlintUI

final class ManualRimeSetupContentTests: XCTestCase {
    func testMapsSchemaIDsToConfigurationFileNames() {
        XCTAssertEqual(
            ManualRimeSetupContent.fileNames(
                for: ["luna_pinyin", "double_pinyin_flypy"]
            ),
            [
                "luna_pinyin.custom.yaml",
                "double_pinyin_flypy.custom.yaml",
            ]
        )
    }

    func testConfigurationBlockUsesStandaloneManagedPatch() {
        XCTAssertEqual(
            ManualRimeSetupContent.configurationBlock,
            """
            # BEGIN GLINT RIME CANDIDATE BRIDGE
            __patch:
              patch/+:
                engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            # END GLINT RIME CANDIDATE BRIDGE
            """
        )
    }
}
