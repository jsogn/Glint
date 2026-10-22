import CryptoKit
import Darwin
import Foundation
import GlintCore

public struct LocalTranslationModelCandidate: Sendable, Equatable {
    public let sourceDirectory: URL
    public let proposedName: String
    public let modelType: String
    public let sizeBytes: Int64
    public let estimatedRAMBytes: Int64
    public let hasChatTemplate: Bool
}

public enum LocalModelImportError: Error, LocalizedError, Equatable {
    case notADirectory
    case missingConfig
    case invalidConfig
    case missingWeights
    case missingTokenizer
    case missingChatTemplate
    case missingWeightShard(String)
    case unsafeFile(String)

    public var errorDescription: String? {
        switch self {
        case .notADirectory:
            "请选择一个模型文件夹"
        case .missingConfig:
            "模型缺少 config.json"
        case .invalidConfig:
            "config.json 无法识别"
        case .missingWeights:
            "模型缺少 safetensors 权重文件"
        case .missingTokenizer:
            "模型缺少 tokenizer 文件"
        case .missingChatTemplate:
            "模型缺少聊天模板，无法可靠用于翻译"
        case let .missingWeightShard(name):
            "模型缺少分片权重：\(name)"
        case let .unsafeFile(name):
            "模型包含不安全的文件：\(name)"
        }
    }
}

