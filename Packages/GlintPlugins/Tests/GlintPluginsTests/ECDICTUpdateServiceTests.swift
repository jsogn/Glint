import CryptoKit
import Foundation
import GlintCore
import GlintDictionary
import os
import XCTest
import zlib

@testable import GlintPlugins

private let oldECDICTRevision =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
private let newECDICTRevision =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

private final class ECDICTStubURLProtocol: URLProtocol {
    private static let atomData =
        OSAllocatedUnfairLock<Data>(initialState: Data())
    private static let archiveData =
        OSAllocatedUnfairLock<Data>(initialState: Data())
    private static let paths =
        OSAllocatedUnfairLock<[String]>(initialState: [])

    static func configure(
        atom: Data,
        archive: Data
    ) {
        atomData.withLock { $0 = atom }
        archiveData.withLock { $0 = archive }
        paths.withLock { $0 = [] }
    }

    static var requestedPaths: [String] {
        paths.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "ecdict.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        ECDICTStubURLProtocol.paths.withLock {
            $0.append(path)
        }
        let isAtom = path == "/commits.atom"
        let body = isAtom
            ? ECDICTStubURLProtocol.atomData.withLock { $0 }
            : ECDICTStubURLProtocol.archiveData.withLock { $0 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type":
                    isAtom
                    ? "application/atom+xml"
                    : "application/gzip",
                "Content-Length": String(body.count),
            ]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ECDICTUpdateServiceTests: XCTestCase {
    func testInstallsNewerArchiveAndSkipsSecondCheck() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent(
            "bundled",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundled,
            withIntermediateDirectories: true
        )
        try writeDictionary(
            sourceDate: "2026-10-19T00:00:00Z",
            sourceRevision: oldECDICTRevision,
            translation: "旧词, 旧释义",
            english: "old word",
            directory: bundled
        )
        let csv = makeCSV(
            translation: "新词, 新释义",
            english: "new word"
        )
        ECDICTStubURLProtocol.configure(
            atom: makeAtom(revision: newECDICTRevision),
            archive: try makeTarGzip(
                csv: csv,
                entryName: "ECDICT-\(newECDICTRevision)/ecdict.csv"
            )
        )
        let manager = PluginManager(baseDirectory: root)
        let service = makeService(
            manager: manager,
            bundledDirectory: bundled
        )

        let updated = try await service.checkForUpdate()

        XCTAssertTrue(updated.didUpdate)
        XCTAssertEqual(updated.version, "2026.10.20")
        let installed = await manager.installedPlugin(
            id: "dict-ecdict"
        )
        XCTAssertEqual(installed?.revision, newECDICTRevision)
        XCTAssertEqual(installed?.coreUpdateKind, .ecdict)
        XCTAssertEqual(
            installed?.sourceChecksum,
            SHA256.hash(data: csv).map {
                String(format: "%02x", $0)
            }.joined()
        )
        let installedDirectory = await manager.pluginDirectory(
            for: "dict-ecdict"
        )
        let ranker = ECDICTRanker(
            databaseURL: installedDirectory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
        )
        XCTAssertEqual(
            ranker.fallbackCandidates(term: "新词", limit: 3),
            ["new word"]
        )

        let second = try await service.checkForUpdate()
        XCTAssertFalse(second.didUpdate)
        XCTAssertEqual(second.version, "2026.10.20")
        XCTAssertEqual(
            ECDICTStubURLProtocol.requestedPaths,
            [
                "/commits.atom",
                "/ECDICT/tar.gz/\(newECDICTRevision)",
                "/commits.atom",
            ]
        )
    }

    func testInvalidArchiveKeepsBundledDictionary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent(
            "bundled",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundled,
            withIntermediateDirectories: true
        )
        try writeDictionary(
            sourceDate: "2026-10-19T00:00:00Z",
            sourceRevision: oldECDICTRevision,
            translation: "旧词, 旧释义",
            english: "old word",
            directory: bundled
        )
        ECDICTStubURLProtocol.configure(
            atom: makeAtom(revision: newECDICTRevision),
            archive: Data(repeating: 0x7F, count: 1_000_100)
        )
        let manager = PluginManager(baseDirectory: root)
        let service = makeService(
            manager: manager,
            bundledDirectory: bundled
        )

        do {
            _ = try await service.checkForUpdate()
            XCTFail("损坏的归档不应安装")
        } catch {
            XCTAssertEqual(
                error as? ECDICTUpdateError,
                .invalidArchive
            )
        }

