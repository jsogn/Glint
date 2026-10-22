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
            capabilities: ["word"],
            languages: ["zh-Hans", "en"],
            sizeBytes: Int64(archiveData.count),
            sha256: sha,
            url: archive,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
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
            capabilities: manifest.capabilities,
            languages: manifest.languages,
            sizeBytes: Int64(finalData.count),
            sha256: finalSHA,
            url: archive,
            license: manifest.license,
            minRAMBytes: manifest.minRAMBytes,
            quality: manifest.quality,
            recommended: manifest.recommended
        )

        let catalogURL = root.appendingPathComponent("catalog.json")
        try JSONEncoder().encode([finalManifest]).write(to: catalogURL)
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(manager: manager)

        let catalog = try await service.fetchCatalog(from: catalogURL)
        XCTAssertEqual(catalog.map(\.id), ["test-dictionary"])
        _ = try await service.install(finalManifest)
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
                == "\"catalog-v1\"" {
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 304,
                        httpVersion: nil,
                        headerFields: [
                            "ETag": "\"catalog-v1\"",
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
            capabilities: ["word"],
            languages: ["zh-Hans", "en"],
            sizeBytes: 1,
            sha256: "unused",
            url: URL(string: "https://example.com/plugin.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
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
            capabilities: ["word"],
            languages: ["zh-Hans", "en"],
            sizeBytes: Int64(data.count),
            sha256: digest,
            url: archive,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
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
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler:
        ((URLRequest) -> (HTTPURLResponse, Data)?)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler,
              let (response, data) = handler(request) else {
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
