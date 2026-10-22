import CryptoKit
import Foundation

public enum PluginCatalogError: Error, LocalizedError, Equatable {
    case invalidResponse
    case checksumMismatch
    case extractionFailed
    case manifestNotFound
    case manifestMismatch
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
    private let manager: PluginManager
    private let fileManager: FileManager
    private let session: URLSession

    public init(
        manager: PluginManager = PluginManager(),
        fileManager: FileManager = .default,
        session: URLSession? = nil
    ) {
        self.manager = manager
        self.fileManager = fileManager
        self.session = session ?? Self.defaultSession
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
        let plugins = if let plugins = try? decoder.decode(
            [PluginManifest].self,
            from: data
        ) {
            plugins
        } else {
            try decoder.decode(PluginCatalogPayload.self, from: data).plugins
        }
        return PluginCatalogFetchResult(
            plugins: plugins,
            isNotModified: false,
            etag: responseETag,
            lastModified: responseLastModified
        )
    }

    public func install(
        _ manifest: PluginManifest,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> PluginManifest {
        try Task.checkCancellation()
        guard PluginRuntimePolicy.supportsDownloadedRuntime(
            type: manifest.type,
            runtime: manifest.runtime
        ) else {
            throw PluginCatalogError.unsupportedRuntime
        }
        guard manifest.url.isFileURL || Self.isAllowedRemoteURL(manifest.url) else {
            throw PluginCatalogError.invalidResponse
        }
        if manifest.runtime == "mlx" {
            return try await installMLXSnapshot(manifest, progress: progress)
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("GlintPlugin-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let archiveURL = workDirectory.appendingPathComponent("plugin.archive")
        if manifest.url.isFileURL {
            try fileManager.copyItem(at: manifest.url, to: archiveURL)
            progress?(0.5)
        } else {
            let downloadDirectory = workDirectory.appendingPathComponent(
                "download",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true
            )
            let delegate = DownloadProgressDelegate(progress: progress)
            let (temporaryURL, response) = try await session.download(
                from: manifest.url,
                delegate: delegate
            )
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw PluginCatalogError.invalidResponse
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        }

        guard let archiveData = try? Data(contentsOf: archiveURL) else {
            throw PluginCatalogError.invalidResponse
        }
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard manifest.sha256 != "REPLACE_ME", digest == manifest.sha256.lowercased() else {
            throw PluginCatalogError.checksumMismatch
        }
        progress?(0.85)
        try Task.checkCancellation()

        let extractedDirectory = workDirectory.appendingPathComponent(
            "extracted",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: extractedDirectory,
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-x",
            "-k",
            archiveURL.path,
            extractedDirectory.path,
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PluginCatalogError.extractionFailed
        }
        try validatePluginContents(in: extractedDirectory)

        guard let manifestURL = findManifest(in: extractedDirectory),
              let data = try? Data(contentsOf: manifestURL),
              let embedded = try? JSONDecoder().decode(PluginManifest.self, from: data) else {
            throw PluginCatalogError.manifestNotFound
        }
        guard embedded.id == manifest.id,
              embedded.type == manifest.type,
              embedded.version == manifest.version else {
            throw PluginCatalogError.manifestMismatch
        }

        let pluginDirectory = manifestURL.deletingLastPathComponent()
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try Task.checkCancellation()
        let installed = try await manager.installPreparedPlugin(
            at: pluginDirectory,
            keepBackup: true
        )
        progress?(1)
        return installed
    }

    public func uninstall(id: String) async throws {
        try await manager.remove(id: id)
    }

    private func findManifest(in directory: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == "manifest.json" {
            return url
        }
        return nil
    }

    private func validatePluginContents(in directory: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw PluginCatalogError.extractionFailed
        }
        let rejectedExtensions: Set<String> = [
            "app", "bundle", "command", "dylib", "framework", "jar",
            "js", "o", "py", "rb", "sh", "so", "a",
        ]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw PluginCatalogError.unsafeContent
            }
            let pathExtension = url.pathExtension.lowercased()
            if rejectedExtensions.contains(pathExtension) {
                throw PluginCatalogError.unsafeContent
            }
            guard values.isRegularFile == true else { continue }
            if fileManager.isExecutableFile(atPath: url.path)
                || Self.hasExecutableMagic(url) {
                throw PluginCatalogError.unsafeContent
            }
        }
    }

