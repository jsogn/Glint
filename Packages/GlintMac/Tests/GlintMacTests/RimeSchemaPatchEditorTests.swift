import XCTest
@testable import GlintMac

final class RimeSchemaPatchEditorTests: XCTestCase {
    private let editor = RimeSchemaPatchEditor()

    func testCreatesManagedPatchForMissingCustomFile() throws {
        let result = try editor.install(
            into: nil,
            schemaID: "luna_pinyin"
        )

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.createdFile)
        XCTAssertEqual(
            result.source,
            """
            patch:
              engine/filters/+:
                # BEGIN GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*glint.candidate_bridge
                # END GLINT RIME CANDIDATE BRIDGE

            """
        )
    }

    func testPreservesExistingPatchAndAddsFilterKey() throws {
        let source = """
            # User preference
            patch:
              switches:
                - name: ascii_mode
                  reset: 0
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.createdFile)
        XCTAssertTrue(result.source.hasPrefix(source))
        XCTAssertTrue(
            result.source.contains(
                """
                  engine/filters/+:
                    # BEGIN GLINT RIME CANDIDATE BRIDGE
                    - lua_filter@*glint.candidate_bridge
                    # END GLINT RIME CANDIDATE BRIDGE
                """
            )
        )
    }

    func testExtendsExistingFilterList() throws {
        let source = """
            patch:
              engine/filters/+:
                - lua_filter@*user_filter
              menu:
                page_size: 5
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertTrue(result.changed)
        XCTAssertTrue(
            result.source.contains(
                """
                  engine/filters/+:
                    # BEGIN GLINT RIME CANDIDATE BRIDGE
                    - lua_filter@*glint.candidate_bridge
                    # END GLINT RIME CANDIDATE BRIDGE
                    - lua_filter@*user_filter
                """
            )
        )
        XCTAssertTrue(result.source.contains("  menu:\n    page_size: 5"))
    }

    func testAlreadyInstalledFilterIsIdempotent() throws {
        let source = """
            patch:
              engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertFalse(result.changed)
        XCTAssertFalse(result.createdFile)
        XCTAssertEqual(result.source, source)
    }

    func testNestedEngineMappingIsRejectedWithoutRewriting() {
        let source = """
            patch:
              engine:
                filters:
                  - lua_filter@*user_filter
            """

        XCTAssertThrowsError(
            try editor.install(
                into: source,
                schemaID: "luna_pinyin"
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSchemaPatchError,
                .unsupportedEngineStructure
            )
        }
    }

    func testInlineFilterListIsRejectedWithoutGuessing() {
        let source = """
            patch:
              engine/filters/+: [ lua_filter@*user_filter ]
            """

        XCTAssertThrowsError(
            try editor.install(
                into: source,
                schemaID: "luna_pinyin"
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSchemaPatchError,
                .unsupportedFilterList
            )
        }
    }

    func testRemoveManagedFilterPreservesUserContent() {
        let source = """
            patch:
              engine/filters/+:
                # BEGIN GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*glint.candidate_bridge
                # END GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*user_filter
              menu:
                page_size: 5
            """

        let result = editor.removeManagedFilter(from: source)

        XCTAssertEqual(
            result,
            """
            patch:
              engine/filters/+:
                - lua_filter@*user_filter
              menu:
                page_size: 5
            """
        )
    }

    func testRemoveManualFilterLineWithoutManagedMarkers() {
        let source = """
            patch:
              engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            """

        XCTAssertEqual(
            editor.removeManagedFilter(from: source),
            "patch:"
        )
    }
}
