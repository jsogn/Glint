import Foundation
import GlintCore

public enum PluginCatalogError: Error, LocalizedError, Equatable {
    case invalidResponse
    case checksumMismatch
    case extractionFailed
    case manifestNotFound
    case manifestMismatch
    case runtimeFilesMissing
    case invalidModelRepository
    case invalidModelSnapshot
    case insufficientDiskSpace
    case unsupportedRuntime
    case unsafeContent

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "插件下载服务器返回了无效响应"
        case .checksumMismatch: return "插件文件校验失败"
        case .extractionFailed: return "插件压缩包无法解压"
        case .manifestNotFound: return "插件压缩包缺少 manifest.json"
        case .manifestMismatch: return "插件清单与目录记录不一致"
        case .runtimeFilesMissing: return "插件缺少运行所需的数据文件"
        case .invalidModelRepository: return "模型仓库地址无效"
        case .invalidModelSnapshot: return "模型文件不完整或校验失败"
        case .insufficientDiskSpace: return "磁盘空间不足，无法安装该模型"
        case .unsupportedRuntime: return "插件使用了不支持的运行环境"
        case .unsafeContent: return "插件包含不允许执行的文件或链接"
        }
    }
}

public struct PluginCatalogFetchResult: Sendable {
    public let plugins: [PluginManifest]
    public let isNotModified: Bool
    public let etag: String?
    public let lastModified: String?

    public init(
        plugins: [PluginManifest],
        isNotModified: Bool,
        etag: String?,
        lastModified: String?
    ) {
        self.plugins = plugins
        self.isNotModified = isNotModified
        self.etag = etag
        self.lastModified = lastModified
    }
}

public actor PluginCatalogService {
    let manager: PluginManager
    let fileManager: FileManager
    let session: URLSession

    public init(
        manager: PluginManager = PluginManager(),
        fileManager: FileManager = .default,
        session: URLSession? = nil
    ) {
        self.manager = manager
        self.fileManager = fileManager
        self.session =
            session
            ?? HuggingFaceRemotePolicy.makeSession(
                requestTimeout: 30,
                resourceTimeout: 60 * 60
            )
    }

    public func fetchCatalog(from url: URL) async throws -> [PluginManifest] {
        try await fetchCatalogResult(from: url).plugins
    }

    public func fetchCatalogResult(
        from url: URL,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> PluginCatalogFetchResult {
        guard url.isFileURL || Self.isAllowedRemoteURL(url) else {
            throw PluginCatalogError.invalidResponse
        }
        let data: Data
        let responseETag: String?
        let responseLastModified: String?
        if url.isFileURL {
            data = try Data(contentsOf: url)
            responseETag = nil
            responseLastModified = nil
        } else {
            var request = URLRequest(url: url)
            if let etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified {
                request.setValue(
                    lastModified,
                    forHTTPHeaderField: "If-Modified-Since"
                )
            }
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PluginCatalogError.invalidResponse
            }
            if http.statusCode == 304 {
                return PluginCatalogFetchResult(
                    plugins: [],
                    isNotModified: true,
                    etag: http.value(forHTTPHeaderField: "ETag") ?? etag,
                    lastModified: http.value(
                        forHTTPHeaderField: "Last-Modified"
                    ) ?? lastModified
                )
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PluginCatalogError.invalidResponse
            }
            data = responseData
            responseETag = http.value(forHTTPHeaderField: "ETag")
            responseLastModified = http.value(
                forHTTPHeaderField: "Last-Modified"
            )
        }

        let decoder = JSONDecoder()
        let plugins = try decoder.decode(
            PluginCatalogPayload.self,
            from: data
        ).plugins
        return PluginCatalogFetchResult(
            plugins: plugins,
            isNotModified: false,
            etag: responseETag,
            lastModified: responseLastModified
        )
    }

    public func uninstall(id: String) async throws {
        try await manager.remove(id: id)
        await discardDownload(for: id)
    }

    public func discardDownload(for id: String) async {
        let downloads = await manager.downloadStagingDirectory()
        removeDownloadStagingDirectory(
            downloads.appendingPathComponent(
                Self.downloadIdentifier(id),
                isDirectory: true
            )
        )
    }
}
