import CryptoKit
import Foundation
import XCTest
@testable import GlintPlugins

final class PluginCatalogServiceTests: XCTestCase {
    func testModelDownloadsPreferMirrorThenFallbackInternationally() {
        let manifestURL = URL(
            string: "https://huggingface.co/mlx-community/Hy-MT2-1.8B-4bit"
        )!
        let endpoints = PluginCatalogService.huggingFaceEndpoints(
            for: manifestURL,
            environment: [:]
        )
        XCTAssertEqual(
            endpoints.compactMap(\.host),
            ["hf-mirror.com", "huggingface.co"]
        )

        let overridden = PluginCatalogService.huggingFaceEndpoints(
            for: manifestURL,
            environment: [
                "GLINT_HF_ENDPOINT": "https://preferred.example",
                "GLINT_HF_MIRROR": "https://cn.example",
            ]
        )
        XCTAssertEqual(
            overridden.compactMap(\.host),
            ["preferred.example", "cn.example", "huggingface.co"]
        )
    }

    func testMLXDownloadProgressUsesBytesWhenOneFileDominates() {
        let totalBytes: Int64 = 1_017_375_718
        let smallFilesBytes: Int64 = 14_567
        let modelBytes: Int64 = 1_007_776_125

        let afterSmallFiles = MLXDownloadProgress.fraction(
            completedBytes: smallFilesBytes,
            currentFileBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 5,
            totalFiles: 9
        )
        let halfwayThroughModel = MLXDownloadProgress.fraction(
            completedBytes: smallFilesBytes,
            currentFileBytes: modelBytes / 2,
            totalBytes: totalBytes,
            completedFiles: 5,
            totalFiles: 9
        )

        XCTAssertLessThan(afterSmallFiles, 0.03)
        XCTAssertGreaterThan(halfwayThroughModel, afterSmallFiles)
        XCTAssertLessThan(halfwayThroughModel, 0.5)
    }

    func testMLXDownloadProgressIsContinuousAtFileBoundary() {
        let totalBytes: Int64 = 1_017_375_718
        let smallFilesBytes: Int64 = 14_567
        let modelBytes: Int64 = 1_007_776_125

        let beforeBoundary = MLXDownloadProgress.fraction(
            completedBytes: smallFilesBytes,
            currentFileBytes: modelBytes,
            totalBytes: totalBytes,
            completedFiles: 5,
            totalFiles: 9
        )
        let afterBoundary = MLXDownloadProgress.fraction(
            completedBytes: smallFilesBytes + modelBytes,
            currentFileBytes: 0,
            totalBytes: totalBytes,
            completedFiles: 6,
            totalFiles: 9
        )

        XCTAssertEqual(
            beforeBoundary,
            afterBoundary,
            accuracy: 0.000_001
        )
    }

    func testMLXDownloadProgressFallsBackToFileCountWithoutSizes() {
        XCTAssertEqual(
            MLXDownloadProgress.fraction(
                completedBytes: 0,
                currentFileBytes: 0,
                totalBytes: 0,
                completedFiles: 5,
                totalFiles: 9
            ),
            0.02 + 0.88 * 5 / 9,
            accuracy: 0.000_001
        )
    }

    func testFetchInstallAndUninstallLocalCatalogPlugin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintPluginCatalogTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data("dictionary".utf8).write(
            to: source.appendingPathComponent("dictionary.sqlite3")
        )

        let archive = root.appendingPathComponent("plugin.zip")
        try createArchive(from: source, at: archive)

        let archiveData = try Data(contentsOf: archive)
        let sha = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = PluginManifest(
            id: "test-dictionary",
            type: .dictionary,
            name: "Test Dictionary",
            version: "1.0",
            runtime: "sqlite-v1",
            sizeBytes: Int64(archiveData.count),
            sha256: sha,
            url: archive,
            license: "MIT",
            minRAMBytes: 0
        )
        try JSONEncoder().encode(manifest).write(
            to: source.appendingPathComponent("manifest.json")
        )

