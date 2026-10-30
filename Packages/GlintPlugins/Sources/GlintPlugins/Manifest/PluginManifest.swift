import Foundation
import GlintCore

public enum PluginKind: String, Codable, Sendable {
    case dictionary
    case translation
}

public enum PluginSource: String, Codable, Sendable {
    case bundled
    case catalog
    case local
}

public enum CoreDictionaryUpdateKind: String, Codable, Sendable {
    case cedict
    case ecdict
}

enum PluginRuntimePolicy {
    static func supportsDownloadedRuntime(
        _ manifest: PluginManifest
    ) -> Bool {
        switch manifest.type {
        case .translation:
            if manifest.runtime == "mlx" {
                return true
            }
            return manifest.runtime == "ctranslate2-data"
                && manifest.id == TranslationModelSelection.opusMTModelID
                && manifest.source == .catalog
        case .dictionary:
            return [
                "sqlite-v1",
                "cedict-sqlite",
                "ecdict-rank",
            ].contains(manifest.runtime)
        }
    }
}

public struct PluginManifest: Codable, Sendable, Equatable {
    public static let fileName = "manifest.json"

    public let id: String
    public let type: PluginKind
    public let name: String
    public let version: String
    public let runtime: String
    public let sizeBytes: Int64
    public let sha256: String
    public let url: URL
    public let license: String
    public let minRAMBytes: Int64
    public let summary: String?
    public let revision: String?
    public let modelscopeURL: URL?
    public let source: PluginSource
    public let sourceDate: String?
    public let sourceChecksum: String?
    public let coreUpdateKind: CoreDictionaryUpdateKind?
    public let promptProfile: TranslationPromptProfile?

    public init(
        id: String,
        type: PluginKind,
        name: String,
        version: String,
        runtime: String,
        sizeBytes: Int64,
        sha256: String,
        url: URL,
        license: String,
        minRAMBytes: Int64,
        summary: String? = nil,
        revision: String? = nil,
        modelscopeURL: URL? = nil,
        source: PluginSource = .catalog,
        sourceDate: String? = nil,
        sourceChecksum: String? = nil,
        coreUpdateKind: CoreDictionaryUpdateKind? = nil,
        promptProfile: TranslationPromptProfile? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.version = version
        self.runtime = runtime
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.url = url
        self.license = license
        self.minRAMBytes = minRAMBytes
        self.summary = summary
        self.revision = revision
        self.modelscopeURL = modelscopeURL
        self.source = source
        self.sourceDate = sourceDate
        self.sourceChecksum = sourceChecksum
        self.coreUpdateKind = coreUpdateKind
        self.promptProfile = promptProfile
    }

    public static func load(from directory: URL) throws -> PluginManifest {
        let data = try Data(
            contentsOf: directory.appendingPathComponent(Self.fileName)
        )
        return try JSONDecoder().decode(Self.self, from: data)
    }

}
