import Foundation

extension SquirrelIntegrationService {
    @discardableResult
    public func uninstall() async throws -> SquirrelIntegrationStatus {
        try withProcessLock {
            try uninstallLocked()
        }
    }

    func uninstallLocked() throws -> SquirrelIntegrationStatus {
        try recoverInterruptedTransactionIfNeeded()
        let manifestURL = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        let manifest: Manifest?
        if fileManager.fileExists(atPath: manifestURL.path) {
            if let decoded = try? readManifest() {
                guard isTrustedManifest(decoded) else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                manifest = decoded
            } else {
                manifest = nil
            }
        } else {
            manifest = nil
        }
        let targetURLs = uninstallTargetURLs(
            manifest: manifest,
            manifestURL: manifestURL
        )
        if let manifest {
            try validateUninstall(using: manifest)
        }
        let currentSnapshots = try targetURLs.map {
            try snapshot(of: $0)
        }
        let expectedStates = try expectedUninstallStates(
            manifest: manifest,
            targetURLs: targetURLs,
            snapshots: currentSnapshots
        )
        let transaction = try beginPendingTransaction(
            snapshots: currentSnapshots,
            expectedStates: expectedStates,
            schemaIDs: manifest?.schemaIDs
                ?? compiledSchemaIDs().sorted()
        )
        let originalStates = Dictionary(
            uniqueKeysWithValues: transaction.entries.map {
                ($0.targetPath, $0)
            }
        )
        try runPendingTransaction(transaction) { didWrite in
            if let manifest {
                try applyUninstall(
                    using: manifest,
                    originalStates: originalStates
                )
            } else {
                try applyUnmanagedUninstall(
                    originalStates: originalStates
                )
            }
            didWrite = true
            try reload()
        }
        try? fileManager.removeItem(at: manifestURL)
        if let backupDirectory = manifest?.backupDirectory {
            let url = URL(
                fileURLWithPath: backupDirectory,
                isDirectory: true
            )
            if isManagedBackupDirectory(url) {
                try? fileManager.removeItem(at: url)
            }
        }
        return status()
    }

    func applyUninstall(
        using manifest: Manifest,
        originalStates: [String: PendingTransactionEntry]
    ) throws {
        guard isTrustedManifest(manifest) else {
            throw SquirrelIntegrationError.invalidManifest
        }

        for (targetPath, backupPath) in manifest.backups {
            let target = URL(fileURLWithPath: targetPath)
            if isBridgeAssetURL(target) {
                continue
            }
            let backup = URL(fileURLWithPath: backupPath)
            guard
                isManagedURL(target),
                !isSymbolicLink(at: backup),
                isPath(
                    backup.path,
                    inside: manifest.backupDirectory
                )
            else {
                throw SquirrelIntegrationError.invalidManifest
            }
            let backupData = try Data(contentsOf: backup)
            guard
                let expectedHash = manifest.backupHashes[targetPath],
                Self.sha256(backupData) == expectedHash
            else {
                throw SquirrelIntegrationError.uninstallConflict
            }
            try verifyOriginalState(
                of: target,
                originalStates: originalStates,
                mismatch: .uninstallConflict
            )
            try writeData(
                PlannedWrite(
                    url: target,
                    data: backupData,
                    permissions:
                        manifest.backupPermissions[targetPath]
                )
            )
        }
        for path in manifest.createdFiles {
            let url = URL(fileURLWithPath: path)
            guard isManagedURL(url) else {
                throw SquirrelIntegrationError.invalidManifest
            }
            if fileManager.fileExists(atPath: url.path) {
                try verifyOriginalState(
                    of: url,
                    originalStates: originalStates,
                    mismatch: .uninstallConflict
                )
                try fileManager.removeItem(at: url)
            }
        }
        try removeManagedBridgeAssets(
            originalStates: originalStates
        )
    }

    func validateUninstall(
        using manifest: Manifest
    ) throws {
        guard isTrustedManifest(manifest) else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let managedPaths =
            Array(manifest.backups.keys)
            + manifest.createdFiles
        let createdPaths = Set(manifest.createdFiles)
        for path in managedPaths {
            let url = URL(fileURLWithPath: path)
            guard isManagedURL(url) else {
                throw SquirrelIntegrationError.invalidManifest
            }
            guard let expectedHash = manifest.fileHashes[path] else {
                throw SquirrelIntegrationError.invalidManifest
            }
            let currentData: Data?
            if fileManager.fileExists(atPath: url.path) {
                currentData = try snapshot(of: url).data
            } else {
                currentData = nil
            }
            if currentData == nil, createdPaths.contains(path) {
                continue
            }
            guard
                let currentData,
                Self.sha256(currentData) == expectedHash
            else {
                throw SquirrelIntegrationError.uninstallConflict
            }
        }
        for (path, backupPath) in manifest.backups {
            guard let expectedHash = manifest.backupHashes[path] else {
                throw SquirrelIntegrationError.invalidManifest
            }
            let backupData = try Data(
                contentsOf: URL(fileURLWithPath: backupPath)
            )
            guard Self.sha256(backupData) == expectedHash else {
                throw SquirrelIntegrationError.uninstallConflict
            }
        }
    }

