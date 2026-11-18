import Darwin
import Foundation

extension SquirrelIntegrationService {
    func verifyOriginalState(
        of url: URL,
        originalStates: [String: PendingTransactionEntry],
        mismatch: SquirrelIntegrationError
    ) throws {
        guard let original = originalStates[url.path] else {
            throw SquirrelIntegrationError.invalidManifest
        }
        guard !isSymbolicLink(at: url) else {
            throw SquirrelIntegrationError.unsafePath
        }
        if original.existed {
            guard
                fileManager.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url),
                Self.sha256(data) == original.snapshotHash,
                original.permissions == nil
                    || ((try? permissions(of: url)) ?? nil)
                        == original.permissions
            else {
                throw mismatch
            }
        } else if fileManager.fileExists(atPath: url.path) {
            throw mismatch
        }
    }

    func readPendingTransaction() throws -> PendingTransaction {
        guard !isSymbolicLink(at: pendingTransactionURL) else {
            throw SquirrelIntegrationError.invalidManifest
        }
        do {
            let data = try Data(contentsOf: pendingTransactionURL)
            return try JSONDecoder().decode(
                PendingTransaction.self,
                from: data
            )
        } catch {
            throw SquirrelIntegrationError.invalidManifest
        }
    }

    func withProcessLock<T>(
        _ body: () throws -> T
    ) throws -> T {
        Self.installationProcessLock.lock()
        defer {
            Self.installationProcessLock.unlock()
        }
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let lockURL = supportDirectory.appendingPathComponent(
            ".rime-install.lock"
        )
        guard isManagedURL(lockURL) else {
            throw SquirrelIntegrationError.unsafePath
        }
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw SquirrelIntegrationError.lockFailed
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw SquirrelIntegrationError.lockFailed
        }
        var fileLock = Darwin.flock()
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        fileLock.l_start = 0
        fileLock.l_len = 0
        while Darwin.fcntl(
            descriptor,
            F_SETLKW,
            &fileLock
        ) == -1 {
            if errno == EINTR { continue }
            throw SquirrelIntegrationError.lockFailed
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(
                descriptor,
                F_SETLK,
                &unlock
            )
        }
        return try body()
    }

    func writePendingTransaction(
        _ transaction: PendingTransaction
    ) throws {
        guard !isSymbolicLink(at: pendingTransactionURL) else {
            throw SquirrelIntegrationError.unsafePath
        }
        try writeData(
            PlannedWrite(
                url: pendingTransactionURL,
                data: try JSONEncoder().encode(transaction),
                permissions: 0o600
            )
        )
    }

    func beginPendingTransaction(
        snapshots: [Snapshot],
        expectedStates: [String: ExpectedTransactionState],
        schemaIDs: [String]
    ) throws -> PendingTransaction {
        guard
            !fileManager.fileExists(
                atPath: pendingTransactionURL.path
            )
        else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let transactionRoot = supportDirectory.appendingPathComponent(
            "Transactions",
            isDirectory: true
        )
        guard isSafeDedicatedDirectoryRoot(transactionRoot) else {
            throw SquirrelIntegrationError.unsafePath
        }
        try fileManager.createDirectory(
            at: transactionRoot,
            withIntermediateDirectories: true
        )
        let transactionDirectory =
            transactionRoot.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: transactionDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: transactionDirectory.path
        )
        var entries: [PendingTransactionEntry] = []
        let orderedSnapshots = snapshots.sorted {
            $0.url.path < $1.url.path
        }
        for (index, snapshot) in orderedSnapshots.enumerated() {
            guard isManagedURL(snapshot.url) else {
                throw SquirrelIntegrationError.unsafePath
            }
            guard let expected = expectedStates[snapshot.url.path],
                expected.absent || expected.hash != nil
            else {
                throw SquirrelIntegrationError.invalidManifest
            }
            if let data = snapshot.data {
                let snapshotURL =
                    transactionDirectory.appendingPathComponent(
                        String(format: "%03d.snapshot", index)
                    )
                try data.write(to: snapshotURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: snapshotURL.path
                )
                entries.append(
                    PendingTransactionEntry(
                        targetPath: snapshot.url.path,
                        existed: true,
                        snapshotPath: snapshotURL.path,
                        snapshotHash: Self.sha256(data),
                        expectedHash: expected.hash,
                        expectedAbsent: expected.absent,
                        permissions: snapshot.permissions
                    )
                )
            } else {
                entries.append(
                    PendingTransactionEntry(
                        targetPath: snapshot.url.path,
                        existed: false,
                        snapshotPath: nil,
                        snapshotHash: nil,
                        expectedHash: expected.hash,
                        expectedAbsent: expected.absent,
                        permissions: nil
                    )
                )
            }
        }
        let transaction = PendingTransaction(
            phase: .prepared,
            schemaIDs: schemaIDs,
            transactionDirectory: transactionDirectory.path,
            entries: entries
        )
        try validate(transaction)
        try writePendingTransaction(transaction)
        return transaction
    }

    func rollbackPendingTransaction(
        _ transaction: PendingTransaction
    ) throws {
        do {
            try restorePendingTransaction(transaction)
        } catch {
            throw SquirrelIntegrationError.rollbackFailed
        }
        var committed = transaction
        committed.phase = .committed
        do {
            try writePendingTransaction(committed)
            try finishPendingTransaction(committed)
        } catch {
            throw SquirrelIntegrationError.rollbackFailed
        }
    }

    func commitPendingTransaction(
        _ transaction: PendingTransaction
    ) throws {
        var committed = transaction
        committed.phase = .committed
        do {
            try writePendingTransaction(committed)
            try finishPendingTransaction(committed)
        } catch {
            throw SquirrelIntegrationError.rollbackFailed
        }
    }

    func runPendingTransaction(
        _ transaction: PendingTransaction,
        apply: (inout Bool) throws -> Void
    ) throws {
        var didWrite = false
        do {
            try apply(&didWrite)
            try commitPendingTransaction(transaction)
        } catch SquirrelIntegrationError.reloadFailed {
            try rollbackPendingTransaction(transaction)
            do {
                try reload()
            } catch {
                throw SquirrelIntegrationError.reloadFailed
            }
            throw SquirrelIntegrationError.reloadFailed
        } catch let error as SquirrelIntegrationError {
            if fileManager.fileExists(
                atPath: pendingTransactionURL.path
            ) {
                try rollbackPendingTransaction(transaction)
            }
            if didWrite {
                do {
                    try reload()
                } catch {
                    throw SquirrelIntegrationError.reloadFailed
                }
            }
            throw error
        } catch {
            if fileManager.fileExists(
                atPath: pendingTransactionURL.path
            ) {
                try rollbackPendingTransaction(transaction)
            }
            if didWrite {
                do {
                    try reload()
                } catch {
                    throw SquirrelIntegrationError.reloadFailed
                }
            }
            throw error
        }
    }

    func finishPendingTransaction(
        _ transaction: PendingTransaction
    ) throws {
        if fileManager.fileExists(atPath: pendingTransactionURL.path) {
            try fileManager.removeItem(at: pendingTransactionURL)
        }
        let directory = URL(
            fileURLWithPath: transaction.transactionDirectory,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
    }

    func validate(_ transaction: PendingTransaction) throws {
        guard
            Set(transaction.schemaIDs).count
                == transaction.schemaIDs.count,
            transaction.schemaIDs.allSatisfy(Self.isValidSchemaID)
        else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let transactionDirectory = URL(
            fileURLWithPath: transaction.transactionDirectory,
            isDirectory: true
        )
        guard
            !isSymbolicLink(at: transactionDirectory),
            isManagedTransactionDirectory(transactionDirectory)
        else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let allowedPaths = Set(
            (managedTargetURLs(schemaIDs: transaction.schemaIDs)
                + [pendingTransactionURL, manifestURL]).map { $0.standardizedFileURL.path }
        )
        guard
            Set(transaction.entries.map(\.targetPath)).count
                == transaction.entries.count
        else {
            throw SquirrelIntegrationError.invalidManifest
        }
        for entry in transaction.entries {
            let target = URL(fileURLWithPath: entry.targetPath)
            guard
                allowedPaths.contains(
                    target.standardizedFileURL.path
                ),
                isManagedURL(target),
                !(entry.expectedAbsent && entry.expectedHash != nil),
                entry.expectedAbsent || entry.expectedHash != nil,
                (entry.permissions.map { (0...0o777).contains($0) }
                    ?? true)
            else {
                throw SquirrelIntegrationError.invalidManifest
            }
            if entry.existed {
                guard
                    let snapshotPath = entry.snapshotPath,
                    let snapshotHash = entry.snapshotHash
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
                let snapshot = URL(fileURLWithPath: snapshotPath)
                guard
                    isPath(
                        snapshot.path,
                        inside: transaction.transactionDirectory
                    ),
                    !isSymbolicLink(at: snapshot),
                    let data = try? Data(contentsOf: snapshot),
                    Self.sha256(data) == snapshotHash
                else {
                    throw SquirrelIntegrationError.invalidManifest
                }
            } else if entry.snapshotPath != nil
                || entry.snapshotHash != nil
            {
                throw SquirrelIntegrationError.invalidManifest
            }
        }
    }

    func restorePendingTransaction(
        _ transaction: PendingTransaction
    ) throws {
        for entry in transaction.entries {
            let target = URL(fileURLWithPath: entry.targetPath)
            guard
                !isSymbolicLink(at: target),
                isManagedURL(target)
            else {
                throw SquirrelIntegrationError.rollbackFailed
            }
            let currentHash: String?
            if fileManager.fileExists(atPath: target.path) {
                guard let data = try? Data(contentsOf: target) else {
                    throw SquirrelIntegrationError.rollbackFailed
                }
                currentHash = Self.sha256(data)
            } else {
                currentHash = nil
            }
            let matchesOriginal =
                entry.existed
                ? currentHash == entry.snapshotHash
                : currentHash == nil
            let matchesExpected =
                entry.expectedAbsent
                ? currentHash == nil
                : currentHash == entry.expectedHash
            guard matchesOriginal || matchesExpected else {
                throw SquirrelIntegrationError.rollbackFailed
            }
            if entry.existed {
                guard
                    let snapshotPath = entry.snapshotPath,
                    let snapshotHash = entry.snapshotHash
                else {
                    throw SquirrelIntegrationError.rollbackFailed
                }
                let data = try Data(
                    contentsOf: URL(fileURLWithPath: snapshotPath)
                )
                guard Self.sha256(data) == snapshotHash else {
                    throw SquirrelIntegrationError.rollbackFailed
                }
                do {
                    try writeData(
                        PlannedWrite(
                            url: target,
                            data: data,
                            permissions: entry.permissions
                        )
                    )
                    guard
                        try Data(contentsOf: target) == data,
                        try permissions(of: target)
                            == entry.permissions
                    else {
                        throw SquirrelIntegrationError.rollbackFailed
                    }
                } catch let error as SquirrelIntegrationError {
                    throw error
                } catch {
                    throw SquirrelIntegrationError.rollbackFailed
                }
            } else {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                guard !fileManager.fileExists(atPath: target.path) else {
                    throw SquirrelIntegrationError.rollbackFailed
                }
            }
        }
    }
}
