import Darwin
import Foundation

public enum RimeSupportDirectoryMigrationError:
    Error, Equatable, Sendable
{
    case unsafePath
    case directoryConflict
}

public struct RimeSupportDirectoryMigrator {
    private static let currentDirectoryName =
        "RimeCandidateSupport"
    private static let legacyDirectoryName =
        "RimeCandidateLab"
    private static let migrationMarkerName =
        ".rime-support-migration-v1"
    private static let migrationLockName =
        ".rime-support-migration-v1.lock"
    private static let ownedJSONFileNames = [
        "install-manifest.json",
        "pending-install-transaction.json",
    ]

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func productionDirectory(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Glint", isDirectory: true)
            .appendingPathComponent(
                currentDirectoryName,
                isDirectory: true
            )
    }

    public static func legacyDirectory(
        applicationSupportDirectory: URL
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Glint", isDirectory: true)
            .appendingPathComponent(
                legacyDirectoryName,
                isDirectory: true
            )
    }

    public func migrateIfNeeded(
        applicationSupportDirectory: URL
    ) throws -> URL {
        let glintDirectory =
            applicationSupportDirectory
            .appendingPathComponent("Glint", isDirectory: true)
        guard
            !pathEntryExists(at: glintDirectory)
                || !isSymbolicLink(at: glintDirectory)
        else {
            throw RimeSupportDirectoryMigrationError.unsafePath
        }
        try fileManager.createDirectory(
            at: glintDirectory,
            withIntermediateDirectories: true
        )
        return try withMigrationLock(
            at: glintDirectory.appendingPathComponent(
                Self.migrationLockName
            )
        ) {
            try migrateLocked(
                glintDirectory: glintDirectory,
                applicationSupportDirectory: applicationSupportDirectory
            )
        }
    }

    private func migrateLocked(
        glintDirectory: URL,
        applicationSupportDirectory: URL
    ) throws -> URL {
        let currentDirectory = Self.productionDirectory(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let legacyDirectory = Self.legacyDirectory(
            applicationSupportDirectory: applicationSupportDirectory
        )
        let migrationMarker = glintDirectory.appendingPathComponent(
            Self.migrationMarkerName
        )
        let currentExists = pathEntryExists(at: currentDirectory)
        let legacyExists = pathEntryExists(at: legacyDirectory)
        if currentExists {
            guard !legacyExists else {
                throw RimeSupportDirectoryMigrationError.directoryConflict
            }
            guard
                !isSymbolicLink(at: currentDirectory),
                isDirectory(at: currentDirectory)
            else {
                throw RimeSupportDirectoryMigrationError.unsafePath
            }
            if pathEntryExists(at: migrationMarker) {
                try validateMarker(at: migrationMarker)
                try rewriteOwnedJSONPaths(
                    in: currentDirectory,
                    replacing: legacyDirectory.path,
                    with: currentDirectory.path
                )
                try fileManager.removeItem(at: migrationMarker)
            }
            return currentDirectory
        }
        guard legacyExists else {
            return currentDirectory
        }
        guard
            !isSymbolicLink(at: legacyDirectory),
            isDirectory(at: legacyDirectory)
        else {
            throw RimeSupportDirectoryMigrationError.unsafePath
        }

        if pathEntryExists(at: migrationMarker) {
            try validateMarker(at: migrationMarker)
        } else {
            try Data().write(
                to: migrationMarker,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: migrationMarker.path
            )
        }
        try fileManager.moveItem(
            at: legacyDirectory,
            to: currentDirectory
        )
        try rewriteOwnedJSONPaths(
            in: currentDirectory,
            replacing: legacyDirectory.path,
            with: currentDirectory.path
        )
        try fileManager.removeItem(at: migrationMarker)
        return currentDirectory
    }

    private func withMigrationLock<T>(
        at url: URL,
        body: () throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw RimeSupportDirectoryMigrationError.unsafePath
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw RimeSupportDirectoryMigrationError.unsafePath
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        while Darwin.fcntl(
            descriptor,
            F_SETLKW,
            &lock
        ) == -1 {
            if errno == EINTR { continue }
            throw RimeSupportDirectoryMigrationError.unsafePath
        }
        defer {
            var unlock = Darwin.flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
        }
        return try body()
    }

    private func validateMarker(at url: URL) throws {
        guard
            !isSymbolicLink(at: url),
            (try? fileManager.attributesOfItem(
                atPath: url.path
            )[.type] as? FileAttributeType) == .typeRegular
        else {
            throw RimeSupportDirectoryMigrationError.unsafePath
        }
    }

    private func rewriteOwnedJSONPaths(
        in directory: URL,
        replacing oldRoot: String,
        with newRoot: String
    ) throws {
        for fileName in Self.ownedJSONFileNames {
            let file = directory.appendingPathComponent(fileName)
            guard pathEntryExists(at: file) else {
                continue
            }
            guard !isSymbolicLink(at: file) else {
                throw RimeSupportDirectoryMigrationError.unsafePath
            }
            let originalData = try Data(contentsOf: file)
            let object = try JSONSerialization.jsonObject(
                with: originalData
            )
            let (rewrittenObject, changed) = rewriteJSONValue(
                object,
                replacing: oldRoot,
                with: newRoot
            )
            guard changed else { continue }
            let permissions =
                try fileManager.attributesOfItem(
                    atPath: file.path
                )[.posixPermissions] as? NSNumber
            let data = try JSONSerialization.data(
                withJSONObject: rewrittenObject,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: file, options: .atomic)
            if let permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: file.path
                )
            }
        }
    }

    private func rewriteJSONValue(
        _ value: Any,
        replacing oldRoot: String,
        with newRoot: String
    ) -> (Any, Bool) {
        if let string = value as? String {
            let rewritten = rewritePath(
                string,
                replacing: oldRoot,
                with: newRoot
            )
            return (rewritten, rewritten != string)
        }
        if let dictionary = value as? [String: Any] {
            var changed = false
            var rewritten: [String: Any] = [:]
            rewritten.reserveCapacity(dictionary.count)
            for (key, entry) in dictionary {
                let newKey = rewritePath(
                    key,
                    replacing: oldRoot,
                    with: newRoot
                )
                let (newEntry, entryChanged) = rewriteJSONValue(
                    entry,
                    replacing: oldRoot,
                    with: newRoot
                )
                changed = changed || newKey != key || entryChanged
                rewritten[newKey] = newEntry
            }
            return (rewritten, changed)
        }
        if let array = value as? [Any] {
            var changed = false
            let rewritten = array.map { entry in
                let (newEntry, entryChanged) = rewriteJSONValue(
                    entry,
                    replacing: oldRoot,
                    with: newRoot
                )
                changed = changed || entryChanged
                return newEntry
            }
            return (rewritten, changed)
        }
        return (value, false)
    }

    private func rewritePath(
        _ path: String,
        replacing oldRoot: String,
        with newRoot: String
    ) -> String {
        guard
            path == oldRoot
                || path.hasPrefix(oldRoot + "/")
        else {
            return path
        }
        return newRoot + path.dropFirst(oldRoot.count)
    }

    private func isDirectory(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(
            atPath: url.path
        )[.type] as? FileAttributeType) == .typeDirectory
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil
    }

    private func pathEntryExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || isSymbolicLink(at: url)
    }
}
