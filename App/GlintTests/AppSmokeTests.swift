import AppKit
import GlintDictionary
import GlintPlugins
import XCTest
import GlintCore

final class AppSmokeTests: XCTestCase {
    private var appBundleURL: URL {
        Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Glint.app", isDirectory: true)
    }

    func testCandidateModel() {
        let candidate = Candidate(text: "你好", kind: .word)
        XCTAssertEqual(candidate.text, "你好")
        XCTAssertEqual(candidate.kind, .word)
    }

    func testDictionaryPOSProviderRefreshesAfterPluginReplacement()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintDictionaryReloadTest-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let oldPlugin = root.appendingPathComponent(
            "old",
            isDirectory: true
        )
        let newPlugin = root.appendingPathComponent(
            "new",
            isDirectory: true
        )
        try makeECDICTPlugin(
            at: oldPlugin,
            english: "oldreloadword",
            translation: "n. 旧词性"
        )
        try makeECDICTPlugin(
            at: newPlugin,
            english: "newreloadword",
            translation: "v. 新词性"
        )
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = appBundleURL.appendingPathComponent(
            "Contents/MacOS/Glint"
        )
        process.arguments = [
            "--dictionary-pos-reload-check",
            oldPlugin.path,
            newPlugin.path,
            "oldreloadword",
            "newreloadword",
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        try process.run()
        guard
            finished.wait(timeout: .now() + 10) == .success
        else {
            process.terminate()
            XCTFail("Dictionary reload check timed out")
            return
        }

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "stdout:\n\(output)\nstderr:\n\(error)"
        )
        XCTAssertTrue(
            output.contains("before=noun"),
            "stdout:\n\(output)\nstderr:\n\(error)"
        )
        XCTAssertTrue(
            output.contains("after=verb"),
            "stdout:\n\(output)\nstderr:\n\(error)"
        )
    }

    func testMenuBarIconVariantsShareTemplateCanvas() throws {
        let resources = try XCTUnwrap(Bundle(url: appBundleURL))
        let enabled = try XCTUnwrap(
            resources.image(forResource: "BrandMark")
        )
        let disabled = try XCTUnwrap(
            resources.image(forResource: "BrandMarkOff")
        )

        XCTAssertTrue(enabled.isTemplate)
        XCTAssertTrue(disabled.isTemplate)
        XCTAssertEqual(enabled.size.width, disabled.size.width, accuracy: 0.001)
        XCTAssertEqual(enabled.size.height, disabled.size.height, accuracy: 0.001)
        XCTAssertNotEqual(enabled.tiffRepresentation, disabled.tiffRepresentation)
    }

    func testAppTargetsMacOS15() throws {
        let resources = try XCTUnwrap(Bundle(url: appBundleURL))
        XCTAssertEqual(
            resources.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            "15.0"
        )
    }

    func testAppBundlesSquirrelBridgeAssets() throws {
        let helper = appBundleURL.appendingPathComponent(
            "Contents/Helpers/RimeCandidateBridge"
        )
        let luaDirectory = appBundleURL.appendingPathComponent(
            "Contents/Resources/RimeCandidateBridge",
            isDirectory: true
        )

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helper.path)
        )
        for fileName in ["candidate_bridge.lua", "json.lua"] {
            let file = luaDirectory.appendingPathComponent(fileName)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: file.path)
            )
            XCTAssertGreaterThan(
                try Data(contentsOf: file).count,
                0
            )
        }
    }

    func testAppBundlesOnlyCoreDictionaries() {
        let resources = appBundleURL.appendingPathComponent(
            "Contents/Resources",
            isDirectory: true
        )

        for dictionaryID in ["dict-cedict", "dict-ecdict"] {
            let dictionaryURL = resources.appendingPathComponent(
                dictionaryID
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: dictionaryURL.path
                )
            )
        }
        let wiktionaryURL = resources.appendingPathComponent(
            "dict-wiktionary-zh-en"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: wiktionaryURL.path
            )
        )
    }

    private func makeECDICTPlugin(
        at directory: URL,
        english: String,
        translation: String
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let csv = directory.appendingPathComponent("source.csv")
        try Data(
            """
            word,phonetic,definition,translation,pos,collins,oxford,tag,bnc,frq,exchange,detail,audio
            \(english),,,"\(translation)",,1,0,,,100,,
            """.utf8
        ).write(to: csv)
        try ECDICTRankBuilder.build(
            fromCSVURL: csv,
            to: directory.appendingPathComponent(
                "ecdict_rank.sqlite3"
            )
        )
        let manifest = PluginManifest(
            id: "dict-ecdict",
            type: .dictionary,
            name: "ECDICT Rank Index",
            version: "test",
            runtime: "ecdict-rank",
            sizeBytes: 1,
            sha256: "test",
            url: URL(string: "https://ecdict.test/source.csv")!,
            license: "MIT",
            minRAMBytes: 0,
            source: .bundled,
            coreUpdateKind: .ecdict
        )
        try JSONEncoder().encode(manifest).write(
            to: directory.appendingPathComponent(
                PluginManifest.fileName
            )
        )
    }
}
