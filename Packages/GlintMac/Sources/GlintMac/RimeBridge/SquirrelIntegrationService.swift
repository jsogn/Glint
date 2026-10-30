import CryptoKit
import Foundation
import GlintCore

public enum SquirrelIntegrationState: Sendable, Equatable {
    case unavailable
    case available
    case installed
    case repairRequired
    case manualSetupRequired
}

public struct SquirrelIntegrationStatus: Sendable, Equatable {
    public let state: SquirrelIntegrationState
    public let schemaIDs: [String]
    public let protocolVersion: Int
    public let detail: String?

    public init(
        state: SquirrelIntegrationState,
        schemaIDs: [String],
        protocolVersion: Int,
        detail: String?
    ) {
        self.state = state
        self.schemaIDs = schemaIDs
        self.protocolVersion = protocolVersion
        self.detail = detail
    }
}

public enum SquirrelIntegrationError: Error, LocalizedError, Equatable {
    case squirrelUnavailable
    case noCompiledSchemas
    case missingBundledAssets
    case unsupportedSchemaSelection
    case unsupportedSchema(String, RimeSchemaPatchError)
    case invalidManifest
    case uninstallConflict
    case reloadFailed

    public var errorDescription: String? {
        switch self {
        case .squirrelUnavailable:
            "未找到 Rime"
        case .noCompiledSchemas:
            "尚未找到已部署的 Rime 输入方案"
        case .missingBundledAssets:
            "Glint 安装包中的 Rime 适配器不完整"
        case .unsupportedSchemaSelection:
            "无法安全确认 Rime 当前启用的输入方案，请按手动安装说明操作"
        case .unsupportedSchema(let schemaID, _):
            "输入方案 \(schemaID) 的配置过于复杂，未进行自动修改"
        case .invalidManifest:
            "Rime 适配器安装记录无效"
        case .uninstallConflict:
            "安装后的文件已被修改，已停止卸载以避免覆盖你的改动"
        case .reloadFailed:
            "Rime 重新部署失败"
        }
    }
}

