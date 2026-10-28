import CryptoKit
import Foundation
import GlintDictionary
import zlib

public struct ECDICTUpdateResult: Sendable {
    let didUpdate: Bool
    let version: String
    let sourceDate: String?
    let termCount: Int
    let rankCount: Int

    public var statusText: String {
        let dateText = sourceDate.map { " · \($0.prefix(10))" } ?? ""
        if didUpdate {
            return "ECDICT 已更新至 \(version)\(dateText)"
        }
        return "ECDICT 已是最新（\(version)\(dateText)）"
    }
}

public enum ECDICTUpdateError: Error, LocalizedError, Equatable {
    case unavailable
    case invalidResponse
    case missingSourceDate
    case invalidArchive
    case implausibleDatabase

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "ECDICT 更新资源不可用"
        case .invalidResponse:
            "ECDICT 更新服务器返回了无效响应"
        case .missingSourceDate:
            "ECDICT 数据缺少更新时间"
        case .invalidArchive:
            "ECDICT 下载文件格式无效"
        case .implausibleDatabase:
            "下载的 ECDICT 数据不完整"
        }
    }
}

public actor ECDICTUpdateService {
    public static let dictionaryID = "dict-ecdict"
    public static let atomURL = URL(
        string:
            "https://github.com/skywind3000/ECDICT/commits/master/ecdict.csv.atom"
    )!
    public static let archiveURLTemplate =
        "https://codeload.github.com/skywind3000/ECDICT/tar.gz/{revision}"

    private struct SourceRevision: Sendable {
        let commitSHA: String
        let date: String
    }

    private struct TarGzipExtractor {
        private static let blockSize = 512

        private let destination: URL
        private let fileManager: FileManager
        private var buffer = Data()
        private var output: FileHandle?
        private var remainingEntryBytes = 0
        private var remainingFileBytes = 0
        private var didFindSource = false

        init(destination: URL, fileManager: FileManager) throws {
            self.destination = destination
            self.fileManager = fileManager
            try? fileManager.removeItem(at: destination)
            guard
                fileManager.createFile(
                    atPath: destination.path,
                    contents: nil
                )
            else {
                throw ECDICTUpdateError.invalidArchive
            }
        }

        mutating func append(_ data: Data) throws {
            buffer.append(data)
            try consumeAvailableBytes()
        }

        mutating func finish() throws {
            if remainingEntryBytes > 0 {
                throw ECDICTUpdateError.invalidArchive
            }
            try output?.close()
            output = nil
            guard didFindSource,
                (try? destination.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0) ?? 0 > 0
            else {
                throw ECDICTUpdateError.invalidArchive
            }
        }

        private mutating func consumeAvailableBytes() throws {
            while true {
                if remainingEntryBytes > 0 {
                    guard !buffer.isEmpty else { return }
                    let count = min(remainingEntryBytes, buffer.count)
                    let writeCount = min(remainingFileBytes, count)
                    if writeCount > 0, let output {
                        try output.write(
                            contentsOf: buffer.prefix(writeCount)
                        )
                    }
                    remainingEntryBytes -= count
                    remainingFileBytes -= writeCount
                    buffer.removeFirst(count)
                    if remainingEntryBytes == 0 {
                        try output?.close()
                        output = nil
                    }
                    continue
                }
                guard buffer.count >= Self.blockSize else { return }
                let header = [UInt8](buffer.prefix(Self.blockSize))
                buffer.removeFirst(Self.blockSize)
                if header.allSatisfy({ $0 == 0 }) {
                    return
                }
                let name = Self.headerName(header)
                let size = Self.headerSize(header)
                let padding =
                    (Self.blockSize - size % Self.blockSize)
                    % Self.blockSize
                remainingEntryBytes = size + padding
                remainingFileBytes = size
                if name == "ecdict.csv"
                    || name.hasSuffix("/ecdict.csv")
                {
                    guard !didFindSource,
                        fileManager.fileExists(atPath: destination.path)
                    else {
                        throw ECDICTUpdateError.invalidArchive
                    }
                    output = try FileHandle(
                        forWritingTo: destination
                    )
                    didFindSource = true
                }
            }
        }

        private static func headerName(_ header: [UInt8]) -> String {
            let prefix = string(
                bytes: header[345..<500]
            )
            let name = string(
                bytes: header[0..<100]
            )
            return prefix.isEmpty ? name : "\(prefix)/\(name)"
        }

        private static func headerSize(_ header: [UInt8]) -> Int {
            let raw = string(bytes: header[124..<136])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(raw, radix: 8) ?? 0
        }

        private static func string(
            bytes: ArraySlice<UInt8>
        ) -> String {
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }

    private let pluginManager: PluginManager
    private let installer: CoreDictionaryInstaller
    private let session: URLSession
    private let fileManager: FileManager
    private let bundledDirectory: URL?
    private let atomURL: URL
    private let archiveURLTemplate: String
    private let minimumTermCount: Int
    private let minimumRankCount: Int

    public init(
        pluginManager: PluginManager,
        bundledDirectory: URL?,
        session: URLSession? = nil,
        fileManager: FileManager = .default,
        atomURL: URL? = nil,
        archiveURLTemplate: String? = nil,
        minimumTermCount: Int = 80_000,
        minimumRankCount: Int = 120_000
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
                configuration.timeoutIntervalForResource = 300
                return URLSession(configuration: configuration)
            }()
        self.fileManager = fileManager
        self.bundledDirectory = bundledDirectory
        self.atomURL = atomURL ?? Self.atomURL
        self.archiveURLTemplate =
            archiveURLTemplate ?? Self.archiveURLTemplate
        self.minimumTermCount = minimumTermCount
        self.minimumRankCount = minimumRankCount
    }

    public func checkForUpdate() async throws -> ECDICTUpdateResult {
        guard let bundledDirectory else {
            throw ECDICTUpdateError.unavailable
        }
        let current = try await currentDictionary(
            bundledDirectory: bundledDirectory
        )
        let revision = try await remoteRevision()
        let currentRevision =
            current.manifest.revision
            ?? current.summary.sourceRevision
        if revision.commitSHA == currentRevision {
            return result(
                didUpdate: false,
                manifest: current.manifest,
                summary: current.summary
            )
        }

        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "GlintECDICTUpdate-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: workDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workDirectory) }

        let archiveURL = workDirectory.appendingPathComponent(
            "source.tar.gz"
        )
        try await downloadArchive(
            revision: revision.commitSHA,
            to: archiveURL
        )
        let csvURL = workDirectory.appendingPathComponent("ecdict.csv")
        try Self.extractSourceArchive(
            from: archiveURL,
            to: csvURL
        )
        let sourceChecksum = try Self.sha256(fileURL: csvURL)
        let builtDatabase = workDirectory.appendingPathComponent(
            "ecdict_rank.sqlite3"
        )
        let summary = try ECDICTRankBuilder.build(
            fromCSVURL: csvURL,
            to: builtDatabase,
            sourceChecksum: sourceChecksum,
            sourceDate: revision.date,
            sourceRevision: revision.commitSHA
        )
        try Task.checkCancellation()
        guard
            summary.termCount >= minimumTermCount,
            summary.rankCount >= minimumRankCount
        else {
            throw ECDICTUpdateError.implausibleDatabase
        }

        let version = Self.version(from: revision.date)
        let manifest = try await installer.install(
            PreparedCoreDictionaryInstallation(
                dictionaryID: Self.dictionaryID,
                bundledDirectory: bundledDirectory,
                builtArtifactURL: builtDatabase,
                artifactFileName: "ecdict_rank.sqlite3",
                manifestFields: CoreDictionaryManifestFields(
                    name: current.manifest.name,
                    version: version,
                    runtime: current.manifest.runtime,
                    url: URL(
                        string:
                            "https://github.com/skywind3000/ECDICT"
                    )!,
                    license: current.manifest.license,
                    minRAMBytes: current.manifest.minRAMBytes,
                    summary: current.manifest.summary,
                    revision: revision.commitSHA,
                    sourceDate: revision.date,
                    sourceChecksum: sourceChecksum,
                    coreUpdateKind: .ecdict
                ),
                validate: { databaseURL in
                    (try? ECDICTRankBuilder.inspect(
                        databaseURL: databaseURL,
                        fullIntegrityCheck: true
                    )) == summary
                }
            ),
            workDirectory: workDirectory
        )
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
        summary: ECDICTRankSummary
    ) {
        if let installed = await pluginManager.installedPlugin(
            id: Self.dictionaryID
        ) {
            let directory = await pluginManager.pluginDirectory(
                for: Self.dictionaryID
            )
            let database = directory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
            if let summary = try? ECDICTRankBuilder.inspect(
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
            throw ECDICTUpdateError.unavailable
        }
        let database = bundledDirectory.appendingPathComponent(
            "ecdict_rank.sqlite3"
        )
        return (
            manifest,
            try ECDICTRankBuilder.inspect(databaseURL: database)
        )
    }

    private func remoteRevision() async throws -> SourceRevision {
        var request = URLRequest(
            url: atomURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.setValue(
            Self.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let text = String(data: data, encoding: .utf8)
        else {
            throw ECDICTUpdateError.invalidResponse
        }
        let pattern =
            #"<entry>\s*<id>tag:github\.com,2008:Grit::Commit/([0-9a-f]{40})</id>.*?<updated>([^<]+)</updated>"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.dotMatchesLineSeparators]
            ),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
            ),
            let shaRange = Range(match.range(at: 1), in: text),
            let dateRange = Range(match.range(at: 2), in: text)
        else {
            throw ECDICTUpdateError.missingSourceDate
        }
        return SourceRevision(
            commitSHA: String(text[shaRange]),
            date: String(text[dateRange])
        )
    }

    private func downloadArchive(
        revision: String,
        to destination: URL
    ) async throws {
        let urlString = archiveURLTemplate.replacingOccurrences(
            of: "{revision}",
            with: revision
        )
        guard let url = URL(string: urlString) else {
            throw ECDICTUpdateError.invalidResponse
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 300
        )
        request.setValue(
            Self.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            data.count > 1_000_000,
            data.count < 200_000_000
        else {
            throw ECDICTUpdateError.invalidArchive
        }
        try data.write(to: destination, options: .atomic)
    }

    private func dataWithRetry(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await session.data(for: request)
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < 2 else {
                    throw error
                }
                try await Task.sleep(for: .seconds(attempt + 1))
            }
        }
        throw lastError ?? ECDICTUpdateError.invalidResponse
    }

    private func result(
        didUpdate: Bool,
        manifest: PluginManifest,
        summary: ECDICTRankSummary
    ) -> ECDICTUpdateResult {
        ECDICTUpdateResult(
            didUpdate: didUpdate,
            version: manifest.version,
            sourceDate: summary.sourceDate,
            termCount: summary.termCount,
            rankCount: summary.rankCount
        )
    }

    private static func extractSourceArchive(
        from archiveURL: URL,
        to csvURL: URL
    ) throws {
        let archive = try Data(
            contentsOf: archiveURL,
            options: [.mappedIfSafe]
        )
        var stream = z_stream()
        guard
            inflateInit2_(
                &stream,
                16 + MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK
        else {
            throw ECDICTUpdateError.invalidArchive
        }
        defer { inflateEnd(&stream) }

        var extractor = try TarGzipExtractor(
            destination: csvURL,
            fileManager: .default
        )
        var status: Int32 = Z_OK
        try archive.withUnsafeBytes { rawBuffer in
            stream.next_in = UnsafeMutablePointer<
                Bytef
            >(
                mutating:
                    rawBuffer
                    .bindMemory(to: Bytef.self)
                    .baseAddress
            )
            stream.avail_in = uInt(rawBuffer.count)
            repeat {
                var output = [UInt8](
                    repeating: 0,
                    count: 65_536
                )
                let produced = try output.withUnsafeMutableBytes {
                    outputBuffer -> Int in
                    stream.next_out =
                        outputBuffer
                        .bindMemory(to: Bytef.self)
                        .baseAddress
                    stream.avail_out = uInt(outputBuffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw ECDICTUpdateError.invalidArchive
                    }
                    return outputBuffer.count - Int(stream.avail_out)
                }
                if produced > 0 {
                    try extractor.append(
                        Data(output.prefix(produced))
                    )
                }
                try Task.checkCancellation()
            } while status != Z_STREAM_END
        }
        try extractor.finish()
    }

    private static var userAgent: String {
        "Glint/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")"
    }

    private static func version(from sourceDate: String) -> String {
        sourceDate.prefix(10).replacingOccurrences(of: "-", with: ".")
    }

    private static func sha256(fileURL: URL) throws -> String {
        let data = try Data(
            contentsOf: fileURL,
            options: [.mappedIfSafe]
        )
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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
}
