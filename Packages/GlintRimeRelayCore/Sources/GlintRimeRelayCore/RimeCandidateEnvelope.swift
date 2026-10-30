import Foundation

public struct RimeCandidateEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 3

    public let version: Int
    public let sessionID: String
    public let sequence: UInt64
    public let heartbeat: Bool
    public let active: Bool
    public let schemaID: String?
    public let selectedText: String?
    public let selectedIndex: Int?
    public let candidates: [String]

    public init(
        version: Int = Self.currentVersion,
        sessionID: String,
        sequence: UInt64,
        heartbeat: Bool,
        active: Bool,
        schemaID: String?,
        selectedText: String?,
        selectedIndex: Int?,
        candidates: [String]
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sequence = sequence
        self.heartbeat = heartbeat
        self.active = active
        self.schemaID = schemaID
        self.selectedText = selectedText
        self.selectedIndex = selectedIndex
        self.candidates = candidates
    }

    public var isValid: Bool {
        guard version == Self.currentVersion else { return false }
        guard
            !sessionID.isEmpty,
            sessionID.count <= 128
        else {
            return false
        }
        guard active else {
            return selectedText == nil
                && selectedIndex == nil
                && candidates.isEmpty
        }
        guard
            let selectedText,
            !selectedText.isEmpty,
            selectedText.count <= 256,
            candidates.count <= 20
        else {
            return false
        }
        guard
            candidates.allSatisfy({
                !$0.isEmpty && $0.count <= 256
            })
        else {
            return false
        }
        guard let selectedIndex else {
            return true
        }
        return candidates.indices.contains(selectedIndex)
            && candidates[selectedIndex] == selectedText
    }

    public static func decode(line: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: line)
    }
}
