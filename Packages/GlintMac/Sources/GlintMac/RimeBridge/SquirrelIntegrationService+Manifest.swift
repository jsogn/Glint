import Foundation

extension SquirrelIntegrationService {
    var pendingTransactionURL: URL {
        supportDirectory.appendingPathComponent(
            "pending-install-transaction.json"
        )
    }

    var manifestURL: URL {
        supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
    }

    func readManifest() throws -> Manifest {
        guard !isSymbolicLink(at: manifestURL) else {
            throw SquirrelIntegrationError.invalidManifest
        }
        do {
            let data = try Data(contentsOf: manifestURL)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw SquirrelIntegrationError.invalidManifest
        }
    }

    func snapshot(of url: URL) throws -> Snapshot {
        guard !isSymbolicLink(at: url) else {
            throw SquirrelIntegrationError.unsafePath
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return Snapshot(url: url, data: nil, permissions: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SquirrelIntegrationError.invalidManifest
        }
        let permissions =
            (try? fileManager.attributesOfItem(
                atPath: url.path
            )[.posixPermissions] as? NSNumber)?.intValue
        return Snapshot(
            url: url,
            data: data,
            permissions: permissions
        )
    }

    func writeData(_ write: PlannedWrite) throws {
        guard
            isManagedURL(write.url),
            !isSymbolicLink(at: write.url)
        else {
            throw SquirrelIntegrationError.unsafePath
        }
        try fileManager.createDirectory(
            at: write.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try write.data.write(to: write.url, options: .atomic)
        if let permissions = write.permissions {
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: write.url.path
            )
        }
    }

    func originalDataWithoutManagedFilter(
        for url: URL,
        data: Data,
        removingEmptyFilterKey: Bool = true
    ) throws -> Data {
        guard url.lastPathComponent.hasSuffix(".custom.yaml") else {
            return data
        }
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = data.starts(with: bom)
        let body = hasBOM ? data.dropFirst(bom.count) : data[...]
        guard
            let source = String(data: Data(body), encoding: .utf8)
        else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let hasMarkers = source.components(separatedBy: "\n").contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == RimeSchemaPatchEditor.beginMarker
                || line == RimeSchemaPatchEditor.endMarker
        }
        let removed = patchEditor.removeManagedFilter(
            from: source,
            removingEmptyFilterKey: removingEmptyFilterKey
        )
        guard !hasMarkers || removed != source else {
            throw SquirrelIntegrationError.invalidManifest
        }
        var result = Data(removed.utf8)
        if hasBOM {
            result.insert(contentsOf: bom, at: 0)
        }
        return result
    }

    func isTrustedManifest(_ manifest: Manifest) -> Bool {
        let relayURL = URL(fileURLWithPath: manifest.relayPath)
        let backupDirectory = URL(
            fileURLWithPath: manifest.backupDirectory,
            isDirectory: true
        )
        guard
            !isSymbolicLink(at: relayURL),
            !isSymbolicLink(at: backupDirectory),
            pathsEqual(relayURL, relayDestination),
            isManagedBackupDirectory(backupDirectory)
        else {
            return false
        }
        let schemaIDs = manifest.schemaIDs
        guard
            Set(schemaIDs).count == schemaIDs.count,
            schemaIDs.allSatisfy(Self.isValidSchemaID)
        else {
            return false
        }
        let compiledSchemas = Set(compiledSchemaIDs())
        let allowedPaths = Set(
            managedTargetURLs(schemaIDs: schemaIDs).map {
                $0.standardizedFileURL.path
            }
        )
        let backups = manifest.backups
        let createdFiles = manifest.createdFiles
        guard
            Set(backups.keys).isSubset(of: allowedPaths),
            Set(createdFiles).isSubset(of: allowedPaths),
            Set(backups.keys).isDisjoint(with: Set(createdFiles))
        else {
            return false
        }
        let createdSet = Set(createdFiles)
        for schemaID in schemaIDs
        where !compiledSchemas.contains(schemaID) {
            let customURL = schemaCustomURL(schemaID: schemaID)
            if fileManager.fileExists(atPath: customURL.path) {
                guard
                    let source = try? String(
                        contentsOf: customURL,
                        encoding: .utf8
                    ),
                    patchEditor.containsFilter(in: source)
                else {
                    return false
                }
            } else if !createdSet.contains(
                customURL.standardizedFileURL.path
            ) {
                return false
            }
        }
        for backupPath in backups.values {
            let backup = URL(fileURLWithPath: backupPath)
            guard
                !isSymbolicLink(at: backup),
                isPath(
                    backup.path,
                    inside: backupDirectory.path
                )
            else {
                return false
            }
        }
        let allowedHashPaths = Set(
            managedTargetURLs(schemaIDs: schemaIDs).map {
                $0.standardizedFileURL.path
            }
        )
        guard
            Set(manifest.fileHashes.keys)
                .isSubset(of: allowedHashPaths)
        else {
            return false
        }
        guard
            Set(manifest.backupHashes.keys)
                .isSubset(of: Set(backups.keys))
        else {
            return false
        }
        guard
            Set(manifest.backupPermissions.keys)
                .isSubset(of: Set(backups.keys)),
            manifest.backupPermissions.values.allSatisfy({
                (0...0o777).contains($0)
            })
        else {
            return false
        }
        return true
    }
}
