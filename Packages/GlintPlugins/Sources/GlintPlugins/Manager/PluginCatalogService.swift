import CryptoKit
import Foundation

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

    public func install(
        _ manifest: PluginManifest,
        progress: (@Sendable (PluginInstallProgress) -> Void)? = nil
    ) async throws -> PluginManifest {
        try Task.checkCancellation()
        guard
            PluginRuntimePolicy.supportsDownloadedRuntime(
                type: manifest.type,
                runtime: manifest.runtime
            )
        else {
            throw PluginCatalogError.unsupportedRuntime
        }
        guard manifest.url.isFileURL || Self.isAllowedRemoteURL(manifest.url) else {
            throw PluginCatalogError.invalidResponse
        }
        if let modelscopeURL = manifest.modelscopeURL,
            !Self.isAllowedModelScopeURL(modelscopeURL)
        {
            throw PluginCatalogError.invalidResponse
        }
        if manifest.runtime == "mlx" {
            return try await installMLXSnapshot(manifest, progress: progress)
        }
        let reporter = InstallProgressReporter(progress)
        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.preparing,
                phase: .preparing,
                sourceHost: manifest.url.host
            ),
            force: true
        )

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
            reporter.emit(
                PluginInstallProgress(
                    fraction: 0.05,
                    phase: .preparing
                ),
                force: true
            )
        } else {
            let downloadDirectory = workDirectory.appendingPathComponent(
                "download",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true
            )
            let totalBytes = max(0, manifest.sizeBytes)
            let (temporaryURL, response) = try await downloadTemporaryFile(
                from: manifest.url
            ) {
                [reporter, totalBytes, sourceHost = manifest.url.host]
                completed,
                expected,
                speed in
                let resolvedTotal = expected > 0 ? expected : totalBytes
                let ratio =
                    resolvedTotal > 0
                    ? Double(min(completed, resolvedTotal))
                        / Double(resolvedTotal)
                    : 0
                reporter.emit(
                    PluginInstallProgress(
                        fraction: PluginInstallProgressRange.mapped(
                            ratio,
                            from: PluginInstallProgressRange.downloadingStart,
                            to: PluginInstallProgressRange.downloadingEnd
                        ),
                        phase: .downloading,
                        completedBytes: completed,
                        totalBytes: resolvedTotal,
                        bytesPerSecond: speed,
                        sourceHost: sourceHost
                    )
                )
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                throw PluginCatalogError.invalidResponse
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        }

        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.verifyingStart,
                phase: .verifying,
                totalBytes: manifest.sizeBytes
            ),
            force: true
        )
        guard let archiveData = try? Data(contentsOf: archiveURL) else {
            throw PluginCatalogError.invalidResponse
        }
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard manifest.sha256 != "REPLACE_ME", digest == manifest.sha256.lowercased() else {
            throw PluginCatalogError.checksumMismatch
        }
        try Task.checkCancellation()
        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.installingStart,
                phase: .installing,
                totalBytes: manifest.sizeBytes
            ),
            force: true
        )

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

        guard let manifestURL = findManifest(in: extractedDirectory) else {
            throw PluginCatalogError.manifestNotFound
        }
        let pluginDirectory = manifestURL.deletingLastPathComponent()
        guard
            let embedded = try? PluginManifest.load(
                from: pluginDirectory
            )
        else {
            throw PluginCatalogError.manifestNotFound
        }
        guard embedded.id == manifest.id,
            embedded.type == manifest.type,
            embedded.version == manifest.version
        else {
            throw PluginCatalogError.manifestMismatch
        }
        guard
            Self.hasRequiredRuntimeFiles(
                for: embedded,
                in: pluginDirectory
            )
        else {
            throw PluginCatalogError.runtimeFilesMissing
        }

        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try Task.checkCancellation()
        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.installingEnd,
                phase: .installing
            ),
            force: true
        )
        let installed = try await manager.installPreparedPlugin(
            at: pluginDirectory,
            keepBackup: true
        )
        reporter.emit(
            PluginInstallProgress(fraction: 1, phase: .installing),
            force: true
        )
        return installed
    }

    public func uninstall(id: String) async throws {
        try await manager.remove(id: id)
    }

    private func findManifest(in directory: URL) -> URL? {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == PluginManifest.fileName {
            return url
        }
        return nil
    }

    private func validatePluginContents(in directory: URL) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
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
                || Self.hasExecutableMagic(url)
            {
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
            data.count == 4
        else {
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
        progress: (@Sendable (PluginInstallProgress) -> Void)?
    ) async throws -> PluginManifest {
        guard
            let huggingFaceRepository = Self.repositoryID(
                from: manifest.url
            )
        else {
            throw PluginCatalogError.invalidModelRepository
        }
        var sources: [MLXDownloadSource] = []
        if manifest.revision == nil,
            let modelscopeURL = manifest.modelscopeURL
        {
            guard
                let repository = Self.repositoryID(
                    from: modelscopeURL,
                    pathPrefix: "models"
                )
            else {
                throw PluginCatalogError.invalidModelRepository
            }
            sources.append(
                .modelScope(
                    repository: repository,
                    endpoint: modelscopeURL
                )
            )
        }
        sources.append(
            contentsOf: Self.huggingFaceEndpoints(for: manifest.url).map {
                .huggingFace(
                    repository: huggingFaceRepository,
                    revision: manifest.revision ?? "main",
                    endpoint: $0
                )
            }
        )
        let reporter = InstallProgressReporter(progress)

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
        for source in sources {
            try Task.checkCancellation()
            reporter.reset()
            reporter.emit(
                PluginInstallProgress(
                    fraction: PluginInstallProgressRange.preparing,
                    phase: .preparing,
                    sourceHost: source.host
                ),
                force: true
            )
            do {
                switch source {
                case let .modelScope(repository, endpoint):
                    try await downloadModelScopeSnapshot(
                        repository: repository,
                        endpoint: endpoint,
                        into: modelDirectory,
                        reporter: reporter
                    )
                case let .huggingFace(repository, revision, endpoint):
                    try await downloadHuggingFaceSnapshot(
                        repository: repository,
                        revision: revision,
                        endpoint: endpoint,
                        into: modelDirectory,
                        reporter: reporter
                    )
                }
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
        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.installingStart,
                phase: .installing
            ),
            force: true
        )
        let installed = try await manager.installPreparedPlugin(
            at: pluginDirectory,
            keepBackup: true
        )
        reporter.emit(
            PluginInstallProgress(fraction: 1, phase: .installing),
            force: true
        )
        return installed
    }

    private func downloadModelScopeSnapshot(
        repository: String,
        endpoint: URL,
        into directory: URL,
        reporter: InstallProgressReporter
    ) async throws {
        guard
            var apiComponents = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw PluginCatalogError.invalidModelRepository
        }
        apiComponents.path =
            "/api/v1/models/\(repository)/repo/files"
        apiComponents.queryItems = [
            URLQueryItem(name: "Revision", value: "master"),
            URLQueryItem(name: "Recursive", value: "true"),
        ]
        apiComponents.fragment = nil
        guard let apiURL = apiComponents.url else {
            throw PluginCatalogError.invalidModelRepository
        }
        let (data, response) = try await session.data(from: apiURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw PluginCatalogError.invalidResponse
        }
        let snapshot = try JSONDecoder().decode(
            ModelScopeSnapshot.self,
            from: data
        )
        var files: [SnapshotDownloadFile] = []
        for file in snapshot.data.files {
            guard file.type == "blob",
                Self.shouldInstallModelFile(file.path)
            else {
                continue
            }
            guard let revision = file.revision, !revision.isEmpty else {
                throw PluginCatalogError.invalidModelSnapshot
            }
            files.append(
                SnapshotDownloadFile(
                    path: file.path,
                    size: file.size,
                    sha256: file.sha256,
                    revision: revision
                )
            )
        }
        files.sort { $0.path < $1.path }

        guard
            var originComponents = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )
        else {
            throw PluginCatalogError.invalidModelRepository
        }
        originComponents.path = ""
        originComponents.query = nil
        originComponents.fragment = nil
        guard let origin = originComponents.url else {
            throw PluginCatalogError.invalidModelRepository
        }
        try await downloadSnapshotFiles(
            files,
            downloadURL: { file in
                guard let revision = file.revision else { return nil }
                let base =
                    "\(origin.absoluteString)/models/\(repository)/resolve/\(revision)/"
                return Self.fileURL(base: base, path: file.path)
            },
            sourceHost: endpoint.host,
            into: directory,
            reporter: reporter
        )
    }

    private func downloadHuggingFaceSnapshot(
        repository: String,
        revision: String,
        endpoint: URL,
        into directory: URL,
        reporter: InstallProgressReporter
    ) async throws {
        guard
            let apiURL = URL(
                string: "\(endpoint.absoluteString)/api/models/\(repository)/revision/\(revision)?blobs=true"
            )
        else {
            throw PluginCatalogError.invalidModelRepository
        }
        let (data, response) = try await session.data(from: apiURL)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw PluginCatalogError.invalidResponse
        }
        let snapshot = try JSONDecoder().decode(
            HuggingFaceSnapshot.self,
            from: data
        )
        let files = snapshot.siblings.compactMap {
            file
                -> SnapshotDownloadFile? in
            guard Self.shouldInstallModelFile(file.rfilename) else {
                return nil
            }
            return SnapshotDownloadFile(
                path: file.rfilename,
                size: file.size ?? 0,
                sha256: file.lfs?.sha256,
                revision: nil
            )
        }.sorted { $0.path < $1.path }
        let downloadBase =
            "\(endpoint.absoluteString)/\(repository)/resolve/\(revision)/"
        try await downloadSnapshotFiles(
            files,
            downloadURL: {
                Self.fileURL(base: downloadBase, path: $0.path)
            },
            sourceHost: endpoint.host,
            into: directory,
            reporter: reporter
        )
    }

    private func downloadSnapshotFiles(
        _ files: [SnapshotDownloadFile],
        downloadURL: @escaping @Sendable (SnapshotDownloadFile) -> URL?,
        sourceHost: String?,
        into directory: URL,
        reporter: InstallProgressReporter
    ) async throws {
        let expectedBytes = try validateSnapshotDownload(
            files,
            into: directory
        )
        var completedBytes = Int64(0)
        var downloadedFiles: [DownloadedSnapshotFile] = []
        for (index, file) in files.enumerated() {
            let progress = SnapshotFileProgress(
                downloadURL: downloadURL,
                sourceHost: sourceHost,
                expectedBytes: expectedBytes,
                completedBytes: completedBytes,
                fileCount: files.count,
                reporter: reporter
            )
            let downloaded = try await downloadSnapshotFile(
                file,
                index: index,
                into: directory,
                progress: progress
            )
            completedBytes += downloaded.actualBytes
            downloadedFiles.append(downloaded)
            progress.reportCompletion(
                index: index,
                completedBytes: completedBytes
            )
        }
        try verifySnapshotFiles(
            downloadedFiles,
            expectedBytes: expectedBytes,
            reporter: reporter
        )
    }

    private func validateSnapshotDownload(
        _ files: [SnapshotDownloadFile],
        into directory: URL
    ) throws -> Int64 {
        guard Self.isCompleteModelSnapshot(files) else {
            throw PluginCatalogError.invalidModelSnapshot
        }
        guard
            let expectedBytes = RemoteByteCount.checkedSum(
                files.lazy.map(\.size)
            )
        else {
            throw PluginCatalogError.invalidModelSnapshot
        }
        let available =
            try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage ?? 0
        if expectedBytes > 0, available > 0 {
            guard
                let requiredBytes = RemoteByteCount.checkedProduct(
                    expectedBytes,
                    2
                )
            else {
                throw PluginCatalogError.invalidModelSnapshot
            }
            if available < requiredBytes {
                throw PluginCatalogError.insufficientDiskSpace
            }
        }
        return expectedBytes
    }

    private func downloadSnapshotFile(
        _ file: SnapshotDownloadFile,
        index: Int,
        into directory: URL,
        progress: SnapshotFileProgress
    ) async throws -> DownloadedSnapshotFile {
        try Task.checkCancellation()
        guard
            let destination = Self.safeDestination(
                for: file.path,
                in: directory
            )
        else {
            throw PluginCatalogError.invalidModelSnapshot
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard
            let resolvedDownloadURL = progress.downloadURL(file)
        else {
            throw PluginCatalogError.invalidModelRepository
        }

        let (temporaryURL, response) = try await downloadTemporaryFile(
            from: resolvedDownloadURL
        ) { received, _, speed in
            progress.reportDownload(
                index: index,
                received: received,
                speed: speed
            )
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw PluginCatalogError.invalidResponse
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)

        let actualBytes =
            try destination.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize ?? 0
        if file.size > 0, actualBytes != file.size {
            throw PluginCatalogError.invalidModelSnapshot
        }
        return DownloadedSnapshotFile(
            destination: destination,
            actualBytes: Int64(actualBytes),
            expectedSHA256: file.sha256
        )
    }

    private func verifySnapshotFiles(
        _ downloadedFiles: [DownloadedSnapshotFile],
        expectedBytes: Int64,
        reporter: InstallProgressReporter
    ) throws {
        let completedBytes = downloadedFiles.reduce(Int64(0)) {
            $0 + $1.actualBytes
        }
        reporter.emit(
            PluginInstallProgress(
                fraction: PluginInstallProgressRange.verifyingStart,
                phase: .verifying,
                completedBytes: completedBytes,
                totalBytes: expectedBytes
            ),
            force: true
        )
        var verifiedBytes = Int64(0)
        for (index, file) in downloadedFiles.enumerated() {
            try Task.checkCancellation()
            if let expectedSHA = file.expectedSHA256 {
                let verifiedBeforeFile = verifiedBytes
                let actualBytes = file.actualBytes
                let fileIndex = index
                let fileCount = downloadedFiles.count
                let digest = try Self.sha256(
                    of: file.destination
                ) { fileProgress in
                    let current =
                        verifiedBeforeFile
                        + Int64(
                            Double(actualBytes)
                                * min(max(fileProgress, 0), 1)
                        )
                    let raw =
                        expectedBytes > 0
                        ? Double(current) / Double(expectedBytes)
                        : Double(fileIndex) / Double(max(1, fileCount))
                    reporter.emit(
                        PluginInstallProgress(
                            fraction: PluginInstallProgressRange.mapped(
                                raw,
                                from: PluginInstallProgressRange.verifyingStart,
                                to: PluginInstallProgressRange.verifyingEnd
                            ),
                            phase: .verifying,
                            completedBytes: current,
                            totalBytes: expectedBytes
                        )
                    )
                }
                guard digest == expectedSHA.lowercased() else {
                    throw PluginCatalogError.invalidModelSnapshot
                }
            }
            verifiedBytes += file.actualBytes
            let raw =
                expectedBytes > 0
                ? Double(verifiedBytes) / Double(expectedBytes)
                : Double(index + 1) / Double(max(1, downloadedFiles.count))
            reporter.emit(
                PluginInstallProgress(
                    fraction: PluginInstallProgressRange.mapped(
                        raw,
                        from: PluginInstallProgressRange.verifyingStart,
                        to: PluginInstallProgressRange.verifyingEnd
                    ),
                    phase: .verifying,
                    completedBytes: verifiedBytes,
                    totalBytes: expectedBytes
                )
            )
        }
    }

    private struct SnapshotFileProgress: Sendable {
        let downloadURL: @Sendable (SnapshotDownloadFile) -> URL?
        let sourceHost: String?
        let expectedBytes: Int64
        let completedBytes: Int64
        let fileCount: Int
        let reporter: InstallProgressReporter

        func reportDownload(
            index: Int,
            received: Int64,
            speed: Int64?
        ) {
            let fraction = MLXDownloadProgress.fraction(
                completedBytes: completedBytes,
                currentFileBytes: received,
                totalBytes: expectedBytes,
                completedFiles: index,
                totalFiles: fileCount
            )
            let reportedBytes =
                expectedBytes > 0
                ? min(expectedBytes, completedBytes + received)
                : completedBytes + received
            reporter.emit(
                PluginInstallProgress(
                    fraction: fraction,
                    phase: .downloading,
                    completedBytes: reportedBytes,
                    totalBytes: expectedBytes,
                    bytesPerSecond: speed,
                    sourceHost: sourceHost
                )
            )
        }

        func reportCompletion(
            index: Int,
            completedBytes: Int64
        ) {
            reporter.emit(
                PluginInstallProgress(
                    fraction: MLXDownloadProgress.fraction(
                        completedBytes: completedBytes,
                        currentFileBytes: 0,
                        totalBytes: expectedBytes,
                        completedFiles: index + 1,
                        totalFiles: fileCount
                    ),
                    phase: .downloading,
                    completedBytes: completedBytes,
                    totalBytes: expectedBytes,
                    sourceHost: sourceHost
                )
            )
        }
    }

    private static func repositoryID(
        from url: URL,
        pathPrefix: String? = nil
    ) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= (pathPrefix == nil ? 2 : 3) else {
            return nil
        }
        if let pathPrefix {
            guard components[0] == pathPrefix else { return nil }
            return "\(components[1])/\(components[2])"
        }
        return "\(components[0])/\(components[1])"
    }

    private static func fileURL(
        base: String,
        path: String
    ) -> URL? {
        guard var url = URL(string: base) else { return nil }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    static func huggingFaceEndpoints(
        for manifestURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        HuggingFaceRemotePolicy.endpoints(
            for: manifestURL,
            environment: environment
        )
    }

    private static func isAllowedRemoteURL(_ url: URL) -> Bool {
        HuggingFaceRemotePolicy.isAllowedRemoteURL(url)
    }

    private static func isAllowedModelScopeURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "modelscope.cn" || host == "www.modelscope.cn"
    }

    private static func shouldInstallModelFile(_ name: String) -> Bool {
        guard !name.hasPrefix("."),
            !name.hasPrefix("README"),
            !name.contains("/."),
            !name.split(separator: "/").contains("..")
        else {
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

    static func hasRequiredRuntimeFiles(
        for manifest: PluginManifest,
        in directory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        let requiredName: String?
        switch manifest.runtime {
        case "sqlite-v1":
            requiredName = "dictionary.sqlite3"
        case "cedict-sqlite":
            requiredName = "cedict.sqlite3"
        case "ecdict-rank":
            requiredName = "ecdict_rank.sqlite3"
        default:
            requiredName = nil
        }
        guard let requiredName else { return false }
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent(requiredName).path
        )
    }

    private static func isCompleteModelSnapshot(
        _ files: [SnapshotDownloadFile]
    ) -> Bool {
        let names = Set(files.map(\.path))
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        let hasTokenizer =
            names.contains("tokenizer.json")
            || names.contains { $0.hasSuffix(".model") }
            || names.contains { $0.hasSuffix(".spm") }
        return names.contains("config.json") && hasWeights && hasTokenizer
    }

    private static func safeDestination(for path: String, in root: URL) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
            !components.contains(where: { $0 == ".." })
        else {
            return nil
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func downloadTemporaryFile(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64, Int64?) -> Void
    ) async throws -> (URL, URLResponse) {
        let taskBox = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = ProgressDownloadDelegate(
                    continuation: continuation,
                    onProgress: progress
                )
                let task = session.downloadTask(with: url)
                taskBox.install(task: task, delegate: delegate)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    private static func sha256(
        of url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let totalBytes =
            try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var hasher = SHA256()
        var processedBytes = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024),
            !data.isEmpty
        {
            try Task.checkCancellation()
            hasher.update(data: data)
            processedBytes += data.count
            if totalBytes > 0 {
                progress?(
                    min(1, Double(processedBytes) / Double(totalBytes))
                )
            }
        }
        progress?(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

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

private enum MLXDownloadSource {
    case modelScope(repository: String, endpoint: URL)
    case huggingFace(
        repository: String,
        revision: String,
        endpoint: URL
    )

    var host: String? {
        switch self {
        case let .modelScope(_, endpoint),
            let .huggingFace(_, _, endpoint):
            return endpoint.host
        }
    }
}

private struct SnapshotDownloadFile {
    let path: String
    let size: Int64
    let sha256: String?
    let revision: String?
}

private struct ModelScopeSnapshot: Decodable {
    struct Payload: Decodable {
        let files: [File]

        private enum CodingKeys: String, CodingKey {
            case files = "Files"
        }
    }

    struct File: Decodable {
        let path: String
        let size: Int64
        let sha256: String?
        let revision: String?
        let type: String

        private enum CodingKeys: String, CodingKey {
            case path = "Path"
            case size = "Size"
            case sha256 = "Sha256"
            case revision = "Revision"
            case type = "Type"
        }
    }

    let data: Payload

    private enum CodingKeys: String, CodingKey {
        case data = "Data"
    }
}

private struct DownloadedSnapshotFile {
    let destination: URL
    let actualBytes: Int64
    let expectedSHA256: String?
}

private final class DownloadSpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestamp = DispatchTime.now().uptimeNanoseconds
    private var lastBytes: Int64 = 0
    private var smoothedBytesPerSecond: Double = 0

    func update(totalBytes: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed =
            now > lastTimestamp
            ? Double(now - lastTimestamp) / 1_000_000_000
            : 0
        guard elapsed >= 0.2 else {
            return smoothedBytesPerSecond > 0
                ? Int64(smoothedBytesPerSecond)
                : nil
        }
        let deltaBytes = max(0, totalBytes - lastBytes)
        let instantaneous = Double(deltaBytes) / elapsed
        smoothedBytesPerSecond =
            smoothedBytesPerSecond == 0
            ? instantaneous
            : smoothedBytesPerSecond * 0.75 + instantaneous * 0.25
        lastTimestamp = now
        lastBytes = totalBytes
        guard smoothedBytesPerSecond > 0 else { return nil }
        return Int64(smoothedBytesPerSecond)
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var delegate: ProgressDownloadDelegate?
    private var isCancelled = false

    func install(
        task: URLSessionDownloadTask,
        delegate: ProgressDownloadDelegate
    ) {
        lock.lock()
        self.task = task
        self.delegate = delegate
        let shouldCancel = isCancelled
        lock.unlock()
        task.delegate = delegate
        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

private final class ProgressDownloadDelegate:
    NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let continuation: CheckedContinuation<(URL, URLResponse), Error>
    private let onProgress: @Sendable (Int64, Int64, Int64?) -> Void
    private let speedMeter = DownloadSpeedMeter()
    private let lock = NSLock()
    private var completed = false

    init(
        continuation: CheckedContinuation<(URL, URLResponse), Error>,
        onProgress: @escaping @Sendable (Int64, Int64, Int64?) -> Void
    ) {
        self.continuation = continuation
        self.onProgress = onProgress
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(
            totalBytesWritten,
            totalBytesExpectedToWrite,
            speedMeter.update(totalBytes: totalBytesWritten)
        )
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        if let http = response as? HTTPURLResponse,
            !(200..<300).contains(http.statusCode)
        {
            finish(.failure(PluginCatalogError.invalidResponse))
            return
        }
        let retainedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintDownload-\(UUID().uuidString).tmp"
            )
        do {
            try FileManager.default.moveItem(
                at: location,
                to: retainedURL
            )
            finish(.success((retainedURL, response)))
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        finish(.failure(error))
    }

    private func finish(
        _ result: Result<(URL, URLResponse), Error>
    ) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private final class InstallProgressReporter: @unchecked Sendable {
    private static let minimumFractionDelta = 0.001
    private static let maximumUpdateInterval: UInt64 = 200_000_000

    private let progress: (@Sendable (PluginInstallProgress) -> Void)?
    private let lock = NSLock()
    private var lastFraction = -1.0
    private var lastPhase: PluginInstallProgress.Phase?
    private var lastSourceHost: String?
    private var lastEmission: UInt64 = 0

    init(_ progress: (@Sendable (PluginInstallProgress) -> Void)?) {
        self.progress = progress
    }

    func reset() {
        lock.lock()
        lastFraction = -1
        lastPhase = nil
        lastSourceHost = nil
        lastEmission = 0
        lock.unlock()
    }

    func emit(
        _ value: PluginInstallProgress,
        force: Bool = false
    ) {
        guard let progress else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let phaseChanged = value.phase != lastPhase
        let sourceChanged = value.sourceHost != lastSourceHost
        let fractionAdvanced =
            value.fraction >= lastFraction + Self.minimumFractionDelta
        let intervalElapsed =
            now >= lastEmission
            && now - lastEmission >= Self.maximumUpdateInterval
        let shouldEmit =
            force
            || phaseChanged
            || sourceChanged
            || fractionAdvanced
            || (intervalElapsed && value.fraction >= lastFraction)
        guard shouldEmit else {
            lock.unlock()
            return
        }
        lastFraction = value.fraction
        lastPhase = value.phase
        lastSourceHost = value.sourceHost
        lastEmission = now
        lock.unlock()
        progress(value)
    }
}
