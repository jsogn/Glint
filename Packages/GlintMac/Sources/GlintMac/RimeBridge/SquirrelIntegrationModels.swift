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

extension SquirrelIntegrationService {
    struct Manifest: Codable, Sendable {
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

    struct Snapshot: Sendable {
        let url: URL
        let data: Data?
        let permissions: Int?
    }

    struct PlannedWrite: Sendable {
        let url: URL
        let data: Data
        let permissions: Int?
    }

    struct DesiredInstallWrite {
        let write: PlannedWrite
        let isSchemaPatch: Bool
        let changedByPatchEditor: Bool
    }

    struct InstallPlan {
        let plannedWrites: [PlannedWrite]
        let plannedSnapshots: [String: Snapshot]
        let carriedBackupPaths: [String: String]
        let createdFiles: Set<String>
        let managedHashes: [String: String]
        let unownedHashes: [String: String]
        let managedSchemaIDs: [String]
    }

    enum TransactionPhase: String, Codable, Sendable {
        case prepared
        case committed
    }

    struct PendingTransactionEntry:
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

    struct ExpectedTransactionState: Sendable {
        let hash: String?
        let absent: Bool
    }

    struct PendingTransaction: Codable, Sendable {
        var phase: TransactionPhase
        let schemaIDs: [String]
        let transactionDirectory: String
        let entries: [PendingTransactionEntry]
    }
}
