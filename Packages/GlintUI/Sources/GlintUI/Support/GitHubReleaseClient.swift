import Foundation

struct GitHubReleaseClient: Sendable {
    typealias DataLoader =
        @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: Error {
        case invalidResponse
        case unexpectedStatus(Int)
    }

    private struct Payload: Decodable {
        let tagName: String
        let pageURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/jsogn/Glint/releases/latest"
    )!

    private let currentVersion: String
    private let dataLoader: DataLoader

    init(
        currentVersion: String,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.currentVersion = currentVersion
        self.dataLoader = dataLoader
    }

    func latestRelease() async throws -> AppRelease {
        var request = URLRequest(
            url: Self.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "2022-11-28",
            forHTTPHeaderField: "X-GitHub-Api-Version"
        )
        request.setValue(
            "Glint/\(currentVersion)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await dataLoader(request)
        guard let response = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw ClientError.unexpectedStatus(response.statusCode)
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return AppRelease(
            version: payload.tagName,
            pageURL: payload.pageURL
        )
    }
}