    private static func hasExecutableMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4),
              data.count == 4 else {
            return false
        }
        let bytes = Array(data)
        if bytes.starts(with: [0x23, 0x21]) {
            return true
        }
        return [
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF],
            [0xBF, 0xBA, 0xFE, 0xCA],
        ].contains(bytes)
    }

    private func installMLXSnapshot(
        _ manifest: PluginManifest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> PluginManifest {
        guard let repository = Self.huggingFaceRepositoryID(from: manifest.url) else {
            throw PluginCatalogError.invalidModelRepository
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("GlintMLX-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let modelDirectory = workDirectory.appendingPathComponent(
            "model",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )

        var lastError: Error?
        for endpoint in Self.huggingFaceEndpoints(for: manifest.url) {
            try Task.checkCancellation()
            progress?(0)
            do {
                try await downloadMLXSnapshot(
                    repository: repository,
                    revision: manifest.revision ?? "main",
                    endpoint: endpoint,
                    into: modelDirectory,
                    progress: progress
                )
                lastError = nil
                break
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = error
                try? fileManager.removeItem(at: modelDirectory)
                try fileManager.createDirectory(
                    at: modelDirectory,
                    withIntermediateDirectories: true
                )
            }
        }
        if let lastError {
            throw lastError
        }
        try Task.checkCancellation()

        let pluginDirectory = workDirectory.appendingPathComponent(
            "plugin",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: pluginDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(
            at: modelDirectory,
            to: pluginDirectory.appendingPathComponent("model", isDirectory: true)
        )
        try JSONEncoder().encode(manifest).write(
            to: pluginDirectory.appendingPathComponent("manifest.json")
        )

        try Task.checkCancellation()
        let installed = try await manager.installLocalPlugin(at: pluginDirectory)
        progress?(1)
        return installed
    }

    private func downloadMLXSnapshot(
        repository: String,
        revision: String,
        endpoint: URL,
        into directory: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let apiURL = URL(
            string: "\(endpoint.absoluteString)/api/models/\(repository)/revision/\(revision)?blobs=true"
        ) else {
            throw PluginCatalogError.invalidModelRepository
        }
        let (data, response) = try await session.data(from: apiURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw PluginCatalogError.invalidResponse
        }
        let snapshot = try JSONDecoder().decode(HuggingFaceSnapshot.self, from: data)
        let files = snapshot.siblings
            .filter { Self.shouldInstallModelFile($0.rfilename) }
            .sorted { $0.rfilename < $1.rfilename }
        guard Self.isCompleteModelSnapshot(files) else {
            throw PluginCatalogError.invalidModelSnapshot
        }

        let expectedBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let available = try directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage ?? 0
        if expectedBytes > 0, available > 0, available < expectedBytes * 2 {
            throw PluginCatalogError.insufficientDiskSpace
        }

        var completedBytes = Int64(0)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let destination = Self.safeDestination(
                for: file.rfilename,
                in: directory
            ) else {
                throw PluginCatalogError.invalidModelSnapshot
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard let downloadURL = URL(
                string: "\(endpoint.absoluteString)/\(repository)/resolve/\(revision)/"
                    + file.rfilename
            ) else {
                throw PluginCatalogError.invalidModelRepository
            }

            let fileBytes = file.size ?? 0
            let completedBeforeFile = completedBytes
            let fileCount = files.count
            let delegate = SnapshotFileProgressDelegate {
                [completedBeforeFile, expectedBytes, index, fileCount, fileBytes] received in
                if expectedBytes > 0 {
                    let current = completedBeforeFile + min(received, fileBytes)
                    progress?(min(0.98, Double(current) / Double(expectedBytes)))
                } else {
                    progress?(0.98 * Double(index) / Double(fileCount))
                }
            }
            let (temporaryURL, response) = try await session.download(
                from: downloadURL,
                delegate: delegate
            )
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw PluginCatalogError.invalidResponse
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)

            let actualBytes = try destination.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
            if fileBytes > 0, actualBytes != fileBytes {
                throw PluginCatalogError.invalidModelSnapshot
            }
            if let expectedSHA = file.lfs?.sha256,
               try Self.sha256(of: destination) != expectedSHA.lowercased() {
                throw PluginCatalogError.invalidModelSnapshot
            }
            try Task.checkCancellation()
            completedBytes += Int64(actualBytes)
            progress?(min(0.98, Double(index + 1) / Double(files.count)))
        }
    }

    private static func huggingFaceRepositoryID(from url: URL) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return nil }
        return "\(components[0])/\(components[1])"
    }

    static func huggingFaceEndpoints(
        for manifestURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var values: [String] = []
        if let configured = environment["GLINT_HF_ENDPOINT"] {
            values.append(configured)
        }
        values.append(environment["GLINT_HF_MIRROR"] ?? "https://hf-mirror.com")
        values.append("https://huggingface.co")
        if let host = manifestURL.host {
            let scheme = manifestURL.scheme ?? "https"
            values.append("\(scheme)://\(host)")
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(trimmed).inserted else { return nil }
            return URL(string: trimmed)
        }.filter {
            isAllowedRemoteURL($0)
        }
    }

    private static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" {
            return true
        }
        guard scheme == "http",
              let host = url.host?.lowercased() else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private static func shouldInstallModelFile(_ name: String) -> Bool {
        guard !name.hasPrefix("."),
              !name.hasPrefix("README"),
              !name.contains("/."),
              !name.split(separator: "/").contains("..") else {
            return false
        }
        return name.hasSuffix(".safetensors")
            || name.hasSuffix(".json")
            || name.hasSuffix(".jinja")
            || name.hasSuffix(".txt")
            || name.hasSuffix(".model")
            || name.hasSuffix(".spm")
            || name.hasSuffix(".tiktoken")
    }

    private static func isCompleteModelSnapshot(
        _ files: [HuggingFaceSnapshot.Sibling]
    ) -> Bool {
        let names = Set(files.map(\.rfilename))
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        let hasTokenizer = names.contains("tokenizer.json")
            || names.contains { $0.hasSuffix(".model") }
        return names.contains("config.json") && hasWeights && hasTokenizer
    }

    private static func safeDestination(for path: String, in root: URL) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." }) else {
            return nil
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024),
              !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

private struct PluginCatalogPayload: Decodable {
    let plugins: [PluginManifest]
}

private struct HuggingFaceSnapshot: Decodable {
    struct Sibling: Decodable {
        struct LFS: Decodable {
            let sha256: String?
        }

        let rfilename: String
        let size: Int64?
        let lfs: LFS?
    }

    let siblings: [Sibling]
}

private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(
            min(
                0.8,
                0.8 * Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            )
        )
    }
}

private final class SnapshotFileProgressDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let onProgress: @Sendable (Int64) -> Void

    init(onProgress: @escaping @Sendable (Int64) -> Void) {
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten)
    }
}
