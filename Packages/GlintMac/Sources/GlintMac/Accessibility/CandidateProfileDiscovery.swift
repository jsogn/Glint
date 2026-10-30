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
    case isolatedSelectedTextItems
}

struct CandidateProfileKey: Hashable, Sendable {
    let bundleIdentifier: String
    let inputSourceIdentifier: String
    let applicationVersion: String

    var sourceKey: CandidateProfileSourceKey {
        CandidateProfileSourceKey(
            bundleIdentifier: bundleIdentifier,
            inputSourceIdentifier: inputSourceIdentifier
        )
    }

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

struct CandidateProfileSourceKey: Hashable, Sendable {
    let bundleIdentifier: String
    let inputSourceIdentifier: String
}

private final class CandidateProfileReadCoordinator: @unchecked Sendable {
    private let locks =
        OSAllocatedUnfairLock<
            [CandidateProfileSourceKey: NSLock]
        >(initialState: [:])

    func withLock<T>(
        for sourceKey: CandidateProfileSourceKey,
        _ operation: () throws -> T
    ) rethrows -> T {
        let lock = locks.withLock { locks in
            if let lock = locks[sourceKey] {
                return lock
            }
            let lock = NSLock()
            locks[sourceKey] = lock
            return lock
        }
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class CandidateProfileCache: @unchecked Sendable {
    private struct Entry: Sendable {
        var profile: CandidateReadProfile?
        var profileNeedsActivation = false
        var profileNeedsProbe = false
        // Version is validation metadata, never part of the cache identity.
        var validatedApplicationVersion: String?
        // Repeated hits during one probe must not invalidate that probe.
        var probeApplicationVersion: String?
        var unavailableFailureCount = 0
        var failedAttempts = 0
        var retryAfter: UInt64 = 0
        var profileFailureCount = 0
        var profileFailureStartedAt: UInt64?
    }

    private struct State: Sendable {
        var entries: [CandidateProfileSourceKey: Entry] = [:]
        var generations: [CandidateProfileSourceKey: UInt64] = [:]
        var discoveryIsInFlight = false
    }

    private static let retryDelays: [UInt64] = [
        500_000_000,
        2_000_000_000,
        10_000_000_000,
        30_000_000_000,
        60_000_000_000,
        5 * 60 * 1_000_000_000,
        10 * 60 * 1_000_000_000,
    ]
    private static let failuresBeforeProfileInvalidation = 3
    private static let failuresBeforeUnrecognizedProbe = 3
    private static let minimumProfileFailureDuration: UInt64 =
        2 * 1_000_000_000

    private let lock: OSAllocatedUnfairLock<State>
    private let readCoordinator = CandidateProfileReadCoordinator()
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
        let sourceKey = key.sourceKey
        return lock.withLock { state -> CandidateReadProfile? in
            if let entry = state.entries[sourceKey] {
                guard let profile = entry.profile else {
                    return nil
                }
                return entry.profileNeedsActivation
                    ? nil
                    : profile
            }
            guard let profile = persistence?.profile(for: key) else {
                return nil
            }
            var entry = state.entries[sourceKey] ?? Entry()
            entry.profile = profile
            state.entries[sourceKey] = entry
            return profile
        }
    }

    func hasProfileOrPending(
        for identity: InputMethodIdentity
    ) -> Bool {
        guard let key = profileKey(for: identity) else {
            return false
        }
        return lock.withLock {
            $0.entries[key.sourceKey]?.profile != nil
        }
    }

    func withProfileRead<T>(
        for identity: InputMethodIdentity,
        _ operation: () throws -> T
    ) rethrows -> T {
        guard let bundleIdentifier = identity.bundleIdentifier else {
            return try operation()
        }
        let sourceKey = CandidateProfileSourceKey(
            bundleIdentifier: bundleIdentifier,
            inputSourceIdentifier: identity.inputSourceIdentifier
        )
        return try readCoordinator.withLock(
            for: sourceKey,
            operation
        )
    }

    func activatePendingProfile(
        for identity: InputMethodIdentity
    ) -> Bool {
        guard let key = profileKey(for: identity) else {
            return false
        }
        let sourceKey = key.sourceKey
        return lock.withLock { state in
            guard var entry = state.entries[sourceKey],
                entry.profile != nil,
                entry.profileNeedsActivation
            else {
                return false
            }
            entry.profileNeedsActivation = false
            state.entries[sourceKey] = entry
            return true
        }
    }

    @discardableResult
    func requestDiscovery(
        for identity: InputMethodIdentity
    ) -> Task<Void, Never>? {
        guard let key = profileKey(for: identity) else {
            return nil
        }
        let sourceKey = key.sourceKey
        let now = clock()
        let generation = lock.withLock {
            state -> UInt64? in
            var entry = state.entries[sourceKey] ?? Entry()
            let versionChanged =
                entry.profile != nil
                && entry.validatedApplicationVersion
                    != key.applicationVersion
            if versionChanged {
                entry.profileNeedsProbe = true
                if entry.probeApplicationVersion
                    != key.applicationVersion
                {
                    entry.probeApplicationVersion =
                        key.applicationVersion
                    state.generations[sourceKey, default: 0] &+= 1
                }
                state.entries[sourceKey] = entry
            }
            if state.discoveryIsInFlight {
                return nil
            }
            // A prior verified structure remains usable until a real read
            // fails, at which point discovery can correct the live profile.
            guard
                entry.profile == nil
                    || entry.profileNeedsProbe
                    || entry.validatedApplicationVersion
                        != key.applicationVersion,
                now >= entry.retryAfter
            else {
                return nil
            }
            entry.probeApplicationVersion = key.applicationVersion
            state.entries[sourceKey] = entry
            state.discoveryIsInFlight = true
            return state.generations[sourceKey, default: 0]
        }
        guard let generation else {
            return nil
        }
        return Task.detached(priority: .utility) { [self] in
            let profile = readCoordinator.withLock(
                for: sourceKey
            ) {
                discover(key)
            }
            completeDiscovery(
                for: key,
                generation: generation,
                profile: profile
            )
        }
    }

    func recordProfileHit(
        for identity: InputMethodIdentity
    ) {
        guard let key = profileKey(for: identity) else {
            return
        }
        let sourceKey = key.sourceKey
        lock.withLock { state in
            guard var entry = state.entries[sourceKey],
                entry.profile != nil
            else {
                return
            }
            let versionChanged =
                entry.validatedApplicationVersion
                != key.applicationVersion
            entry.profileFailureCount = 0
            entry.profileFailureStartedAt = nil
            entry.unavailableFailureCount = 0
            if versionChanged {
                entry.profileNeedsProbe = true
                if entry.probeApplicationVersion
                    != key.applicationVersion
                {
                    entry.probeApplicationVersion =
                        key.applicationVersion
                    state.generations[sourceKey, default: 0] &+= 1
                }
            } else {
                entry.profileNeedsProbe = false
                entry.validatedApplicationVersion =
                    key.applicationVersion
                state.generations[sourceKey, default: 0] &+= 1
            }
            state.entries[sourceKey] = entry
        }
    }

    func recordProfileMiss(
        for identity: InputMethodIdentity,
        reason: AXCandidateReadMissReason = .structureMismatch
    ) {
        guard let key = profileKey(for: identity) else {
            return
        }
        let sourceKey = key.sourceKey
        let now = clock()
        let invalidated = lock.withLock { state -> Bool in
            guard var entry = state.entries[sourceKey],
                entry.profile != nil
            else {
                return false
            }
            if reason == .unavailable {
                entry.unavailableFailureCount += 1
                if entry.unavailableFailureCount
                    >= Self.failuresBeforeUnrecognizedProbe
                {
                    entry.profileNeedsProbe = true
                }
                state.entries[sourceKey] = entry
                return false
            }
            guard reason == .structureMismatch else {
                return false
            }
            entry.profileNeedsProbe = true
            if entry.profileFailureStartedAt == nil {
                entry.profileFailureStartedAt = now
            }
            entry.profileFailureCount += 1
            let failureStartedAt =
                entry.profileFailureStartedAt ?? now
            let duration =
                now >= failureStartedAt
                ? now - failureStartedAt
                : 0
            guard
                entry.profileFailureCount
                    >= Self.failuresBeforeProfileInvalidation,
                duration >= Self.minimumProfileFailureDuration
            else {
                state.entries[sourceKey] = entry
                return false
            }
            state.entries[sourceKey] = Entry()
            state.generations[sourceKey, default: 0] &+= 1
            persistence?.remove(key)
            return true
        }
        guard invalidated else {
            return
        }
        candidateProfileLogger.notice(
            "profile invalidated source=\(key.inputSourceIdentifier, privacy: .public)"
        )
    }

    private func completeDiscovery(
        for key: CandidateProfileKey,
        generation: UInt64,
        profile: CandidateReadProfile?
    ) {
        let now = clock()
        let sourceKey = key.sourceKey
        let result = lock.withLock {
            state -> (
                profile: CandidateReadProfile?,
                failedAttempts: Int,
                applied: Bool
            ) in
            state.discoveryIsInFlight = false
            guard
                state.generations[sourceKey, default: 0]
                    == generation
            else {
                return (
                    profile: nil,
                    failedAttempts: 0,
                    applied: false
                )
            }
            var entry = state.entries[sourceKey] ?? Entry()
            if entry.profile != nil,
                entry.validatedApplicationVersion
                    == key.applicationVersion,
                !entry.profileNeedsActivation,
                !entry.profileNeedsProbe
            {
                return (
                    profile: nil,
                    failedAttempts: entry.failedAttempts,
                    applied: false
                )
            }
            if let profile {
                entry.profile = profile
                entry.profileNeedsActivation = true
                entry.profileNeedsProbe = false
                entry.validatedApplicationVersion =
                    key.applicationVersion
                entry.unavailableFailureCount = 0
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
            state.entries[sourceKey] = entry
            if let profile {
                persistence?.store(profile, for: key)
            }
            return (
                profile: profile,
                failedAttempts: entry.failedAttempts,
                applied: profile != nil
            )
        }
        if let profile = result.profile {
            candidateProfileLogger.notice(
                "profile discovered source=\(key.inputSourceIdentifier, privacy: .public) kind=\(profile.rawValue, privacy: .public)"
            )
        } else if result.applied {
            candidateProfileLogger.debug(
                "profile discovery failed source=\(key.inputSourceIdentifier, privacy: .public) attempts=\(result.failedAttempts, privacy: .public)"
            )
        } else {
            candidateProfileLogger.debug(
                "profile discovery superseded source=\(key.inputSourceIdentifier, privacy: .public)"
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
        guard failedAttempts > 0 else {
            return retryDelays[0]
        }
        return retryDelays[
            min(failedAttempts - 1, retryDelays.count - 1)
        ]
    }
}

struct PreferredCandidateReader: AXCandidateReading {
    let preferred: any AXCandidateReading
    let fallback: any AXCandidateReading
    let onPreferredSuccess: @Sendable () -> Void

    init(
        preferred: any AXCandidateReading,
        fallback: any AXCandidateReading,
        onPreferredSuccess: @escaping @Sendable () -> Void = {}
    ) {
        self.preferred = preferred
        self.fallback = fallback
        self.onPreferredSuccess = onPreferredSuccess
    }

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        if let snapshot = preferred.snapshot(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        ) {
            onPreferredSuccess()
            return snapshot
        }
        // This path runs on every idle poll. A definitive end needs no
        // secondary AX scan, which would multiply empty reads.
        if preferred.missReason == .candidateEnded {
            return nil
        }
        return fallback.snapshot(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
    }

    var missReason: AXCandidateReadMissReason {
        let preferredReason = preferred.missReason
        let fallbackReason = fallback.missReason
        if preferredReason == .candidateEnded
            || fallbackReason == .candidateEnded
        {
            return .candidateEnded
        }
        if preferredReason == .temporaryLayout
            || fallbackReason == .temporaryLayout
        {
            return .temporaryLayout
        }
        if preferredReason == .structureMismatch
            || fallbackReason == .structureMismatch
        {
            return .structureMismatch
        }
        return .unavailable
    }
}

struct AdaptiveUnknownCandidateReader: AXCandidateReading {
    let source: ActiveInputSource
    let fallback: any AXCandidateReading
    let profiles: CandidateProfileCache
    let allowsProfileDiscovery: Bool
    let selectedTextItemReaders: SelectedTextItemReaderPool

    init(
        source: ActiveInputSource,
        fallback: any AXCandidateReading,
        profiles: CandidateProfileCache,
        allowsProfileDiscovery: Bool,
        selectedTextItemReaders: SelectedTextItemReaderPool
    ) {
        self.source = source
        self.fallback = fallback
        self.profiles = profiles
        self.allowsProfileDiscovery = allowsProfileDiscovery
        self.selectedTextItemReaders = selectedTextItemReaders
    }

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        if !allowsProfileDiscovery,
            profiles.activatePendingProfile(
                for: source.identity
            )
        {
            return nil
        }
        if let profile = profiles.profile(for: source.identity) {
            let reader = candidateReader(for: profile)
            if let candidate = profiles.withProfileRead(
                for: source.identity,
                {
                    reader.snapshot(
                        processIdentifier: processIdentifier,
                        includeVisibleCandidates:
                            includeVisibleCandidates,
                        includeVisibleTexts: includeVisibleTexts
                    )
                }
            ) {
                profiles.recordProfileHit(for: source.identity)
                profiles.requestDiscovery(for: source.identity)
                return candidate
            }
            if allowsProfileDiscovery,
                Self.shouldRecordProfileMiss(
                    for: reader.missReason
                )
            {
                profiles.recordProfileMiss(
                    for: source.identity,
                    reason: reader.missReason
                )
            }
        }
        let fallbackSnapshot = fallback.snapshot(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
        if fallbackSnapshot != nil || allowsProfileDiscovery {
            profiles.requestDiscovery(for: source.identity)
        }
        return fallbackSnapshot
    }

    static func shouldRecordProfileMiss(
        for reason: AXCandidateReadMissReason
    ) -> Bool {
        reason == .structureMismatch
            || reason == .unavailable
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
        case .isolatedSelectedTextItems:
            return selectedTextItemReaders.reader(
                bundleIdentifier: bundleIdentifier,
                inputSourceIdentifier:
                    source.identity.inputSourceIdentifier
            )
        }
    }
}

enum CandidateProfileDetector {
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
            accessLimits: .discovery,
            maximumWindowCount: maximumWindowCount,
            maximumNodeCount: maximumNodeCount
        )
        let listSnapshot = listReader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )
        let textReader = WeTypeCandidateReader(
            bundleIdentifier: key.bundleIdentifier,
            accessLimits: .discovery,
            maximumWindowCount: maximumWindowCount,
            maximumNodeCount: maximumNodeCount
        )
        let textSnapshot = textReader.snapshot(
            includeVisibleCandidates: true,
            includeVisibleTexts: false
        )
        let selectedTextItemReader =
            SelectedTextItemCandidateReader(
                bundleIdentifier: key.bundleIdentifier,
                accessLimits: .discovery,
                maximumWindowCount: maximumWindowCount,
                maximumNodeCount: maximumNodeCount
            )
        let selectedTextItemSnapshot =
            selectedTextItemReader.snapshot(
                includeVisibleCandidates: true,
                includeVisibleTexts: false
            )
        return classify(
            listSnapshot: listSnapshot,
            textSnapshot: textSnapshot,
            selectedTextItemSnapshot: selectedTextItemSnapshot
        )
    }

    static func classify(
        listSnapshot: AXCandidateSnapshot?,
        textSnapshot: AXCandidateSnapshot?,
        selectedTextItemSnapshot: AXCandidateSnapshot? = nil
    ) -> CandidateReadProfile? {
        if let selectedTextItemSnapshot,
            selectedTextItemSnapshot.options.count
                >= CandidateCountPolicy.profileDiscoveryMinimum,
            selectedTextItemSnapshot.selectionIsExact
        {
            return .isolatedSelectedTextItems
        }
        if let textSnapshot,
            textSnapshot.options.count
                >= CandidateCountPolicy.profileDiscoveryMinimum,
            textSnapshot.selectionIsExact
        {
            return .isolatedStyledText
        }
        if let listSnapshot,
            listSnapshot.options.count
                >= CandidateCountPolicy.profileDiscoveryMinimum
        {
            return .isolatedCandidateList
        }
        return nil
    }
}
