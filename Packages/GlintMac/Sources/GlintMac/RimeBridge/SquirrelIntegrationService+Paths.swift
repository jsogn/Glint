import Foundation

extension SquirrelIntegrationService {
    func isManagedURL(_ url: URL) -> Bool {
        isPath(url.path, inside: rimeDirectory.path)
            || isPath(url.path, inside: supportDirectory.path)
    }

    func isManagedBackupDirectory(_ url: URL) -> Bool {
        let backupRoot = supportDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        guard
            isSafeDedicatedDirectoryRoot(backupRoot),
            !isSymbolicLink(at: url),
            isLexicallyInside(url, root: backupRoot)
        else {
            return false
        }
        let path = canonicalPath(of: url)
        let root = canonicalPath(of: backupRoot)
        return path != root && isPath(path, inside: root)
    }

    func isManagedTransactionDirectory(_ url: URL) -> Bool {
        let transactionRoot = supportDirectory.appendingPathComponent(
            "Transactions",
            isDirectory: true
        )
        guard
            isSafeDedicatedDirectoryRoot(transactionRoot),
            !isSymbolicLink(at: url),
            isLexicallyInside(url, root: transactionRoot)
        else {
            return false
        }
        let path = canonicalPath(of: url)
        let root = canonicalPath(of: transactionRoot)
        return path != root && isPath(path, inside: root)
    }

    func isSafeDedicatedDirectoryRoot(_ url: URL) -> Bool {
        guard
            pathsEqual(url.deletingLastPathComponent(), supportDirectory),
            !isSymbolicLink(at: url)
        else {
            return false
        }
        return isPath(url.path, inside: supportDirectory.path)
            && canonicalPath(of: url) != canonicalPath(of: supportDirectory)
    }

    func isLexicallyInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    func isPath(_ path: String, inside root: String) -> Bool {
        let resolvedPath = canonicalPath(
            of: URL(fileURLWithPath: path)
        )
        let resolvedRoot = canonicalPath(
            of: URL(fileURLWithPath: root)
        )
        return resolvedPath == resolvedRoot
            || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    func managedTargetURLs(schemaIDs: [String]) -> [URL] {
        [relayDestination]
            + Self.luaFileNames.map(luaDestination(named:))
            + schemaIDs.map(schemaCustomURL(schemaID:))
    }

    func canonicalPath(of url: URL) -> String {
        let standardized = url.standardizedFileURL
        var existing = standardized
        var missingComponents: [String] = []
        while !fileManager.fileExists(atPath: existing.path),
            existing.path != "/"
        {
            missingComponents.insert(
                existing.lastPathComponent,
                at: 0
            )
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missingComponents {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    func pathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path
            == rhs.standardizedFileURL.path
    }

    func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil
    }

    func permissions(of url: URL) throws -> Int? {
        (try fileManager.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber)?.intValue
    }

    func luaDestination(named name: String) -> URL {
        rimeDirectory.appendingPathComponent(
            "lua/glint/\(name)"
        )
    }

    var relayDestination: URL {
        supportDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
    }

    func schemaCustomURL(schemaID: String) -> URL {
        rimeDirectory.appendingPathComponent(
            "\(schemaID).custom.yaml"
        )
    }
}
