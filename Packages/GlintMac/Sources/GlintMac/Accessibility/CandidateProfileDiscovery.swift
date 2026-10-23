import Foundation
import GlintCore
import os

private let candidateProfileLogger = Logger(
    subsystem: "com.local.glint",
    category: "CandidateProfiles"
)

enum CandidateReadProfile: String, Sendable, Equatable {
    case isolatedCandidateList
    case isolatedStyledText
}

struct CandidateProfileKey: Hashable, Sendable {
    let bundleIdentifier: String
    let inputSourceIdentifier: String
    let applicationVersion: String

    init?(
        identity: InputMethodIdentity,
        applicationVersion: String
    ) {
        guard
            let bundleIdentifier = identity.bundleIdentifier,
            !bundleIdentifier.isEmpty
        else {
            return nil
        }
        self.init(
            bundleIdentifier: bundleIdentifier,
            inputSourceIdentifier: identity.inputSourceIdentifier,
            applicationVersion: applicationVersion
        )
    }

    init(
        bundleIdentifier: String,
        inputSourceIdentifier: String,
        applicationVersion: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.inputSourceIdentifier = inputSourceIdentifier
        self.applicationVersion = applicationVersion
    }
}

final class CandidateProfileCache: @unchecked Sendable {
    private struct Entry: Sendable {
        var profile: CandidateReadProfile?
        var failedAttempts = 0
        var retryAfter: UInt64 = 0
    }

    private struct State: Sendable {
        var entries: [CandidateProfileKey: Entry] = [:]
        var discoveryIsInFlight = false
    }

    private static let firstRetryDelay: UInt64 = 500_000_000
    private static let minimumCooldown: UInt64 = 10 * 60 * 1_000_000_000
    private static let maximumCooldown: UInt64 = 60 * 60 * 1_000_000_000
    private static let failuresBeforeCooldown = 2

    private let lock: OSAllocatedUnfairLock<State>
    private let clock: @Sendable () -> UInt64
    private let applicationVersion: @Sendable (String) -> String
    private let persistence: CandidateProfilePersistence?
    private let discover:
        @Sendable (
            CandidateProfileKey
        ) -> CandidateReadProfile?

    init(
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        applicationVersion: @escaping @Sendable (String) -> String = {
            CandidateInputMethodVersion.current(for: $0)
        },
        persistence: CandidateProfilePersistence? = nil,
        discover:
            @escaping @Sendable (
                CandidateProfileKey
            ) -> CandidateReadProfile? = {
                CandidateProfileDetector.detect(for: $0)
            }
    ) {
        self.clock = clock
        self.applicationVersion = applicationVersion
        self.persistence = persistence
        self.discover = discover
        lock = OSAllocatedUnfairLock(initialState: State())
    }

    func profile(
        for identity: InputMethodIdentity
    ) -> CandidateReadProfile? {
        guard let key = profileKey(for: identity) else {
            return nil
        }
        if let profile = lock.withLock({
            $0.entries[key]?.profile
        }) {
            return profile
        }
        guard let profile = persistence?.profile(for: key) else {
            return nil
        }
        lock.withLock { state in
            var entry = state.entries[key] ?? Entry()
            entry.profile = profile
            state.entries[key] = entry
        }
        return profile
    }

    @discardableResult
    func requestDiscovery(
        for identity: InputMethodIdentity
    ) -> Task<Void, Never>? {
        guard let key = profileKey(for: identity) else {
            return nil
        }
        let now = clock()
        let accepted = lock.withLock { state -> Bool in
            if state.discoveryIsInFlight {
                return false
            }
            let entry = state.entries[key] ?? Entry()
            guard entry.profile == nil,
                now >= entry.retryAfter
            else {
                return false
            }
            state.discoveryIsInFlight = true
            return true
        }
        guard accepted else {
            return nil
        }
        return Task.detached(priority: .utility) { [self] in
            let profile = discover(key)
            completeDiscovery(for: key, profile: profile)
        }
    }

