public enum AppPolicy: Sendable, Equatable {
    case all
    case whitelist(Set<String>)
    case blacklist(Set<String>)

    public func allows(bundleIdentifier: String) -> Bool {
        switch self {
        case .all:
            return true
        case .whitelist(let identifiers):
            return identifiers.contains(bundleIdentifier)
        case .blacklist(let identifiers):
            return !identifiers.contains(bundleIdentifier)
        }
    }
}
