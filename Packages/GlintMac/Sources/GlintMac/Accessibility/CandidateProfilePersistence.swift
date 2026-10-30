import AppKit
import Foundation
import os

enum CandidateInputMethodVersion {
    private struct CacheEntry: Sendable {
        let version: String
        let expiresAt: UInt64
    }

    private static let cache = OSAllocatedUnfairLock<
        [String: CacheEntry]
    >(initialState: [:])

    static func current(for bundleIdentifier: String) -> String {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cached = cache.withLock({
            $0[bundleIdentifier]
        }), cached.expiresAt > now {
            return cached.version
        }
        guard
            let application =
                NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: bundleIdentifier
                )
                .first(where: { !$0.isTerminated })
        else {
            cache.withLock {
                $0[bundleIdentifier] = CacheEntry(
                    version: "unavailable",
                    expiresAt: now + 500_000_000
                )
            }
            return "unavailable"
        }
        let version = Self.version(for: application)
        cache.withLock {
            $0[bundleIdentifier] = CacheEntry(
                version: version,
                expiresAt: now + 5_000_000_000
            )
        }
        return version
    }

    private static func version(
        for application: NSRunningApplication
    ) -> String {
        if let bundleURL = application.bundleURL,
            let bundle = Bundle(url: bundleURL)
        {
            let shortVersion =
                bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
            let build =
                bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
            let components = [shortVersion, build].compactMap {
                $0?.isEmpty == false ? $0 : nil
            }
            if !components.isEmpty {
                return components.joined(separator: "-")
            }
        }
        if let executableURL = application.executableURL,
            let modificationDate =
                try? executableURL
                .resourceValues(
                    forKeys: [.contentModificationDateKey]
                )
                .contentModificationDate
        {
            return "mtime-\(modificationDate.timeIntervalSince1970)"
        }
        return "unknown"
    }
}

final class CandidateProfilePersistence: @unchecked Sendable {
    static let currentStorageKey = "candidateProfiles.v2"

    private struct Record: Codable {
        let bundleIdentifier: String
        let inputSourceIdentifier: String
        let applicationVersion: String
        let profile: String

        var key: CandidateProfileKey {
            CandidateProfileKey(
                bundleIdentifier: bundleIdentifier,
                inputSourceIdentifier: inputSourceIdentifier,
                applicationVersion: applicationVersion
            )
        }

        var sourceKey: CandidateProfileSourceKey {
            key.sourceKey
        }
    }

    static let shared = make(defaults: .standard)

    static func make(
        defaults: UserDefaults
    ) -> CandidateProfilePersistence {
        CandidateProfilePersistence(
            defaults: defaults,
            storageKey: currentStorageKey
        )
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let profiles:
        OSAllocatedUnfairLock<
            [CandidateProfileSourceKey: Record]
        >

    init(
        defaults: UserDefaults,
        storageKey: String
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        profiles = OSAllocatedUnfairLock(
            initialState: Self.load(
                from: defaults,
                storageKey: storageKey
            )
        )
    }

    func profile(
        for key: CandidateProfileKey
    ) -> CandidateReadProfile? {
        profiles.withLock { profiles in
            profiles[key.sourceKey].flatMap {
                CandidateReadProfile(rawValue: $0.profile)
            }
        }
    }

    func store(
        _ profile: CandidateReadProfile,
        for key: CandidateProfileKey
    ) {
        profiles.withLock { profiles in
            profiles[key.sourceKey] = Record(
                bundleIdentifier: key.bundleIdentifier,
                inputSourceIdentifier:
                    key.inputSourceIdentifier,
                applicationVersion: key.applicationVersion,
                profile: profile.rawValue
            )
            persist(Array(profiles.values))
        }
    }

    func remove(_ key: CandidateProfileKey) {
        profiles.withLock { profiles in
            profiles.removeValue(forKey: key.sourceKey)
            persist(Array(profiles.values))
        }
    }

    private func persist(_ records: [Record]) {
        guard let data = try? JSONEncoder().encode(records)
        else {
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(
        from defaults: UserDefaults,
        storageKey: String
    ) -> [CandidateProfileSourceKey: Record] {
        guard
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode(
                [Record].self,
                from: data
            )
        else {
            return [:]
        }
        var profiles: [CandidateProfileSourceKey: Record] = [:]
        for record in records {
            guard CandidateReadProfile(rawValue: record.profile) != nil
            else {
                continue
            }
            profiles[record.sourceKey] = record
        }
        return profiles
    }
}

public struct CandidateProfileProbeResult: Sendable, Equatable {
    public let applicationVersion: String
    public let profile: String?
    public let elapsedMilliseconds: Double

    public init(
        applicationVersion: String,
        profile: String?,
        elapsedMilliseconds: Double
    ) {
        self.applicationVersion = applicationVersion
        self.profile = profile
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public enum CandidateProfileProbe {
    public static func probe(
        bundleIdentifier: String,
        inputSourceIdentifier: String,
        applicationVersion: String? = nil
    ) -> CandidateProfileProbeResult {
        let version =
            applicationVersion
            ?? CandidateInputMethodVersion.current(
                for: bundleIdentifier
            )
        let key = CandidateProfileKey(
            bundleIdentifier: bundleIdentifier,
            inputSourceIdentifier: inputSourceIdentifier,
            applicationVersion: version
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let profile = CandidateProfileDetector.detect(for: key)
        let elapsedMilliseconds =
            Double(
                DispatchTime.now().uptimeNanoseconds - startedAt
            ) / 1_000_000
        return CandidateProfileProbeResult(
            applicationVersion: version,
            profile: profile?.rawValue,
            elapsedMilliseconds: elapsedMilliseconds
        )
    }
}
