import Foundation

extension SquirrelIntegrationService {
    func compiledSchemaIDs() -> [String] {
        let buildDirectory = rimeDirectory.appendingPathComponent(
            "build",
            isDirectory: true
        )
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: buildDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }
        return files.compactMap { file in
            let name = file.lastPathComponent
            let suffix = ".schema.yaml"
            guard name.hasSuffix(suffix) else { return nil }
            return String(name.dropLast(suffix.count))
        }
        .sorted()
    }

    func enabledSchemaIDs(
        compiledSchemaIDs: [String]
    ) throws -> [String] {
        guard let sharedDefault = readSharedDefaultConfiguration() else {
            throw SquirrelIntegrationError.unsupportedSchemaSelection
        }
        let customURL = rimeDirectory.appendingPathComponent(
            "default.custom.yaml"
        )
        let userCustom: String?
        if fileManager.fileExists(atPath: customURL.path) {
            userCustom = try String(
                contentsOf: customURL,
                encoding: .utf8
            )
        } else {
            userCustom = nil
        }
        let schemaIDs: [String]
        do {
            schemaIDs = try schemaListResolver.enabledSchemaIDs(
                sharedDefault: sharedDefault,
                userDefaultCustom: userCustom,
                compiledSchemaIDs: compiledSchemaIDs
            )
        } catch {
            let managedSchemaIDs = compiledSchemaIDs.filter(
                schemaContainsManagedFilter
            )
            guard !managedSchemaIDs.isEmpty else {
                throw SquirrelIntegrationError.unsupportedSchemaSelection
            }
            return managedSchemaIDs
        }
        if !schemaIDs.isEmpty {
            return schemaIDs
        }
        let managedSchemaIDs = compiledSchemaIDs.filter(
            schemaContainsManagedFilter
        )
        guard !managedSchemaIDs.isEmpty else {
            throw SquirrelIntegrationError.unsupportedSchemaSelection
        }
        return managedSchemaIDs
    }

    func readSharedDefaultConfiguration() -> String? {
        let sharedSupport = squirrelApplication.appendingPathComponent(
            "Contents/SharedSupport",
            isDirectory: true
        )
        let candidates = [
            sharedSupport.appendingPathComponent("build/default.yaml"),
            sharedSupport.appendingPathComponent("default.yaml"),
        ]
        for candidate in candidates {
            if let source = try? String(
                contentsOf: candidate,
                encoding: .utf8
            ) {
                return source
            }
        }
        return nil
    }

    func bridgeAssetsMatchDisk() -> Bool {
        guard let luaAssets = try? loadLuaAssets() else {
            return false
        }
        let luaMatch = luaAssets.allSatisfy { asset in
            guard
                let data = try? Data(
                    contentsOf: luaDestination(named: asset.name)
                )
            else {
                return false
            }
            return data == asset.data
        }
        let sourceRelay = try? Data(contentsOf: relaySource)
        let destinationRelay = try? Data(
            contentsOf: relayDestination
        )
        let relayPermissions =
            (try? fileManager.attributesOfItem(
                atPath: relayDestination.path
            )[.posixPermissions] as? NSNumber)?.intValue
        let relayMatch =
            sourceRelay != nil
            && sourceRelay == destinationRelay
            && relayPermissions == 0o700
        return luaMatch && relayMatch
    }

    func bridgeAssetsMatchManifest(
        _ manifest: Manifest
    ) -> Bool {
        let assetURLs =
            [relayDestination]
            + Self.luaFileNames.map(luaDestination(named:))
        for url in assetURLs {
            guard
                let expectedHash = manifest.fileHashes[url.path],
                let data = try? Data(contentsOf: url),
                Self.sha256(data) == expectedHash
            else {
                return false
            }
        }
        let relayPermissions =
            (try? fileManager.attributesOfItem(
                atPath: relayDestination.path
            )[.posixPermissions] as? NSNumber)?.intValue
        return relayPermissions == 0o700
    }

    func hasAnyInstalledBridgeComponent() -> Bool {
        fileManager.fileExists(atPath: relayDestination.path)
            || Self.luaFileNames.contains {
                fileManager.fileExists(
                    atPath: luaDestination(named: $0).path
                )
            }
    }

    func canInstallOrUpdateSchema(schemaID: String) -> Bool {
        guard
            let source = try? String(
                contentsOf: schemaCustomURL(schemaID: schemaID),
                encoding: .utf8
            )
        else {
            return true
        }
        return
            (try? patchEditor.install(
                into: source,
                schemaID: schemaID
            )) != nil
    }

    func schemaContainsFilter(schemaID: String) -> Bool {
        guard
            let source = try? String(
                contentsOf: schemaCustomURL(schemaID: schemaID),
                encoding: .utf8
            )
        else {
            return false
        }
        return patchEditor.containsFilter(in: source)
    }

    func schemaContainsManagedFilter(schemaID: String) -> Bool {
        guard
            let source = try? String(
                contentsOf: schemaCustomURL(schemaID: schemaID),
                encoding: .utf8
            )
        else {
            return false
        }
        return patchEditor.containsManagedFilter(in: source)
    }

    func loadLuaAssets() throws -> [(name: String, data: Data)] {
        do {
            return try Self.luaFileNames.map { name in
                (
                    name: name,
                    data: try Data(
                        contentsOf:
                            luaSourceDirectory
                            .appendingPathComponent(name)
                    )
                )
            }
        } catch {
            throw SquirrelIntegrationError.missingBundledAssets
        }
    }
}
