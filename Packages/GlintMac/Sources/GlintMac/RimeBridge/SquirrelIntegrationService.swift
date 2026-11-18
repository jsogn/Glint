import CryptoKit
import Foundation
import GlintCore
import GlintRimeRelayCore

public actor SquirrelIntegrationService {
    public static let luaFileNames = [
        "candidate_bridge.lua",
        "json.lua",
    ]
    // Semantic contract version for installed Lua, relay, and socket protocol.
    // Never bump for unrelated app code or byte-only rebuild changes.
    public static let currentBridgeAssetVersion = 2
    static let installationProcessLock = NSLock()

    let rimeDirectory: URL
    let supportDirectory: URL
    let squirrelApplication: URL
    let luaSourceDirectory: URL
    let relaySource: URL
    let reload: @Sendable () throws -> Void
    let patchEditor = RimeSchemaPatchEditor()
    let schemaListResolver = RimeSchemaListResolver()
    let fileManager = FileManager.default

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

    nonisolated static func isValidSchemaID(
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

    nonisolated static func sha256(_ data: Data) -> String {
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
