import CryptoKit
import Foundation
import GlintCore

public enum ModelHubError: Error, LocalizedError, Equatable {
    case invalidRepository
    case invalidResponse
    case incompleteModel
    case unsupportedModel
    case unsupportedModelType(String)
    case unsupportedPipeline(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "模型仓库地址无效"
        case .invalidResponse:
            return "模型市场返回了无效响应"
        case .incompleteModel:
            return "模型文件不完整，无法安装"
        case .unsupportedModel:
            return "模型与当前 Glint 运行时不兼容"
        case .unsupportedModelType(let value):
            return "当前版本不支持模型架构 \(value)"
        case .unsupportedPipeline(let value):
            return "不是 Glint 支持的文本生成模型（\(value)）"
        case .unavailable:
            return "模型市场暂时不可用"
        }
    }
}

public struct UpstreamModelSummary: Identifiable, Sendable, Equatable {
    public let repository: String
    public let name: String
    public let downloads: Int
    public let likes: Int
    public let pipelineTag: String?
    public let tags: [String]
    public let license: String?

    public var id: String { repository }

    public init(
        repository: String,
        name: String,
        downloads: Int,
        likes: Int,
        pipelineTag: String?,
        tags: [String],
        license: String?
    ) {
        self.repository = repository
        self.name = name
        self.downloads = downloads
        self.likes = likes
        self.pipelineTag = pipelineTag
        self.tags = tags
        self.license = license
    }
}

public struct UpstreamModelSnapshot: Sendable, Equatable {
    public let repository: String
    public let revision: String
    public let lastModified: String?
    public let modelType: String
    public let sizeBytes: Int64
    public let license: String
    public let hasChatTemplate: Bool
    public let parameterCount: Int64?
    public let quantizationBits: Double?
    public let pipelineTag: String?

    public init(
        repository: String,
        revision: String,
        lastModified: String?,
        modelType: String,
        sizeBytes: Int64,
        license: String,
        hasChatTemplate: Bool
    ) {
        self.init(
            repository: repository,
            revision: revision,
            lastModified: lastModified,
            modelType: modelType,
            sizeBytes: sizeBytes,
            license: license,
            hasChatTemplate: hasChatTemplate,
            parameterCount: nil,
            quantizationBits: nil,
            pipelineTag: nil
        )
    }

    public init(
        repository: String,
        revision: String,
        lastModified: String?,
        modelType: String,
        sizeBytes: Int64,
        license: String,
        hasChatTemplate: Bool,
        parameterCount: Int64?,
        quantizationBits: Double?,
        pipelineTag: String?
    ) {
        self.repository = repository
        self.revision = revision
        self.lastModified = lastModified
        self.modelType = modelType
        self.sizeBytes = sizeBytes
        self.license = license
        self.hasChatTemplate = hasChatTemplate
        self.parameterCount = parameterCount
        self.quantizationBits = quantizationBits
        self.pipelineTag = pipelineTag
    }
}

public struct ModelInstallPreparation: Sendable, Equatable {
    public let manifest: PluginManifest
    public let snapshot: UpstreamModelSnapshot

    public init(
        manifest: PluginManifest,
        snapshot: UpstreamModelSnapshot
    ) {
        self.manifest = manifest
        self.snapshot = snapshot
    }
}

public struct UpstreamModelUpdate: Sendable, Equatable {
    public let currentRevision: String
    public let latestRevision: String
    public let lastModified: String?
    public let manifest: PluginManifest

    public init(
        currentRevision: String,
        latestRevision: String,
        lastModified: String?,
        manifest: PluginManifest
    ) {
        self.currentRevision = currentRevision
        self.latestRevision = latestRevision
        self.lastModified = lastModified
        self.manifest = manifest
    }
}

