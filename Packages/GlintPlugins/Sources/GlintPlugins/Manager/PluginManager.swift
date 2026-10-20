import Foundation

public enum PluginManagerError: Error, LocalizedError {
    case invalidPluginID

    public var errorDescription: String? {
        switch self {
        case .invalidPluginID:
            "插件标识无效"
        }
    }
}

public actor PluginManager {
    public private(set) var installed: [PluginManifest] = []
    private let pluginsDirectory: URL
    private let fileManager: FileManager

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
        at sourceDirectory: URL
    ) throws -> PluginManifest {
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

        if hadExistingInstall {
            try fileManager.moveItem(at: target, to: backup)
        }
        do {
            try fileManager.moveItem(at: sourceDirectory, to: target)
            if hadExistingInstall {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
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

    public func remove(id: String) throws {
        guard Self.isValidPluginID(id) else {
            throw PluginManagerError.invalidPluginID
        }
        let target = pluginsDirectory.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
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
            guard name.hasPrefix(".backup-") else { continue }
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

    private static func isValidPluginID(_ id: String) -> Bool {
        !id.isEmpty
            && id != "."
            && id != ".."
            && !id.contains("/")
            && !id.contains("\\")
            && !id.hasPrefix(".")
    }
}
