import Foundation
import GlintCore
import XCTest
@testable import GlintInference

final class OpenAICompatibleTranslationEngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSendsChatCompletionAndParsesTranslation() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://localhost:11434/v1/chat/completions"
            )
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer secret"
            )
            let body = try XCTUnwrap(Self.readBody(from: request))
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            XCTAssertEqual(json["model"] as? String, "qwen3:8b")

            let data = Data(
                #"{"choices":[{"message":{"content":"Hello"}}]}"#.utf8
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let engine = OpenAICompatibleTranslationEngine(
            configuration: OpenAICompatibleConfiguration(
                baseURL: "http://localhost:11434/v1",
                model: "qwen3:8b",
                apiKey: "secret"
            ),
            session: URLSession(configuration: configuration)
        )

        let result = try await engine.translate(
            Candidate(text: "你好", kind: .word, confidence: 1)
        )
        XCTAssertEqual(result?.text, "Hello")
        XCTAssertEqual(result?.source, .translation)
    }

    func testRuntimeRoutesOpenAICompatibleSelection() async throws {
        let suiteName = "GlintRuntimeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let providerID = "provider-test"
        let selectionID = TranslationModelSelection.openAICompatibleSelectionID(
            for: providerID
        )
        TranslationModelSelection.select(
            selectionID,
            in: defaults
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "http://localhost:18080/v1/chat/completions"
            )
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    #"{"choices":[{"message":{"content":"Hello from runtime"}}]}"#.utf8
                )
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let runtime = TranslationRuntime(
            defaults: defaults,
            modelResolver: { modelID in
                .openAICompatible(
                    modelID: selectionID,
                    configuration: OpenAICompatibleConfiguration(
                        baseURL: "http://localhost:18080/v1",
                        model: "mock"
                    )
                )
            },
            openAISession: URLSession(configuration: configuration)
        )

        let result = try await runtime.translate(
            Candidate(text: "你好", kind: .word, confidence: 1)
        )
        XCTAssertEqual(result?.text, "Hello from runtime")
        UserDefaults(suiteName: suiteName)?
            .removePersistentDomain(forName: suiteName)
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let capacity = buffer.count
            let count = buffer.withUnsafeMutableBytes {
                stream.read(
                    $0.bindMemory(to: UInt8.self).baseAddress!,
                    maxLength: capacity
                )
            }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
