import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GlintCore

struct SquirrelPanelFrameReader {
    private let bundleIdentifier: String
    private let accessLimits: AXAccessLimits
    private let maximumWindowCount: Int

    init(
        bundleIdentifier: String =
            InputMethodIdentifier.squirrelBundle,
        accessLimits: AXAccessLimits = .interactive,
        maximumWindowCount: Int = 3
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.accessLimits = accessLimits
        self.maximumWindowCount = max(1, maximumWindowCount)
    }

    func panelFrame() -> CGRect? {
        guard
            let application =
                NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })
        else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        let session = AXReadSession(limits: accessLimits)
        let windows = session.elementsAttribute(
            appElement,
            kAXWindowsAttribute
        )
        return
            windows
            .prefix(maximumWindowCount)
            .compactMap { window -> (CGRect, Bool)? in
                guard
                    let frame = session.frame(of: window),
                    frame.width > 0,
                    frame.height > 0
                else {
                    return nil
                }
                return (
                    frame,
                    !(session.boolAttribute(
                        window,
                        kAXHiddenAttribute
                    ) ?? false)
                )
            }
            .max {
                if $0.1 != $1.1 {
                    return !$0.1
                }
                return $0.0.width * $0.0.height
                    < $1.0.width * $1.0.height
            }?
            .0
    }
}

final class SquirrelCandidateReader: AXCandidateReading, @unchecked Sendable {
    private static let maximumSnapshotAgeNanoseconds: UInt64 =
        5_000_000_000

    private let store: RimeCandidateSnapshotStore
    private let panelFrame: @Sendable () -> CGRect?
    private(set) var missReason: AXCandidateReadMissReason = .unavailable

    init(
        store: RimeCandidateSnapshotStore,
        panelFrame: @escaping @Sendable () -> CGRect? = {
            SquirrelPanelFrameReader().panelFrame()
        }
    ) {
        self.store = store
        self.panelFrame = panelFrame
    }

    static func hasFreshSnapshot(
        in store: RimeCandidateSnapshotStore
    ) -> Bool {
        store.latest(
            maxAgeNanoseconds: maximumSnapshotAgeNanoseconds
        ) != nil
    }

    func snapshot(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot? {
        missReason = .unavailable
        guard
            let envelope = store.latest(
                maxAgeNanoseconds:
                    Self.maximumSnapshotAgeNanoseconds
            ),
            let selectedText = envelope.selectedText
        else {
            missReason = .candidateEnded
            return nil
        }
        let candidateTexts: [String]
        let selectedIndex: Int
        if let index = envelope.selectedIndex,
            envelope.candidates.indices.contains(index),
            envelope.candidates[index] == selectedText
        {
            candidateTexts = envelope.candidates
            selectedIndex = index
        } else if let index = envelope.candidates.firstIndex(
            of: selectedText
        ) {
            candidateTexts = envelope.candidates
            selectedIndex = index
        } else {
            candidateTexts = [selectedText]
            selectedIndex = 0
        }
        let frame = panelFrame()
        let options =
            includeVisibleCandidates
            ? candidateTexts.enumerated().map { index, text in
                AXCandidateOption(
                    text:
                        includeVisibleTexts || index == selectedIndex
                        ? text
                        : "",
                    frame: nil,
                    isSelected: index == selectedIndex
                )
            }
            : []
        let geometry = frame.map {
            AXCandidateGeometry(
                horizontalFrame: $0,
                horizontalSource: .item,
                verticalFrame: $0,
                verticalSource: .item
            )
        }
        return AXCandidateSnapshot(
            text: selectedText,
            visibleTexts:
                includeVisibleTexts
                ? candidateTexts
                : [],
            options: options,
            frame: frame,
            candidateWindowFrame: frame,
            candidateListFrame: frame,
            geometry: geometry,
            selectedIndex: selectedIndex,
            selectionIsExact: true,
            usesInputCaretFrameFallback: true
        )
    }
}
