import Foundation

public enum PluginManagerError: Error, LocalizedError {
    case invalidPluginID
    case pluginNotFound
    case upgradeInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidPluginID:
            "插件标识无效"
        case .pluginNotFound:
            "插件目录不存在"
        case .upgradeInProgress:
            "上一个插件升级尚未完成"
        }
    }
}

public actor PluginManager {
    private struct PendingUpgrade {
        let id: String
        let backupURL: URL
    }

    private struct PersistedUpgrade: Codable {
        let id: String
        let backupName: String
    }

    public private(set) var installed: [PluginManifest] = []
    private let pluginsDirectory: URL
    private let fileManager: FileManager
    private var pendingUpgrade: PendingUpgrade?

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let support = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Glint", isDirectory: true)
        self.pluginsDirectory = support.appendingPathComponent("plugins", isDirectory: true)
        try? fileManager.createDirectory(
            at: pluginsDirectory,
            withIntermediateDirectories: true
        )
    }

    public func installedPlugins() -> [PluginManifest] {
        recoverInterruptedInstalls()
        guard let directories = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            installed = []
            return []
        }

        var manifests: [PluginManifest] = []
        for directory in directories {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
                continue
            }
            manifests.append(manifest)
        }
        installed = manifests.sorted { $0.name < $1.name }
        return installed
    }

    public func installedPlugin(id: String) -> PluginManifest? {
        if let cached = installed.first(where: { $0.id == id }) {
            return cached
        }
        return installedPlugins().first(where: { $0.id == id })
    }

    @discardableResult
    public func installLocalPlugin(at sourceDirectory: URL) throws -> PluginManifest {
        let staging = stagingURL()
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: sourceDirectory, to: staging)
        return try installPreparedPlugin(at: staging)
    }

    @discardableResult
    public func installPreparedPlugin(
        at sourceDirectory: URL,
        keepBackup: Bool = false
    ) throws -> PluginManifest {
        guard pendingUpgrade == nil else {
            throw PluginManagerError.upgradeInProgress
        }
        let manifestURL = sourceDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        guard Self.isValidPluginID(manifest.id) else {
            throw PluginManagerError.invalidPluginID
        }
        let target = pluginsDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        let backup = pluginsDirectory.appendingPathComponent(
            ".backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadExistingInstall = fileManager.fileExists(atPath: target.path)

        if hadExistingInstall, keepBackup {
            try persistUpgradeMarker(id: manifest.id, backupURL: backup)
        }
        if hadExistingInstall {
            do {
                try fileManager.moveItem(at: target, to: backup)
            } catch {
                if keepBackup {
                    try? fileManager.removeItem(at: upgradeMarkerURL)
                }
                throw error
            }
        }
        do {
            try fileManager.moveItem(at: sourceDirectory, to: target)
            if hadExistingInstall {
                if keepBackup {
                    pendingUpgrade = PendingUpgrade(
                        id: manifest.id,
                        backupURL: backup
                    )
                } else {
                    try? fileManager.removeItem(at: backup)
                }
            }
        } catch {
            if keepBackup {
                try? fileManager.removeItem(at: upgradeMarkerURL)
            }
            if hadExistingInstall,
               !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: backup, to: target)
            }
            throw error
        }

        installed.removeAll { $0.id == manifest.id }
        installed.append(manifest)
        installed.sort { $0.name < $1.name }
        return manifest
    }

    public func commitPendingUpgrade() throws {
        guard let pendingUpgrade else { return }
        if fileManager.fileExists(atPath: pendingUpgrade.backupURL.path) {
            try fileManager.removeItem(at: pendingUpgrade.backupURL)
        }
        try? fileManager.removeItem(at: upgradeMarkerURL)
        self.pendingUpgrade = nil
    }

    public func hasPendingUpgrade() -> Bool {
        pendingUpgrade != nil
    }

    public func rollbackPendingUpgrade() throws {
        guard let pendingUpgrade else { return }
        let target = pluginsDirectory.appendingPathComponent(
            pendingUpgrade.id,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: pendingUpgrade.backupURL.path) else {
            try? fileManager.removeItem(at: upgradeMarkerURL)
            self.pendingUpgrade = nil
            return
        }
        let failed = pluginsDirectory.appendingPathComponent(
            ".failed-\(UUID().uuidString)",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.moveItem(at: target, to: failed)
        }
        do {
            try fileManager.moveItem(at: pendingUpgrade.backupURL, to: target)
        } catch {
            if fileManager.fileExists(atPath: failed.path),
               !fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: failed, to: target)
            }
            throw error
        }
        if fileManager.fileExists(atPath: failed.path) {
            try? fileManager.removeItem(at: failed)
        }
        try? fileManager.removeItem(at: upgradeMarkerURL)
        self.pendingUpgrade = nil
        _ = installedPlugins()
    }

    public func remove(id: String) throws {
        guard Self.isValidPluginID(id) else {
            throw PluginManagerError.invalidPluginID
        }
        let target = pluginsDirectory.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: target.path) else {
            throw PluginManagerError.pluginNotFound
        }
        try fileManager.removeItem(at: target)
        installed.removeAll { $0.id == id }
    }

    public func pluginDirectory(for id: String) -> URL {
        pluginsDirectory.appendingPathComponent(id, isDirectory: true)
    }

    func createStagingDirectory() throws -> URL {
        let directory = stagingURL()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func stagingURL() -> URL {
        pluginsDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func recoverInterruptedInstalls() {
        recoverPersistedUpgrade()
        // Hidden entries are normally skipped. This pass is intentionally
        // explicit so stale staging and backup folders can be recovered.
        guard let allDirectories = try? fileManager.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }

        for directory in allDirectories {
            let name = directory.lastPathComponent
            if name.hasPrefix(".staging-") {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if name.hasPrefix(".failed-") {
                try? fileManager.removeItem(at: directory)
                continue
            }
            guard name.hasPrefix(".backup-") else { continue }
            if let pendingUpgrade,
               directory.lastPathComponent
                == pendingUpgrade.backupURL.lastPathComponent {
                continue
            }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(
                      PluginManifest.self,
                      from: data
                  ) else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            let target = pluginsDirectory.appendingPathComponent(
                manifest.id,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.removeItem(at: directory)
            } else {
                try? fileManager.moveItem(at: directory, to: target)
            }
        }
    }

    private var upgradeMarkerURL: URL {
        pluginsDirectory.appendingPathComponent(".upgrade-state.json")
    }

    private func persistUpgradeMarker(
        id: String,
        backupURL: URL
    ) throws {
        let state = PersistedUpgrade(
            id: id,
            backupName: backupURL.lastPathComponent
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: upgradeMarkerURL, options: .atomic)
    }

    private func recoverPersistedUpgrade() {
        guard let data = try? Data(contentsOf: upgradeMarkerURL),
              let state = try? JSONDecoder().decode(
                  PersistedUpgrade.self,
                  from: data
              ),
              Self.isValidPluginID(state.id),
              !state.backupName.contains("/"),
              !state.backupName.contains("\\"),
              state.backupName.hasPrefix(".backup-") else {
            try? fileManager.removeItem(at: upgradeMarkerURL)
            return
        }
        let backup = pluginsDirectory.appendingPathComponent(
            state.backupName,
            isDirectory: true
        )
        let target = pluginsDirectory.appendingPathComponent(
            state.id,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: backup.path) else {
            try? fileManager.removeItem(at: upgradeMarkerURL)
            return
        }
        let failed = pluginsDirectory.appendingPathComponent(
            ".failed-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: target, to: failed)
            }
            try fileManager.moveItem(at: backup, to: target)
            if fileManager.fileExists(atPath: failed.path) {
                try? fileManager.removeItem(at: failed)
            }
            try? fileManager.removeItem(at: upgradeMarkerURL)
            pendingUpgrade = nil
        } catch {
            if !fileManager.fileExists(atPath: target.path),
               fileManager.fileExists(atPath: failed.path) {
                try? fileManager.moveItem(at: failed, to: target)
            }
        }
    }

    private static func isValidPluginID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.hasPrefix(".")
    }

}
