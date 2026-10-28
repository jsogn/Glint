import Foundation
import GlintDictionary

public struct CoreDictionaryUpdateResult: Sendable {
    let didUpdate: Bool
    let version: String
    let sourceDate: String?
    let entryCount: Int
    let senseCount: Int

    public var statusText: String {
        let dateText = sourceDate.map { " · \($0.prefix(10))" } ?? ""
        if didUpdate {
            return "CC-CEDICT 已更新至 \(version)\(dateText)"
        }
        return "CC-CEDICT 已是最新（\(version)\(dateText)）"
    }
}

public enum CoreDictionaryUpdateError: Error, LocalizedError, Equatable {
    case unavailable
    case invalidResponse
    case missingSourceDate
    case implausibleDatabase

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "CC-CEDICT 更新资源不可用"
        case .invalidResponse:
            "CC-CEDICT 下载服务器返回了无效响应"
        case .missingSourceDate:
            "CC-CEDICT 文件缺少日期信息"
        case .implausibleDatabase:
            "下载的 CC-CEDICT 数据不完整"
        }
    }
}

public actor CoreDictionaryUpdateService {
    public static let dictionaryID = "dict-cedict"
    public static let sourceURL = URL(
        string:
            "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz"
    )!

    private enum DefaultsKey {
        static let etag = "coreDictionary.dict-cedict.etag"
        static let lastModified =
            "coreDictionary.dict-cedict.lastModified"
    }

    private let pluginManager: PluginManager
    private let installer: CoreDictionaryInstaller
    private let session: URLSession
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let bundledDirectory: URL?
    private let minimumEntryCount: Int
    private let minimumSenseCount: Int
    private let sourceURL: URL

    public init(
        pluginManager: PluginManager,
        bundledDirectory: URL?,
        session: URLSession? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        sourceURL: URL? = nil,
        minimumEntryCount: Int = 100_000,
        minimumSenseCount: Int = 150_000
    ) {
        self.pluginManager = pluginManager
        self.installer = CoreDictionaryInstaller(
            pluginManager: pluginManager
        )
        self.session =
            session
            ?? {
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 180
                configuration.timeoutIntervalForResource = 240
                return URLSession(configuration: configuration)
            }()
        self.defaults = defaults
        self.fileManager = fileManager
        self.bundledDirectory = bundledDirectory
        self.minimumEntryCount = minimumEntryCount
        self.minimumSenseCount = minimumSenseCount
        self.sourceURL = sourceURL ?? Self.sourceURL
    }

    public func checkForUpdate() async throws -> CoreDictionaryUpdateResult {
        guard let bundledDirectory else {
            throw CoreDictionaryUpdateError.unavailable
        }
        let current = try await currentDictionary(
            bundledDirectory: bundledDirectory
        )
        let storedETag = defaults.string(forKey: DefaultsKey.etag)
        let storedLastModified = defaults.string(
            forKey: DefaultsKey.lastModified
        )
        var metadataRequest = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        metadataRequest.httpMethod = "HEAD"
        if let storedETag {
            metadataRequest.setValue(
                storedETag,
                forHTTPHeaderField: "If-None-Match"
            )
        }
        if let storedLastModified {
            metadataRequest.setValue(
                storedLastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }
        if let (_, response) = try? await session.data(
            for: metadataRequest
        ),
            let http = response as? HTTPURLResponse
        {
            if http.statusCode == 304 {
                return result(
                    didUpdate: false,
                    manifest: current.manifest,
                    summary: current.summary
                )
            }
            let remoteETag = http.value(forHTTPHeaderField: "ETag")
            let knownETagMatches =
                storedETag != nil && remoteETag == storedETag
            let firstCheckOnSameDay =
                storedETag == nil
                && Self.isNotAfterCurrentDay(
                    response: http,
                    currentSourceDate: current.summary.sourceDate
                )
            if (200..<300).contains(http.statusCode),
                knownETagMatches || firstCheckOnSameDay
            {
                storeHTTPMetadata(from: http)
                return result(
                    didUpdate: false,
                    manifest: current.manifest,
                    summary: current.summary
                )
            }
        }
        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 240
        )
        request.setValue(
            "Glint/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")",
            forHTTPHeaderField: "User-Agent"
        )
        if let etag = defaults.string(forKey: DefaultsKey.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = defaults.string(
            forKey: DefaultsKey.lastModified
        ) {
            request.setValue(
                lastModified,
                forHTTPHeaderField: "If-Modified-Since"
            )
        }

        let (downloadedURL, response) = try await downloadSource(
            request: request
        )
        defer { try? fileManager.removeItem(at: downloadedURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw CoreDictionaryUpdateError.invalidResponse
        }
        if http.statusCode == 304 {
            return result(
                didUpdate: false,
                manifest: current.manifest,
                summary: current.summary
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CoreDictionaryUpdateError.invalidResponse
        }

        let downloadedDate = try CedictDatabaseBuilder.sourceDate(
            fromGzipURL: downloadedURL
        )
        guard let downloadedDate else {
            throw CoreDictionaryUpdateError.missingSourceDate
        }
        let downloadedETag = http.value(
            forHTTPHeaderField: "ETag"
        )
        let representationChanged =
            downloadedETag != nil
            && downloadedETag != defaults.string(
                forKey: DefaultsKey.etag
            )
        guard
            Self.isNewer(
                downloadedDate,
                than: current.summary.sourceDate
            ) || representationChanged
        else {
            storeHTTPMetadata(from: http)
            return result(
                didUpdate: false,
                manifest: current.manifest,
                summary: current.summary
            )
        }
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "GlintCoreDictionary-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let builtDatabase = workDirectory.appendingPathComponent(
            "cedict.sqlite3"
        )
        let summary = try CedictDatabaseBuilder.build(
            fromGzipURL: downloadedURL,
            to: builtDatabase
        )
        try Task.checkCancellation()
        guard
            summary.entryCount >= minimumEntryCount,
            summary.senseCount >= minimumSenseCount
        else {
            throw CoreDictionaryUpdateError.implausibleDatabase
        }

        let version = Self.version(from: downloadedDate)
        let manifest = try await installer.install(
            PreparedCoreDictionaryInstallation(
                dictionaryID: Self.dictionaryID,
                bundledDirectory: bundledDirectory,
                builtArtifactURL: builtDatabase,
                artifactFileName: "cedict.sqlite3",
                manifestFields: CoreDictionaryManifestFields(
                    name: current.manifest.name,
                    version: version,
                    runtime: current.manifest.runtime,
                    url: sourceURL,
                    license: current.manifest.license,
                    minRAMBytes: current.manifest.minRAMBytes,
                    summary: current.manifest.summary,
                    sourceDate: downloadedDate,
                    coreUpdateKind: .cedict
                ),
                validate: { databaseURL in
                    (try? CedictDatabaseBuilder.inspect(
                        databaseURL: databaseURL,
                        fullIntegrityCheck: true
                    )) == summary
                }
            ),
            workDirectory: workDirectory
        )
        storeHTTPMetadata(from: http)
        return result(
            didUpdate: true,
            manifest: manifest,
            summary: summary
        )
    }

    private func currentDictionary(
        bundledDirectory: URL
    ) async throws -> (
        manifest: PluginManifest,
        summary: CedictDatabaseSummary
    ) {
        if let installed = await pluginManager.installedPlugin(
            id: Self.dictionaryID
        ) {
            let directory = await pluginManager.pluginDirectory(
                for: Self.dictionaryID
            )
            let database = directory.appendingPathComponent(
                "cedict.sqlite3"
            )
            if let summary = try? CedictDatabaseBuilder.inspect(
                databaseURL: database
            ) {
                return (installed, summary)
            }
        }
        guard
            let manifest = try? PluginManifest.load(
                from: bundledDirectory
            )
        else {
            throw CoreDictionaryUpdateError.unavailable
        }
        let database = bundledDirectory.appendingPathComponent(
            "cedict.sqlite3"
        )
        return (
            manifest,
            try CedictDatabaseBuilder.inspect(databaseURL: database)
        )
    }

    private func result(
        didUpdate: Bool,
        manifest: PluginManifest,
        summary: CedictDatabaseSummary
    ) -> CoreDictionaryUpdateResult {
        CoreDictionaryUpdateResult(
            didUpdate: didUpdate,
            version: manifest.version,
            sourceDate: summary.sourceDate,
            entryCount: summary.entryCount,
            senseCount: summary.senseCount
        )
    }

    private func storeHTTPMetadata(
        from response: HTTPURLResponse
    ) {
        if let etag = response.value(forHTTPHeaderField: "ETag") {
            defaults.set(etag, forKey: DefaultsKey.etag)
        }
        if let modified = response.value(
            forHTTPHeaderField: "Last-Modified"
        ) {
            defaults.set(modified, forKey: DefaultsKey.lastModified)
        }
    }

    private func downloadSource(
        request: URLRequest
    ) async throws -> (URL, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(
                    for: request
                )
                let retainedURL = fileManager.temporaryDirectory
                    .appendingPathComponent(
                        "GlintCedictDownload-\(UUID().uuidString).gz"
                    )
                try data.write(to: retainedURL, options: .atomic)
                return (retainedURL, response)
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < 2 else {
                    throw error
                }
                try await Task.sleep(
                    for: .seconds(attempt + 1)
                )
            }
        }
        throw lastError ?? CoreDictionaryUpdateError.invalidResponse
    }

    private static func isNewer(
        _ candidate: String,
        than current: String?
    ) -> Bool {
        guard let current else { return true }
        let formatter = ISO8601DateFormatter()
        if let candidateDate = formatter.date(from: candidate),
            let currentDate = formatter.date(from: current)
        {
            return candidateDate > currentDate
        }
        return candidate > current
    }

    private static func httpDay(from value: String?) -> String? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else {
            return nil
        }
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isNotAfterCurrentDay(
        response: HTTPURLResponse,
        currentSourceDate: String?
    ) -> Bool {
        guard
            let remoteDay = httpDay(
                from: response.value(
                    forHTTPHeaderField: "Last-Modified"
                )
            ),
            let currentDay = currentSourceDate?.prefix(10)
        else {
            return false
        }
        return remoteDay <= String(currentDay)
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .networkConnectionLost,
            .secureConnectionFailed,
            .cannotConnectToHost,
            .notConnectedToInternet,
        ].contains(urlError.code)
    }

    private static func version(from sourceDate: String) -> String {
        let components = sourceDate.prefix(10).split(separator: "-")
        guard components.count == 3 else { return sourceDate }
        return components.joined(separator: ".")
    }

}
