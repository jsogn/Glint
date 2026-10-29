import Foundation

enum HuggingFaceRemotePolicy {
    private static let defaultMirror = "https://hf-mirror.com"
    private static let officialEndpoint = "https://huggingface.co"

    static func endpoints(
        for manifestURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var values: [String] = []
        if let configured = environment["GLINT_HF_ENDPOINT"] {
            values.append(configured)
        }
        values.append(environment["GLINT_HF_MIRROR"] ?? defaultMirror)
        values.append(officialEndpoint)
        if let manifestURL {
            appendManifestEndpoint(manifestURL, to: &values)
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            guard seen.insert(trimmed).inserted else { return nil }
            return URL(string: trimmed)
        }.filter(isAllowedRemoteURL)
    }

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" {
            return true
        }
        guard scheme == "http",
            let host = url.host?.lowercased()
        else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    static func makeSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static func appendManifestEndpoint(
        _ manifestURL: URL,
        to values: inout [String]
    ) {
        guard let host = manifestURL.host else { return }
        let scheme = manifestURL.scheme ?? "https"
        values.append("\(scheme)://\(host)")
    }
}
