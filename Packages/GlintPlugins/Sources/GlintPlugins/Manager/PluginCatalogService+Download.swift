import Foundation
import GlintCore

extension PluginCatalogService {
    func modelDownloadSources(
        for manifest: PluginManifest
    ) throws -> [MLXDownloadSource] {
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
        return sources
    }

    func downloadStagingDirectory(
        for manifest: PluginManifest
    ) async throws -> URL {
        let downloads = await manager.downloadStagingDirectory()
        let pluginDirectory = downloads.appendingPathComponent(
            Self.downloadIdentifier(manifest.id),
            isDirectory: true
        )
        let identity = [
            manifest.url.absoluteString,
            manifest.revision ?? "",
            manifest.version,
            String(manifest.sizeBytes),
        ].joined(separator: "\u{0}")
        let directory = pluginDirectory.appendingPathComponent(
            Self.downloadIdentifier(identity),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        pruneDownloadStagingDirectories(
            in: pluginDirectory,
            keeping: directory
        )
        return directory
    }

    func pruneDownloadStagingDirectories(
        in directory: URL,
        keeping current: URL
    ) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        guard
            let items = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isDirectoryKey,
                ],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        for item in items
        where item.standardizedFileURL != current.standardizedFileURL {
            guard
                let values = try? item.resourceValues(
                    forKeys: [
                        .contentModificationDateKey,
                        .isDirectoryKey,
                    ]
                ),
                values.isDirectory == true,
                let modified = values.contentModificationDate,
                modified < cutoff
            else {
                continue
            }
            try? fileManager.removeItem(at: item)
        }
    }

    func removeDownloadStagingDirectory(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
        let parent = directory.deletingLastPathComponent()
        guard
            let remaining = try? fileManager.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ),
            remaining.isEmpty
        else {
            return
        }
        try? fileManager.removeItem(at: parent)
    }

    func downloadModelSnapshot(
        sources: [MLXDownloadSource],
        into modelDirectory: URL,
        reporter: InstallProgressReporter
    ) async throws {
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
                if Task.isCancelled
                    || (error as? URLError)?.code == .cancelled
                {
                    throw CancellationError()
                }
                lastError = error
                if case .modelScope = source {
                    // Unpinned ModelScope `master` and Hugging Face `main`
                    // are independent mutable sources. Never concatenate or
                    // mix their partial snapshots.
                    try? fileManager.removeItem(at: modelDirectory)
                    try fileManager.createDirectory(
                        at: modelDirectory,
                        withIntermediateDirectories: true
                    )
                }
            }
        }
        if let lastError {
            throw lastError
        }
        try Task.checkCancellation()
    }

    func downloadModelScopeSnapshot(
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

    func downloadHuggingFaceSnapshot(
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

    func downloadSnapshotFiles(
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

    func validateSnapshotDownload(
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
                let totalRequirement = RemoteByteCount.checkedProduct(
                    expectedBytes,
                    2
                )
            else {
                throw PluginCatalogError.invalidModelSnapshot
            }
            let stagedBytes = stagedSnapshotBytes(
                files,
                in: directory
            )
            let requiredBytes = max(0, totalRequirement - stagedBytes)
            if available < requiredBytes {
                throw PluginCatalogError.insufficientDiskSpace
            }
        }
        return expectedBytes
    }

    func stagedSnapshotBytes(
        _ files: [SnapshotDownloadFile],
        in directory: URL
    ) -> Int64 {
        var total: Int64 = 0
        for file in files {
            guard
                let destination = Self.safeDestination(
                    for: file.path,
                    in: directory
                )
            else {
                continue
            }
            let destinationBytes = fileSize(at: destination) ?? 0
            let partBytes =
                fileSize(
                    at: Self.partialDownloadURL(for: destination)
                ) ?? 0
            let availableFileBytes = max(
                destinationBytes,
                partBytes
            )
            let countedBytes =
                file.size > 0
                ? min(file.size, availableFileBytes)
                : availableFileBytes
            let addition = total.addingReportingOverflow(countedBytes)
            guard !addition.overflow else {
                return total
            }
            total = addition.partialValue
        }
        return total
    }

    func downloadSnapshotFile(
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
        let existingBytes = fileSize(at: destination)
        if let existingBytes,
            file.size <= 0 || existingBytes == file.size
        {
            return DownloadedSnapshotFile(
                destination: destination,
                actualBytes: existingBytes,
                expectedSHA256: file.sha256
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard
            let resolvedDownloadURL = progress.downloadURL(file)
        else {
            throw PluginCatalogError.invalidModelRepository
        }

        let partURL = Self.partialDownloadURL(for: destination)
        let partialBytes = fileSize(at: partURL) ?? 0
        if file.size > 0, partialBytes == file.size {
            try fileManager.moveItem(at: partURL, to: destination)
            return DownloadedSnapshotFile(
                destination: destination,
                actualBytes: partialBytes,
                expectedSHA256: file.sha256
            )
        }

        let downloader = ResumableFileDownloader(
            session: session
        )
        _ = try await downloader.download(
            from: resolvedDownloadURL,
            to: partURL,
            expectedBytes: file.size
        ) { received, _, speed in
            progress.reportDownload(
                index: index,
                received: received,
                speed: speed
            )
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: partURL, to: destination)

        let actualBytes = fileSize(at: destination) ?? 0
        if file.size > 0, actualBytes != file.size {
            try? fileManager.removeItem(at: destination)
            throw PluginCatalogError.invalidModelSnapshot
        }
        return DownloadedSnapshotFile(
            destination: destination,
            actualBytes: actualBytes,
            expectedSHA256: file.sha256
        )
    }

    func verifySnapshotFiles(
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
                    try? fileManager.removeItem(at: file.destination)
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

    struct SnapshotFileProgress: Sendable {
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
}
