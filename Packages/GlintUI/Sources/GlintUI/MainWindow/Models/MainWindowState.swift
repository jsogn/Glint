import Foundation
import GlintPlugins

public struct PluginUpdateInfo: Sendable, Equatable {
    public let currentVersion: String
    public let availableVersion: String
}

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

public struct CoreDictionaryUpdateState: Equatable, Sendable {
    public let isChecking: Bool
    public let statusText: String?
    public let isError: Bool
}

public struct TranslationModelUpdateState: Equatable, Sendable {
    public let isChecking: Bool
    public let statusText: String?
    public let isError: Bool
    public let update: UpstreamModelUpdate?
}

enum SystemTranslationSetupState: Equatable, Sendable {
    case installationRequired
    case installationIncomplete
    case installing
    case failed(String)
    case unsupported
}
