import Foundation
import GlintRimeRelayCore

extension SquirrelIntegrationService {
    @discardableResult
    public func install() async throws -> SquirrelIntegrationStatus {
        try withProcessLock {
            try installLocked()
        }
    }

    func installLocked() throws -> SquirrelIntegrationStatus {
        try recoverInterruptedTransactionIfNeeded()
        guard fileManager.fileExists(atPath: squirrelApplication.path)
        else {
            throw SquirrelIntegrationError.squirrelUnavailable
        }
        let compiledSchemas = compiledSchemaIDs()
        guard !compiledSchemas.isEmpty else {
            throw SquirrelIntegrationError.noCompiledSchemas
        }
        let schemas = try enabledSchemaIDs(
            compiledSchemaIDs: compiledSchemas
        )
        let previousManifest: Manifest?
        let manifestURL = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        if fileManager.fileExists(atPath: manifestURL.path) {
            let manifest = try readManifest()
            guard isTrustedManifest(manifest) else {
                throw SquirrelIntegrationError.invalidManifest
            }
            previousManifest = manifest
        } else {
            previousManifest = nil
        }
        let desiredWrites = try desiredInstallWrites(
            schemas: schemas
        )

        let plan = try planInstallWrites(
            desiredWrites: desiredWrites,
            previousManifest: previousManifest,
            schemas: schemas
        )
        if plan.plannedWrites.isEmpty,
            isCurrentInstallManifest(
                previousManifest,
                schemas: plan.managedSchemaIDs
            )
        {
            return status()
        }

        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let backupRoot = supportDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        guard isSafeDedicatedDirectoryRoot(backupRoot) else {
            throw SquirrelIntegrationError.unsafePath
        }
        let backupDirectory = backupRoot.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: backupDirectory.path
        )

        let previousBackups = previousManifest?.backups ?? [:]
        var snapshots = Array(plan.plannedSnapshots.values)
        var backups: [String: String] = [:]
        var backupHashes: [String: String] = [:]
        var backupPermissions: [String: Int] = [:]
        let backupTargets = Set(
            plan.plannedSnapshots.compactMap { path, snapshot in
                snapshot.data == nil
                    || plan.createdFiles.contains(path)
                    ? nil
                    : path
            }
                + plan.carriedBackupPaths.keys
        )
        for (index, path) in backupTargets.sorted().enumerated() {
            var originalData: Data
            let originalPermissions: Int?
            if let previousBackupPath = previousBackups[path] {
                let previousBackup = URL(
                    fileURLWithPath: previousBackupPath
                )
                originalData = try Data(contentsOf: previousBackup)
                guard
                    let expectedHash =
                        previousManifest?.backupHashes[path],
                    Self.sha256(originalData) == expectedHash
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                originalPermissions =
                    previousManifest?.backupPermissions[path]
            } else {
                guard let snapshot = plan.plannedSnapshots[path],
                    let data = snapshot.data
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                originalData = data
                originalPermissions = snapshot.permissions
            }
            let backupURL = backupDirectory.appendingPathComponent(
                String(format: "%03d.backup", index)
            )
            try originalData.write(to: backupURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backupURL.path
            )
            backups[path] = backupURL.path
            backupHashes[path] = Self.sha256(originalData)
            if let originalPermissions {
                backupPermissions[path] = originalPermissions
            }
        }
        snapshots.append(try snapshot(of: manifestURL))
        guard
            try enabledSchemaIDs(compiledSchemaIDs: compiledSchemas)
                == schemas
        else {
            throw SquirrelIntegrationError.installConflict
        }

        let manifest = Manifest(
            assetVersion: Self.currentBridgeAssetVersion,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: RimeCandidateEnvelope.currentVersion,
            relayPath: relayDestination.path,
            schemaIDs: plan.managedSchemaIDs,
            backupDirectory: backupDirectory.path,
            backups: backups,
            createdFiles: plan.createdFiles.sorted(),
            fileHashes: plan.managedHashes.merging(
                plan.unownedHashes,
                uniquingKeysWith: { current, _ in current }
            ),
            backupHashes: backupHashes,
            backupPermissions: backupPermissions
        )

