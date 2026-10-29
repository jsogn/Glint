import Foundation
import XCTest
@testable import GlintPlugins

final class ModelHubServiceTests: XCTestCase {
    func testInspectResolvesPinnedSnapshotAndRuntimeMetadata() async throws {
        let repository = "mlx-community/Hy-MT2-1.8B-4bit"
        ModelHubStubURLProtocol.handler = { request in
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
            switch url.path {
            case "/api/models/\(repository)":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "id": "\(repository)",
                          "sha": "new-revision",
                          "lastModified": "2026-10-20T10:00:00.000Z",
                          "private": false,
                          "gated": false,
                          "pipeline_tag": "translation",
                          "safetensors": {"total": 1800000000},
                          "tags": [
                            "mlx",
                            "translation",
                            "safetensors",
                            "license:apache-2.0"
                          ]
                        }
                        """
                    )
                )
            case "/api/models/\(repository)/revision/new-revision":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "siblings": [
                            {"rfilename": "config.json", "size": 120},
                            {"rfilename": "model.safetensors", "size": 1000, "lfs": {"sha256": "weights"}},
                            {"rfilename": "tokenizer.json", "size": 200},
                            {"rfilename": "tokenizer_config.json", "size": 80}
                          ]
                        }
                        """
                    )
                )
            case "/\(repository)/resolve/new-revision/config.json":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "model_type": "hunyuan_v1_dense",
                          "quantization_config": {"bits": 4}
                        }
                        """
                    )
                )
            case "/\(repository)/resolve/new-revision/tokenizer_config.json":
                return (
                    response,
                    Self.data(#"{"chat_template":"{{ messages }}"}"#)
                )
            default:
                return nil
            }
        }
        defer { ModelHubStubURLProtocol.handler = nil }

        let service = makeService()
        let snapshot = try await service.inspect(repository: repository)

        XCTAssertEqual(snapshot.repository, repository)
        XCTAssertEqual(snapshot.revision, "new-revision")
        XCTAssertEqual(snapshot.modelType, "hunyuan_v1_dense")
        XCTAssertEqual(snapshot.sizeBytes, 1400)
        XCTAssertEqual(snapshot.license, "apache-2.0")
        XCTAssertTrue(snapshot.hasChatTemplate)
        XCTAssertEqual(snapshot.parameterCount, 1_800_000_000)
        XCTAssertEqual(snapshot.quantizationBits, 4)
        XCTAssertEqual(snapshot.pipelineTag, "translation")
    }

    func testInspectRejectsOverflowingSnapshotSize() async {
        let repository = "example/overflowing-size"
        ModelHubStubURLProtocol.handler = { request in
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
            switch url.path {
            case "/api/models/\(repository)":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "sha": "overflow-revision",
                          "private": false,
                          "gated": false,
                          "tags": ["mlx", "translation"],
                          "pipeline_tag": "translation"
                        }
                        """
                    )
                )
            case "/api/models/\(repository)/revision/overflow-revision":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "siblings": [
                            {"rfilename": "config.json", "size": 1},
                            {"rfilename": "model-a.safetensors", "size": 9223372036854775807},
                            {"rfilename": "model-b.safetensors", "size": 1},
                            {"rfilename": "tokenizer.json", "size": 1},
                            {"rfilename": "chat_template.jinja", "size": 1}
                          ]
                        }
                        """
                    )
                )
            case "/\(repository)/resolve/overflow-revision/config.json":
                return (response, Self.data(#"{"model_type":"qwen3"}"#))
            default:
                return nil
            }
        }
        defer { ModelHubStubURLProtocol.handler = nil }

        do {
            _ = try await makeService().inspect(repository: repository)
            XCTFail("Expected overflowing size to be rejected")
        } catch {
            XCTAssertEqual(error as? ModelHubError, .invalidResponse)
        }
    }

    func testUpdateReturnsNilWhenInstalledRevisionMatchesUpstream() async throws {
        let repository = "mlx-community/Qwen3-0.6B-4bit"
        ModelHubStubURLProtocol.handler = snapshotHandler(
            repository: repository,
            revision: "same-revision"
        )
        defer { ModelHubStubURLProtocol.handler = nil }

        let installed = installedManifest(
            repository: repository,
            revision: "same-revision"
        )
        let update = try await makeService().update(for: installed)

        XCTAssertNil(update)
    }

    func testUpdateBuildsManifestWithNewRevisionAndPreservesIdentity() async throws {
        let repository = "mlx-community/Qwen3-0.6B-4bit"
        ModelHubStubURLProtocol.handler = snapshotHandler(
            repository: repository,
            revision: "new-revision"
        )
        defer { ModelHubStubURLProtocol.handler = nil }

        let installed = installedManifest(
            repository: repository,
            revision: "old-revision"
        )
        let update = try await makeService().update(for: installed)
        let manifest = try XCTUnwrap(update?.manifest)

        XCTAssertEqual(update?.currentRevision, "old-revision")
        XCTAssertEqual(update?.latestRevision, "new-revision")
        XCTAssertEqual(manifest.id, installed.id)
        XCTAssertEqual(manifest.name, installed.name)
        XCTAssertEqual(manifest.revision, "new-revision")
        XCTAssertEqual(manifest.url, installed.url)
        XCTAssertEqual(manifest.runtime, "mlx")
    }

    func testSearchReturnsUpstreamRepositoriesWithoutCatalogHosting() async throws {
        ModelHubStubURLProtocol.handler = { request in
            guard let url = request.url,
                url.host == "hf-mirror.com",
                url.path == "/api/models"
            else {
                return nil
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Self.data(
                    """
                    [
                      {
                        "id": "mlx-community/Hy-MT2-1.8B-4bit",
                        "downloads": 1200,
                        "likes": 5,
                        "library_name": "mlx",
                        "pipeline_tag": "translation",
                        "tags": ["mlx", "translation", "license:apache-2.0"],
                        "config": {
                          "model_type": "hunyuan_v1_dense",
                          "architectures": ["HunYuanDenseV1ForCausalLM"],
                          "quantization_config": {"bits": 4},
                          "chat_template_jinja": "{{ messages }}"
                        },
                        "safetensors": {"total": 1800000000},
                        "siblings": [
                          {"rfilename": "config.json"},
                          {"rfilename": "model.safetensors"},
                          {"rfilename": "tokenizer.json"},
                          {"rfilename": "chat_template.jinja"}
                        ]
                      }
                    ]
                    """
                )
            )
        }
        defer { ModelHubStubURLProtocol.handler = nil }

        let results = try await makeService().search(
            query: "Hy-MT2",
            limit: 10
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(
            results.first?.repository,
            "mlx-community/Hy-MT2-1.8B-4bit"
        )
        XCTAssertEqual(results.first?.downloads, 1200)
        XCTAssertEqual(results.first?.license, "apache-2.0")
    }

    func testEmptyMarketSearchBrowsesTranslationPipeline() async throws {
        ModelHubStubURLProtocol.handler = { request in
            guard let url = request.url,
                url.host == "hf-mirror.com",
                url.path == "/api/models"
            else {
                return nil
            }
            let query =
                URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
            XCTAssertEqual(
                query.first { $0.name == "pipeline_tag" }?.value,
                "translation"
            )
            XCTAssertNil(query.first { $0.name == "search" })
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Self.data(
                    """
                    [
                      {
                        "id": "mlx-community/Hy-MT2-1.8B-4bit",
                        "downloads": 1200,
                        "likes": 5,
                        "library_name": "mlx",
                        "pipeline_tag": "translation",
                        "tags": ["mlx", "translation", "license:apache-2.0"],
                        "config": {
                          "model_type": "hunyuan_v1_dense",
                          "chat_template_jinja": "{{ messages }}"
                        },
                        "safetensors": {"total": 1800000000},
                        "siblings": [
                          {"rfilename": "config.json"},
                          {"rfilename": "model.safetensors"},
                          {"rfilename": "tokenizer.json"}
                        ]
                      }
                    ]
                    """
                )
            )
        }
        defer { ModelHubStubURLProtocol.handler = nil }

        let results = try await makeService().search(query: "")

        XCTAssertEqual(
            results.first?.repository,
            "mlx-community/Hy-MT2-1.8B-4bit"
        )
    }

    func testSearchReturnsAllMLXModelsWithoutAvailabilityJudgment()
        async throws
    {
        ModelHubStubURLProtocol.handler = { request in
            guard let url = request.url,
                url.host == "hf-mirror.com",
                url.path == "/api/models"
            else {
                return nil
            }
            let items: [[String: Any]] = [
                Self.searchRecord(
                    id: "mlx-community/Hy-MT2-1.8B-4bit",
                    tags: ["mlx", "translation"],
                    modelType: "hunyuan_v1_dense",
                    parameterCount: 1_800_000_000
                ),
                Self.searchRecord(
                    id: "example/general-chat",
                    tags: ["mlx", "text-generation"],
                    modelType: "qwen3",
                    parameterCount: 4_000_000_000,
                    pipelineTag: "text-generation"
                ),
                Self.searchRecord(
                    id: "example/abliterated-translation",
                    tags: ["mlx", "translation", "abliterated"],
                    modelType: "hunyuan_v1_dense",
                    parameterCount: 1_800_000_000
                ),
                Self.searchRecord(
                    id: "example/unsupported-translation",
                    tags: ["mlx", "translation"],
                    modelType: "custom_arch",
                    parameterCount: 2_000_000_000
                ),
                Self.searchRecord(
                    id: "example/oversized-translation",
                    tags: ["mlx", "translation"],
                    modelType: "hunyuan_v1_dense",
                    parameterCount: 30_000_000_000,
                    bits: 8
                ),
                Self.searchRecord(
                    id: "example/large-bf16-translation",
                    tags: ["mlx", "translation"],
                    modelType: "hunyuan_v1_dense",
                    parameterCount: 7_500_000_000,
                    bits: nil
                ),
                Self.searchRecord(
                    id: "example/custom-code-translation",
                    tags: ["mlx", "translation", "custom_code"],
                    modelType: "hunyuan_v1_dense",
                    parameterCount: 1_800_000_000
                ),
            ]
            let data = try! JSONSerialization.data(withJSONObject: items)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }
        defer { ModelHubStubURLProtocol.handler = nil }

        let results = try await makeService().search(query: "Qwen3")

        XCTAssertEqual(
            results.map(\.repository),
            [
                "mlx-community/Hy-MT2-1.8B-4bit",
                "example/general-chat",
                "example/abliterated-translation",
                "example/unsupported-translation",
                "example/oversized-translation",
                "example/large-bf16-translation",
                "example/custom-code-translation",
            ]
        )
    }

    func testInspectAllowsNativeArchitectureWithCustomCodeMetadata()
        async throws
    {
        let repository = "example/custom-model"
        ModelHubStubURLProtocol.handler = snapshotHandler(
            repository: repository,
            revision: "custom-revision",
            tags: ["mlx", "custom_code", "translation"],
            extraFiles: ["modeling_custom.py"]
        )
        defer { ModelHubStubURLProtocol.handler = nil }

        let snapshot = try await makeService().inspect(
            repository: repository
        )

        XCTAssertEqual(snapshot.modelType, "qwen3")
    }

    func testInspectRejectsNonTextPipeline() async throws {
        let repository = "example/image-model"
        ModelHubStubURLProtocol.handler = snapshotHandler(
            repository: repository,
            revision: "image-revision",
            pipelineTag: "image-text-to-text"
        )
        defer { ModelHubStubURLProtocol.handler = nil }

        do {
            _ = try await makeService().inspect(repository: repository)
            XCTFail("Expected non-text model to be rejected")
        } catch let error as ModelHubError {
            XCTAssertEqual(
                error,
                .unsupportedPipeline("image-text-to-text")
            )
        }
    }

    func testInspectRejectsAdapterOnlySnapshot() async throws {
        let repository = "example/adapter-model"
        ModelHubStubURLProtocol.handler = snapshotHandler(
            repository: repository,
            revision: "adapter-revision",
            modelWeightName: "adapter_model.safetensors",
            extraFiles: ["adapter_config.json"]
        )
        defer { ModelHubStubURLProtocol.handler = nil }

        do {
            _ = try await makeService().inspect(repository: repository)
            XCTFail("Expected adapter-only model to be rejected")
        } catch let error as ModelHubError {
            XCTAssertEqual(error, .incompleteModel)
        }
    }

    private func makeService() -> ModelHubService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelHubStubURLProtocol.self]
        return ModelHubService(
            session: URLSession(configuration: configuration),
            endpoints: [URL(string: "https://hf-mirror.com")!]
        )
    }

    private func installedManifest(
        repository: String,
        revision: String
    ) -> PluginManifest {
        PluginManifest(
            id: "llm-qwen3-0.6b",
            type: .translation,
            name: "Qwen3 0.6B",
            version: "0.1.0",
            runtime: "mlx",
            sizeBytes: 351_386_061,
            sha256: "HUGGINGFACE_SNAPSHOT",
            url: URL(string: "https://huggingface.co/\(repository)")!,
            license: "APACHE-2.0",
            minRAMBytes: 4_294_967_296,
            summary: "Test model",
            revision: revision,
            source: .catalog
        )
    }

    private func snapshotHandler(
        repository: String,
        revision: String,
        tags: [String] = [
            "mlx",
            "safetensors",
            "license:apache-2.0",
        ],
        pipelineTag: String = "translation",
        modelWeightName: String = "model.safetensors",
        extraFiles: [String] = []
    ) -> (URLRequest) -> (HTTPURLResponse, Data)? {
        { request in
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
            switch url.path {
            case "/api/models/\(repository)":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "sha": "\(revision)",
                          "lastModified": "2026-10-20T10:00:00.000Z",
                          "private": false,
                          "gated": false,
                          "tags": \(Self.json(tags)),
                          "pipeline_tag": "\(pipelineTag)"
                        }
                        """
                    )
                )
            case "/api/models/\(repository)/revision/\(revision)":
                return (
                    response,
                    Self.data(
                        """
                        {
                          "siblings": [
                            {"rfilename": "config.json", "size": 120},
                            {"rfilename": \(Self.json(modelWeightName)), "size": 1000, "lfs": {"sha256": "weights"}},
                            {"rfilename": "tokenizer.json", "size": 200},
                            {"rfilename": "tokenizer_config.json", "size": 80}
                            \(extraFiles.map { ", {\"rfilename\": \(Self.json($0))}" }.joined())
                          ]
                        }
                        """
                    )
                )
            case "/\(repository)/resolve/\(revision)/config.json":
                return (response, Self.data(#"{"model_type":"qwen3"}"#))
            case "/\(repository)/resolve/\(revision)/tokenizer_config.json":
                return (
                    response,
                    Self.data(#"{"chat_template":"{{ messages }}"}"#)
                )
            default:
                return nil
            }
        }
    }

    private static func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func json(_ value: Any) -> String {
        if let string = value as? String {
            return String(
                data: try! JSONEncoder().encode(string),
                encoding: .utf8
            )!
        }
        return String(
            data: try! JSONSerialization.data(withJSONObject: value),
            encoding: .utf8
        )!
    }

    private static func searchRecord(
        id: String,
        tags: [String],
        modelType: String,
        parameterCount: Int64,
        bits: Int? = 4,
        pipelineTag: String = "translation"
    ) -> [String: Any] {
        var config: [String: Any] = [
            "model_type": modelType,
            "chat_template_jinja": "{{ messages }}",
        ]
        if let bits {
            config["quantization_config"] = ["bits": bits]
        }
        let parameterTypes =
            bits == nil
            ? ["BF16": parameterCount]
            : ["U32": parameterCount]
        return [
            "id": id,
            "downloads": 1,
            "likes": 0,
            "library_name": "mlx",
            "pipeline_tag": pipelineTag,
            "tags": tags,
            "config": config,
            "safetensors": [
                "total": parameterCount,
                "parameters": parameterTypes,
            ],
            "siblings": [
                ["rfilename": "config.json"],
                ["rfilename": "model.safetensors"],
                ["rfilename": "tokenizer.json"],
                ["rfilename": "chat_template.jinja"],
            ],
        ]
    }
}

private final class ModelHubStubURLProtocol: URLProtocol {
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