        // Rebuild the archive so it includes manifest.json, then recompute its hash.
        try FileManager.default.removeItem(at: archive)
        try createArchive(from: source, at: archive)
        let finalData = try Data(contentsOf: archive)
        let finalSHA = SHA256.hash(data: finalData)
            .map { String(format: "%02x", $0) }
            .joined()
        let finalManifest = PluginManifest(
            id: manifest.id,
            type: manifest.type,
            name: manifest.name,
            version: manifest.version,
            runtime: manifest.runtime,
            sizeBytes: Int64(finalData.count),
            sha256: finalSHA,
            url: archive,
            license: manifest.license,
            minRAMBytes: manifest.minRAMBytes
        )

        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(
            ["plugins": [finalManifest]]
        ).write(to: catalogURL)
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(manager: manager)

        let catalog = try await service.fetchCatalog(from: catalogURL)
        XCTAssertEqual(catalog.map(\.id), ["test-dictionary"])
        let progressCollector = InstallProgressCollector()
        _ = try await service.install(finalManifest) {
            progressCollector.append($0)
        }
        let progress = progressCollector.values
        XCTAssertEqual(progress.first?.phase, .preparing)
        XCTAssertEqual(progress.last?.fraction, 1)
        XCTAssertEqual(
            progress.map(\.fraction),
            progress.map(\.fraction).sorted()
        )
        let installed = await manager.installedPlugins()
        XCTAssertEqual(installed.first?.id, finalManifest.id)
        try await service.uninstall(id: finalManifest.id)
        let remaining = await manager.installedPlugins()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCatalogFetchUsesConditionalRequest() async throws {
        let body = Data(#"{"plugins":[]}"#.utf8)
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return nil }
            if request.value(forHTTPHeaderField: "If-None-Match")
                == "\"catalog-v1\""
            {
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 304,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"catalog-v1\""
                        ]
                    )!,
                    Data()
                )
            }
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "ETag": "\"catalog-v1\"",
                        "Last-Modified": "Wed, 21 Oct 2026 10:00:00 GMT",
                    ]
                )!,
                body
            )
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let service = PluginCatalogService(
            manager: PluginManager(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "GlintCatalogETag-\(UUID().uuidString)"
                    )
            ),
            session: URLSession(configuration: configuration)
        )
        let url = URL(string: "https://example.com/catalog.json")!

        let first = try await service.fetchCatalogResult(from: url)
        XCTAssertFalse(first.isNotModified)
        XCTAssertEqual(first.etag, "\"catalog-v1\"")
        XCTAssertEqual(
            first.lastModified,
            "Wed, 21 Oct 2026 10:00:00 GMT"
        )

        let second = try await service.fetchCatalogResult(
            from: url,
            etag: first.etag,
            lastModified: first.lastModified
        )
        XCTAssertTrue(second.isNotModified)
        XCTAssertTrue(second.plugins.isEmpty)
    }

    func testRemovingMissingPluginThrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintMissingPlugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)

        do {
            try await manager.remove(id: "missing-plugin")
            XCTFail("Removing a missing plugin should fail")
        } catch let error as PluginManagerError {
            guard case .pluginNotFound = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRejectsDownloadedCTranslatePlugin() async {
        let manifest = PluginManifest(
            id: "unsafe-ct2",
            type: .translation,
            name: "Unsafe CT2",
            version: "1.0",
            runtime: "ctranslate2",
            sizeBytes: 1,
            sha256: "unused",
            url: URL(string: "https://example.com/plugin.zip")!,
            license: "MIT",
            minRAMBytes: 0
        )
        let service = PluginCatalogService()

        do {
            _ = try await service.install(manifest)
            XCTFail("Downloaded CTranslate2 plugins must be rejected")
        } catch let error as PluginCatalogError {
            XCTAssertEqual(error, .unsupportedRuntime)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testModelScopeSnapshotInstallsBeforeHuggingFaceFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelScopeCatalog-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let payloads: [String: Data] = [
            "config.json": Data("{}".utf8),
            "tokenizer.json": Data("{\"tokenizer\":true}".utf8),
            "model.safetensors": Data([0x01, 0x02, 0x03, 0x04]),
        ]
        let snapshotFiles = payloads.map { path, data in
            [
                "Path": path,
                "Size": data.count,
                "Sha256": sha256(data),
                "Revision": "modelscope-revision",
                "Type": "blob",
            ] as [String: Any]
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: [
                "Data": ["Files": snapshotFiles]
            ]
        )
        let requestCollector = RequestHostCollector()
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return nil }
            requestCollector.append(url.host)
            guard url.host == "modelscope.cn" else { return nil }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if url.path
                == "/api/v1/models/example/model/repo/files"
            {
                return (response, snapshotData)
            }
            if url.path.contains(
                "/models/example/model/resolve/modelscope-revision/"
            ),
                let data = payloads[url.lastPathComponent]
            {
                return (response, data)
            }
            return nil
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(
            manager: manager,
            session: URLSession(configuration: configuration)
        )
        let modelscopeURL = URL(
            string: "https://modelscope.cn/models/example/model"
        )!
        let manifest = PluginManifest(
            id: "modelscope-test-model",
            type: .translation,
            name: "ModelScope Test Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: Int64(payloads.values.map(\.count).reduce(0, +)),
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "APACHE-2.0",
            minRAMBytes: 0,
            modelscopeURL: modelscopeURL
        )
        let progressCollector = InstallProgressCollector()

        let installed = try await service.install(manifest) {
            progressCollector.append($0)
        }

        XCTAssertEqual(installed.modelscopeURL, modelscopeURL)
        XCTAssertFalse(requestCollector.values.isEmpty)
        XCTAssertTrue(
            requestCollector.values.allSatisfy {
                $0 == "modelscope.cn"
            }
        )
        XCTAssertEqual(
            progressCollector.values.first?.sourceHost,
            "modelscope.cn"
        )
    }

    func testPinnedMLXSnapshotDoesNotUseMutableModelScopeMaster()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintPinnedModelCatalog-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let payloads: [String: Data] = [
            "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
            "tokenizer.json": Data("{\"tokenizer\":true}".utf8),
            "model.safetensors": Data([0x01, 0x02, 0x03, 0x04]),
        ]
        let snapshotFiles = payloads.map { path, data in
            [
                "rfilename": path,
                "size": data.count,
                "lfs": path == "model.safetensors"
                    ? ["sha256": sha256(data)]
                    : nil,
            ].compactMapValues { $0 }
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: ["siblings": snapshotFiles]
        )
        let requestCollector = RequestHostCollector()
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return nil }
            requestCollector.append(url.host)
            guard url.host == "hf-mirror.com" else { return nil }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if url.path
                == "/api/models/example/model/revision/pinned-revision"
            {
                return (response, snapshotData)
            }
            if url.path.contains(
                "/example/model/resolve/pinned-revision/"
            ),
                let data = payloads[url.lastPathComponent]
            {
                return (response, data)
            }
            return nil
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(
            manager: manager,
            session: URLSession(configuration: configuration)
        )
        let manifest = PluginManifest(
            id: "pinned-model",
            type: .translation,
            name: "Pinned Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: Int64(payloads.values.map(\.count).reduce(0, +)),
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "pinned-revision",
            modelscopeURL: URL(
                string: "https://modelscope.cn/models/example/model"
            )!
        )

        _ = try await service.install(manifest)

        XCTAssertEqual(
            Set(requestCollector.values.compactMap { $0 }),
            ["hf-mirror.com"]
        )
    }

    func testMLXSnapshotRejectsOverflowingFileSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintOverflowingModelCatalog-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let snapshotData = try JSONSerialization.data(
            withJSONObject: [
                "siblings": [
                    [
                        "rfilename": "config.json",
                        "size": 1,
                    ],
                    [
                        "rfilename": "model-a.safetensors",
                        "size": Int64.max,
                    ],
                    [
                        "rfilename": "model-b.safetensors",
                        "size": 1,
                    ],
                    [
                        "rfilename": "tokenizer.json",
                        "size": 1,
                    ],
                ]
            ]
        )
        StubURLProtocol.handler = { request in
            guard let url = request.url,
                ["hf-mirror.com", "huggingface.co"].contains(url.host),
                url.path
                    == "/api/models/example/overflow/revision/overflow-revision"
            else {
                return nil
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, snapshotData)
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let service = PluginCatalogService(
            manager: PluginManager(baseDirectory: root),
            session: URLSession(configuration: configuration)
        )
        let manifest = PluginManifest(
            id: "overflow-model",
            type: .translation,
            name: "Overflow Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: 0,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/overflow"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "overflow-revision"
        )

        do {
            _ = try await service.install(manifest)
            XCTFail("Expected overflowing file size to be rejected")
        } catch let error as PluginCatalogError {
            XCTAssertEqual(error, .invalidModelSnapshot)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMLXSnapshotUpgradeRetainsPreviousRevisionForRollback()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintMLXUpgradeRollback-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let payloads: [String: Data] = [
            "config.json": Data(#"{"model_type":"qwen3"}"#.utf8),
            "tokenizer.json": Data("{\"tokenizer\":true}".utf8),
            "model.safetensors": Data([0x11, 0x22, 0x33]),
        ]
        let snapshotFiles = payloads.map { path, data in
            [
                "rfilename": path,
                "size": data.count,
                "lfs": path == "model.safetensors"
                    ? ["sha256": sha256(data)]
                    : nil,
            ].compactMapValues { $0 }
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: ["siblings": snapshotFiles]
        )
        StubURLProtocol.handler = { request in
            guard let url = request.url,
                url.host == "hf-mirror.com"
            else {
                return nil
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if url.path.hasPrefix("/api/models/example/model/revision/") {
                return (response, snapshotData)
            }
            if url.path.contains("/example/model/resolve/"),
                let data = payloads[url.lastPathComponent]
            {
                return (response, data)
            }
            return nil
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(
            manager: manager,
            session: URLSession(configuration: configuration)
        )
        let first = PluginManifest(
            id: "rollback-model",
            type: .translation,
            name: "Rollback Model",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: Int64(payloads.values.map(\.count).reduce(0, +)),
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "MIT",
            minRAMBytes: 0,
            revision: "revision-one"
        )
        let second = PluginManifest(
            id: first.id,
            type: first.type,
            name: first.name,
            version: first.version,
            runtime: first.runtime,
            sizeBytes: first.sizeBytes,
            sha256: first.sha256,
            url: first.url,
            license: first.license,
            minRAMBytes: first.minRAMBytes,
            revision: "revision-two"
        )

        _ = try await service.install(first)
        _ = try await service.install(second)

        let hasPendingUpgrade = await manager.hasPendingUpgrade()
        let updatedRevision = await manager.installedPlugin(
            id: first.id
        )?.revision
        XCTAssertTrue(hasPendingUpgrade)
        XCTAssertEqual(updatedRevision, "revision-two")

        try await manager.rollbackPendingUpgrade()

        let restoredRevision = await manager.installedPlugin(
            id: first.id
        )?.revision
        XCTAssertEqual(restoredRevision, "revision-one")
    }

    func testModelScopeFailureFallsBackToHuggingFaceMirror() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintModelScopeFallback-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let payloads: [String: Data] = [
            "config.json": Data("{}".utf8),
            "tokenizer.json": Data("{\"tokenizer\":true}".utf8),
            "model.safetensors": Data([0x05, 0x06, 0x07]),
        ]
        let snapshotFiles = payloads.map { path, data in
            [
                "rfilename": path,
                "size": data.count,
                "lfs": ["sha256": sha256(data)],
            ] as [String: Any]
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: ["siblings": snapshotFiles]
        )
        let requestCollector = RequestHostCollector()
        StubURLProtocol.handler = { request in
            guard let url = request.url else { return nil }
            requestCollector.append(url.host)
            let response = HTTPURLResponse(
                url: url,
                statusCode: url.host == "modelscope.cn" ? 404 : 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if url.host == "modelscope.cn",
                url.path
                    == "/api/v1/models/example/model/repo/files"
            {
                return (response, Data())
            }
            guard url.host == "hf-mirror.com" else { return nil }
            if url.path.contains("/api/models/") {
                return (response, snapshotData)
            }
            if let data = payloads[url.lastPathComponent] {
                return (response, data)
            }
            return nil
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(
            manager: manager,
            session: URLSession(configuration: configuration)
        )
        let manifest = PluginManifest(
            id: "modelscope-fallback-test",
            type: .translation,
            name: "ModelScope Fallback Test",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: Int64(payloads.values.map(\.count).reduce(0, +)),
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "APACHE-2.0",
            minRAMBytes: 0,
            modelscopeURL: URL(
                string: "https://modelscope.cn/models/example/model"
            )!
        )
        let progressCollector = InstallProgressCollector()

        _ = try await service.install(manifest) {
            progressCollector.append($0)
        }

        let hosts = requestCollector.values
        XCTAssertTrue(hosts.contains("modelscope.cn"))
        XCTAssertTrue(hosts.contains("hf-mirror.com"))
        let progressHosts = Set(
            progressCollector.values.compactMap(\.sourceHost)
        )
        XCTAssertTrue(progressHosts.contains("modelscope.cn"))
        XCTAssertTrue(progressHosts.contains("hf-mirror.com"))
    }

    func testLargeDownloadReportsProgressBeforeFileCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintChunkedProgress-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        let modelData = Data(
            repeating: 0x5A,
            count: 3_000_000
        )
        let payloads: [String: Data] = [
            "config.json": Data("{}".utf8),
            "tokenizer.json": Data("{\"tokenizer\":true}".utf8),
            "zz-model.safetensors": modelData,
        ]
        let snapshotFiles = payloads.map { path, data in
            [
                "Path": path,
                "Size": data.count,
                "Sha256": sha256(data),
                "Revision": "modelscope-revision",
                "Type": "blob",
            ] as [String: Any]
        }
        let snapshotData = try JSONSerialization.data(
            withJSONObject: [
                "Data": ["Files": snapshotFiles]
            ]
        )
        ChunkedURLProtocol.handler = { request in
            guard let url = request.url else { return nil }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if url.path.hasSuffix("/repo/files") {
                return (response, snapshotData)
            }
            if let data = payloads[url.lastPathComponent] {
                return (response, data)
            }
            return nil
        }
        defer { ChunkedURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedURLProtocol.self]
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(
            manager: manager,
            session: URLSession(configuration: configuration)
        )
        let manifest = PluginManifest(
            id: "chunked-progress-test",
            type: .translation,
            name: "Chunked Progress Test",
            version: "1.0",
            runtime: "mlx",
            sizeBytes: Int64(payloads.values.map(\.count).reduce(0, +)),
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(
                string: "https://huggingface.co/example/model"
            )!,
            license: "APACHE-2.0",
            minRAMBytes: 0,
            modelscopeURL: URL(
                string: "https://modelscope.cn/models/example/model"
            )!
        )
        let progressCollector = InstallProgressCollector()

        _ = try await service.install(manifest) {
            progressCollector.append($0)
        }

        XCTAssertTrue(
            progressCollector.values.contains {
                $0.phase == .downloading
                    && $0.fraction > 0.1
                    && $0.fraction < 0.85
            }
        )
    }

    func testDictionaryArchiveRequiresRuntimeFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintRuntimeFiles-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifest = PluginManifest(
            id: "test-dictionary",
            type: .dictionary,
            name: "Test Dictionary",
            version: "1.0",
            runtime: "sqlite-v1",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.com/plugin.zip")!,
            license: "MIT",
            minRAMBytes: 0
        )

        XCTAssertFalse(
            PluginCatalogService.hasRequiredRuntimeFiles(
                for: manifest,
                in: directory
            )
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(
                    "dictionary.sqlite3"
                ).path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            PluginCatalogService.hasRequiredRuntimeFiles(
                for: manifest,
                in: directory
            )
        )
    }

    func testOnlyManagedOPUSModelCanUseDownloadedCTranslateData() {
        let managed = PluginManifest(
            id: "mt-opus-zh-en",
            type: .translation,
            name: "OPUS-MT Chinese-English",
            version: "0.1.0",
            runtime: "ctranslate2-data",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.com/opus.zip")!,
            license: "CC-BY-4.0",
            minRAMBytes: 0
        )
        let unmanaged = PluginManifest(
            id: "arbitrary-ct2",
            type: .translation,
            name: "Arbitrary",
            version: "1.0",
            runtime: "ctranslate2-data",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.com/arbitrary.zip")!,
            license: "MIT",
            minRAMBytes: 0
        )

        XCTAssertTrue(
            PluginRuntimePolicy.supportsDownloadedRuntime(managed)
        )
        XCTAssertFalse(
            PluginRuntimePolicy.supportsDownloadedRuntime(unmanaged)
        )
    }

    func testOPUSArchiveRequiresAllModelDataFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintOPUSRuntimeFiles-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("model"),
            withIntermediateDirectories: true
        )
        let manifest = PluginManifest(
            id: "mt-opus-zh-en",
            type: .translation,
            name: "OPUS-MT Chinese-English",
            version: "0.1.0",
            runtime: "ctranslate2-data",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://example.com/opus.zip")!,
            license: "CC-BY-4.0",
            minRAMBytes: 0
        )

        XCTAssertFalse(
            PluginCatalogService.hasRequiredRuntimeFiles(
                for: manifest,
                in: directory
            )
        )
        for name in [
            "model.bin",
            "config.json",
            "shared_vocabulary.json",
            "source.spm",
            "target.spm",
        ] {
            XCTAssertTrue(
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(
                        "model/\(name)"
                    ).path,
                    contents: Data()
                )
            )
        }
        XCTAssertTrue(
            PluginCatalogService.hasRequiredRuntimeFiles(
                for: manifest,
                in: directory
            )
        )
    }

    func testManagedOPUSDataPackageInstallsAndUninstalls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintOPUSPackage-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(
            "mt-opus-zh-en",
            isDirectory: true
        )
        let modelDirectory = source.appendingPathComponent(
            "model",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        let embedded = PluginManifest(
            id: "mt-opus-zh-en",
            type: .translation,
            name: "OPUS-MT Chinese-English",
            version: "0.1.0",
            runtime: "ctranslate2-data",
            sizeBytes: 1,
            sha256: "embedded",
            url: URL(string: "https://example.com/opus.zip")!,
            license: "CC-BY-4.0",
            minRAMBytes: 0
        )
        try JSONEncoder().encode(embedded).write(
            to: source.appendingPathComponent(
                PluginManifest.fileName
            )
        )
        for name in [
            "model.bin",
            "config.json",
            "shared_vocabulary.json",
            "source.spm",
            "target.spm",
        ] {
            try Data([0x00]).write(
                to: modelDirectory.appendingPathComponent(name)
            )
        }
        let archive = root.appendingPathComponent("opus.zip")
        try createArchive(from: source, at: archive)
        let archiveData = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = PluginManifest(
            id: embedded.id,
            type: embedded.type,
            name: embedded.name,
            version: embedded.version,
            runtime: embedded.runtime,
            sizeBytes: Int64(archiveData.count),
            sha256: digest,
            url: archive,
            license: embedded.license,
            minRAMBytes: embedded.minRAMBytes
        )
        let manager = PluginManager(
            baseDirectory: root.appendingPathComponent(
                "support",
                isDirectory: true
            )
        )
        let service = PluginCatalogService(manager: manager)

        let installed = try await service.install(manifest)

        XCTAssertEqual(installed.id, "mt-opus-zh-en")
        XCTAssertEqual(installed.runtime, "ctranslate2-data")
        XCTAssertEqual(installed.source, .catalog)
        let installedDirectory = await manager.pluginDirectory(
            for: installed.id
        )
        let modelFile = installedDirectory.appendingPathComponent(
            "model/model.bin"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: modelFile.path
            )
        )

        try await service.uninstall(id: installed.id)

        let remaining = await manager.installedPlugin(id: installed.id)
        XCTAssertNil(remaining)
    }

    func testPublishedOPUSArchiveContainsOnlyInstallableModelData() async throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryRoot.deleteLastPathComponent()
        }
        let archive = repositoryRoot.appendingPathComponent(
            "build/dist/mt-opus-zh-en-0.1.0.zip"
        )
        guard FileManager.default.fileExists(atPath: archive.path) else {
            throw XCTSkip(
                "Run scripts/package_opus_model_data.sh before package tests."
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintPublishedOPUS-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(manager: manager)
        let catalog = try await service.fetchCatalog(
            from: repositoryRoot.appendingPathComponent(
                "Resources/catalog.json"
            )
        )
        let published = try XCTUnwrap(
            catalog.first {
                $0.id == "mt-opus-zh-en"
            }
        )
        let localManifest = PluginManifest(
            id: published.id,
            type: published.type,
            name: published.name,
            version: published.version,
            runtime: published.runtime,
            sizeBytes: published.sizeBytes,
            sha256: published.sha256,
            url: archive,
            license: published.license,
            minRAMBytes: published.minRAMBytes,
            summary: published.summary,
            source: .catalog
        )

        let installed = try await service.install(localManifest)
        let installedDirectory = await manager.pluginDirectory(
            for: installed.id
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: installedDirectory.appendingPathComponent(
                    "model/model.bin"
                ).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installedDirectory.appendingPathComponent(
                    "bin"
                ).path
            )
        )

        try await service.uninstall(id: installed.id)
        let remaining = await manager.installedPlugin(id: installed.id)
        XCTAssertNil(remaining)
    }

    func testRejectsExecutablePluginContent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintUnsafePlugin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(
            to: source.appendingPathComponent("payload.dylib")
        )
        let archive = root.appendingPathComponent("unsafe.zip")
        try createArchive(from: source, at: archive)
        let data = try Data(contentsOf: archive)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = PluginManifest(
            id: "unsafe-content",
            type: .dictionary,
            name: "Unsafe Content",
            version: "1.0",
            runtime: "sqlite-v1",
            sizeBytes: Int64(data.count),
            sha256: digest,
            url: archive,
            license: "MIT",
            minRAMBytes: 0
        )
        let service = PluginCatalogService(
            manager: PluginManager(baseDirectory: root)
        )

        do {
            _ = try await service.install(manifest)
            XCTFail("Executable plugin content must be rejected")
        } catch let error as PluginCatalogError {
            XCTAssertEqual(error, .unsafeContent)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func createArchive(from source: URL, at archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data)?)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler,
            let (response, data) = handler(request)
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotConnectToHost)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ChunkedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data)?)?
    private var sender: ChunkedURLProtocolSender?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler,
            let (response, data) = handler(request)
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotConnectToHost)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        let sender = ChunkedURLProtocolSender(
            urlProtocol: self,
            data: data
        )
        self.sender = sender
        DispatchQueue.global(qos: .userInitiated).async {
            sender.send()
        }
    }

    override func stopLoading() {
        sender?.stop()
    }
}

private final class ChunkedURLProtocolSender: @unchecked Sendable {
    private let urlProtocol: URLProtocol
    private let data: Data
    private let lock = NSLock()
    private var stopped = false

    init(urlProtocol: URLProtocol, data: Data) {
        self.urlProtocol = urlProtocol
        self.data = data
    }

    func send() {
        let chunkSize = max(64 * 1024, data.count / 30)
        var offset = 0
        while offset < data.count {
            lock.lock()
            let stopped = stopped
            lock.unlock()
            if stopped { return }
            let end = min(offset + chunkSize, data.count)
            urlProtocol.client?.urlProtocol(
                urlProtocol,
                didLoad: data.subdata(in: offset..<end)
            )
            offset = end
            Thread.sleep(forTimeInterval: 0.01)
        }
        urlProtocol.client?.urlProtocolDidFinishLoading(urlProtocol)
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class InstallProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PluginInstallProgress] = []

    var values: [PluginInstallProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ progress: PluginInstallProgress) {
        lock.lock()
        storage.append(progress)
        lock.unlock()
    }
}

private final class RequestHostCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []

    var values: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ host: String?) {
        lock.lock()
        storage.append(host)
        lock.unlock()
    }
}