    func applyUnmanagedUninstall(
        originalStates: [String: PendingTransactionEntry]
    ) throws {
        for schemaID in compiledSchemaIDs() {
            let url = schemaCustomURL(schemaID: schemaID)
            let current = try snapshot(of: url)
            guard let currentData = current.data else { continue }
            let removed = try originalDataWithoutManagedFilter(
                for: url,
                data: currentData,
                removingEmptyFilterKey: false
            )
            if removed != currentData {
                try verifyOriginalState(
                    of: url,
                    originalStates: originalStates,
                    mismatch: .uninstallConflict
                )
                try writeData(
                    PlannedWrite(
                        url: url,
                        data: removed,
                        permissions: current.permissions
                    )
                )
            }
        }
        try removeManagedBridgeAssets(
            originalStates: originalStates
        )
    }

    func removeManagedBridgeAssets(
        originalStates: [String: PendingTransactionEntry]
    ) throws {
        let urls =
            [relayDestination]
            + Self.luaFileNames.map(luaDestination(named:))
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try verifyOriginalState(
                of: url,
                originalStates: originalStates,
                mismatch: .uninstallConflict
            )
            try fileManager.removeItem(at: url)
        }
    }

    func isBridgeAssetURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == relayDestination.standardizedFileURL.path
            || Self.luaFileNames.contains {
                luaDestination(named: $0).standardizedFileURL.path == path
            }
    }

    func uninstallTargetURLs(
        manifest: Manifest?,
        manifestURL: URL
    ) -> [URL] {
        var paths = Set<String>()
        paths.insert(manifestURL.path)
        paths.insert(relayDestination.path)
        for name in Self.luaFileNames {
            paths.insert(luaDestination(named: name).path)
        }
        if let manifest {
            for path in manifest.backups.keys {
                paths.insert(path)
            }
            for path in manifest.createdFiles {
                paths.insert(path)
            }
        } else {
            for schemaID in compiledSchemaIDs() {
                paths.insert(schemaCustomURL(schemaID: schemaID).path)
            }
        }
        return
            paths
            .map(URL.init(fileURLWithPath:))
            .filter(isManagedURL)
    }

    func expectedUninstallStates(
        manifest: Manifest?,
        targetURLs: [URL],
        snapshots: [Snapshot]
    ) throws -> [String: ExpectedTransactionState] {
        let snapshotsByPath = Dictionary(
            uniqueKeysWithValues: snapshots.map {
                ($0.url.standardizedFileURL.path, $0)
            }
        )
        var states: [String: ExpectedTransactionState] = [:]
        if let manifestSnapshot = snapshotsByPath[
            manifestURL.standardizedFileURL.path
        ] {
            states[manifestURL.path] = ExpectedTransactionState(
                hash: manifestSnapshot.data.map(Self.sha256),
                absent: manifestSnapshot.data == nil
            )
        }
        let assetPaths =
            [relayDestination.path]
            + Self.luaFileNames.map {
                luaDestination(named: $0).path
            }
        for path in assetPaths {
            states[path] = ExpectedTransactionState(
                hash: nil,
                absent: true
            )
        }

        if let manifest {
            for (targetPath, backupPath) in manifest.backups {
                if isBridgeAssetURL(
                    URL(fileURLWithPath: targetPath)
                ) {
                    continue
                }
                let backupData = try Data(
                    contentsOf: URL(fileURLWithPath: backupPath)
                )
                guard
                    let expectedHash =
                        manifest.backupHashes[targetPath],
                    Self.sha256(backupData) == expectedHash
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                states[targetPath] = ExpectedTransactionState(
                    hash: expectedHash,
                    absent: false
                )
            }
            for path in manifest.createdFiles {
                states[path] = ExpectedTransactionState(
                    hash: nil,
                    absent: true
                )
            }
        } else {
            for schemaID in compiledSchemaIDs() {
                let url = schemaCustomURL(schemaID: schemaID)
                guard
                    let snapshot = snapshotsByPath[
                        url.standardizedFileURL.path
                    ]
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                let expected: Data?
                if let data = snapshot.data {
                    expected = try originalDataWithoutManagedFilter(
                        for: url,
                        data: data,
                        removingEmptyFilterKey: false
                    )
                } else {
                    expected = nil
                }
                states[url.path] = ExpectedTransactionState(
                    hash: expected.map(Self.sha256),
                    absent: expected == nil
                )
            }
        }
        for url in targetURLs {
            guard states[url.path] != nil else {
                throw SquirrelIntegrationError.invalidManifest
            }
        }
        return states
    }
}