        let manifestData = try JSONEncoder().encode(manifest)
        var expectedStates: [String: ExpectedTransactionState] = [:]
        for write in plan.plannedWrites {
            expectedStates[write.url.path] = ExpectedTransactionState(
                hash: Self.sha256(write.data),
                absent: false
            )
        }
        expectedStates[manifestURL.path] = ExpectedTransactionState(
            hash: Self.sha256(manifestData),
            absent: false
        )
        let transaction = try beginPendingTransaction(
            snapshots: snapshots,
            expectedStates: expectedStates,
            schemaIDs: plan.managedSchemaIDs
        )
        let originalStates = Dictionary(
            uniqueKeysWithValues: transaction.entries.map {
                ($0.targetPath, $0)
            }
        )
        try runPendingTransaction(transaction) { didWrite in
            for write in plan.plannedWrites {
                let expected = plan.plannedSnapshots[write.url.path]
                let current = try snapshot(of: write.url)
                guard
                    current.data == expected?.data,
                    current.permissions == expected?.permissions
                else {
                    throw SquirrelIntegrationError.installConflict
                }
                try writeData(write)
                didWrite = true
            }
            try verifyOriginalState(
                of: manifestURL,
                originalStates: originalStates,
                mismatch: .installConflict
            )
            try writeData(
                PlannedWrite(
                    url: manifestURL,
                    data: manifestData,
                    permissions: 0o600
                )
            )
            didWrite = true
            if !plan.plannedWrites.isEmpty {
                try reload()
            }
        }
        if let previousBackupDirectory =
            previousManifest?.backupDirectory
        {
            let url = URL(
                fileURLWithPath: previousBackupDirectory,
                isDirectory: true
            )
            if isManagedBackupDirectory(url) {
                try? fileManager.removeItem(at: url)
            }
        }
        return status()
    }

    func desiredInstallWrites(
        schemas: [String]
    ) throws -> [DesiredInstallWrite] {
        let luaAssets = try loadLuaAssets()
        let relayData: Data
        do {
            relayData = try Data(contentsOf: relaySource)
        } catch {
            throw SquirrelIntegrationError.missingBundledAssets
        }

        var desiredWrites = luaAssets.map { asset in
            DesiredInstallWrite(
                write: PlannedWrite(
                    url: luaDestination(named: asset.name),
                    data: asset.data,
                    permissions: nil
                ),
                isSchemaPatch: false,
                changedByPatchEditor: true
            )
        }
        desiredWrites.append(
            DesiredInstallWrite(
                write: PlannedWrite(
                    url: relayDestination,
                    data: relayData,
                    permissions: 0o700
                ),
                isSchemaPatch: false,
                changedByPatchEditor: true
            )
        )

        for schemaID in schemas {
            let customURL = schemaCustomURL(schemaID: schemaID)
            let source: String?
            let hasByteOrderMark: Bool
            let existingData = try snapshot(of: customURL).data
            if fileManager.fileExists(atPath: customURL.path) {
                guard let existingData else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                let bom = Data([0xEF, 0xBB, 0xBF])
                hasByteOrderMark = existingData.starts(with: bom)
                let sourceData =
                    hasByteOrderMark
                    ? existingData.dropFirst(bom.count)
                    : existingData[...]
                guard
                    let decoded = String(
                        data: Data(sourceData),
                        encoding: .utf8
                    )
                else {
                    throw SquirrelIntegrationError.unsupportedSchema(
                        schemaID,
                        .missingPatchRoot
                    )
                }
                source = decoded
            } else {
                source = nil
                hasByteOrderMark = false
            }
            let result: RimeSchemaPatchResult
            do {
                result = try patchEditor.install(
                    into: source,
                    schemaID: schemaID
                )
            } catch let error as RimeSchemaPatchError {
                throw SquirrelIntegrationError.unsupportedSchema(
                    schemaID,
                    error
                )
            }
            var patchedData = Data(result.source.utf8)
            if hasByteOrderMark {
                patchedData.insert(
                    contentsOf: [0xEF, 0xBB, 0xBF],
                    at: 0
                )
            }
            desiredWrites.append(
                DesiredInstallWrite(
                    write: PlannedWrite(
                        url: customURL,
                        data: patchedData,
                        permissions: nil
                    ),
                    isSchemaPatch: true,
                    changedByPatchEditor: result.changed
                )
            )
        }
        return desiredWrites
    }

    func planInstallWrites(
        desiredWrites: [DesiredInstallWrite],
        previousManifest: Manifest?,
        schemas: [String]
    ) throws -> InstallPlan {
        let previousBackups = previousManifest?.backups ?? [:]
        let previousCreatedFiles = Set(
            previousManifest?.createdFiles ?? []
        )
        var plannedWrites: [PlannedWrite] = []
        var plannedSnapshots: [String: Snapshot] = [:]
        var carriedBackupPaths: [String: String] = [:]
        var createdFiles: Set<String> = []
        var managedHashes: [String: String] = [:]
        var unownedHashes: [String: String] = [:]

        for desired in desiredWrites {
            let path = desired.write.url.path
            guard isManagedURL(desired.write.url) else {
                throw SquirrelIntegrationError.unsafePath
            }
            let current = try snapshot(of: desired.write.url)
            let previouslyBackedUp = previousBackups[path]
            let previouslyCreated = previousCreatedFiles.contains(path)
            let previouslyOwned =
                previouslyBackedUp != nil || previouslyCreated
            let currentHash = current.data.map(Self.sha256)
            if previouslyOwned,
                current.data != desired.write.data,
                previousManifest?.fileHashes[path] == nil
            {
                throw SquirrelIntegrationError.installConflict
            }
            if previouslyOwned,
                let expectedHash =
                    previousManifest?.fileHashes[path],
                currentHash != expectedHash
            {
                let canRecreateDeletedFile =
                    current.data == nil && previouslyCreated
                if !canRecreateDeletedFile {
                    throw SquirrelIntegrationError.installConflict
                }
            }
            if desired.isSchemaPatch,
                !desired.changedByPatchEditor,
                !previouslyOwned
            {
                unownedHashes[path] = Self.sha256(desired.write.data)
                continue
            }

            managedHashes[path] = Self.sha256(desired.write.data)
            if current.data == desired.write.data {
                if previouslyCreated {
                    createdFiles.insert(path)
                } else if let backupPath = previouslyBackedUp {
                    carriedBackupPaths[path] = backupPath
                }
                continue
            }
            if !previouslyOwned {
                unownedHashes[path] = nil
            }
            plannedWrites.append(desired.write)
            plannedSnapshots[path] = current
            if previouslyCreated {
                createdFiles.insert(path)
            } else if current.data == nil {
                createdFiles.insert(path)
            }
        }

        var managedSchemaIDs = schemas
        for schemaID in previousManifest?.schemaIDs ?? []
        where !managedSchemaIDs.contains(schemaID) {
            managedSchemaIDs.append(schemaID)
        }
        let desiredPaths = Set(
            desiredWrites.map(\.write.url.path)
        )
        for path in previousBackups.keys
        where !desiredPaths.contains(path) {
            guard
                let expectedHash =
                    previousManifest?.fileHashes[path]
            else {
                throw SquirrelIntegrationError.installConflict
            }
            carriedBackupPaths[path] = previousBackups[path]
            managedHashes[path] = expectedHash
        }
        for path in previousCreatedFiles
        where !desiredPaths.contains(path) {
            guard
                let expectedHash =
                    previousManifest?.fileHashes[path]
            else {
                throw SquirrelIntegrationError.installConflict
            }
            createdFiles.insert(path)
            managedHashes[path] = expectedHash
        }

        return InstallPlan(
            plannedWrites: plannedWrites,
            plannedSnapshots: plannedSnapshots,
            carriedBackupPaths: carriedBackupPaths,
            createdFiles: createdFiles,
            managedHashes: managedHashes,
            unownedHashes: unownedHashes,
            managedSchemaIDs: managedSchemaIDs
        )
    }

    func isCurrentInstallManifest(
        _ manifest: Manifest?,
        schemas: [String]
    ) -> Bool {
        manifest?.assetVersion == Self.currentBridgeAssetVersion
            && manifest?.protocolVersion
                == RimeCandidateEnvelope.currentVersion
            && manifest?.schemaIDs == schemas
    }
}
