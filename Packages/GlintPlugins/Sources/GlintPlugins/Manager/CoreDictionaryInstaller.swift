import CryptoKit
import Foundation

public struct CoreDictionaryManifestFields: Sendable {
    public let name: String
    public let version: String
    public let runtime: String
    public let url: URL
    public let license: String
    public let minRAMBytes: Int64
    public let summary: String?
    public let revision: String?
    public let sourceDate: String?
    public let sourceChecksum: String?
    public let coreUpdateKind: CoreDictionaryUpdateKind

    public init(
        name: String,
        version: String,
        runtime: String,
        url: URL,
        license: String,
        minRAMBytes: Int64,
        summary: String?,
        revision: String? = nil,
        sourceDate: String?,
        sourceChecksum: String? = nil,
        coreUpdateKind: CoreDictionaryUpdateKind
    ) {
        self.name = name
        self.version = version
        self.runtime = runtime
        self.url = url
        self.license = license
        self.minRAMBytes = minRAMBytes
        self.summary = summary
        self.revision = revision
        self.sourceDate = sourceDate
        self.sourceChecksum = sourceChecksum
        self.coreUpdateKind = coreUpdateKind
    }
}

public struct PreparedCoreDictionaryInstallation: Sendable {
    public let dictionaryID: String
    public let bundledDirectory: URL
    public let builtArtifactURL: URL
    public let artifactFileName: String
    public let manifestFields: CoreDictionaryManifestFields
    public let validate: @Sendable (URL) -> Bool

    public init(
        dictionaryID: String,
        bundledDirectory: URL,
        builtArtifactURL: URL,
        artifactFileName: String,
        manifestFields: CoreDictionaryManifestFields,
        validate: @escaping @Sendable (URL) -> Bool
    ) {
        self.dictionaryID = dictionaryID
        self.bundledDirectory = bundledDirectory
        self.builtArtifactURL = builtArtifactURL
        self.artifactFileName = artifactFileName
        self.manifestFields = manifestFields
        self.validate = validate
    }
}

public enum CoreDictionaryInstallError: Error, LocalizedError {
    case validationFailed

    public var errorDescription: String? {
        "词典安装校验失败，已恢复原词典"
    }
}

public actor CoreDictionaryInstaller {
    private let pluginManager: PluginManager
    private let fileManager = FileManager.default

    public init(pluginManager: PluginManager) {
        self.pluginManager = pluginManager
    }

    public func install(
        _ request: PreparedCoreDictionaryInstallation,
        workDirectory: URL
    ) async throws -> PluginManifest {
        let stagingDirectory = workDirectory.appendingPathComponent(
            "plugin",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        for item in try fileManager.contentsOfDirectory(
            at: request.bundledDirectory,
            includingPropertiesForKeys: nil
        ) {
            try fileManager.copyItem(
                at: item,
                to: stagingDirectory.appendingPathComponent(
                    item.lastPathComponent
                )
            )
        }
        let stagedArtifact = stagingDirectory.appendingPathComponent(
            request.artifactFileName
        )
        try? fileManager.removeItem(at: stagedArtifact)
        try fileManager.copyItem(
            at: request.builtArtifactURL,
            to: stagedArtifact
        )
        let fields = request.manifestFields
        let manifest = PluginManifest(
            id: request.dictionaryID,
            type: .dictionary,
            name: fields.name,
            version: fields.version,
            runtime: fields.runtime,
            sizeBytes: Int64(fileSize(at: stagedArtifact)),
            sha256: try sha256(fileURL: stagedArtifact),
            url: fields.url,
            license: fields.license,
            minRAMBytes: fields.minRAMBytes,
            summary: fields.summary,
            revision: fields.revision,
            source: .bundled,
            sourceDate: fields.sourceDate,
            sourceChecksum: fields.sourceChecksum,
            coreUpdateKind: fields.coreUpdateKind
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: stagingDirectory.appendingPathComponent(
                PluginManifest.fileName
            ),
            options: .atomic
        )

        try Task.checkCancellation()
        let hadExistingInstall =
            await pluginManager.installedPlugin(
                id: request.dictionaryID
            ) != nil
        _ = try await pluginManager.installPreparedPlugin(
            at: stagingDirectory,
            keepBackup: hadExistingInstall
        )
        let installedDirectory = await pluginManager.pluginDirectory(
            for: request.dictionaryID
        )
        let installedArtifact =
            installedDirectory.appendingPathComponent(
                request.artifactFileName
            )
        guard request.validate(installedArtifact) else {
            if hadExistingInstall {
                try? await pluginManager.rollbackPendingUpgrade()
            } else {
                try? await pluginManager.remove(id: request.dictionaryID)
            }
            throw CoreDictionaryInstallError.validationFailed
        }
        try await pluginManager.commitPendingUpgrade()
        return manifest
    }

    private func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
    }

    private func sha256(fileURL: URL) throws -> String {
        let data = try Data(
            contentsOf: fileURL,
            options: [.mappedIfSafe]
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