public actor SquirrelIntegrationService {
    public static let luaFileNames = [
        "candidate_bridge.lua",
        "json.lua",
    ]

    private struct Manifest: Codable, Sendable {
        let assetVersion: Int
        let installedAt: String
        let protocolVersion: Int
        let relayPath: String
        let schemaIDs: [String]
        let backupDirectory: String
        let backups: [String: String]?
        let createdFiles: [String]?
        let fileHashes: [String: String]?
    }

    private struct Snapshot: Sendable {
        let url: URL
        let data: Data?
        let permissions: Int?
    }

    private struct PlannedWrite: Sendable {
        let url: URL
        let data: Data
        let permissions: Int?
    }

    private let rimeDirectory: URL
    private let supportDirectory: URL
    private let squirrelApplication: URL
    private let luaSourceDirectory: URL
    private let relaySource: URL
    private let reload: @Sendable () throws -> Void
    private let patchEditor = RimeSchemaPatchEditor()
    private let schemaListResolver = RimeSchemaListResolver()
    private let fileManager = FileManager.default

    public init(
        rimeDirectory: URL,
        supportDirectory: URL,
        squirrelApplication: URL,
        luaSourceDirectory: URL,
        relaySource: URL,
        reload: (@Sendable () throws -> Void)? = nil
    ) {
        self.rimeDirectory = rimeDirectory
        self.supportDirectory = supportDirectory
        self.squirrelApplication = squirrelApplication
        self.luaSourceDirectory = luaSourceDirectory
        self.relaySource = relaySource
        self.reload =
            reload
            ?? {
                try Self.reloadSquirrel(
                    at: squirrelApplication
                )
            }
    }

    public func status() -> SquirrelIntegrationStatus {
        guard fileManager.fileExists(atPath: squirrelApplication.path)
        else {
            return SquirrelIntegrationStatus(
                state: .unavailable,
                schemaIDs: [],
                protocolVersion: RimeCandidateEnvelope.currentVersion,
                detail: SquirrelIntegrationError.squirrelUnavailable
                    .localizedDescription
            )
        }
        let compiledSchemas = compiledSchemaIDs()
        guard !compiledSchemas.isEmpty else {
            return SquirrelIntegrationStatus(
                state: .repairRequired,
                schemaIDs: [],
                protocolVersion: RimeCandidateEnvelope.currentVersion,
                detail: SquirrelIntegrationError.noCompiledSchemas
                    .localizedDescription
            )
        }

        let manifest = try? readManifest()
        let enabledSchemas = try? enabledSchemaIDs(
            compiledSchemaIDs: compiledSchemas
        )
        let schemas: [String]
        if let enabledSchemas, !enabledSchemas.isEmpty {
            schemas = enabledSchemas
        } else if let manifest,
            manifest.protocolVersion == RimeCandidateEnvelope.currentVersion,
            bridgeAssetsMatchDisk(),
            manifest.schemaIDs.allSatisfy({
                compiledSchemas.contains($0)
                    && schemaContainsFilter(schemaID: $0)
            })
        {
            schemas = manifest.schemaIDs
        } else {
            let hasBridgeState =
                manifest != nil
                || bridgeAssetsMatchDisk()
                || hasAnyInstalledBridgeComponent()
                || compiledSchemas.contains(where: schemaContainsFilter)
            return SquirrelIntegrationStatus(
                state: hasBridgeState ? .repairRequired : .manualSetupRequired,
                schemaIDs: [],
                protocolVersion: manifest?.protocolVersion
                    ?? RimeCandidateEnvelope.currentVersion,
                detail:
                    hasBridgeState
                    ? "适配器安装不完整"
                    : SquirrelIntegrationError.unsupportedSchemaSelection
                        .localizedDescription
            )
        }

        let unsupportedEnabledSchemas = schemas.filter {
            !canInstallOrUpdateSchema(schemaID: $0)
        }
        if !unsupportedEnabledSchemas.isEmpty,
            !unsupportedEnabledSchemas.allSatisfy({
                schemaContainsFilter(schemaID: $0)
            })
        {
            let hasBridgeState =
                manifest != nil
                || bridgeAssetsMatchDisk()
                || hasAnyInstalledBridgeComponent()
                || schemas.contains(where: schemaContainsFilter)
            return SquirrelIntegrationStatus(
                state: hasBridgeState ? .repairRequired : .manualSetupRequired,
                schemaIDs: schemas,
                protocolVersion: manifest?.protocolVersion
                    ?? RimeCandidateEnvelope.currentVersion,
                detail:
                    hasBridgeState
                    ? "适配器安装不完整"
                    : SquirrelIntegrationError.unsupportedSchemaSelection
                        .localizedDescription
            )
        }

        let assetsMatch = bridgeAssetsMatchDisk()
        let schemasMatch = schemas.allSatisfy {
            schemaContainsFilter(schemaID: $0)
        }
        let protocolMatches =
            manifest?.protocolVersion
            == RimeCandidateEnvelope.currentVersion
        let hasAnyBridgeState =
            assetsMatch
            || schemasMatch
            || manifest != nil
            || hasAnyInstalledBridgeComponent()
            || compiledSchemas.contains(where: schemaContainsFilter)

        let state: SquirrelIntegrationState
        let detail: String?
        if assetsMatch, schemasMatch, protocolMatches {
            state = .installed
            detail = nil
        } else if hasAnyBridgeState {
            state = .repairRequired
            detail =
                manifest != nil && !protocolMatches
                ? "适配器版本需要更新"
                : "适配器安装不完整"
        } else {
            state = .available
            detail = nil
        }
        return SquirrelIntegrationStatus(
            state: state,
            schemaIDs: schemas,
            protocolVersion: manifest?.protocolVersion
                ?? RimeCandidateEnvelope.currentVersion,
            detail: detail
        )
    }

    @discardableResult
    public func install() async throws -> SquirrelIntegrationStatus {
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
        let luaAssets = try loadLuaAssets()
        let relayData: Data
        do {
            relayData = try Data(contentsOf: relaySource)
        } catch {
            throw SquirrelIntegrationError.missingBundledAssets
        }

        var plannedWrites = luaAssets.map { asset in
            PlannedWrite(
                url: luaDestination(named: asset.name),
                data: asset.data,
                permissions: nil
            )
        }
        plannedWrites.append(
            PlannedWrite(
                url: relayDestination,
                data: relayData,
                permissions: 0o700
            )
        )

        for schemaID in schemas {
            let customURL = schemaCustomURL(schemaID: schemaID)
            let source: String?
            if fileManager.fileExists(atPath: customURL.path) {
                source = try String(
                    contentsOf: customURL,
                    encoding: .utf8
                )
            } else {
                source = nil
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
            plannedWrites.append(
                PlannedWrite(
                    url: customURL,
                    data: Data(result.source.utf8),
                    permissions: nil
                )
            )
        }

        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        let backupDirectory =
            supportDirectory
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true
        )

        var snapshots: [Snapshot] = []
        var backups: [String: String] = [:]
        var createdFiles: [String] = []
        for (index, write) in plannedWrites.enumerated() {
            let snapshot = snapshot(of: write.url)
            snapshots.append(snapshot)
            if let data = snapshot.data {
                let backupURL = backupDirectory.appendingPathComponent(
                    String(format: "%03d.backup", index)
                )
                try data.write(to: backupURL, options: .atomic)
                backups[write.url.path] = backupURL.path
            } else {
                createdFiles.append(write.url.path)
            }
        }
        snapshots.append(snapshot(of: manifestURL))

        let initiallyCreatedFiles = Set(createdFiles)
        let plannedHashes = Dictionary(
            uniqueKeysWithValues: plannedWrites.map {
                ($0.url.path, Self.sha256($0.data))
            }
        )
        let previousCreatedFiles = Set(
            previousManifest?.createdFiles ?? []
        )
        createdFiles = plannedWrites.compactMap { write in
            if initiallyCreatedFiles.contains(write.url.path) {
                return write.url.path
            }
            guard previousCreatedFiles.contains(write.url.path) else {
                return nil
            }
            if let expectedHash =
                previousManifest?.fileHashes?[write.url.path]
            {
                guard
                    let currentData = try? Data(contentsOf: write.url),
                    Self.sha256(currentData) == expectedHash
                else {
                    return nil
                }
            } else if write.url.lastPathComponent.hasSuffix(
                ".custom.yaml"
            ),
                let source = try? String(
                    contentsOf: write.url,
                    encoding: .utf8
                )
            {
                guard patchEditor.isPristineManagedPatch(source) else {
                    return nil
                }
            } else {
                return nil
            }
            return write.url.path
        }
        if !createdFiles.isEmpty {
            let created = Set(createdFiles)
            backups = backups.filter { !created.contains($0.key) }
        }

        let manifest = Manifest(
            assetVersion: RimeCandidateEnvelope.currentVersion,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            protocolVersion: RimeCandidateEnvelope.currentVersion,
            relayPath: relayDestination.path,
            schemaIDs: schemas,
            backupDirectory: backupDirectory.path,
            backups: backups,
            createdFiles: createdFiles,
            fileHashes: plannedHashes
        )

        do {
            for write in plannedWrites {
                try writeData(write)
            }
            try writeData(
                PlannedWrite(
                    url: manifestURL,
                    data: try JSONEncoder().encode(manifest),
                    permissions: 0o600
                )
            )
            try reload()
        } catch SquirrelIntegrationError.reloadFailed {
            restore(snapshots)
            throw SquirrelIntegrationError.reloadFailed
        } catch {
            restore(snapshots)
            throw error
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

    @discardableResult
    public func uninstall() async throws -> SquirrelIntegrationStatus {
        let manifestURL = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        let manifest: Manifest?
        if fileManager.fileExists(atPath: manifestURL.path) {
            manifest = (try? readManifest()).flatMap {
                isTrustedManifest($0) ? $0 : nil
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
        let currentSnapshots = targetURLs.map {
            snapshot(of: $0)
        }
        do {
            if let manifest {
                try applyUninstall(using: manifest)
            } else {
                try applyUnmanagedUninstall()
            }
        } catch {
            restore(currentSnapshots)
            throw error
        }
        do {
            try reload()
        } catch {
            restore(currentSnapshots)
            throw SquirrelIntegrationError.reloadFailed
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

    private func applyUninstall(
        using manifest: Manifest
    ) throws {
        guard
            isTrustedManifest(manifest),
            isManagedURL(URL(fileURLWithPath: manifest.relayPath))
        else {
            throw SquirrelIntegrationError.invalidManifest
        }

        for (targetPath, backupPath) in manifest.backups ?? [:] {
            let target = URL(fileURLWithPath: targetPath)
            let backup = URL(fileURLWithPath: backupPath)
            guard
                isManagedURL(target),
                isPath(
                    backup.path,
                    inside: manifest.backupDirectory
                )
            else {
                throw SquirrelIntegrationError.invalidManifest
            }
            let backupData = try Data(contentsOf: backup)
            try writeData(
                PlannedWrite(
                    url: target,
                    data: restoredData(
                        for: target,
                        data: backupData
                    ),
                    permissions: nil
                )
            )
        }
        for path in manifest.createdFiles ?? [] {
            let url = URL(fileURLWithPath: path)
            guard isManagedURL(url) else {
                throw SquirrelIntegrationError.invalidManifest
            }
            try? fileManager.removeItem(at: url)
        }
        try removeManagedBridgeAssets()
    }

    private func validateUninstall(
        using manifest: Manifest
    ) throws {
        guard isTrustedManifest(manifest) else {
            throw SquirrelIntegrationError.invalidManifest
        }
        let managedPaths =
            (manifest.backups ?? [:]).keys
            + (manifest.createdFiles ?? [])
        for path in managedPaths {
            let url = URL(fileURLWithPath: path)
            guard isManagedURL(url) else {
                throw SquirrelIntegrationError.invalidManifest
            }
            guard
                let expectedHash = manifest.fileHashes?[path],
                let currentData = try? Data(contentsOf: url)
            else {
                continue
            }
            guard Self.sha256(currentData) == expectedHash else {
                throw SquirrelIntegrationError.uninstallConflict
            }
        }
    }

    private func applyUnmanagedUninstall() throws {
        for schemaID in compiledSchemaIDs() {
            let url = schemaCustomURL(schemaID: schemaID)
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            let source = try String(
                contentsOf: url,
                encoding: .utf8
            )
            let removed = patchEditor.removeManagedFilter(from: source)
            if removed != source {
                if patchEditor.isEffectivelyEmptyPatchDocument(removed) {
                    try? fileManager.removeItem(at: url)
                } else {
                    try writeData(
                        PlannedWrite(
                            url: url,
                            data: Data(removed.utf8),
                            permissions: nil
                        )
                    )
                }
            }
        }
        try removeManagedBridgeAssets()
    }

    private func removeManagedBridgeAssets() throws {
        let urls =
            [relayDestination]
            + Self.luaFileNames.map(luaDestination(named:))
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func uninstallTargetURLs(
        manifest: Manifest?,
        manifestURL: URL
    ) -> [URL] {
        var paths = Set<String>()
        paths.insert(manifestURL.path)
        paths.insert(relayDestination.path)
        for name in Self.luaFileNames {
            paths.insert(luaDestination(named: name).path)
        }
        for schemaID in compiledSchemaIDs() {
            paths.insert(schemaCustomURL(schemaID: schemaID).path)
        }
        if let manifest {
            paths.insert(manifest.relayPath)
            for path in manifest.backups?.keys ?? [:].keys {
                paths.insert(path)
            }
            for path in manifest.createdFiles ?? [] {
                paths.insert(path)
            }
        }
        return
            paths
            .map(URL.init(fileURLWithPath:))
            .filter(isManagedURL)
    }

    private func compiledSchemaIDs() -> [String] {
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

    private func enabledSchemaIDs(
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
            throw SquirrelIntegrationError.unsupportedSchemaSelection
        }
        guard !schemaIDs.isEmpty else {
            throw SquirrelIntegrationError.unsupportedSchemaSelection
        }
        return schemaIDs
    }

    private func readSharedDefaultConfiguration() -> String? {
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

    private func bridgeAssetsMatchDisk() -> Bool {
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

    private func hasAnyInstalledBridgeComponent() -> Bool {
        fileManager.fileExists(atPath: relayDestination.path)
            || Self.luaFileNames.contains {
                fileManager.fileExists(
                    atPath: luaDestination(named: $0).path
                )
            }
    }

    private func canInstallOrUpdateSchema(schemaID: String) -> Bool {
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

    private func schemaContainsFilter(schemaID: String) -> Bool {
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

    private func loadLuaAssets() throws -> [(name: String, data: Data)] {
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

    private func luaDestination(named name: String) -> URL {
        rimeDirectory.appendingPathComponent(
            "lua/glint/\(name)"
        )
    }

    private var relayDestination: URL {
        supportDirectory.appendingPathComponent(
            "RimeCandidateBridge"
        )
    }

    private func schemaCustomURL(schemaID: String) -> URL {
        rimeDirectory.appendingPathComponent(
            "\(schemaID).custom.yaml"
        )
    }

    private func readManifest() throws -> Manifest {
        let url = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw SquirrelIntegrationError.invalidManifest
        }
    }

    private func snapshot(of url: URL) -> Snapshot {
        let data = try? Data(contentsOf: url)
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

    private func writeData(_ write: PlannedWrite) throws {
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

    private func restore(_ snapshots: [Snapshot]) {
        for snapshot in snapshots.reversed() {
            if let data = snapshot.data {
                try? fileManager.createDirectory(
                    at: snapshot.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: snapshot.url, options: .atomic)
                if let permissions = snapshot.permissions {
                    try? fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: snapshot.url.path
                    )
                }
            } else {
                try? fileManager.removeItem(at: snapshot.url)
            }
        }
    }

    private func restoredData(for url: URL, data: Data) -> Data {
        guard
            url.lastPathComponent.hasSuffix(".custom.yaml"),
            let source = String(data: data, encoding: .utf8)
        else {
            return data
        }
        return Data(
            patchEditor.removeManagedFilter(from: source).utf8
        )
    }

    private func isManagedURL(_ url: URL) -> Bool {
        isPath(url.path, inside: rimeDirectory.path)
            || isPath(url.path, inside: supportDirectory.path)
    }

    private func isTrustedManifest(_ manifest: Manifest) -> Bool {
        isManagedURL(URL(fileURLWithPath: manifest.relayPath))
            && isManagedBackupDirectory(
                URL(fileURLWithPath: manifest.backupDirectory)
            )
    }

    private func isManagedBackupDirectory(_ url: URL) -> Bool {
        let backupRoot = supportDirectory.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        let path = url.standardizedFileURL.path
        let root = backupRoot.standardizedFileURL.path
        return path != root && isPath(path, inside: root)
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path)
            .standardizedFileURL.path
        let standardizedRoot = URL(fileURLWithPath: root)
            .standardizedFileURL.path
        return standardizedPath == standardizedRoot
            || standardizedPath.hasPrefix(standardizedRoot + "/")
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func reloadSquirrel(
        at application: URL
    ) throws {
        let executable = application.appendingPathComponent(
            "Contents/MacOS/Squirrel"
        )
        guard
            FileManager.default.isExecutableFile(
                atPath: executable.path
            )
        else {
            throw SquirrelIntegrationError.reloadFailed
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--reload"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SquirrelIntegrationError.reloadFailed
        }
        guard process.terminationStatus == 0 else {
            throw SquirrelIntegrationError.reloadFailed
        }
    }
}
