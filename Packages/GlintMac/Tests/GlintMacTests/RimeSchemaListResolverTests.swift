import XCTest
@testable import GlintMac

final class RimeSchemaListResolverTests: XCTestCase {
    private let resolver = RimeSchemaListResolver()

    func testUsesSharedListAndExcludesCompiledSchemaThatIsNotEnabled()
        throws
    {
        let shared = """
            # Rime default settings
            schema_list:
              - schema: luna_pinyin
              - schema: luna_pinyin_simp
            switcher:
              caption: Rime
            """

        let result = try resolver.enabledSchemaIDs(
            sharedDefault: shared,
            userDefaultCustom: nil,
            compiledSchemaIDs: [
                "luna_pinyin",
                "luna_pinyin_fluency",
                "luna_pinyin_simp",
            ]
        )

        XCTAssertEqual(result, ["luna_pinyin", "luna_pinyin_simp"])
    }

    func testUserSchemaListReplacesSharedList() throws {
        let shared = """
            schema_list:
              - schema: luna_pinyin
              - schema: luna_pinyin_simp
            """
        let custom = """
            patch:
              menu:
                page_size: 9
              schema_list:
                - schema: luna_pinyin_fluency
            """

        let result = try resolver.enabledSchemaIDs(
            sharedDefault: shared,
            userDefaultCustom: custom,
            compiledSchemaIDs: [
                "luna_pinyin",
                "luna_pinyin_fluency",
                "luna_pinyin_simp",
            ]
        )

        XCTAssertEqual(result, ["luna_pinyin_fluency"])
    }

    func testUserSchemaListAppendExtendsSharedList() throws {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              schema_list/+:
                - schema: luna_pinyin_simp
            """

        let result = try resolver.enabledSchemaIDs(
            sharedDefault: shared,
            userDefaultCustom: custom,
            compiledSchemaIDs: ["luna_pinyin", "luna_pinyin_simp"]
        )

        XCTAssertEqual(result, ["luna_pinyin", "luna_pinyin_simp"])
    }

    func testInlineUserSchemaListIsRejectedInsteadOfGuessing() {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              schema_list: [ { schema: luna_pinyin_simp } ]
            """

        XCTAssertThrowsError(
            try resolver.enabledSchemaIDs(
                sharedDefault: shared,
                userDefaultCustom: custom,
                compiledSchemaIDs: ["luna_pinyin", "luna_pinyin_simp"]
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSchemaListError,
                .unsupportedSchemaList
            )
        }
    }

    func testUnknownSchemaListPatchOperationIsRejected() {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              schema_list/@before 0:
                - schema: luna_pinyin_simp
            """

        XCTAssertThrowsError(
            try resolver.enabledSchemaIDs(
                sharedDefault: shared,
                userDefaultCustom: custom,
                compiledSchemaIDs: ["luna_pinyin", "luna_pinyin_simp"]
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSchemaListError,
                .unsupportedSchemaList
            )
        }
    }

    func testMergedSchemaListPatchIsRejectedInsteadOfUsingSharedList() {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              <<: &override
                schema_list:
                  - schema: luna_pinyin_simp
            """

        XCTAssertThrowsError(
            try resolver.enabledSchemaIDs(
                sharedDefault: shared,
                userDefaultCustom: custom,
                compiledSchemaIDs: [
                    "luna_pinyin",
                    "luna_pinyin_simp",
                ]
            )
        )
    }

    func testIncludedSchemaListPatchIsRejected() {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              __include: schema_list_override:/patch
            """

        XCTAssertThrowsError(
            try resolver.enabledSchemaIDs(
                sharedDefault: shared,
                userDefaultCustom: custom,
                compiledSchemaIDs: [
                    "luna_pinyin",
                    "luna_pinyin_simp",
                ]
            )
        )
    }

    func testQuotedSchemaListKeyIsRejectedInsteadOfUsingSharedList() {
        let shared = """
            schema_list:
              - schema: luna_pinyin
            """
        let custom = """
            patch:
              "schema_list":
                - schema: luna_pinyin_simp
            """

        XCTAssertThrowsError(
            try resolver.enabledSchemaIDs(
                sharedDefault: shared,
                userDefaultCustom: custom,
                compiledSchemaIDs: [
                    "luna_pinyin",
                    "luna_pinyin_simp",
                ]
            )
        )
    }
}
