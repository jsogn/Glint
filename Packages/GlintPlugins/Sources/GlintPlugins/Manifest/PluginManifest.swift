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

public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let type: PluginKind
    public let name: String
    public let version: String
    public let runtime: String
    public let capabilities: [String]
    public let languages: [String]
    public let sizeBytes: Int64
    public let sha256: String
    public let url: URL
    public let license: String
    public let minRAMBytes: Int64
    public let quality: String
    public let recommended: Bool
    public let summary: String?
    public let revision: String?
    public let source: PluginSource?
    public let promptProfile: TranslationPromptProfile?

    public init(
        id: String,
        type: PluginKind,
        name: String,
        version: String,
        runtime: String,
        capabilities: [String],
        languages: [String],
        sizeBytes: Int64,
        sha256: String,
        url: URL,
        license: String,
        minRAMBytes: Int64,
        quality: String,
        recommended: Bool,
        summary: String? = nil,
        revision: String? = nil,
        source: PluginSource? = .catalog,
        promptProfile: TranslationPromptProfile? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.version = version
        self.runtime = runtime
        self.capabilities = capabilities
        self.languages = languages
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.url = url
        self.license = license
        self.minRAMBytes = minRAMBytes
        self.quality = quality
        self.recommended = recommended
        self.summary = summary
        self.revision = revision
        self.source = source
        self.promptProfile = promptProfile
    }
}
