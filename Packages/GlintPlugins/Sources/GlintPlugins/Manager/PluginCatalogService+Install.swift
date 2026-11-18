import CryptoKit
import Foundation
import GlintCore

extension PluginCatalogService {
    public func install(
        _ manifest: PluginManifest,
        progress: (@Sendable (PluginInstallProgress) -> Void)? = nil
    ) async throws -> PluginManifest {
        try Task.checkCancellation()
        guard
            PluginRuntimePolicy.supportsDownloadedRuntime(
                manifest
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
            .appendingPathComponent(
                "GlintPlugin-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        var stagingRoot: URL?
        var didInstall = false
        defer {
            try? fileManager.removeItem(at: workDirectory)
            if didInstall, let stagingRoot {
                removeDownloadStagingDirectory(stagingRoot)
            }
        }

        var archiveURL = workDirectory.appendingPathComponent(
            "plugin.archive"
        )
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
            let downloadDirectory = try await downloadStagingDirectory(
                for: manifest
            )
            stagingRoot = downloadDirectory
            let persistentArchive = downloadDirectory.appendingPathComponent(
                "plugin.archive"
            )
            try fileManager.createDirectory(
                at: downloadDirectory,
                withIntermediateDirectories: true
            )
            if !(try isValidDownloadedArchive(
                persistentArchive,
                for: manifest
            )) {
                try? fileManager.removeItem(at: persistentArchive)
            }
            if fileManager.fileExists(atPath: persistentArchive.path) {
                archiveURL = persistentArchive
            } else {
                let partURL = Self.partialDownloadURL(
                    for: persistentArchive
                )
                let existingPartBytes = fileSize(at: partURL) ?? 0
                if manifest.sizeBytes <= 0
                    || existingPartBytes != manifest.sizeBytes
                {
                    let downloader = ResumableFileDownloader(
                        session: session
                    )
                    _ = try await downloader.download(
                        from: manifest.url,
                        to: partURL,
                        expectedBytes: manifest.sizeBytes
                    ) {
                        [
                            reporter, totalBytes = manifest.sizeBytes,
                            sourceHost = manifest.url.host
                        ]
                        completed,
                        expected,
                        speed in
                        let resolvedTotal =
                            expected > 0 ? expected : totalBytes
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
                    let downloadedBytes = fileSize(at: partURL) ?? 0
                    if manifest.sizeBytes > 0,
                        downloadedBytes != manifest.sizeBytes
                    {
                        throw PluginCatalogError.invalidResponse
                    }
                }
                if fileManager.fileExists(atPath: persistentArchive.path) {
                    try fileManager.removeItem(at: persistentArchive)
                }
                try fileManager.moveItem(
                    at: partURL,
                    to: persistentArchive
                )
                archiveURL = persistentArchive
            }
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
        let digest = DigestHex.string(
            for: SHA256.hash(data: archiveData)
        )
        guard manifest.sha256 != "REPLACE_ME",
            digest == manifest.sha256.lowercased()
        else {
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
            embedded.version == manifest.version,
            embedded.runtime == manifest.runtime
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
        didInstall = true
        return installed
    }

    func installMLXSnapshot(
        _ manifest: PluginManifest,
        progress: (@Sendable (PluginInstallProgress) -> Void)?
    ) async throws -> PluginManifest {
        let sources = try modelDownloadSources(for: manifest)
        let reporter = InstallProgressReporter(progress)

        let stagingRoot = try await downloadStagingDirectory(
            for: manifest
        )
        let modelDirectory = stagingRoot.appendingPathComponent(
            "model",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        try await downloadModelSnapshot(
            sources: sources,
            into: modelDirectory,
            reporter: reporter
        )

        try JSONEncoder().encode(manifest).write(
            to: stagingRoot.appendingPathComponent(
                PluginManifest.fileName
            )
        )
        let installed = try await installPreparedSnapshot(
            stagingRoot,
            reporter: reporter
        )
        removeDownloadStagingDirectory(stagingRoot)
        return installed
    }

    func installPreparedSnapshot(
        _ pluginDirectory: URL,
        reporter: InstallProgressReporter
    ) async throws -> PluginManifest {
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
}
