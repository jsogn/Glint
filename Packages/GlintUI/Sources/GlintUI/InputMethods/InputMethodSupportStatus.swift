import Foundation

public enum InputMethodSupportState: String, Sendable, Equatable {
    case native
    case available
    case installed
    case repairRequired
    case manualSetupRequired
    case unavailable
}

public struct InputMethodSupportStatus:
    Identifiable,
    Sendable,
    Equatable
{
    public let id: String
    public let name: String
    public let detail: String
    public let state: InputMethodSupportState
    public let schemaIDs: [String]
    public let protocolVersion: Int?
    public let isExperimental: Bool

    public init(
        id: String,
        name: String,
        detail: String,
        state: InputMethodSupportState,
        schemaIDs: [String],
        protocolVersion: Int?,
        isExperimental: Bool = false
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.state = state
        self.schemaIDs = schemaIDs
        self.protocolVersion = protocolVersion
        self.isExperimental = isExperimental
    }

    public static let applePinyin = InputMethodSupportStatus(
        id: "apple-pinyin",
        name: "简体拼音",
        detail: "原生读取当前候选，无需额外安装。",
        state: .native,
        schemaIDs: [],
        protocolVersion: nil
    )
}
