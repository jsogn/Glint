import CryptoKit
import Darwin
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
    case unsafePath
    case installConflict
    case uninstallConflict
    case reloadFailed
    case rollbackFailed
    case lockFailed

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
        case .unsafePath:
            "检测到不安全的文件路径，已停止修改 Rime 配置"
        case .installConflict:
            "安装后的文件已被修改，已停止升级以避免覆盖你的改动"
        case .uninstallConflict:
            "安装后的文件已被修改，已停止卸载以避免覆盖你的改动"
        case .reloadFailed:
            "Rime 重新部署失败"
        case .rollbackFailed:
            "Rime 配置恢复失败，备份仍保留；请按手动恢复说明处理"
        case .lockFailed:
            "另一个 Glint 实例正在更新 Rime 配置，请稍后重试"
        }
    }
}

public actor SquirrelIntegrationService {
    public static let luaFileNames = [
        "candidate_bridge.lua",
        "json.lua",
    ]
    // Bump whenever the bundled Lua, relay, or bridge protocol contract changes.
    public static let currentBridgeAssetVersion = 2
    private static let installationProcessLock = NSLock()

    private struct Manifest: Codable, Sendable {
        let assetVersion: Int
        let installedAt: String
        let protocolVersion: Int
        let relayPath: String
        let schemaIDs: [String]
        let backupDirectory: String
        let backups: [String: String]
        let createdFiles: [String]
        let fileHashes: [String: String]
        let backupHashes: [String: String]
        let backupPermissions: [String: Int]
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

    private enum TransactionPhase: String, Codable, Sendable {
        case prepared
        case committed
    }

    private struct PendingTransactionEntry:
        Codable, Sendable, Equatable
    {
        let targetPath: String
        let existed: Bool
        let snapshotPath: String?
        let snapshotHash: String?
        let expectedHash: String?
        let expectedAbsent: Bool
        let permissions: Int?
    }

    private struct ExpectedTransactionState: Sendable {
        let hash: String?
        let absent: Bool
    }

    private struct PendingTransaction: Codable, Sendable {
        var phase: TransactionPhase
        let schemaIDs: [String]
        let transactionDirectory: String
        let entries: [PendingTransactionEntry]
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
        if fileManager.fileExists(
            atPath: pendingTransactionURL.path
        ) {
            return SquirrelIntegrationStatus(
                state: .repairRequired,
                schemaIDs: [],
                protocolVersion: RimeCandidateEnvelope.currentVersion,
                detail: "上次 Rime 适配器操作未完成，需要恢复"
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
        let manifestAssetsMatch =
            manifest.map(bridgeAssetsMatchManifest)
            ?? bridgeAssetsMatchDisk()
        let bridgeVersionMatches =
            manifest?.assetVersion
            == Self.currentBridgeAssetVersion
        let protocolMatches =
            manifest?.protocolVersion
            == RimeCandidateEnvelope.currentVersion
        let enabledSchemas = try? enabledSchemaIDs(
            compiledSchemaIDs: compiledSchemas
        )
        let schemas: [String]
        if let enabledSchemas, !enabledSchemas.isEmpty {
            schemas = enabledSchemas
        } else if let manifest,
            bridgeVersionMatches,
            protocolMatches,
            manifestAssetsMatch,
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
        let hasAnyBridgeState =
            assetsMatch
            || schemasMatch
            || manifest != nil
            || hasAnyInstalledBridgeComponent()
            || compiledSchemas.contains(where: schemaContainsFilter)

        let state: SquirrelIntegrationState
        let detail: String?
        if manifestAssetsMatch,
            schemasMatch,
            protocolMatches,
            bridgeVersionMatches
        {
            state = .installed
            detail = nil
        } else if hasAnyBridgeState {
            state = .repairRequired
            detail =
                manifest != nil
                    && (!protocolMatches || !bridgeVersionMatches)
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
    public func synchronizeInstalledSupportIfNeeded() async throws
        -> SquirrelIntegrationStatus
    {
        try withProcessLock {
            try synchronizeInstalledSupportLocked()
        }
    }

    private func synchronizeInstalledSupportLocked() throws
        -> SquirrelIntegrationStatus
    {
        try recoverInterruptedTransactionIfNeeded()
        let manifestURL = supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return status()
        }
        let manifest = try readManifest()
        guard isTrustedManifest(manifest) else {
            throw SquirrelIntegrationError.invalidManifest
        }
        guard
            manifest.assetVersion == Self.currentBridgeAssetVersion,
            manifest.protocolVersion
                == RimeCandidateEnvelope.currentVersion
        else {
            return try installLocked()
        }
        return status()
    }

    func recoverInterruptedTransactionIfNeeded() throws {
        guard
            fileManager.fileExists(
                atPath: pendingTransactionURL.path
            )
        else {
            return
        }
        let transaction = try readPendingTransaction()
        try validate(transaction)
        if transaction.phase == .prepared {
            try restorePendingTransaction(transaction)
            do {
                try reload()
            } catch {
                throw SquirrelIntegrationError.reloadFailed
            }
            var committed = transaction
            committed.phase = .committed
            try writePendingTransaction(committed)
        }
        try fileManager.removeItem(at: pendingTransactionURL)
        let transactionDirectory = URL(
            fileURLWithPath: transaction.transactionDirectory,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: transactionDirectory.path) {
            try? fileManager.removeItem(at: transactionDirectory)
        }
    }

    @discardableResult
    public func install() async throws -> SquirrelIntegrationStatus {
        try withProcessLock {
            try installLocked()
        }
    }

    private func installLocked() throws -> SquirrelIntegrationStatus {
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
        let luaAssets = try loadLuaAssets()
        let relayData: Data
        do {
            relayData = try Data(contentsOf: relaySource)
        } catch {
            throw SquirrelIntegrationError.missingBundledAssets
        }

        var desiredWrites = luaAssets.map { asset in
            (
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
            (
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
                (
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
        let desiredPaths = Set(desiredWrites.map(\.write.url.path))
        for path in previousBackups.keys where !desiredPaths.contains(path) {
            guard
                let expectedHash =
                    previousManifest?.fileHashes[path]
            else {
                throw SquirrelIntegrationError.installConflict
            }
            carriedBackupPaths[path] = previousBackups[path]
            managedHashes[path] = expectedHash
        }
        for path in previousCreatedFiles where !desiredPaths.contains(path) {
            guard
                let expectedHash =
                    previousManifest?.fileHashes[path]
            else {
                throw SquirrelIntegrationError.installConflict
            }
            createdFiles.insert(path)
            managedHashes[path] = expectedHash
        }

        let manifestIsCurrent =
            previousManifest?.assetVersion
            == Self.currentBridgeAssetVersion
            && previousManifest?.protocolVersion
                == RimeCandidateEnvelope.currentVersion
            && previousManifest?.schemaIDs == managedSchemaIDs
        if plannedWrites.isEmpty, manifestIsCurrent {
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

        var snapshots = Array(plannedSnapshots.values)
        var backups: [String: String] = [:]
        var backupHashes: [String: String] = [:]
        var backupPermissions: [String: Int] = [:]
        let backupTargets = Set(
            plannedSnapshots.compactMap { path, snapshot in
                snapshot.data == nil || createdFiles.contains(path)
                    ? nil
                    : path
            }
                + carriedBackupPaths.keys
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
                guard let snapshot = plannedSnapshots[path],
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
            schemaIDs: managedSchemaIDs,
            backupDirectory: backupDirectory.path,
            backups: backups,
            createdFiles: createdFiles.sorted(),
            fileHashes: managedHashes.merging(
                unownedHashes,
                uniquingKeysWith: { current, _ in current }
            ),
            backupHashes: backupHashes,
            backupPermissions: backupPermissions
        )

        let manifestData = try JSONEncoder().encode(manifest)
        var expectedStates: [String: ExpectedTransactionState] = [:]
        for write in plannedWrites {
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
            schemaIDs: managedSchemaIDs
        )
        let originalStates = Dictionary(
            uniqueKeysWithValues: transaction.entries.map {
                ($0.targetPath, $0)
            }
        )
        var didWrite = false
        do {
            for write in plannedWrites {
                let expected = plannedSnapshots[write.url.path]
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
            if !plannedWrites.isEmpty {
                try reload()
            }
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
        try withProcessLock {
            try uninstallLocked()
        }
    }

    private func uninstallLocked() throws -> SquirrelIntegrationStatus {
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
        var didWrite = false
        let originalStates = Dictionary(
            uniqueKeysWithValues: transaction.entries.map {
                ($0.targetPath, $0)
            }
        )
        do {
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
            try commitPendingTransaction(transaction)
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
        return status()
    }

    private func applyUninstall(
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

    private func validateUninstall(
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

    private func applyUnmanagedUninstall(
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

    private func removeManagedBridgeAssets(
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

    private func isBridgeAssetURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == relayDestination.standardizedFileURL.path
            || Self.luaFileNames.contains {
                luaDestination(named: $0).standardizedFileURL.path == path
            }
    }

    private func verifyOriginalState(
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

    private func expectedUninstallStates(
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

    private func bridgeAssetsMatchManifest(
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

    private var pendingTransactionURL: URL {
        supportDirectory.appendingPathComponent(
            "pending-install-transaction.json"
        )
    }

    private var manifestURL: URL {
        supportDirectory.appendingPathComponent(
            "install-manifest.json"
        )
    }

    private func schemaCustomURL(schemaID: String) -> URL {
        rimeDirectory.appendingPathComponent(
            "\(schemaID).custom.yaml"
        )
    }

    private func readPendingTransaction() throws -> PendingTransaction {
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

    private func withProcessLock<T>(
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

    private func writePendingTransaction(
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

    private func beginPendingTransaction(
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

    private func rollbackPendingTransaction(
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

    private func commitPendingTransaction(
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

    private func finishPendingTransaction(
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

    private func validate(_ transaction: PendingTransaction) throws {
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

    private func restorePendingTransaction(
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

    private func readManifest() throws -> Manifest {
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

    private func snapshot(of url: URL) throws -> Snapshot {
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

    private func writeData(_ write: PlannedWrite) throws {
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

    private func originalDataWithoutManagedFilter(
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

    private func isManagedURL(_ url: URL) -> Bool {
        isPath(url.path, inside: rimeDirectory.path)
            || isPath(url.path, inside: supportDirectory.path)
    }

    private func isTrustedManifest(_ manifest: Manifest) -> Bool {
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

    private func isManagedBackupDirectory(_ url: URL) -> Bool {
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

    private func isManagedTransactionDirectory(_ url: URL) -> Bool {
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

    private func isSafeDedicatedDirectoryRoot(_ url: URL) -> Bool {
        guard
            pathsEqual(url.deletingLastPathComponent(), supportDirectory),
            !isSymbolicLink(at: url)
        else {
            return false
        }
        return isPath(url.path, inside: supportDirectory.path)
            && canonicalPath(of: url) != canonicalPath(of: supportDirectory)
    }

    private func isLexicallyInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    private func isPath(_ path: String, inside root: String) -> Bool {
        let resolvedPath = canonicalPath(
            of: URL(fileURLWithPath: path)
        )
        let resolvedRoot = canonicalPath(
            of: URL(fileURLWithPath: root)
        )
        return resolvedPath == resolvedRoot
            || resolvedPath.hasPrefix(resolvedRoot + "/")
    }

    private func managedTargetURLs(schemaIDs: [String]) -> [URL] {
        [relayDestination]
            + Self.luaFileNames.map(luaDestination(named:))
            + schemaIDs.map(schemaCustomURL(schemaID:))
    }

    private func canonicalPath(of url: URL) -> String {
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

    private func pathsEqual(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path
            == rhs.standardizedFileURL.path
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(
            atPath: url.path
        )) != nil
    }

    private func permissions(of url: URL) throws -> Int? {
        (try fileManager.attributesOfItem(
            atPath: url.path
        )[.posixPermissions] as? NSNumber)?.intValue
    }

    private nonisolated static func isValidSchemaID(
        _ schemaID: String
    ) -> Bool {
        !schemaID.isEmpty
            && schemaID.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_"
                    || scalar == "-"
                    || scalar == "."
            }
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
            guard
                try ExternalProcessRunner.run(
                    process,
                    timeout: 15
                ) == 0
            else {
                throw SquirrelIntegrationError.reloadFailed
            }
        } catch {
            throw SquirrelIntegrationError.reloadFailed
        }
    }
}
