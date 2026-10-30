import Foundation
import GlintCore

enum AXCandidateReadMissReason: Sendable, Equatable {
    case unavailable
    case temporaryLayout
    case candidateEnded
    case structureMismatch
}

protocol AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot?
    var missReason: AXCandidateReadMissReason { get }
}

extension AXCandidateReading {
    func snapshot(
        processIdentifier: pid_t? = nil,
        includeVisibleCandidates: Bool = false,
        includeVisibleTexts: Bool = true
    ) -> AXCandidateSnapshot? {
        snapshot(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
    }

    var missReason: AXCandidateReadMissReason {
        .unavailable
    }
}

protocol CandidateReaderRouting {
    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading
    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool
}

extension CandidateReaderRouting {
    func reader(
        for source: ActiveInputSource
    ) -> any AXCandidateReading {
        reader(
            for: source,
            allowProfileDiscovery: true
        )
    }

    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool {
        false
    }
}

struct CandidateReaderRegistration {
    let bundleIdentifiers: Set<String>
    let inputSourceIdentifiers: Set<String>
    let reader: any AXCandidateReading
    let isAvailable: @Sendable () -> Bool
    let usesAdaptiveProfileFallback: Bool

    init(
        bundleIdentifiers: Set<String>,
        inputSourceIdentifiers: Set<String>,
        reader: any AXCandidateReading,
        isAvailable: @escaping @Sendable () -> Bool = { true },
        usesAdaptiveProfileFallback: Bool = false
    ) {
        self.bundleIdentifiers = bundleIdentifiers
        self.inputSourceIdentifiers = inputSourceIdentifiers
        self.reader = reader
        self.isAvailable = isAvailable
        self.usesAdaptiveProfileFallback =
            usesAdaptiveProfileFallback
    }

    func matches(_ identity: InputMethodIdentity) -> Bool {
        if let bundleIdentifier = identity.bundleIdentifier,
            bundleIdentifiers.contains(bundleIdentifier)
        {
            return true
        }
        return inputSourceIdentifiers.contains(
            identity.inputSourceIdentifier
        )
    }
}

struct CandidateReaderRouter: CandidateReaderRouting {
    let fallback: any AXCandidateReading
    let registrations: [CandidateReaderRegistration]
    let adaptiveProfiles: CandidateProfileCache?
    let selectedTextItemReaders: SelectedTextItemReaderPool

    init(
        fallback: any AXCandidateReading,
        registrations: [CandidateReaderRegistration],
        adaptiveProfiles: CandidateProfileCache? = nil,
        selectedTextItemReaders:
            SelectedTextItemReaderPool = .init()
    ) {
        self.fallback = fallback
        self.registrations = registrations
        self.adaptiveProfiles = adaptiveProfiles
        self.selectedTextItemReaders = selectedTextItemReaders
    }

    func reader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> any AXCandidateReading {
        if let registration = registrations.first(where: {
            $0.matches(source.identity) && $0.isAvailable()
        }) {
            guard
                registration.usesAdaptiveProfileFallback,
                let profileCache = adaptiveProfiles,
                let adaptive = adaptiveReader(
                    for: source,
                    allowProfileDiscovery: allowProfileDiscovery
                )
            else {
                return registration.reader
            }
            return PreferredCandidateReader(
                preferred: registration.reader,
                fallback: adaptive,
                onPreferredSuccess: {
                    profileCache.requestDiscovery(
                        for: source.identity
                    )
                }
            )
        }
        if let adaptive = adaptiveReader(
            for: source,
            allowProfileDiscovery: allowProfileDiscovery
        ) {
            return adaptive
        }
        return fallback
    }

    private func adaptiveReader(
        for source: ActiveInputSource,
        allowProfileDiscovery: Bool
    ) -> AdaptiveUnknownCandidateReader? {
        guard
            let adaptiveProfiles,
            source.kind == .otherInputMethod
                || source.kind == .unknown,
            source.identity.bundleIdentifier != nil
        else {
            return nil
        }
        return AdaptiveUnknownCandidateReader(
            source: source,
            fallback: fallback,
            profiles: adaptiveProfiles,
            allowsProfileDiscovery: allowProfileDiscovery,
            selectedTextItemReaders: selectedTextItemReaders
        )
    }

    func allowsProcessFallback(
        for source: ActiveInputSource
    ) -> Bool {
        if source.kind == .applePinyin {
            return true
        }
        if registrations.contains(where: {
            $0.matches(source.identity)
        }) {
            return true
        }
        guard
            source.kind == .otherInputMethod
                || source.kind == .unknown
        else {
            return false
        }
        return adaptiveProfiles?.hasProfileOrPending(
            for: source.identity
        ) == true
    }
}

enum CandidateReaderConfiguration {
    static func standard(
        rimeCandidateStore: RimeCandidateSnapshotStore? = nil
    ) -> CandidateReaderRouter {
        let selectedTextItemReaders = SelectedTextItemReaderPool()
        var registrations = [
            CandidateReaderRegistration(
                bundleIdentifiers: [],
                inputSourceIdentifiers: [
                    InputMethodIdentifier.applePinyinInputMode
                ],
                reader: ApplePinyinCandidateReader(
                    upstream: AXCandidateReader()
                )
            ),
            CandidateReaderRegistration(
                bundleIdentifiers: [
                    InputMethodIdentifier.weTypeBundle
                ],
                inputSourceIdentifiers: [
                    InputMethodIdentifier.weTypePinyinMode
                ],
                reader: WeTypeCandidateReader(),
                usesAdaptiveProfileFallback: true
            ),
            CandidateReaderRegistration(
                bundleIdentifiers: [
                    InputMethodIdentifier.sogouBundle
                ],
                inputSourceIdentifiers: [
                    InputMethodIdentifier.sogouPinyinMode
                ],
                reader: SogouCandidateReader(),
                usesAdaptiveProfileFallback: true
            ),
            CandidateReaderRegistration(
                bundleIdentifiers: [
                    InputMethodIdentifier.doubaoBundle
                ],
                inputSourceIdentifiers: [
                    InputMethodIdentifier.doubaoPinyinMode
                ],
                reader: selectedTextItemReaders.reader(
                    bundleIdentifier:
                        InputMethodIdentifier.doubaoBundle,
                    inputSourceIdentifier:
                        InputMethodIdentifier.doubaoPinyinMode
                ),
                usesAdaptiveProfileFallback: true
            ),
        ]
        if let rimeCandidateStore {
            registrations.append(
                CandidateReaderRegistration(
                    bundleIdentifiers: [
                        InputMethodIdentifier.squirrelBundle
                    ],
                    inputSourceIdentifiers: [
                        InputMethodIdentifier.squirrelHansMode,
                        InputMethodIdentifier.squirrelHantMode,
                    ],
                    reader: SquirrelCandidateReader(
                        store: rimeCandidateStore
                    ),
                    isAvailable: {
                        SquirrelCandidateReader.hasFreshSnapshot(
                            in: rimeCandidateStore
                        )
                    }
                )
            )
        }
        return CandidateReaderRouter(
            fallback: AXCandidateReader(),
            registrations: registrations,
            adaptiveProfiles: CandidateProfileCache(
                persistence: .shared
            ),
            selectedTextItemReaders: selectedTextItemReaders
        )
    }
}