public actor ModelHubService {
    private static let maximumModelSizeBytes: Int64 =
        1_024 * 1_073_741_824

    private let session: URLSession
    private let endpoints: [URL]

    public init(
        session: URLSession? = nil,
        endpoints: [URL]? = nil
    ) {
        self.session = session ?? Self.defaultSession
        self.endpoints =
            endpoints?.isEmpty == false
            ? endpoints!
            : Self.defaultEndpoints()
    }

    public func search(
        query: String,
        limit: Int = 30
    ) async throws -> [UpstreamModelSummary] {
        let normalizedLimit = min(max(limit, 1), 50)
        return try await withEndpoints { endpoint in
            guard
                var components = URLComponents(
                    url: endpoint.appendingPathComponent("api/models"),
                    resolvingAgainstBaseURL: false
                )
            else {
                throw ModelHubError.invalidResponse
            }
            var queryItems = [
                URLQueryItem(name: "filter", value: "mlx"),
                URLQueryItem(name: "sort", value: "downloads"),
                URLQueryItem(name: "direction", value: "-1"),
                URLQueryItem(
                    name: "limit",
                    value: String(normalizedLimit)
                ),
            ]
            let trimmedQuery = query.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if trimmedQuery.isEmpty {
                queryItems.append(
                    URLQueryItem(
                        name: "pipeline_tag",
                        value: "translation"
                    )
                )
            } else {
                queryItems.append(
                    URLQueryItem(name: "search", value: trimmedQuery)
                )
            }
            components.queryItems = queryItems
            guard let url = components.url else {
                throw ModelHubError.invalidResponse
            }
            let data = try await data(from: url)
            let decoded = try JSONDecoder().decode(
                [ModelSearchRecord].self,
                from: data
            )
            var seen: Set<String> = []
            var results: [UpstreamModelSummary] = []
            for record in decoded {
                guard
                    Self.isValidRepository(record.id),
                    seen.insert(record.id).inserted,
                    record.libraryName == "mlx"
                        || record.tags.contains("mlx")
                        || record.tags.isEmpty
                else {
                    continue
                }
                results.append(
                    UpstreamModelSummary(
                        repository: record.id,
                        name: record.id.split(separator: "/").last.map(String.init)
                            ?? record.id,
                        downloads: record.downloads ?? 0,
                        likes: record.likes ?? 0,
                        pipelineTag: record.pipelineTag,
                        tags: record.tags,
                        license: Self.license(from: record.tags)
                    )
                )
            }
            return results
        }
    }

    public func inspect(
        repository: String
    ) async throws -> UpstreamModelSnapshot {
        guard Self.isValidRepository(repository) else {
            throw ModelHubError.invalidRepository
        }
        return try await withEndpoints { endpoint in
            let modelData = try await data(
                from: try Self.url(
                    endpoint: endpoint,
                    path: "api/models/\(repository)"
                )
            )
            let record = try JSONDecoder().decode(
                ModelDetailsRecord.self,
                from: modelData
            )
            guard record.private == false,
                record.gated?.isGated == false || record.gated == nil
            else {
                throw ModelHubError.unavailable
            }
            if let pipelineTag = record.pipelineTag,
                !Self.isTextGenerationPipeline(pipelineTag)
            {
                throw ModelHubError.unsupportedPipeline(pipelineTag)
            }
            guard let revision = record.sha, !revision.isEmpty else {
                throw ModelHubError.invalidResponse
            }

            let snapshotData = try await data(
                from: try Self.url(
                    endpoint: endpoint,
                    path:
                        "api/models/\(repository)/revision/\(revision)",
                    queryItems: [
                        URLQueryItem(name: "blobs", value: "true")
                    ]
                )
            )
            let snapshot = try JSONDecoder().decode(
                RepositorySnapshot.self,
                from: snapshotData
            )
            let files = snapshot.siblings.filter {
                Self.isRuntimeModelFile($0.filename)
            }
            let names = Set(files.map(\.filename))
            guard
                names.contains("config.json"),
                Self.hasBaseModelWeights(names),
                Self.hasTokenizer(names)
            else {
                throw ModelHubError.incompleteModel
            }
            let configData = try await data(
                from: try Self.url(
                    endpoint: endpoint,
                    path:
                        "\(repository)/resolve/\(revision)/config.json"
                )
            )
            let config = try JSONDecoder().decode(
                ModelConfigRecord.self,
                from: configData
            )
            guard
                let modelType = config.modelType?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !modelType.isEmpty
            else {
                throw ModelHubError.invalidResponse
            }

            var hasChatTemplate = names.contains("chat_template.jinja")
            if !hasChatTemplate,
                names.contains("tokenizer_config.json"),
                let tokenizerData = try? await data(
                    from: Self.url(
                        endpoint: endpoint,
                        path:
                            "\(repository)/resolve/\(revision)/tokenizer_config.json"
                    )
                ),
                let tokenizer = try? JSONDecoder().decode(
                    TokenizerConfigRecord.self,
                    from: tokenizerData
                ),
                let template = tokenizer.chatTemplate
            {
                hasChatTemplate =
                    !template
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            guard hasChatTemplate else {
                throw ModelHubError.incompleteModel
            }

            guard
                let sizeBytes = RemoteByteCount.checkedSum(
                    files.lazy.map { max(0, $0.size ?? 0) }
                ),
                sizeBytes <= Self.maximumModelSizeBytes
            else {
                throw ModelHubError.invalidResponse
            }
            return UpstreamModelSnapshot(
                repository: repository,
                revision: revision,
                lastModified: record.lastModified,
                modelType: modelType,
                sizeBytes: sizeBytes,
                license: Self.license(from: record.tags) ?? "未知",
                hasChatTemplate: hasChatTemplate,
                parameterCount: record.safetensors?.total,
                quantizationBits: Self.quantizationBits(
                    config: config,
                    tags: record.tags
                ),
                pipelineTag: record.pipelineTag
            )
        }
    }

    public func update(
        for installed: PluginManifest
    ) async throws -> UpstreamModelUpdate? {
        guard installed.type == .translation,
            installed.runtime == "mlx",
            let repository = Self.repositoryID(from: installed.url),
            let currentRevision = installed.revision
        else {
            return nil
        }
        let snapshot = try await inspect(repository: repository)
        guard snapshot.revision != currentRevision else {
            return nil
        }
        return UpstreamModelUpdate(
            currentRevision: currentRevision,
            latestRevision: snapshot.revision,
            lastModified: snapshot.lastModified,
            manifest: Self.manifest(
                for: snapshot,
                matching: installed
            )
        )
    }

    public static func manifest(
        for snapshot: UpstreamModelSnapshot,
        matching installed: PluginManifest?
    ) -> PluginManifest {
        let repositoryURL = URL(
            string: "https://huggingface.co/\(snapshot.repository)"
        )!
        let identifier =
            installed
            ?? PluginManifest(
                id: generatedIdentifier(for: snapshot.repository),
                type: .translation,
                name: snapshot.repository.split(separator: "/").last
                    .map(String.init) ?? snapshot.repository,
                version: String(snapshot.revision.prefix(12)),
                runtime: "mlx",
                sizeBytes: snapshot.sizeBytes,
                sha256: "HUGGINGFACE_SNAPSHOT",
                url: repositoryURL,
                license: snapshot.license,
                minRAMBytes: estimatedRAM(for: snapshot.sizeBytes),
                summary: "上游模型 · \(snapshot.modelType)",
                revision: snapshot.revision,
                source: .catalog,
                promptProfile: inferredPromptProfile(
                    for: snapshot.repository
                )
            )
        return PluginManifest(
            id: identifier.id,
            type: .translation,
            name: identifier.name,
            version: identifier.version,
            runtime: "mlx",
            sizeBytes: snapshot.sizeBytes,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: repositoryURL,
            license: snapshot.license,
            minRAMBytes: max(
                identifier.minRAMBytes,
                estimatedRAM(for: snapshot.sizeBytes)
            ),
            summary: identifier.summary,
            revision: snapshot.revision,
            modelscopeURL: identifier.modelscopeURL,
            source: .catalog,
            promptProfile: identifier.promptProfile
                ?? inferredPromptProfile(for: snapshot.repository)
        )
    }

    private func withEndpoints<T: Sendable>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for endpoint in endpoints {
            do {
                return try await operation(endpoint)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ModelHubError.unavailable
    }

    private func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw ModelHubError.invalidResponse
        }
        return data
    }

    private static func url(
        endpoint: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: endpoint.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )
        else {
            throw ModelHubError.invalidResponse
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw ModelHubError.invalidResponse
        }
        return url
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return parts.allSatisfy { part in
            !part.isEmpty
                && part != "."
                && part != ".."
                && part.unicodeScalars.allSatisfy {
                    allowed.contains($0)
                }
        }
    }

    private static func repositoryID(from url: URL) -> String? {
        let host = url.host?.lowercased()
        guard
            host == "huggingface.co"
                || host?.hasSuffix("hf-mirror.com") == true
        else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count == 2 else { return nil }
        let repository = "\(components[0])/\(components[1])"
        return isValidRepository(repository) ? repository : nil
    }

    private static func hasTokenizer(_ names: Set<String>) -> Bool {
        names.contains("tokenizer.json")
            || names.contains("tokenizer.model")
            || names.contains(where: { $0.hasSuffix(".spm") })
    }

    private static func hasBaseModelWeights(_ names: Set<String>) -> Bool {
        names.contains { name in
            let lowercased = name.lowercased()
            return lowercased.hasSuffix(".safetensors")
                && !lowercased.contains("adapter")
                && !lowercased.contains("lora")
        }
    }

    private static func isTextGenerationPipeline(_ value: String) -> Bool {
        [
            "text-generation",
            "text2text-generation",
            "translation",
        ].contains(value.lowercased())
    }

    private static func quantizationBits(
        config: ModelConfigRecord,
        tags: [String]
    ) -> Double? {
        if let bits = config.quantizationConfig?.bits, bits > 0 {
            return Double(bits)
        }
        for tag in tags {
            let value = tag.lowercased()
            if value == "bf16" || value == "fp16" {
                return 16
            }
            if value == "fp32" {
                return 32
            }
            if let bitRange = value.range(of: "bit") {
                let prefix = value[..<bitRange.lowerBound]
                    .trimmingCharacters(
                        in: CharacterSet(charactersIn: "-_ ")
                    )
                if let bits = Double(prefix), bits > 0 {
                    return bits
                }
            }
        }
        return nil
    }

    private static func isRuntimeModelFile(_ path: String) -> Bool {
        guard !path.hasPrefix("."),
            !path.hasPrefix("README"),
            !path.contains("/.")
        else {
            return false
        }
        return path.hasSuffix(".safetensors")
            || path.hasSuffix(".json")
            || path.hasSuffix(".jinja")
            || path.hasSuffix(".txt")
            || path.hasSuffix(".model")
            || path.hasSuffix(".spm")
            || path.hasSuffix(".tiktoken")
    }

    private static func license(from tags: [String]) -> String? {
        tags.first { $0.hasPrefix("license:") }
            .map { String($0.dropFirst("license:".count)) }
    }

    private static func generatedIdentifier(for repository: String) -> String {
        let digest = SHA256.hash(data: Data(repository.utf8))
        let suffix = digest.prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "upstream-mlx-\(suffix)"
    }

    private static func estimatedRAM(for sizeBytes: Int64) -> Int64 {
        let estimated =
            RemoteByteCount.checkedProduct(sizeBytes, 6)
            ?? Int64.max
        return max(6 * 1_073_741_824, estimated)
    }

    private static func inferredPromptProfile(
        for repository: String
    ) -> TranslationPromptProfile {
        let value = repository.lowercased()
        if value.contains("hy-mt") {
            return .hyMT2
        }
        if value.contains("index-translate") {
            return .indexTranslate
        }
        if value.contains("qwen") {
            return .qwenGeneral
        }
        return .generic
    }

    private static func defaultEndpoints() -> [URL] {
        let environment = ProcessInfo.processInfo.environment
        var values: [String] = []
        if let configured = environment["GLINT_HF_ENDPOINT"] {
            values.append(configured)
        }
        values.append(environment["GLINT_HF_MIRROR"] ?? "https://hf-mirror.com")
        values.append("https://huggingface.co")
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard seen.insert(trimmed).inserted else { return nil }
            return URL(string: trimmed)
        }
    }

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

