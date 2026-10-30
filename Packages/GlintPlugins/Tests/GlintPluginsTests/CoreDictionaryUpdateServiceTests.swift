import Foundation
import GlintCore
import GlintDictionary
import os
import SQLite3
import XCTest
import zlib

@testable import GlintPlugins

private final class CedictStubURLProtocol: URLProtocol {
    private static let responseData =
        OSAllocatedUnfairLock<Data?>(initialState: nil)
    private static let requests =
        OSAllocatedUnfairLock<[String]>(initialState: [])
    private static let responseETag = OSAllocatedUnfairLock(
        initialState: "\"snapshot-20261028\""
    )

    static func configure(
        gzip: Data,
        etag: String = "\"snapshot-20261028\""
    ) {
        responseData.withLock { $0 = gzip }
        responseETag.withLock { $0 = etag }
        requests.withLock { $0 = [] }
    }

    static var requestedMethods: [String] {
        requests.withLock { $0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cedict.test"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        Self.requests.withLock {
            $0.append(method)
        }
        let etag = Self.responseETag.withLock { $0 }
        var headers = [
            "ETag": etag,
            "Last-Modified": "Wed, 28 Oct 2026 09:16:04 GMT",
        ]
        if request.value(forHTTPHeaderField: "If-None-Match")
            == etag
        {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if let data = Self.responseData.withLock({ $0 }) {
            headers["Content-Length"] = String(data.count)
        }
        guard
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if request.httpMethod != "HEAD",
            let data = Self.responseData.withLock({ $0 })
        {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CoreDictionaryUpdateServiceTests: XCTestCase {
    func testRepairReplacesInstalledLegacySchemaWithBundledDictionary()
        async throws
    {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent(
            "bundled",
            isDirectory: true
        )
        let installed = root.appendingPathComponent(
            "installed",
            isDirectory: true
        )
        for directory in [bundled, installed] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try writeDictionary(
            sourceDate: "2026-10-28T00:15:09Z",
            word: "新词",
            gloss: "new word",
            directory: bundled
        )
        try writeLegacyDictionary(
            sourceDate: "2026-10-20T00:00:00Z",
            word: "旧词",
            gloss: "old",
            directory: installed
        )
        let manager = PluginManager(baseDirectory: root)
        _ = try await manager.installPreparedPlugin(at: installed)
        let service = CoreDictionaryUpdateService(
            pluginManager: manager,
            bundledDirectory: bundled
        )

        let repaired = try await service.repairInstalledCopyIfNeeded()

        XCTAssertTrue(repaired)
        let installedDirectory = await manager.pluginDirectory(
            for: "dict-cedict"
        )
        let database = installedDirectory.appendingPathComponent(
            "cedict.sqlite3"
        )
        XCTAssertTrue(
            CedictDatabaseBuilder.isCompatible(databaseURL: database)
        )
        let dictionary = CedictDictionary(
            databaseURL: database,
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "新词", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "new word")
    }

    func testInstallsNewerDictionaryAndSkipsSecondCheck() async throws {
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
            sourceDate: "2026-10-20T00:00:00Z",
            word: "旧词",
            gloss: "old",
            directory: bundled
        )

        let gzip = try makeGzip(
            """
            # CC-CEDICT
            #! date=2026-10-28T00:15:09Z
            新词 新詞 [xin1 ci2] /new word/
            """
        )
        CedictStubURLProtocol.configure(gzip: gzip)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CedictStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName =
            "GlintCoreDictionaryUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        let manager = PluginManager(baseDirectory: root)
        let service = CoreDictionaryUpdateService(
            pluginManager: manager,
            bundledDirectory: bundled,
            session: session,
            defaults: defaults,
            sourceURL: URL(string: "https://cedict.test/cedict.gz")!,
            minimumEntryCount: 1,
            minimumSenseCount: 1
        )

        let updated: CoreDictionaryUpdateResult
        do {
            updated = try await service.checkForUpdate()
        } catch {
            XCTFail(
                """
                更新失败：\(error)，请求=\(CedictStubURLProtocol.requestedMethods)
                """
            )
            throw error
        }

        XCTAssertTrue(updated.didUpdate)
        XCTAssertEqual(updated.version, "2026.10.28")
        let installed = await manager.installedPlugin(
            id: "dict-cedict"
        )
        XCTAssertEqual(installed?.version, "2026.10.28")
        XCTAssertEqual(installed?.coreUpdateKind, .cedict)
        let installedDirectory = await manager.pluginDirectory(
            for: "dict-cedict"
        )
        let dictionary = CedictDictionary(
            databaseURL: installedDirectory.appendingPathComponent(
                "cedict.sqlite3"
            ),
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "新词", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "new word")

        let second = try await service.checkForUpdate()
        XCTAssertFalse(second.didUpdate)
        XCTAssertEqual(second.version, "2026.10.28")
    }

    func testSameDaySnapshotWithChangedETagInstalls() async throws {
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
            sourceDate: "2026-10-27T00:00:00Z",
            word: "旧词",
            gloss: "old",
            directory: bundled
        )
        CedictStubURLProtocol.configure(
            gzip: try makeGzip(
                """
                # CC-CEDICT
                #! date=2026-10-28T00:15:09Z
                首词 首詞 [shou3 ci2] /first snapshot/
                """
            ),
            etag: "\"snapshot-a\""
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CedictStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName =
            "GlintCoreDictionaryUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        let manager = PluginManager(baseDirectory: root)
        let service = CoreDictionaryUpdateService(
            pluginManager: manager,
            bundledDirectory: bundled,
            session: session,
            defaults: defaults,
            sourceURL: URL(string: "https://cedict.test/cedict.gz")!,
            minimumEntryCount: 1,
            minimumSenseCount: 1
        )

        let first = try await service.checkForUpdate()
        XCTAssertTrue(first.didUpdate)

        CedictStubURLProtocol.configure(
            gzip: try makeGzip(
                """
                # CC-CEDICT
                #! date=2026-10-28T09:16:04Z
                新词 新詞 [xin1 ci2] /replacement snapshot/
                """
            ),
            etag: "\"snapshot-b\""
        )
        let second = try await service.checkForUpdate()
        XCTAssertTrue(second.didUpdate)
        XCTAssertEqual(second.version, "2026.10.28")

        let installedDirectory = await manager.pluginDirectory(
            for: "dict-cedict"
        )
        let dictionary = CedictDictionary(
            databaseURL: installedDirectory.appendingPathComponent(
                "cedict.sqlite3"
            ),
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "新词", kind: .word)
        )
        XCTAssertEqual(
            result?.options.first?.text,
            "replacement snapshot"
        )
    }

    func testInvalidDownloadKeepsExistingDictionary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent(
            "bundled",
            isDirectory: true
        )
        let installed = root.appendingPathComponent(
            "installed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundled,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: installed,
            withIntermediateDirectories: true
        )
        try writeDictionary(
            sourceDate: "2026-10-20T00:00:00Z",
            word: "内置词",
            gloss: "bundled",
            directory: bundled
        )
        try writeDictionary(
            sourceDate: "2026-10-22T00:00:00Z",
            word: "现有词",
            gloss: "installed",
            directory: installed
        )

        let manager = PluginManager(baseDirectory: root)
        _ = try await manager.installPreparedPlugin(at: installed)
        CedictStubURLProtocol.configure(
            gzip: Data("not a gzip file".utf8)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CedictStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName =
            "GlintCoreDictionaryUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        let service = CoreDictionaryUpdateService(
            pluginManager: manager,
            bundledDirectory: bundled,
            session: session,
            defaults: defaults,
            sourceURL: URL(string: "https://cedict.test/cedict.gz")!,
            minimumEntryCount: 1,
            minimumSenseCount: 1
        )

        do {
            _ = try await service.checkForUpdate()
            XCTFail("损坏的下载不应被视为更新成功")
        } catch {
            XCTAssertEqual(
                CedictStubURLProtocol.requestedMethods,
                ["HEAD", "GET"]
            )
            XCTAssertEqual(
                error as? CoreDictionaryUpdateError,
                .missingSourceDate
            )
        }

        let existing = await manager.installedPlugin(
            id: "dict-cedict"
        )
        XCTAssertEqual(existing?.version, "2026.10.22")
        let installedDirectory = await manager.pluginDirectory(
            for: "dict-cedict"
        )
        let dictionary = CedictDictionary(
            databaseURL: installedDirectory.appendingPathComponent(
                "cedict.sqlite3"
            ),
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "现有词", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "installed")
    }

    func testImplausibleSnapshotDoesNotInstall() async throws {
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
            sourceDate: "2026-10-20T00:00:00Z",
            word: "旧词",
            gloss: "old",
            directory: bundled
        )
        CedictStubURLProtocol.configure(
            gzip: try makeGzip(
                """
                #! date=2026-10-28T00:15:09Z
                新词 新詞 [xin1 ci2] /new word/
                """
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CedictStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suiteName =
            "GlintCoreDictionaryUpdateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: suiteName
            )
        }
        let manager = PluginManager(baseDirectory: root)
        let service = CoreDictionaryUpdateService(
            pluginManager: manager,
            bundledDirectory: bundled,
            session: session,
            defaults: defaults,
            sourceURL: URL(string: "https://cedict.test/cedict.gz")!,
            minimumEntryCount: 10,
            minimumSenseCount: 10
        )

        do {
            _ = try await service.checkForUpdate()
            XCTFail("数据量异常的快照不应安装")
        } catch CoreDictionaryUpdateError.implausibleDatabase {
        } catch {
            XCTFail("收到意外错误：\(error)")
        }

        let installed = await manager.installedPlugin(
            id: "dict-cedict"
        )
        XCTAssertNil(installed)
        let dictionary = CedictDictionary(
            databaseURL: bundled.appendingPathComponent(
                "cedict.sqlite3"
            ),
            ranker: nil
        )
        let result = try await dictionary.lookup(
            Candidate(text: "旧词", kind: .word)
        )
        XCTAssertEqual(result?.options.first?.text, "old")
    }

