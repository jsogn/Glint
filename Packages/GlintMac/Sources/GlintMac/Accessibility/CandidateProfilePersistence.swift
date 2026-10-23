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
    }

    static let shared = CandidateProfilePersistence(
        defaults: .standard,
        storageKey: "candidateProfiles.v1"
    )

    private let defaults: UserDefaults
    private let storageKey: String
    private let profiles:
        OSAllocatedUnfairLock<
            [CandidateProfileKey: CandidateReadProfile]
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
        profiles.withLock { $0[key] }
    }

    func store(
        _ profile: CandidateReadProfile,
        for key: CandidateProfileKey
    ) {
        let records = profiles.withLock { profiles -> [Record] in
            profiles[key] = profile
            return profiles.map { key, profile in
                Record(
                    bundleIdentifier: key.bundleIdentifier,
                    inputSourceIdentifier:
                        key.inputSourceIdentifier,
                    applicationVersion: key.applicationVersion,
                    profile: profile.rawValue
                )
            }
        }
        persist(records)
    }

    func remove(_ key: CandidateProfileKey) {
        let records = profiles.withLock { profiles -> [Record] in
            profiles.removeValue(forKey: key)
            return profiles.map { key, profile in
                Record(
                    bundleIdentifier: key.bundleIdentifier,
                    inputSourceIdentifier:
                        key.inputSourceIdentifier,
                    applicationVersion: key.applicationVersion,
                    profile: profile.rawValue
                )
            }
        }
        persist(records)
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
    ) -> [CandidateProfileKey: CandidateReadProfile] {
        guard
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode(
                [Record].self,
                from: data
            )
        else {
            return [:]
        }
        var profiles: [CandidateProfileKey: CandidateReadProfile] = [:]
        for record in records {
            guard
                let profile = CandidateReadProfile(
                    rawValue: record.profile
                )
            else {
                continue
            }
            profiles[record.key] = profile
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
