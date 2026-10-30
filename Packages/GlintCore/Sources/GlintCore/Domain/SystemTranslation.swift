import Foundation

public enum SystemTranslationModel {
    public static let appleTranslationID = "system-apple-translation"
}

public enum SystemTranslationAvailability: Sendable, Equatable {
    case unsupported
    case available
    case installing
    case installed
    case failed(String)

    public var canSelect: Bool {
        self == .installed
    }
}