    private func writeDictionary(
        sourceDate: String,
        word: String,
        gloss: String,
        directory: URL
    ) throws {
        let gzip = try makeGzip(
            """
            #! date=\(sourceDate)
            \(word) \(word) [test] /\(gloss)/
            """
        )
        let gzipURL = directory.appendingPathComponent("source.gz")
        try gzip.write(to: gzipURL)
        let databaseURL = directory.appendingPathComponent(
            "cedict.sqlite3"
        )
        try CedictDatabaseBuilder.build(
            fromGzipURL: gzipURL,
            to: databaseURL
        )
        let manifest = PluginManifest(
            id: "dict-cedict",
            type: .dictionary,
            name: "CC-CEDICT",
            version: sourceDate.prefix(10).replacingOccurrences(
                of: "-",
                with: "."
            ),
            runtime: "cedict-sqlite",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://cedict.test/source.gz")!,
            license: "CC-BY-SA-4.0",
            minRAMBytes: 0,
            source: .bundled,
            sourceDate: sourceDate,
            coreUpdateKind: .cedict
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(
                PluginManifest.fileName
            )
        )
    }

    private func writeLegacyDictionary(
        sourceDate: String,
        word: String,
        gloss: String,
        directory: URL
    ) throws {
        let databaseURL = directory.appendingPathComponent(
            "cedict.sqlite3"
        )
        var database: OpaquePointer?
        guard
            sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
                nil
            ) == SQLITE_OK,
            let database
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE entries (
                sense_id INTEGER PRIMARY KEY,
                simplified TEXT NOT NULL,
                traditional TEXT NOT NULL,
                pinyin TEXT NOT NULL,
                gloss TEXT NOT NULL,
                line_order INTEGER NOT NULL,
                sense_order INTEGER NOT NULL
            );
            INSERT INTO metadata(key, value) VALUES
                ('schema', 'cc-cedict-senses-v2'),
                ('source_date', '\(sourceDate)'),
                ('entry_count', '1'),
                ('sense_count', '1');
            INSERT INTO entries(
                simplified,
                traditional,
                pinyin,
                gloss,
                line_order,
                sense_order
            ) VALUES ('\(word)', '\(word)', 'test', '\(gloss)', 1, 0);
            PRAGMA user_version = 2;
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        let manifest = PluginManifest(
            id: "dict-cedict",
            type: .dictionary,
            name: "CC-CEDICT",
            version: sourceDate.prefix(10).replacingOccurrences(
                of: "-",
                with: "."
            ),
            runtime: "cedict-sqlite",
            sizeBytes: 1,
            sha256: "legacy",
            url: URL(string: "https://cedict.test/source.gz")!,
            license: "CC-BY-SA-4.0",
            minRAMBytes: 0,
            source: .bundled,
            sourceDate: sourceDate,
            coreUpdateKind: .cedict
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(
                PluginManifest.fileName
            )
        )
    }

    private func makeGzip(_ text: String) throws -> Data {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        guard let handle = gzopen(file.path, "wb") else {
            throw CocoaError(.fileWriteUnknown)
        }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBytes {
            gzwrite(
                handle,
                $0.baseAddress,
                UInt32(bytes.count)
            )
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
                "GlintCoreDictionaryServiceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
