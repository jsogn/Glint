import Foundation
import GlintCore
import os
import XCTest
@testable import GlintMac

final class SquirrelIntegrationServiceTests: XCTestCase {
    func testIntegrationErrorsExposeActionableDescriptions() {
        XCTAssertEqual(
            SquirrelIntegrationError.unsupportedSchemaSelection
                .localizedDescription,
            "无法安全确认 Rime 当前启用的输入方案，请按手动安装说明操作"
        )
    }

    func testStatusReportsAvailableBeforeInstall() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(status.schemaIDs, ["luna_pinyin"])
        XCTAssertEqual(status.protocolVersion, RimeCandidateEnvelope.currentVersion)
    }

    func testInstallWritesBridgeAndSchemaPatch() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }

        let status = try await fixture.service.install()

        XCTAssertEqual(status.state, .installed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.rimeDirectory
                    .appendingPathComponent(
                        "lua/glint/candidate_bridge.lua"
                    )
                    .path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.relayDestination.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o700
        )
        let custom = try String(
            contentsOf: fixture.schemaCustom,
            encoding: .utf8
        )
        XCTAssertTrue(
            custom.contains(RimeSchemaPatchEditor.filterValue)
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testInstallOnlyPatchesEnabledCompiledSchema() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try Data().write(
            to: fixture.rimeDirectory.appendingPathComponent(
                "build/luna_quanpin.schema.yaml"
            )
        )

        _ = try await fixture.service.install()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.rimeDirectory
                    .appendingPathComponent(
                        "luna_quanpin.custom.yaml"
                    )
                    .path
            )
        )
    }

    func testUnsupportedSchemaListStopsBeforeWritingAnything() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try """
        patch:
          schema_list: [ { schema: luna_pinyin } ]
        """.write(
            to: fixture.defaultCustom,
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected unsupported schema list failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .unsupportedSchemaSelection
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.schemaCustom.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
    }

    func testUnsupportedSchemaListRequiresManualSetupStatus() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try """
        patch:
          schema_list: [ { schema: luna_pinyin } ]
        """.write(
            to: fixture.defaultCustom,
            atomically: true,
            encoding: .utf8
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .manualSetupRequired)
        XCTAssertTrue(status.schemaIDs.isEmpty)
    }

    func testUninstallRestoresExistingCustomConfiguration() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = """
            # Keep this comment
            patch:
              menu:
                page_size: 5
            """
        try original.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        _ = try await fixture.service.install()
        let status = try await fixture.service.uninstall()

        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            original
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 2)
    }

    func testUninstallRemovesPreexistingBridgeAssets() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = """
            patch:
              menu:
                page_size: 5
            """
        try original.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )
        let luaDirectory = fixture.rimeDirectory.appendingPathComponent(
            "lua/glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: luaDirectory,
            withIntermediateDirectories: true
        )
        let luaFiles = SquirrelIntegrationService.luaFileNames.map {
            luaDirectory.appendingPathComponent($0)
        }
        for file in luaFiles {
            try Data("preexisting \(file.lastPathComponent)".utf8)
                .write(to: file)
        }
        try FileManager.default.createDirectory(
            at: fixture.relayDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("preexisting relay".utf8).write(
            to: fixture.relayDestination
        )

        _ = try await fixture.service.install()
        let status = try await fixture.service.uninstall()

        XCTAssertEqual(status.state, .available)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        for file in luaFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path)
            )
        }
        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            original
        )
    }

    func testReinstallThenUninstallRemovesOriginallyCreatedCustomFile()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }

        _ = try await fixture.service.install()
        _ = try await fixture.service.install()
        _ = try await fixture.service.uninstall()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.schemaCustom.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testCorruptManifestUninstallFallsBackToMatchingBridgeFiles()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try Data("not json".utf8).write(
            to: fixture.manifestURL,
            options: .atomic
        )

        let status = try await fixture.service.uninstall()

        XCTAssertEqual(status.state, .available)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.schemaCustom.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testUnmanagedUninstallRemovesStaleBridgeAssets() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.relayDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale relay".utf8).write(
            to: fixture.relayDestination
        )
        let luaDirectory = fixture.rimeDirectory.appendingPathComponent(
            "lua/glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: luaDirectory,
            withIntermediateDirectories: true
        )
        let luaFiles = SquirrelIntegrationService.luaFileNames.map {
            luaDirectory.appendingPathComponent($0)
        }
        for file in luaFiles {
            try Data("stale lua".utf8).write(to: file)
        }

        let status = try await fixture.service.uninstall()

        XCTAssertEqual(status.state, .available)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        for file in luaFiles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: file.path)
            )
        }
    }

    func testInstallDoesNotDeleteBackupDirectoryOutsideManagedRoot()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let outsideDirectory = fixture.root.appendingPathComponent(
            "OutsideBackups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let sentinel = outsideDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try fixture.writeManifest(
            backupDirectory: outsideDirectory,
            backups: [:],
            createdFiles: []
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected invalid manifest failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .invalidManifest
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
    }

    func testUninstallDoesNotDeleteBackupDirectoryOutsideManagedRoot()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let outsideDirectory = fixture.root.appendingPathComponent(
            "OutsideBackups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let sentinel = outsideDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try fixture.writeManifest(
            backupDirectory: outsideDirectory,
            backups: [:],
            createdFiles: []
        )

        _ = try await fixture.service.uninstall()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path)
        )
    }

    func testUninstallRemovesPreExistingManualFilter() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let manual = """
            patch:
              menu:
                page_size: 5
              engine/filters/@before 0: lua_filter@*glint.candidate_bridge
            """
        try manual.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        _ = try await fixture.service.install()
        _ = try await fixture.service.uninstall()

        let restored = try String(
            contentsOf: fixture.schemaCustom,
            encoding: .utf8
        )
        XCTAssertFalse(restored.contains(RimeSchemaPatchEditor.filterValue))
        XCTAssertTrue(restored.contains("page_size: 5"))
    }

    func testUnsupportedSchemaAbortsBeforeWritingAnything() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try """
        patch:
          engine:
            filters:
              - lua_filter@*user_filter
        """.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected unsupported schema failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .unsupportedSchema(
                    "luna_pinyin",
                    .unsupportedEngineStructure
                )
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
    }

    func testMissingRelayReportsBundledAssetError() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.relaySource)

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected missing bundle asset failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .missingBundledAssets
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
    }

    func testReloadFailureRollsBackEveryFile() async throws {
        let fixture = try SquirrelFixture(failReload: true)
        defer { fixture.cleanup() }
        let original = """
            patch:
              menu:
                page_size: 5
            """
        try original.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected reload failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .reloadFailed
            )
        }

        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            original
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testUninstallReloadFailureRestoresInstalledFiles() async throws {
        let fixture = try SquirrelFixture(reloadFailureCall: 2)
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        let installedSchema = try String(
            contentsOf: fixture.schemaCustom,
            encoding: .utf8
        )

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected uninstall reload failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .reloadFailed
            )
        }

        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            installedSchema
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testUninstallRefusesToOverwriteUserChangesAfterInstall()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = """
            patch:
              menu:
                page_size: 5
            """
        try original.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )
        _ = try await fixture.service.install()
        let edited = original + "\n# user edit after install\n"
        try edited.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected uninstall conflict")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .uninstallConflict
            )
        }

        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            edited
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testProtocolMismatchRequiresRepair() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try """
        {
          "assetVersion": 3,
          "installedAt": "2026-10-30T00:00:00Z",
          "protocolVersion": 2,
          "relayPath": "\(fixture.relayDestination.path)",
          "schemaIDs": ["luna_pinyin"],
          "backupDirectory": "\(fixture.supportDirectory.path)/Backups/test"
        }
        """.write(
            to: fixture.manifestURL,
            atomically: true,
            encoding: .utf8
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .repairRequired)
    }

    func testStatusRejectsRelayWithoutExecutablePermissions() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.relayDestination.path
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .repairRequired)
    }

    func testPartialBridgeStateRequiresRepair() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try Data().write(
            to: fixture.rimeDirectory.appendingPathComponent(
                "build/luna_pinyin_simp.schema.yaml"
            )
        )
        try """
        patch:
          schema_list:
            - schema: luna_pinyin
            - schema: luna_pinyin_simp
        """.write(
            to: fixture.defaultCustom,
            atomically: true,
            encoding: .utf8
        )
        try """
        patch:
          engine/filters/@before 0: lua_filter@*glint.candidate_bridge
        """.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: fixture.relayDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale relay".utf8).write(
            to: fixture.relayDestination
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .repairRequired)
    }

    func testStatusRequiresManualSetupForUnsupportedEnabledSchema()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try """
        patch:
          engine:
            filters:
              - lua_filter@*user_filter
        """.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .manualSetupRequired)
    }
}

