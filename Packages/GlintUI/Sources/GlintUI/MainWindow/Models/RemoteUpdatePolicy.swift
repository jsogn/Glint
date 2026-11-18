import Foundation

struct RemoteUpdatePolicy {
    let successInterval: TimeInterval
    let failureInterval: TimeInterval

    func shouldCheck(
        force: Bool,
        now: Date,
        lastSuccess: Date?,
        lastFailure: Date?
    ) -> Bool {
        if force { return true }
        if let lastFailure,
            now.timeIntervalSince(lastFailure) < failureInterval
        {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= successInterval
    }
}

enum MainWindowUpdatePolicies {
    static let catalog = RemoteUpdatePolicy(
        successInterval: 6 * 60 * 60,
        failureInterval: 15 * 60
    )
    static let translationModel = RemoteUpdatePolicy(
        successInterval: 6 * 60 * 60,
        failureInterval: 15 * 60
    )
}
