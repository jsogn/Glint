import Foundation
import XCTest

@testable import GlintUI

final class GitHubReleaseClientTests: XCTestCase {
    private actor RequestRecorder {
        private(set) var request: URLRequest?

        func record(_ request: URLRequest) {
            self.request = request
        }
    }

    func testLatestReleaseDecodesVersionAndPageURL() async throws {
        let responseURL = URL(
            string: "https://api.github.com/repos/jsogn/Glint/releases/latest"
        )!
        let payload = """
            {
              "tag_name": "v0.8.0",
              "html_url": "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
            }
            """
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = GitHubReleaseClient(
            currentVersion: "0.7.5",
            dataLoader: { _ in
                (Data(payload.utf8), response)
            }
        )

        let release = try await client.latestRelease()

        XCTAssertEqual(
            release,
            AppRelease(
                version: "v0.8.0",
                pageURL: URL(
                    string: "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
                )!
            )
        )
    }

    func testLatestReleaseRejectsRateLimitResponse() async {
        let responseURL = URL(
            string: "https://api.github.com/repos/jsogn/Glint/releases/latest"
        )!
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
        let client = GitHubReleaseClient(
            currentVersion: "0.7.5",
            dataLoader: { _ in
                (Data("{}".utf8), response)
            }
        )

        do {
            _ = try await client.latestRelease()
            XCTFail("Expected a rate-limit failure")
        } catch GitHubReleaseClient.ClientError.unexpectedStatus(429) {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLatestReleaseRequestBypassesCacheAndIdentifiesGlint() async throws {
        let responseURL = URL(
            string: "https://api.github.com/repos/jsogn/Glint/releases/latest"
        )!
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let payload = """
            {
              "tag_name": "v0.8.0",
              "html_url": "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
            }
            """
        let recorder = RequestRecorder()
        let client = GitHubReleaseClient(
            currentVersion: "0.7.5",
            dataLoader: { request in
                await recorder.record(request)
                return (Data(payload.utf8), response)
            }
        )

        _ = try await client.latestRelease()

        let capturedRequest = await recorder.request
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, responseURL)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "application/vnd.github+json"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"),
            "Glint/0.7.5"
        )
    }
}
