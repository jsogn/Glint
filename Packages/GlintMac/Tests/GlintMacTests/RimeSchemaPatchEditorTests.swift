import XCTest
@testable import GlintMac

final class RimeSchemaPatchEditorTests: XCTestCase {
    private let editor = RimeSchemaPatchEditor()
    private let managedBlock = """
        # BEGIN GLINT RIME CANDIDATE BRIDGE
        __patch:
          patch/+:
            engine/filters/@before 0: lua_filter@*glint.candidate_bridge
        # END GLINT RIME CANDIDATE BRIDGE
        """

    func testCreatesManagedPatchForMissingCustomFile() throws {
        let result = try editor.install(
            into: nil,
            schemaID: "luna_pinyin"
        )

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.createdFile)
        XCTAssertEqual(result.source, managedBlock + "\n")
    }

    func testAppendsStandalonePatchWithoutChangingExistingConfiguration()
        throws
    {
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
        XCTAssertEqual(result.source, source + "\n" + managedBlock + "\n")
    }

    func testInlinePatchDoesNotNeedStructuralParsing() throws {
        let source = """
            patch: { engine: { filters: [ lua_filter@*user_filter ] } }
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertEqual(result.source, source + "\n" + managedBlock + "\n")
    }

    func testRejectsExistingForeignRootPatch() {
        let source = """
            patch:
              menu/page_size: 5
            __patch:
              menu/page_size: 9
            """

        XCTAssertThrowsError(
            try editor.install(
                into: source,
                schemaID: "luna_pinyin"
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSchemaPatchError,
                .missingPatchRoot
            )
        }
    }

    func testDuplicatePatchRootIsRejectedWithoutRewriting() throws {
        let source = """
            patch:
              menu/page_size: 5
            patch:
              menu/page_size: 9
            """
        let result = try? editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertNil(result)
    }

    func testManualRootFilterIsIdempotent() throws {
        let source = """
            patch:
              engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.source, source)
    }

    func testNestedEngineFilterIsIdempotent() throws {
        let source = """
            patch:
              engine:
                filters:
                  - lua_filter@*glint.candidate_bridge
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.source, source)
    }

    func testUnrelatedFilterScalarDoesNotCountAsInstalled() throws {
        let source = """
            patch:
              notes: "use lua_filter@*glint.candidate_bridge"
            """

        let result = try editor.install(
            into: source,
            schemaID: "luna_pinyin"
        )

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.source, source + "\n" + managedBlock + "\n")
    }

    func testRemovingStandalonePatchBlockRestoresOriginalConfiguration() {
        let original = """
            patch:
              menu/page_size: 5
            """
        let installed = original + "\n" + managedBlock + "\n"

        XCTAssertEqual(
            editor.removeManagedFilter(from: installed),
            original + "\n"
        )
    }

    func testRemovingLegacyManagedFilterPreservesUserContent() {
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

        XCTAssertEqual(
            editor.removeManagedFilter(from: source),
            """
            patch:
              engine/filters/+:
                - lua_filter@*user_filter
              menu:
                page_size: 5
            """
        )
    }

    func testManualFilterWithoutManagedMarkersIsNotOwned() {
        let source = """
            patch:
              engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            """

        XCTAssertEqual(
            editor.removeManagedFilter(from: source),
            source
        )
    }

    func testIncompleteManagedMarkersAreNotRepaired() {
        let source = """
            patch:
              engine/filters/+:
                # BEGIN GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*user_filter
            """

        XCTAssertThrowsError(
            try editor.install(
                into: source,
                schemaID: "luna_pinyin"
            )
        )
    }

    func testCRLFConfigurationFailsClosed() {
        let source = "patch:\r\n  menu/page_size: 5\r\n"

        XCTAssertThrowsError(
            try editor.install(
                into: source,
                schemaID: "luna_pinyin"
            )
        )
    }
}
