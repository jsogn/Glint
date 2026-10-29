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
        if let reader = registrations.first(where: {
            $0.matches(source.identity)
        })?.reader {
            return reader
        }
        guard
            let adaptiveProfiles,
            source.kind == .otherInputMethod
                || source.kind == .unknown,
            source.identity.bundleIdentifier != nil
        else {
            return fallback
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
    static func standard() -> CandidateReaderRouter {
        CandidateReaderRouter(
            fallback: AXCandidateReader(),
            registrations: [
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
                    reader: WeTypeCandidateReader()
                ),
                CandidateReaderRegistration(
                    bundleIdentifiers: [
                        InputMethodIdentifier.sogouBundle
                    ],
                    inputSourceIdentifiers: [
                        InputMethodIdentifier.sogouPinyinMode
                    ],
                    reader: SogouCandidateReader()
                ),
            ],
            adaptiveProfiles: CandidateProfileCache(
                persistence: .shared
            )
        )
    }
}