private struct ModelSearchRecord: Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let libraryName: String?
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case likes
        case pipelineTag = "pipeline_tag"
        case libraryName = "library_name"
        case tags
    }
}

private struct ModelDetailsRecord: Decodable {
    let sha: String?
    let lastModified: String?
    let `private`: Bool?
    let gated: FlexibleGate?
    let tags: [String]
    let pipelineTag: String?
    let safetensors: ModelDetailSafetensorsRecord?

    private enum CodingKeys: String, CodingKey {
        case sha
        case lastModified
        case `private`
        case gated
        case tags
        case pipelineTag = "pipeline_tag"
        case safetensors
    }
}

private enum FlexibleGate: Decodable {
    case flag(Bool)
    case value(String)

    var isGated: Bool {
        switch self {
        case .flag(let value):
            return value
        case .value(let value):
            return !value.isEmpty && value.lowercased() != "false"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
        } else {
            self = .value(try container.decode(String.self))
        }
    }
}

private struct RepositorySnapshot: Decodable {
    struct Sibling: Decodable {
        let filename: String
        let size: Int64?

        private enum CodingKeys: String, CodingKey {
            case filename = "rfilename"
            case size
        }
    }

    let siblings: [Sibling]
}

private struct ModelConfigRecord: Decodable {
    struct QuantizationConfig: Decodable {
        let bits: Int?
    }

    let modelType: String?
    let quantizationConfig: QuantizationConfig?

    private enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case quantizationConfig = "quantization_config"
    }
}

private struct ModelDetailSafetensorsRecord: Decodable {
    let total: Int64?
}

private struct TokenizerConfigRecord: Decodable {
    let chatTemplate: String?

    private enum CodingKeys: String, CodingKey {
        case chatTemplate = "chat_template"
    }
}