    private func completeDiscovery(
        for key: CandidateProfileKey,
        profile: CandidateReadProfile?
    ) {
        let now = clock()
        let result = lock.withLock {
            state -> (
                profile: CandidateReadProfile?,
                failedAttempts: Int
            ) in
            state.discoveryIsInFlight = false
            var entry = state.entries[key] ?? Entry()
            if let profile {
                entry.profile = profile
                entry.failedAttempts = 0
                entry.retryAfter = 0
            } else {
                entry.failedAttempts += 1
                entry.retryAfter =
                    now
                    + Self.retryDelay(
                        after: entry.failedAttempts
                    )
            }
            state.entries[key] = entry
            return (
                profile: profile,
                failedAttempts: entry.failedAttempts
            )
        }
        if let profile = result.profile {
            persistence?.store(profile, for: key)
            candidateProfileLogger.notice(
                "profile discovered source=\(key.inputSourceIdentifier, privacy: .public) kind=\(profile.rawValue, privacy: .public)"
            )
        } else {
            candidateProfileLogger.debug(
                "profile discovery failed source=\(key.inputSourceIdentifier, privacy: .public) attempts=\(result.failedAttempts, privacy: .public)"
            )
        }
    }

    private func profileKey(
        for identity: InputMethodIdentity
    ) -> CandidateProfileKey? {
        guard let bundleIdentifier = identity.bundleIdentifier else {
            return nil
        }
        return CandidateProfileKey(
            identity: identity,
            applicationVersion: applicationVersion(bundleIdentifier)
        )
    }

    private static func retryDelay(
        after failedAttempts: Int
    ) -> UInt64 {
        guard failedAttempts >= failuresBeforeCooldown else {
            return firstRetryDelay
        }
        let exponent = min(failedAttempts - failuresBeforeCooldown, 3)
        return min(
            maximumCooldown,
            minimumCooldown << exponent
        )
    }
}

struct AdaptiveUnknownCandidateReader: AXCandidateReading {
    let source: ActiveInputSource
    let fallback: any AXCandidateReading
    let profiles: CandidateProfileCache
    let allowsProfileDiscovery: Bool

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        if let profile = profiles.profile(for: source.identity),
            let candidate = candidateReader(for: profile).snapshot(
                processIdentifier: processIdentifier,
                includeVisibleCandidates: includeVisibleCandidates,
                includeVisibleTexts: includeVisibleTexts
            )
        {
            return candidate
        }
        let fallbackSnapshot = fallback.snapshot(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
        if fallbackSnapshot == nil,
            allowsProfileDiscovery
        {
            profiles.requestDiscovery(for: source.identity)
        }
        return fallbackSnapshot
    }

    private func candidateReader(
        for profile: CandidateReadProfile
    ) -> any AXCandidateReading {
        guard let bundleIdentifier = source.identity.bundleIdentifier
        else {
            return fallback
        }
        switch profile {
        case .isolatedCandidateList:
            return SogouCandidateReader(
                bundleIdentifier: bundleIdentifier
            )
        case .isolatedStyledText:
            return WeTypeCandidateReader(
                bundleIdentifier: bundleIdentifier
            )
        }
    }
}

enum CandidateProfileDetector {
    private static let discoveryTimeout: Float = 0.05
    private static let maximumWindowCount = 2
    private static let maximumNodeCount = 16

    static func detect(
        for key: CandidateProfileKey
    ) -> CandidateReadProfile? {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsedMilliseconds =
                Double(
                    DispatchTime.now().uptimeNanoseconds - startedAt
                ) / 1_000_000
            candidateProfileLogger.debug(
                "profile probe source=\(key.inputSourceIdentifier, privacy: .public) elapsed_ms=\(elapsedMilliseconds, privacy: .public)"
            )
        }
        let listReader = SogouCandidateReader(
            bundleIdentifier: key.bundleIdentifier,
            messagingTimeout: discoveryTimeout,
            maximumWindowCount: maximumWindowCount,
            maximumNodeCount: maximumNodeCount
        )
        let listSnapshot = listReader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )
        let textReader = WeTypeCandidateReader(
            bundleIdentifier: key.bundleIdentifier,
            messagingTimeout: discoveryTimeout,
            maximumWindowCount: maximumWindowCount,
            maximumNodeCount: maximumNodeCount
        )
        let textSnapshot = textReader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )
        return classify(
            listSnapshot: listSnapshot,
            textSnapshot: textSnapshot
        )
    }

    static func classify(
        listSnapshot: AXCandidateSnapshot?,
        textSnapshot: AXCandidateSnapshot?
    ) -> CandidateReadProfile? {
        if let listSnapshot,
            listSnapshot.options.count >= 2
        {
            return .isolatedCandidateList
        }
        if let textSnapshot,
            textSnapshot.options.count >= 2,
            textSnapshot.selectionIsExact
        {
            return .isolatedStyledText
        }
        return nil
    }
}
