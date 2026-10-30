import Foundation
import XCTest
@testable import GlintMac

final class RimeSupportDirectoryMigrationTests: XCTestCase {
    func testDefaultSocketPathUsesProductionDirectoryName() {
        let directory = URL(
            fileURLWithPath: RimeCandidateBridgeReceiver.defaultSocketPath
        ).deletingLastPathComponent()

        XCTAssertEqual(directory.lastPathComponent, "RimeCandidateSupport")
    }

    func testMigrationMovesLegacySupportDirectoryAndRewritesManifestPaths()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-migration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        let legacyDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateLab",
            isDirectory: true
        )
        let productionDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateSupport",
            isDirectory: true
        )
        let legacyBackupDirectory =
            legacyDirectory.appendingPathComponent(
                "Backups/test",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: legacyBackupDirectory,
            withIntermediateDirectories: true
        )
        let legacyRelay = legacyDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
        try Data("relay".utf8).write(to: legacyRelay)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: legacyRelay.path
        )
        let legacyBackup = legacyBackupDirectory.appendingPathComponent(
            "000.backup"
        )
        try Data("original yaml".utf8).write(to: legacyBackup)

        let rimeSchema = root.appendingPathComponent(
            "Rime/luna_pinyin.custom.yaml"
        )
        let manifest: [String: Any] = [
            "assetVersion": 3,
            "installedAt": "2026-10-30T00:00:00Z",
            "protocolVersion": 3,
            "relayPath": legacyRelay.path,
            "schemaIDs": ["luna_pinyin"],
            "backupDirectory": legacyBackupDirectory.path,
            "backups": [rimeSchema.path: legacyBackup.path],
            "createdFiles": [legacyRelay.path],
            "fileHashes": [legacyRelay.path: "relay-hash"],
            "backupHashes": [rimeSchema.path: "backup-hash"],
            "backupPermissions": [rimeSchema.path: 0o644],
        ]
        let manifestURL = legacyDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(to: manifestURL)

        let resolved = try RimeSupportDirectoryMigrator()
            .migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )

        XCTAssertEqual(resolved, productionDirectory)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyDirectory.path)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: productionDirectory.appendingPathComponent(
                    "RimeCandidateBridge"
                )
            ),
            Data("relay".utf8)
        )

        let migratedManifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: productionDirectory.appendingPathComponent(
                        "install-manifest.json"
                    )
                )
            ) as? [String: Any]
        )
        let migratedRelay = productionDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        ).path
        let migratedBackupDirectory =
            productionDirectory.appendingPathComponent(
                "Backups/test"
            ).path
        let migratedBackup = productionDirectory.appendingPathComponent(
            "Backups/test/000.backup"
        ).path
        XCTAssertEqual(migratedManifest["relayPath"] as? String, migratedRelay)
        XCTAssertEqual(
            migratedManifest["backupDirectory"] as? String,
            migratedBackupDirectory
        )
        XCTAssertEqual(
            (migratedManifest["backups"] as? [String: String])?[
                rimeSchema.path
            ],
            migratedBackup
        )
        XCTAssertEqual(
            migratedManifest["createdFiles"] as? [String],
            [migratedRelay]
        )
        XCTAssertNotNil(
            (migratedManifest["fileHashes"] as? [String: String])?[
                migratedRelay
            ]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: glintDirectory.appendingPathComponent(
                    ".rime-support-migration-v1"
                ).path
            )
        )

        let manifestData = try Data(
            contentsOf: productionDirectory.appendingPathComponent(
                "install-manifest.json"
            )
        )
        let resolvedAgain = try RimeSupportDirectoryMigrator()
            .migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )
        XCTAssertEqual(resolvedAgain, productionDirectory)
        XCTAssertEqual(
            try Data(
                contentsOf: productionDirectory.appendingPathComponent(
                    "install-manifest.json"
                )
            ),
            manifestData
        )
    }

    func testMigrationResumesAfterDirectoryMoveBeforePathRewrite()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-resume-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        let legacyDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateLab",
            isDirectory: true
        )
        let productionDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: productionDirectory,
            withIntermediateDirectories: true
        )
        let legacyRelay = legacyDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
        let manifest: [String: Any] = [
            "assetVersion": 3,
            "installedAt": "2026-10-30T00:00:00Z",
            "protocolVersion": 3,
            "relayPath": legacyRelay.path,
            "schemaIDs": ["luna_pinyin"],
            "backupDirectory":
                legacyDirectory.appendingPathComponent("Backups/test").path,
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        ).write(
            to: productionDirectory.appendingPathComponent(
                "install-manifest.json"
            )
        )
        let marker = glintDirectory.appendingPathComponent(
            ".rime-support-migration-v1"
        )
        try Data().write(to: marker)

        let resolved = try RimeSupportDirectoryMigrator()
            .migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )

        XCTAssertEqual(resolved, productionDirectory)
        let migratedManifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: productionDirectory.appendingPathComponent(
                        "install-manifest.json"
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            migratedManifest["relayPath"] as? String,
            productionDirectory.appendingPathComponent(
                "RimeCandidateBridge"
            ).path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path)
        )
    }

    func testMigrationRewritesPendingTransactionPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-transaction-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        let legacyDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateLab",
            isDirectory: true
        )
        let productionDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateSupport",
            isDirectory: true
        )
        let legacyTransaction = legacyDirectory.appendingPathComponent(
            "Transactions/test",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyTransaction,
            withIntermediateDirectories: true
        )
        let legacyRelay = legacyDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
        let legacySnapshot = legacyTransaction.appendingPathComponent(
            "000.snapshot"
        )
        try Data("snapshot".utf8).write(to: legacySnapshot)
        let pendingTransaction: [String: Any] = [
            "phase": "prepared",
            "schemaIDs": ["luna_pinyin"],
            "transactionDirectory": legacyTransaction.path,
            "entries": [
                [
                    "targetPath": legacyRelay.path,
                    "existed": false,
                    "expectedAbsent": true,
                    "snapshotPath": legacySnapshot.path,
                ]
            ],
        ]
        try JSONSerialization.data(
            withJSONObject: pendingTransaction,
            options: [.sortedKeys]
        ).write(
            to: legacyDirectory.appendingPathComponent(
                "pending-install-transaction.json"
            )
        )

        _ = try RimeSupportDirectoryMigrator().migrateIfNeeded(
            applicationSupportDirectory: applicationSupport
        )

        let migrated = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: productionDirectory.appendingPathComponent(
                        "pending-install-transaction.json"
                    )
                )
            ) as? [String: Any]
        )
        XCTAssertEqual(
            migrated["transactionDirectory"] as? String,
            productionDirectory.appendingPathComponent(
                "Transactions/test"
            ).path
        )
        let entries = try XCTUnwrap(migrated["entries"] as? [[String: Any]])
        XCTAssertEqual(
            entries.first?["targetPath"] as? String,
            productionDirectory.appendingPathComponent(
                "RimeCandidateBridge"
            ).path
        )
        XCTAssertEqual(
            entries.first?["snapshotPath"] as? String,
            productionDirectory.appendingPathComponent(
                "Transactions/test/000.snapshot"
            ).path
        )
    }

    func testMigrationLeavesConflictingDirectoriesUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-conflict-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        let legacyDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateLab",
            isDirectory: true
        )
        let productionDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: productionDirectory,
            withIntermediateDirectories: true
        )
        let legacySentinel = legacyDirectory.appendingPathComponent(
            "legacy"
        )
        let productionSentinel = productionDirectory.appendingPathComponent(
            "production"
        )
        try Data("legacy".utf8).write(to: legacySentinel)
        try Data("production".utf8).write(to: productionSentinel)

        XCTAssertThrowsError(
            try RimeSupportDirectoryMigrator().migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSupportDirectoryMigrationError,
                .directoryConflict
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: legacySentinel),
            Data("legacy".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: productionSentinel),
            Data("production".utf8)
        )
    }

    func testMigrationRejectsSymlinkedLockFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-lock-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        let legacyDirectory = glintDirectory.appendingPathComponent(
            "RimeCandidateLab",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let sentinel = legacyDirectory.appendingPathComponent("sentinel")
        try Data("legacy".utf8).write(to: sentinel)
        let outside = root.appendingPathComponent("outside-lock")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: glintDirectory.appendingPathComponent(
                ".rime-support-migration-v1.lock"
            ),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try RimeSupportDirectoryMigrator().migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSupportDirectoryMigrationError,
                .unsafePath
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("legacy".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: glintDirectory.appendingPathComponent(
                    "RimeCandidateSupport"
                ).path
            )
        )
    }

    func testMigrationRejectsSymlinkedProductionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-target-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: glintDirectory,
            withIntermediateDirectories: true
        )
        let outside = root.appendingPathComponent(
            "outside-support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: glintDirectory.appendingPathComponent(
                "RimeCandidateSupport"
            ),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try RimeSupportDirectoryMigrator().migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSupportDirectoryMigrationError,
                .unsafePath
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("outside".utf8)
        )
    }

    func testMigrationRejectsDanglingLegacySymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "glint-rime-support-dangling-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        let glintDirectory = applicationSupport.appendingPathComponent(
            "Glint",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: glintDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: glintDirectory.appendingPathComponent(
                "RimeCandidateLab"
            ),
            withDestinationURL: root.appendingPathComponent("missing")
        )

        XCTAssertThrowsError(
            try RimeSupportDirectoryMigrator().migrateIfNeeded(
                applicationSupportDirectory: applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? RimeSupportDirectoryMigrationError,
                .unsafePath
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: glintDirectory.appendingPathComponent(
                    "RimeCandidateSupport"
                ).path
            )
        )
    }
}