        let installed = await manager.installedPlugin(
            id: "dict-ecdict"
        )
        XCTAssertNil(installed)
        let ranker = ECDICTRanker(
            databaseURL: bundled.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
        )
        XCTAssertEqual(
            ranker.fallbackCandidates(term: "旧词", limit: 3),
            ["old word"]
        )
    }

    private func makeService(
        manager: PluginManager,
        bundledDirectory: URL
    ) -> ECDICTUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ECDICTStubURLProtocol.self]
        return ECDICTUpdateService(
            pluginManager: manager,
            bundledDirectory: bundledDirectory,
            session: URLSession(configuration: configuration),
            atomURL: URL(
                string: "https://ecdict.test/commits.atom"
            )!,
            archiveURLTemplate:
                "https://ecdict.test/ECDICT/tar.gz/{revision}",
            minimumTermCount: 1,
            minimumRankCount: 1
        )
    }

    private func writeDictionary(
        sourceDate: String,
        sourceRevision: String,
        translation: String,
        english: String,
        directory: URL
    ) throws {
        let csvURL = directory.appendingPathComponent("source.csv")
        let csv = makeCSV(
            translation: translation,
            english: english
        )
        try csv.write(to: csvURL)
        let databaseURL = directory.appendingPathComponent(
            "ecdict_rank.sqlite3"
        )
        try ECDICTRankBuilder.build(
            fromCSVURL: csvURL,
            to: databaseURL,
            sourceChecksum: SHA256.hash(data: csv).map {
                String(format: "%02x", $0)
            }.joined(),
            sourceDate: sourceDate,
            sourceRevision: sourceRevision
        )
        let manifest = PluginManifest(
            id: "dict-ecdict",
            type: .dictionary,
            name: "ECDICT Rank Index",
            version: String(sourceDate.prefix(10)).replacingOccurrences(
                of: "-",
                with: "."
            ),
            runtime: "ecdict-rank",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://ecdict.test/source.csv")!,
            license: "MIT",
            minRAMBytes: 0,
            summary: nil,
            revision: sourceRevision,
            source: .bundled,
            sourceDate: sourceDate,
            sourceChecksum: SHA256.hash(data: csv).map {
                String(format: "%02x", $0)
            }.joined()
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(
                PluginManifest.fileName
            )
        )
    }

    private func makeCSV(
        translation: String,
        english: String
    ) -> Data {
        Data(
            """
            word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
            \(english),,,"\(translation)",,,1,,,100,,
            """.utf8
        )
    }

    private func makeAtom(revision: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <id>tag:github.com,2008:Grit::Commit/\(revision)</id>
                <updated>2026-10-20T02:25:07Z</updated>
              </entry>
            </feed>
            """.utf8
        )
    }

    private func makeTarGzip(
        csv: Data,
        entryName: String
    ) throws -> Data {
        var header = [UInt8](repeating: 0, count: 512)
        writeText(entryName, to: &header, at: 0, count: 100)
        writeOctal("0000644", to: &header, at: 100, count: 8)
        writeOctal("0000000", to: &header, at: 108, count: 8)
        writeOctal("0000000", to: &header, at: 116, count: 8)
        writeOctal(
            String(csv.count, radix: 8),
            to: &header,
            at: 124,
            count: 12
        )
        writeOctal(
            "00000000000",
            to: &header,
            at: 136,
            count: 12
        )
        for index in 148..<156 {
            header[index] = 0x20
        }
        header[156] = Character("0").asciiValue!
        writeText("ustar", to: &header, at: 257, count: 6)
        writeText("00", to: &header, at: 263, count: 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        writeOctal(
            String(checksum, radix: 8),
            to: &header,
            at: 148,
            count: 6
        )
        header[154] = 0
        header[155] = 0x20

        var archive = Data(header)
        archive.append(csv)
        let padding = (512 - csv.count % 512) % 512
        archive.append(Data(repeating: 0, count: padding))
        archive.append(Data(repeating: 0, count: 1_024))
        var compressed = try gzip(archive)
        if compressed.count < 1_000_100 {
            compressed.append(
                Data(
                    repeating: 0,
                    count: 1_000_100 - compressed.count
                )
            )
        }
        return compressed
    }

    private func writeOctal(
        _ value: String,
        to bytes: inout [UInt8],
        at offset: Int,
        count: Int
    ) {
        let encoded = Array(value.utf8.prefix(count))
        let padded =
            String(
                repeating: "0",
                count: max(0, count - encoded.count)
            )
            + String(decoding: encoded, as: UTF8.self)
        writeText(padded, to: &bytes, at: offset, count: count)
    }

    private func writeText(
        _ value: String,
        to bytes: inout [UInt8],
        at offset: Int,
        count: Int
    ) {
        let encoded = Array(value.utf8.prefix(count))
        bytes.replaceSubrange(
            offset..<(offset + encoded.count),
            with: encoded
        )
    }

    private func gzip(_ data: Data) throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        guard let handle = gzopen(file.path, "wb") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bytes = [UInt8](data)
        let written = bytes.withUnsafeBytes {
            gzwrite(handle, $0.baseAddress, UInt32(bytes.count))
        }
        guard written == bytes.count, gzclose(handle) == Z_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintECDICTUpdateTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