private final class SquirrelFixture: @unchecked Sendable {
    let root: URL
    let rimeDirectory: URL
    let supportDirectory: URL
    let squirrelApplication: URL
    let luaSourceDirectory: URL
    let relaySource: URL
    let relayDestination: URL
    let schemaCustom: URL
    let defaultCustom: URL
    let manifestURL: URL
    let reloadCount = OSAllocatedUnfairLock(initialState: 0)
    let service: SquirrelIntegrationService

    convenience init(failReload: Bool) throws {
        try self.init(reloadFailureCall: failReload ? 1 : nil)
    }

    init(reloadFailureCall: Int? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-squirrel-service-\(UUID().uuidString)",
                isDirectory: true
            )
        self.root = root
        rimeDirectory = root.appendingPathComponent(
            "Rime",
            isDirectory: true
        )
        supportDirectory = root.appendingPathComponent(
            "Support/RimeCandidateLab",
            isDirectory: true
        )
        squirrelApplication = root.appendingPathComponent(
            "Squirrel.app",
            isDirectory: true
        )
        luaSourceDirectory = root.appendingPathComponent(
            "Assets/lua/glint",
            isDirectory: true
        )
        relaySource = root.appendingPathComponent("Assets/RimeCandidateBridge")
        relayDestination = supportDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
        schemaCustom = rimeDirectory.appendingPathComponent(
            "luna_pinyin.custom.yaml"
        )
        defaultCustom = rimeDirectory.appendingPathComponent(
            "default.custom.yaml"
        )
        manifestURL = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )

        try FileManager.default.createDirectory(
            at: squirrelApplication,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rimeDirectory.appendingPathComponent(
                "build",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try Data().write(
            to: rimeDirectory.appendingPathComponent(
                "build/luna_pinyin.schema.yaml"
            )
        )
        let sharedSupport = squirrelApplication.appendingPathComponent(
            "Contents/SharedSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sharedSupport.appendingPathComponent(
                "build",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try """
        schema_list:
          - schema: luna_pinyin
        """.write(
            to: sharedSupport.appendingPathComponent(
                "build/default.yaml"
            ),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: luaSourceDirectory,
            withIntermediateDirectories: true
        )
        try Data("lua bridge".utf8).write(
            to: luaSourceDirectory.appendingPathComponent(
                "candidate_bridge.lua"
            )
        )
        try Data("lua json".utf8).write(
            to: luaSourceDirectory.appendingPathComponent("json.lua")
        )
        try FileManager.default.createDirectory(
            at: relaySource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("relay".utf8).write(to: relaySource)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: relaySource.path
        )

        let reloadCount = reloadCount
        service = SquirrelIntegrationService(
            rimeDirectory: rimeDirectory,
            supportDirectory: supportDirectory,
            squirrelApplication: squirrelApplication,
            luaSourceDirectory: luaSourceDirectory,
            relaySource: relaySource,
            reload: {
                let count = reloadCount.withLock {
                    $0 += 1
                    return $0
                }
                if count == reloadFailureCall {
                    throw SquirrelIntegrationError.reloadFailed
                }
            }
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeManifest(
        backupDirectory: URL,
        backups: [String: String],
        createdFiles: [String]
    ) throws {
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "assetVersion": 3,
                "installedAt": "2026-10-30T00:00:00Z",
                "protocolVersion": 3,
                "relayPath": relayDestination.path,
                "schemaIDs": ["luna_pinyin"],
                "backupDirectory": backupDirectory.path,
                "backups": backups,
                "createdFiles": createdFiles,
            ]
        )
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try manifest.write(to: manifestURL, options: .atomic)
    }
}
