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

    func testLegacyOCRArchiveRuntimeIsRejected() async {
        let manifest = PluginManifest(
            id: "test-ocr",
            type: .ocr,
            name: "Test OCR",
            version: "1.0",
            runtime: "onnxruntime",
            capabilities: ["candidate"],
            languages: ["zh-Hans"],
            sizeBytes: 0,
            sha256: "test",
            url: URL(string: "https://example.invalid/test-ocr.zip")!,
            license: "MIT",
            minRAMBytes: 0,
            quality: "test",
            recommended: false
        )
        let service = PluginCatalogService(
            manager: PluginManager(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("GlintOCRReject-\(UUID().uuidString)")
            )
        )
        do {
            _ = try await service.install(manifest)
            XCTFail("legacy OCR archive runtime should be rejected")
        } catch let error as PluginCatalogError {
            XCTAssertEqual(error, .unsupportedRuntime)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOCRModelPrefersMirrorAndFallsBackToOfficialSource() async throws {
        let modelData = Data("official-ocr-model".utf8)
        let digest = SHA256.hash(data: modelData)
            .map { String(format: "%02x", $0) }
            .joined()
        let manifest = PluginManifest(
            id: "test-hf-ocr",
            type: .ocr,
            name: "Test HF OCR",
            version: "1.0",
            runtime: "huggingface-onnx",
            capabilities: ["candidate"],
            languages: ["zh-Hans"],
            sizeBytes: Int64(modelData.count),
            sha256: digest,
            url: URL(
                string: "https://huggingface.co/PaddlePaddle/PP-OCRv6_small_rec_onnx"
            )!,
            license: "Apache-2.0",
            minRAMBytes: 0,
            quality: "test",
            recommended: false,
            revision: "test-revision",
            artifactFile: "inference.onnx"
        )

        let requestedHosts = LockedStringArray()
        StubURLProtocol.handler = { request in
            guard let url = request.url,
                  let host = url.host else {
                return nil
            }
            requestedHosts.append(host)
            let status = host == "hf-mirror.com" ? 503 : 200
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                status == 200 ? modelData : Data()
            )
        }
        defer { StubURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlintHFOCR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = PluginManager(baseDirectory: root)
        let service = PluginCatalogService(manager: manager, session: session)

        _ = try await service.install(manifest)
        let pluginDirectory = await manager.pluginDirectory(for: manifest.id)
        XCTAssertEqual(
            try Data(contentsOf: pluginDirectory.appendingPathComponent(
                "model",
                isDirectory: true
            ).appendingPathComponent(
                "model.onnx"
            )),
            modelData
        )
        XCTAssertEqual(Array(requestedHosts.values.prefix(2)), [
            "hf-mirror.com",
            "huggingface.co",
        ])
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

private final class LockedStringArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
