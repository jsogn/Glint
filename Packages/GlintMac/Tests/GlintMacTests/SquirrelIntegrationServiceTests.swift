import CryptoKit
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
        let manifestData = try Data(contentsOf: fixture.manifestURL)
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData)
                as? [String: Any]
        )
        let backupDirectoryPath = try XCTUnwrap(
            manifest["backupDirectory"] as? String
        )
        XCTAssertEqual(
            try fixture.permissions(
                of: URL(fileURLWithPath: backupDirectoryPath)
            ),
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
        XCTAssertEqual(
            fixture.pendingTransactionObservedDuringReload.withLock {
                $0
            },
            true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
    }

    func testStatusStaysInstalledWhenBundledRelayChangesWithoutVersionBump()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()

        try Data("new UI-only app build relay".utf8).write(
            to: fixture.relaySource,
            options: .atomic
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .installed)
    }

    func testSynchronizeDoesNothingWhenSupportWasNeverInstalled()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }

        let status =
            try await fixture.service
            .synchronizeInstalledSupportIfNeeded()

        XCTAssertEqual(status.state, .available)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testSynchronizeSkipsCurrentInstalledBridgeVersion()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try Data("new UI-only app build relay".utf8).write(
            to: fixture.relaySource,
            options: .atomic
        )

        let status =
            try await fixture.service
            .synchronizeInstalledSupportIfNeeded()

        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testSynchronizeUpgradesOlderInstalledBridgeVersion()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try fixture.setManifestAssetVersion(
            SquirrelIntegrationService.currentBridgeAssetVersion - 1
        )

        let status =
            try await fixture.service
            .synchronizeInstalledSupportIfNeeded()

        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
        XCTAssertEqual(
            try fixture.manifestAssetVersion(),
            SquirrelIntegrationService.currentBridgeAssetVersion
        )
    }

    func testSynchronizeRejectsManifestWithoutFileHashes()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try fixture.removeManifestFileHashes()

        do {
            try await fixture.service
                .synchronizeInstalledSupportIfNeeded()
            XCTFail("Expected invalid-manifest rejection")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .invalidManifest
            )
        }
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testSynchronizeDoesNotRepairModifiedAssetWithoutVersionBump()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try Data("modified installed relay".utf8).write(
            to: fixture.relayDestination,
            options: .atomic
        )

        let status =
            try await fixture.service
            .synchronizeInstalledSupportIfNeeded()

        XCTAssertEqual(status.state, .repairRequired)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testSynchronizeUpgradeStopsOnUnsupportedSchema() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try fixture.setManifestAssetVersion(
            SquirrelIntegrationService.currentBridgeAssetVersion - 1
        )
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
            _ = try await fixture.service
                .synchronizeInstalledSupportIfNeeded()
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

        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
        XCTAssertEqual(
            try fixture.manifestAssetVersion(),
            SquirrelIntegrationService.currentBridgeAssetVersion - 1
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
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

    func testReinstallKeepsPreviouslyManagedSchemaRestorable()
        async throws
    {
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
        let otherCustom = fixture.rimeDirectory.appendingPathComponent(
            "luna_pinyin_simp.custom.yaml"
        )
        let otherOriginal = Data(
            "patch:\n  menu:\n    page_size: 7\n".utf8
        )
        try otherOriginal.write(to: otherCustom)
        _ = try await fixture.service.install()
        try """
        patch:
          schema_list:
            - schema: luna_pinyin
        """.write(
            to: fixture.defaultCustom,
            atomically: true,
            encoding: .utf8
        )

        _ = try await fixture.service.install()
        _ = try await fixture.service.uninstall()

        XCTAssertEqual(try Data(contentsOf: otherCustom), otherOriginal)
    }

    func testReinstallDoesNotRewriteUnchangedManagedFiles() async throws {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        let customInode = try fixture.inode(of: fixture.schemaCustom)
        let relayInode = try fixture.inode(of: fixture.relayDestination)
        let manifestInode = try fixture.inode(of: fixture.manifestURL)

        _ = try await fixture.service.install()

        XCTAssertEqual(try fixture.inode(of: fixture.schemaCustom), customInode)
        XCTAssertEqual(try fixture.inode(of: fixture.relayDestination), relayInode)
        XCTAssertEqual(try fixture.inode(of: fixture.manifestURL), manifestInode)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testReinstallPreservesTheOriginalByteForByteBackup()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            """
            # Keep exact bytes, including this comment.
            patch:
              menu:
                page_size: 5
            """.utf8
        )
        try original.write(to: fixture.schemaCustom, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.schemaCustom.path
        )

        _ = try await fixture.service.install()
        _ = try await fixture.service.install()

        let backupURL = try XCTUnwrap(
            fixture.manifestBackupPath(for: fixture.schemaCustom.path)
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), original)

        _ = try await fixture.service.uninstall()

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), original)
        XCTAssertEqual(
            try fixture.permissions(of: fixture.schemaCustom),
            0o600
        )
    }

    func testInstallRejectsManifestWithoutBackupMetadata()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try fixture.removeManifestBackupMetadata()

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected invalid-manifest rejection")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .invalidManifest
            )
        }
    }

    func testUTF8ByteOrderMarkIsPreservedAcrossInstallAndUninstall()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            [0xEF, 0xBB, 0xBF]
                + Array(
                    """
                    # Keep this BOM.
                    patch:
                      menu:
                        page_size: 5
                    """.utf8
                )
        )
        try original.write(to: fixture.schemaCustom)

        _ = try await fixture.service.install()
        let installed = try Data(contentsOf: fixture.schemaCustom)
        XCTAssertTrue(installed.starts(with: [0xEF, 0xBB, 0xBF]))

        _ = try await fixture.service.uninstall()
        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), original)
    }

    func testCRLFConfigurationIsRejectedWithoutWriting()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            "patch:\r\n  menu:\r\n    page_size: 5\r\n".utf8
        )
        try original.write(to: fixture.schemaCustom)

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected unsupported CRLF configuration")
        } catch {
            guard
                case .unsupportedSchema(
                    "luna_pinyin",
                    RimeSchemaPatchError.unsupportedEngineStructure
                ) = error as? SquirrelIntegrationError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), original)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
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
        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            "patch:\n  engine/filters/+:\n"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.manifestURL.path
            )
        )
    }

    func testUnmanagedUninstallPreservesUserComments()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let userConfiguration = """
            # Keep this comment
            patch:
              engine/filters/+:
                # BEGIN GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*glint.candidate_bridge
                # END GLINT RIME CANDIDATE BRIDGE
            """
        try userConfiguration.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        _ = try await fixture.service.uninstall()

        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            """
            # Keep this comment
            patch:
              engine/filters/+:
            """
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

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected invalid-manifest failure")
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

    func testUninstallPreservesPreExistingManualFilter() async throws {
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

        XCTAssertEqual(
            try String(
                contentsOf: fixture.schemaCustom,
                encoding: .utf8
            ),
            manual
        )
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 2)
    }

    func testModifiedManagedAssetIsNotOverwrittenDuringMigration()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        let modified = Data("user modified installed relay".utf8)
        try modified.write(
            to: fixture.relayDestination,
            options: .atomic
        )
        try fixture.setManifestAssetVersion(
            SquirrelIntegrationService.currentBridgeAssetVersion - 1
        )

        do {
            _ = try await fixture.service
                .synchronizeInstalledSupportIfNeeded()
            XCTFail("Expected managed-file conflict")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .installConflict
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.relayDestination),
            modified
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testMissingFileCreatedByInstallerCanBeRepaired()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.service.install()
        try FileManager.default.removeItem(at: fixture.relayDestination)

        let status = try await fixture.service.install()

        XCTAssertEqual(status.state, .installed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 2)
    }

    func testInstallRejectsSymbolicLinkTargetWithoutChangingIt()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent(
            "outside-custom.yaml"
        )
        let original = Data("patch:\n  menu:\n    page_size: 7\n".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.schemaCustom,
            withDestinationURL: outside
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected symbolic-link rejection")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .unsafePath
            )
        }

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.schemaCustom.path
            ),
            outside.path
        )
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testInstallRejectsSymlinkedParentThatEscapesRimeDirectory()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent(
            "outside-lua",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("glint"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.rimeDirectory.appendingPathComponent("lua"),
            withDestinationURL: outside
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected symbolic-link rejection")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .unsafePath
            )
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(
                    "glint/candidate_bridge.lua"
                ).path
            )
        )
    }

    func testInstallRejectsSymlinkedBackupRoot()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent(
            "outside-backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.supportDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at:
                fixture.supportDirectory.appendingPathComponent(
                    "Backups"
                ),
            withDestinationURL: outside
        )

        do {
            _ = try await fixture.service.install()
            XCTFail("Expected unsafe backup-root rejection")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .unsafePath
            )
        }

        let contents = try FileManager.default.contentsOfDirectory(
            atPath: outside.path
        )
        XCTAssertTrue(contents.isEmpty)
    }

    func testUninstallRejectsCorruptedBackupBeforeWriting()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            "patch:\n  menu:\n    page_size: 5\n".utf8
        )
        try original.write(to: fixture.schemaCustom)
        _ = try await fixture.service.install()
        let installed = try Data(contentsOf: fixture.schemaCustom)
        let backupURL = try XCTUnwrap(
            fixture.manifestBackupPath(for: fixture.schemaCustom.path)
        )
        try Data("corrupted backup".utf8).write(
            to: backupURL,
            options: .atomic
        )

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected backup-integrity failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .uninstallConflict
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: fixture.schemaCustom),
            installed
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
    }

    func testManifestCannotRestoreArbitraryFileInsideRimeDirectory()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let sentinel = fixture.rimeDirectory.appendingPathComponent(
            "unrelated.custom.yaml"
        )
        let original = Data("patch:\n  menu:\n    page_size: 3\n".utf8)
        try original.write(to: sentinel)
        let backupDirectory = fixture.supportDirectory.appendingPathComponent(
            "Backups/malicious",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        let backup = backupDirectory.appendingPathComponent("000.backup")
        try Data("patch: {}\n".utf8).write(to: backup)
        try fixture.writeManifest(
            backupDirectory: backupDirectory,
            backups: [sentinel.path: backup.path],
            createdFiles: []
        )

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected invalid-manifest failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .invalidManifest
            )
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testPreparedTransactionIsRolledBackOnNextStart()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            "patch:\n  menu:\n    page_size: 5\n".utf8
        )
        let partiallyWritten = Data(
            """
            patch:
              menu:
                page_size: 5
              engine/filters/+:
                # BEGIN GLINT RIME CANDIDATE BRIDGE
                - lua_filter@*glint.candidate_bridge
                # END GLINT RIME CANDIDATE BRIDGE
            """.utf8
        )
        try partiallyWritten.write(to: fixture.schemaCustom)
        try fixture.writePendingTransaction(
            phase: "prepared",
            target: fixture.schemaCustom,
            snapshotData: original,
            expectedData: partiallyWritten,
            permissions: 0o640
        )

        try await fixture.service.recoverInterruptedTransactionIfNeeded()

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), original)
        XCTAssertEqual(
            try fixture.permissions(of: fixture.schemaCustom),
            0o640
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
    }

    func testCommittedTransactionIsFinalizedWithoutRollingBack()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let committed = Data(
            "patch:\n  menu:\n    page_size: 9\n".utf8
        )
        try committed.write(to: fixture.schemaCustom)
        try fixture.writePendingTransaction(
            phase: "committed",
            target: fixture.schemaCustom,
            snapshotData: Data(
                "patch:\n  menu:\n    page_size: 5\n".utf8
            ),
            expectedData: committed,
            permissions: 0o644
        )

        try await fixture.service.recoverInterruptedTransactionIfNeeded()

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), committed)
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
    }

    func testPreparedRecoveryDoesNotOverwritePostCrashUserEdit()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let original = Data(
            "patch:\n  menu:\n    page_size: 5\n".utf8
        )
        let transactionOutput = Data(
            "patch:\n  menu:\n    page_size: 8\n".utf8
        )
        let userEdit = Data(
            "patch:\n  menu:\n    page_size: 11\n".utf8
        )
        try userEdit.write(to: fixture.schemaCustom)
        try fixture.writePendingTransaction(
            phase: "prepared",
            target: fixture.schemaCustom,
            snapshotData: original,
            expectedData: transactionOutput,
            permissions: 0o644
        )

        do {
            try await fixture.service
                .recoverInterruptedTransactionIfNeeded()
            XCTFail("Expected post-crash edit conflict")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .rollbackFailed
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), userEdit)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 0)
    }

    func testCorruptTransactionJournalFailsClosed()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let current = Data("patch:\n  menu:\n    page_size: 5\n".utf8)
        try current.write(to: fixture.schemaCustom)
        try FileManager.default.createDirectory(
            at: fixture.supportDirectory,
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(
            to: fixture.pendingTransactionURL
        )

        do {
            try await fixture.service
                .recoverInterruptedTransactionIfNeeded()
            XCTFail("Expected invalid journal failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .invalidManifest
            )
        }

        XCTAssertEqual(try Data(contentsOf: fixture.schemaCustom), current)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
    }

    func testConcurrentInstallersSerializeBeforeChangingRimeConfig()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        let reloadBarrier = InstallReloadBarrier()
        let secondService = fixture.makeService {
            let count = fixture.reloadCount.withLock {
                $0 += 1
                return $0
            }
            reloadBarrier.rendezvous(call: count)
        }

        async let first = fixture.service.install()
        async let second = secondService.install()
        _ = try await (first, second)

        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.pendingTransactionURL.path
            )
        )
        XCTAssertEqual(fixture.reloadCount.withLock { $0 }, 3)
    }

    func testUninstallRollbackRestoresPreexistingUnownedAssets()
        async throws
    {
        let fixture = try SquirrelFixture(reloadFailureCall: 2)
        defer { fixture.cleanup() }
        let luaDirectory = fixture.rimeDirectory.appendingPathComponent(
            "lua/glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: luaDirectory,
            withIntermediateDirectories: true
        )
        for name in SquirrelIntegrationService.luaFileNames {
            try Data(
                contentsOf:
                    fixture.luaSourceDirectory.appendingPathComponent(name)
            ).write(to: luaDirectory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: fixture.relayDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: fixture.relaySource).write(
            to: fixture.relayDestination
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.relayDestination.path
        )
        _ = try await fixture.service.install()

        do {
            _ = try await fixture.service.uninstall()
            XCTFail("Expected uninstall reload failure")
        } catch {
            XCTAssertEqual(
                error as? SquirrelIntegrationError,
                .reloadFailed
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.relayDestination.path
            )
        )
        for name in SquirrelIntegrationService.luaFileNames {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath:
                        luaDirectory.appendingPathComponent(name).path
                )
            )
        }
    }

    func testUninstallRollbackKeepsInstalledVersionOfBackedUpAssets()
        async throws
    {
        let fixture = try SquirrelFixture(reloadFailureCall: 2)
        defer { fixture.cleanup() }
        let luaDirectory = fixture.rimeDirectory.appendingPathComponent(
            "lua/glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: luaDirectory,
            withIntermediateDirectories: true
        )
        for name in SquirrelIntegrationService.luaFileNames {
            try Data("old \(name)".utf8).write(
                to: luaDirectory.appendingPathComponent(name)
            )
        }
        try FileManager.default.createDirectory(
            at: fixture.relayDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("old relay".utf8).write(to: fixture.relayDestination)
        _ = try await fixture.service.install()

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
            try Data(contentsOf: fixture.relayDestination),
            try Data(contentsOf: fixture.relaySource)
        )
        for name in SquirrelIntegrationService.luaFileNames {
            XCTAssertEqual(
                try Data(
                    contentsOf:
                        luaDirectory.appendingPathComponent(name)
                ),
                try Data(
                    contentsOf:
                        fixture.luaSourceDirectory
                        .appendingPathComponent(name)
                )
            )
        }
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

    func testStatusDoesNotTreatLongerFilterAsInstalled()
        async throws
    {
        let fixture = try SquirrelFixture()
        defer { fixture.cleanup() }
        try """
        patch:
          engine/filters/+:
            - lua_filter@*glint.candidate_bridge_custom
        """.write(
            to: fixture.schemaCustom,
            atomically: true,
            encoding: .utf8
        )

        let status = await fixture.service.status()

        XCTAssertEqual(status.state, .available)
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
    let pendingTransactionURL: URL
    let reloadCount = OSAllocatedUnfairLock(initialState: 0)
    let pendingTransactionObservedDuringReload =
        OSAllocatedUnfairLock(initialState: false)
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
            "Support/RimeCandidateSupport",
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
        pendingTransactionURL = supportDirectory.appendingPathComponent(
            "pending-install-transaction.json"
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
        let pendingTransactionObservedDuringReload =
            pendingTransactionObservedDuringReload
        let pendingTransactionURL = pendingTransactionURL
        service = SquirrelIntegrationService(
            rimeDirectory: rimeDirectory,
            supportDirectory: supportDirectory,
            squirrelApplication: squirrelApplication,
            luaSourceDirectory: luaSourceDirectory,
            relaySource: relaySource,
            reload: {
                pendingTransactionObservedDuringReload.withLock {
                    $0 =
                        FileManager.default.fileExists(
                            atPath: pendingTransactionURL.path
                        )
                }
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

    func makeService(
        reload: @escaping @Sendable () throws -> Void
    ) -> SquirrelIntegrationService {
        SquirrelIntegrationService(
            rimeDirectory: rimeDirectory,
            supportDirectory: supportDirectory,
            squirrelApplication: squirrelApplication,
            luaSourceDirectory: luaSourceDirectory,
            relaySource: relaySource,
            reload: reload
        )
    }

    func writeManifest(
        backupDirectory: URL,
        backups: [String: String],
        createdFiles: [String]
    ) throws {
        let manifest = try JSONSerialization.data(
            withJSONObject: [
                "assetVersion": 1,
                "installedAt": "2026-10-30T00:00:00Z",
                "protocolVersion": 3,
                "relayPath": relayDestination.path,
                "schemaIDs": ["luna_pinyin"],
                "backupDirectory": backupDirectory.path,
                "backups": backups,
                "createdFiles": createdFiles,
                "fileHashes": [String: String](),
                "backupHashes": [String: String](),
                "backupPermissions": [String: Int](),
            ]
        )
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        try manifest.write(to: manifestURL, options: .atomic)
    }

    func setManifestAssetVersion(_ version: Int) throws {
        let data = try Data(contentsOf: manifestURL)
        guard
            var manifest = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        manifest["assetVersion"] = version
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL, options: .atomic)
    }

    func manifestAssetVersion() throws -> Int {
        let data = try Data(contentsOf: manifestURL)
        guard
            let manifest = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let version = manifest["assetVersion"] as? Int
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return version
    }

    func removeManifestFileHashes() throws {
        let data = try Data(contentsOf: manifestURL)
        guard
            var manifest = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        manifest.removeValue(forKey: "fileHashes")
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL, options: .atomic)
    }

    func removeManifestBackupMetadata() throws {
        let data = try Data(contentsOf: manifestURL)
        guard
            var manifest = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        manifest.removeValue(forKey: "backupHashes")
        manifest.removeValue(forKey: "backupPermissions")
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: manifestURL, options: .atomic)
    }

    func writePendingTransaction(
        phase: String,
        target: URL,
        snapshotData: Data,
        expectedData: Data?,
        permissions: Int
    ) throws {
        let transactionDirectory = supportDirectory.appendingPathComponent(
            "Transactions/test",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        let snapshot = transactionDirectory.appendingPathComponent(
            "000.snapshot"
        )
        try snapshotData.write(to: snapshot, options: .atomic)
        let hash = SHA256.hash(data: snapshotData)
            .map { String(format: "%02x", $0) }
            .joined()
        let expectedHash = expectedData.map {
            SHA256.hash(data: $0)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        let journal: [String: Any] = [
            "phase": phase,
            "schemaIDs": ["luna_pinyin"],
            "transactionDirectory": transactionDirectory.path,
            "entries": [
                [
                    "targetPath": target.path,
                    "existed": true,
                    "snapshotPath": snapshot.path,
                    "snapshotHash": hash,
                    "expectedHash": expectedHash ?? "",
                    "expectedAbsent": expectedData == nil,
                    "permissions": permissions,
                ]
            ],
        ]
        try JSONSerialization.data(withJSONObject: journal)
            .write(to: pendingTransactionURL, options: .atomic)
    }

    func manifestBackupPath(for targetPath: String) throws -> URL? {
        let data = try Data(contentsOf: manifestURL)
        guard
            let manifest = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let backups = manifest["backups"] as? [String: String],
            let path = backups[targetPath]
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    func inode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return inode.intValue
    }

    func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        guard
            let permissions =
                attributes[.posixPermissions] as? NSNumber
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return permissions.intValue
    }
}

private final class InstallReloadBarrier: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func rendezvous(call: Int) {
        if call == 1 {
            _ = semaphore.wait(timeout: .now() + 0.4)
        } else {
            semaphore.signal()
        }
    }
}
