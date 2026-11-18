import CryptoKit
import Foundation
import GlintCore

extension PluginCatalogService {
    func findManifest(in directory: URL) -> URL? {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else {
            return nil
        }
        for case let url as URL in enumerator
        where url.lastPathComponent == PluginManifest.fileName {
            return url
        }
        return nil
    }

    func validatePluginContents(in directory: URL) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            )
        else {
            throw PluginCatalogError.extractionFailed
        }
        let rejectedExtensions: Set<String> = [
            "app", "bundle", "command", "dylib", "framework", "jar",
            "js", "o", "py", "rb", "sh", "so", "a",
        ]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw PluginCatalogError.unsafeContent
            }
            let pathExtension = url.pathExtension.lowercased()
            if rejectedExtensions.contains(pathExtension) {
                throw PluginCatalogError.unsafeContent
            }
            guard values.isRegularFile == true else { continue }
            if fileManager.isExecutableFile(atPath: url.path)
                || Self.hasExecutableMagic(url)
            {
                throw PluginCatalogError.unsafeContent
            }
        }
    }

    static func hasExecutableMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4),
            data.count == 4
        else {
            return false
        }
        let bytes = Array(data)
        if bytes.starts(with: [0x23, 0x21]) {
            return true
        }
        return [
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xFE, 0xED, 0xFA, 0xCF],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xBE, 0xBA, 0xFE, 0xCA],
            [0xCA, 0xFE, 0xBA, 0xBF],
            [0xBF, 0xBA, 0xFE, 0xCA],
        ].contains(bytes)
    }

    func isValidDownloadedArchive(
        _ url: URL,
        for manifest: PluginManifest
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path),
            manifest.sha256 != "REPLACE_ME"
        else {
            return false
        }
        if manifest.sizeBytes > 0 {
            guard fileSize(at: url) == manifest.sizeBytes else {
                return false
            }
        }
        return try Self.sha256(of: url) == manifest.sha256.lowercased()
    }

    static func downloadIdentifier(_ value: String) -> String {
        DigestHex.string(for: SHA256.hash(data: Data(value.utf8)))
    }

    static func partialDownloadURL(for url: URL) -> URL {
        url.appendingPathExtension("glint-part")
    }

    static func repositoryID(
        from url: URL,
        pathPrefix: String? = nil
    ) -> String? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= (pathPrefix == nil ? 2 : 3) else {
            return nil
        }
        if let pathPrefix {
            guard components[0] == pathPrefix else { return nil }
            return "\(components[1])/\(components[2])"
        }
        return "\(components[0])/\(components[1])"
    }

    static func fileURL(
        base: String,
        path: String
    ) -> URL? {
        guard var url = URL(string: base) else { return nil }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    static func huggingFaceEndpoints(
        for manifestURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        HuggingFaceRemotePolicy.endpoints(
            for: manifestURL,
            environment: environment
        )
    }

    static func isAllowedRemoteURL(_ url: URL) -> Bool {
        HuggingFaceRemotePolicy.isAllowedRemoteURL(url)
    }

    static func isAllowedModelScopeURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
            let host = url.host?.lowercased()
        else {
            return false
        }
        return host == "modelscope.cn" || host == "www.modelscope.cn"
    }

    static func shouldInstallModelFile(_ name: String) -> Bool {
        guard !name.hasPrefix("."),
            !name.hasPrefix("README"),
            !name.contains("/."),
            !name.split(separator: "/").contains("..")
        else {
            return false
        }
        return name.hasSuffix(".safetensors")
            || name.hasSuffix(".json")
            || name.hasSuffix(".jinja")
            || name.hasSuffix(".txt")
            || name.hasSuffix(".model")
            || name.hasSuffix(".spm")
            || name.hasSuffix(".tiktoken")
    }

    static func hasRequiredRuntimeFiles(
        for manifest: PluginManifest,
        in directory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        let requiredNames: [String]
        switch manifest.runtime {
        case "sqlite-v1":
            requiredNames = ["dictionary.sqlite3"]
        case "cedict-sqlite":
            requiredNames = ["cedict.sqlite3"]
        case "ecdict-rank":
            requiredNames = ["ecdict_rank.sqlite3"]
        case "ctranslate2-data":
            guard
                manifest.id == ManagedTranslationModelIDs.opusMT
            else {
                return false
            }
            requiredNames = [
                "model/model.bin",
                "model/config.json",
                "model/shared_vocabulary.json",
                "model/source.spm",
                "model/target.spm",
            ]
        default:
            requiredNames = []
        }
        guard !requiredNames.isEmpty else { return false }
        return requiredNames.allSatisfy {
            fileManager.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
    }

    static func isCompleteModelSnapshot(
        _ files: [SnapshotDownloadFile]
    ) -> Bool {
        let names = Set(files.map(\.path))
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        let hasTokenizer =
            names.contains("tokenizer.json")
            || names.contains { $0.hasSuffix(".model") }
            || names.contains { $0.hasSuffix(".spm") }
        return names.contains("config.json") && hasWeights && hasTokenizer
    }

    static func safeDestination(for path: String, in root: URL) -> URL? {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard !components.isEmpty,
            !components.contains(where: { $0 == ".." })
        else {
            return nil
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    static func sha256(
        of url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let totalBytes =
            (attributes[.size] as? NSNumber)?.intValue ?? 0
        var hasher = SHA256()
        var processedBytes = 0
        while let data = try handle.read(upToCount: 4 * 1024 * 1024),
            !data.isEmpty
        {
            try Task.checkCancellation()
            hasher.update(data: data)
            processedBytes += data.count
            if totalBytes > 0 {
                progress?(
                    min(1, Double(processedBytes) / Double(totalBytes))
                )
            }
        }
        progress?(1)
        return DigestHex.string(for: hasher.finalize())
    }

    func fileSize(at url: URL) -> Int64? {
        guard
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }
}