public actor LocalModelImportService {
    private struct FileEntry: Sendable {
        let source: URL
        let relativePath: String
        let sizeBytes: Int64
    }

    private let manager: PluginManager
    private let fileManager: FileManager

    public init(
        manager: PluginManager = PluginManager(),
        fileManager: FileManager = .default
    ) {
        self.manager = manager
        self.fileManager = fileManager
    }

    public func inspect(
        directory: URL
    ) throws -> LocalTranslationModelCandidate {
        let entries = try modelEntries(in: directory)
        let relativePaths = Set(entries.map(\.relativePath))
        guard relativePaths.contains("config.json") else {
            throw LocalModelImportError.missingConfig
        }
        guard entries.contains(where: {
            $0.relativePath.hasSuffix(".safetensors")
        }) else {
            throw LocalModelImportError.missingWeights
        }
        guard entries.contains(where: {
            let name = URL(fileURLWithPath: $0.relativePath).lastPathComponent
            return name == "tokenizer.json"
                || name == "tokenizer.model"
                || name.hasSuffix(".spm")
        }) else {
            throw LocalModelImportError.missingTokenizer
        }

        let configData = try Data(
            contentsOf: directory.appendingPathComponent("config.json")
        )
        guard let config = try JSONSerialization.jsonObject(
            with: configData
        ) as? [String: Any] else {
            throw LocalModelImportError.invalidConfig
        }
        let architectures = config["architectures"] as? [String] ?? []
        let modelType = (config["model_type"] as? String)
            ?? architectures.first
            ?? "unknown"

        if let indexEntry = entries.first(where: {
            $0.relativePath.hasSuffix(".safetensors.index.json")
        }) {
            let indexData = try Data(contentsOf: indexEntry.source)
            guard let index = try JSONSerialization.jsonObject(
                with: indexData
            ) as? [String: Any],
                  let weightMap = index["weight_map"] as? [String: String] else {
                throw LocalModelImportError.invalidConfig
            }
            for shard in Set(weightMap.values) where !relativePaths.contains(shard) {
                throw LocalModelImportError.missingWeightShard(shard)
            }
        }

        let sizeBytes = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let estimatedRAMBytes = max(
            Int64(2 * 1_073_741_824),
            Int64(Double(sizeBytes) * 2.0)
        )
        let tokenizerConfig = directory.appendingPathComponent(
            "tokenizer_config.json"
        )
        var hasChatTemplate = relativePaths.contains("chat_template.jinja")
        if let data = try? Data(contentsOf: tokenizerConfig),
           let tokenizer = try? JSONSerialization.jsonObject(
               with: data
           ) as? [String: Any],
           let template = tokenizer["chat_template"] as? String {
            hasChatTemplate = hasChatTemplate || !template.isEmpty
        }
        guard hasChatTemplate else {
            throw LocalModelImportError.missingChatTemplate
        }

        return LocalTranslationModelCandidate(
            sourceDirectory: directory.resolvingSymlinksInPath(),
            proposedName: directory.lastPathComponent,
            modelType: modelType,
            sizeBytes: sizeBytes,
            estimatedRAMBytes: estimatedRAMBytes,
            hasChatTemplate: hasChatTemplate
        )
    }

    public func importModel(
        from sourceDirectory: URL,
        displayName: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try Task.checkCancellation()
        let candidate = try inspect(directory: sourceDirectory)
        let entries = try modelEntries(in: sourceDirectory)
        let name = normalizedName(
            displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? candidate.proposedName
        )
        let identifier = Self.importedIdentifier(for: candidate.sourceDirectory)
        let manifest = PluginManifest(
            id: identifier,
            type: .translation,
            name: name,
            version: "local",
            runtime: "mlx",
            capabilities: ["word", "phrase", "sentence"],
            languages: ["zh-Hans", "en"],
            sizeBytes: candidate.sizeBytes,
            sha256: "LOCAL_IMPORT",
            url: candidate.sourceDirectory,
            license: "本地模型",
            minRAMBytes: candidate.estimatedRAMBytes,
            quality: "local",
            recommended: false,
            summary: "本地导入 · \(candidate.modelType)",
            source: .local,
            promptProfile: .generic
        )

        let staging = try await manager.createStagingDirectory()
        let stagingModel = staging.appendingPathComponent(
            "model",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: stagingModel,
                withIntermediateDirectories: true
            )
            try await Task.detached(priority: .userInitiated) {
                try Self.copy(entries: entries, to: stagingModel, progress: progress)
            }.value
            try Task.checkCancellation()
            try JSONEncoder().encode(manifest).write(
                to: staging.appendingPathComponent("manifest.json")
            )
            let installed = try await manager.installPreparedPlugin(at: staging)
            progress?(1)
            return installed
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func modelEntries(in directory: URL) throws -> [FileEntry] {
        let root = directory.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LocalModelImportError.notADirectory
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var entries: [FileEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            if values.isSymbolicLink == true {
                throw LocalModelImportError.unsafeFile(
                    url.path.replacingOccurrences(of: root.path + "/", with: "")
                )
            }
            guard values.isRegularFile == true else { continue }
            let resolvedURL = url.resolvingSymlinksInPath()
            let relativePath = resolvedURL.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            guard Self.isModelFile(relativePath) else { continue }
            entries.append(
                FileEntry(
                    source: resolvedURL,
                    relativePath: relativePath,
                    sizeBytes: Int64(values.fileSize ?? 0)
                )
            )
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func normalizedName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "本地 MLX 模型"
        }
        return String(name.prefix(80))
    }

    private static func importedIdentifier(for directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.path.utf8))
        let suffix = digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "user-mlx-\(suffix)"
    }

    private static func isModelFile(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard !name.hasPrefix(".") else { return false }
        let allowedNames: Set<String> = [
            "config.json",
            "generation_config.json",
            "tokenizer.json",
            "tokenizer.model",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "added_tokens.json",
            "vocab.json",
            "merges.txt",
            "chat_template.jinja",
            "preprocessor_config.json",
        ]
        return allowedNames.contains(name)
            || name.hasSuffix(".safetensors")
            || name.hasSuffix(".safetensors.index.json")
            || name.hasSuffix(".spm")
            || name.hasSuffix(".tiktoken")
    }

    private static func copy(
        entries: [FileEntry],
        to directory: URL,
        progress: (@Sendable (Double) -> Void)?
    ) throws {
        let total = max(Int64(1), entries.reduce(Int64(0)) { $0 + $1.sizeBytes })
        var completed = Int64(0)
        let fileManager = FileManager.default

        for entry in entries {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(
                entry.relativePath,
                isDirectory: false
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try cloneOrCopyFile(from: entry.source, to: destination)
            completed += entry.sizeBytes
            progress?(min(0.95, Double(completed) / Double(total)))
        }
    }

    private static func cloneOrCopyFile(
        from source: URL,
        to destination: URL
    ) throws {
        let cloneStatus = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                copyfile(
                    sourcePath,
                    destinationPath,
                    nil,
                    copyfile_flags_t(COPYFILE_CLONE_FORCE)
                )
            }
        }
        if cloneStatus == 0 {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        try copyFile(from: source, to: destination)
    }

    private static func copyFile(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        while let data = try input.read(upToCount: 8 * 1_048_576),
              !data.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: data)
        }
    }
}
