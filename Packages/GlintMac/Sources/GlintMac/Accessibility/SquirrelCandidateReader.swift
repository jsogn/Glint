import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import GlintCore

enum SquirrelCandidateGeometry {
    private static let verticalAspectRatio: CGFloat = 1.2
    private static let minimumStackedRowHeight: CGFloat = 24

    static func rowFrames(
        in panelFrame: CGRect,
        candidateCount: Int
    ) -> [CGRect]? {
        let hasAspectRatioForStackedRows =
            panelFrame.height
            > panelFrame.width * verticalAspectRatio
        let hasHeightForStackedRows =
            candidateCount > 1
            && panelFrame.height
                >= CGFloat(candidateCount)
                * minimumStackedRowHeight
        guard
            candidateCount > 0,
            panelFrame.width > 0,
            panelFrame.height > 0,
            hasAspectRatioForStackedRows
                || hasHeightForStackedRows
        else {
            return nil
        }
        let rowHeight =
            panelFrame.height / CGFloat(candidateCount)
        return (0..<candidateCount).map { index in
            CGRect(
                x: panelFrame.minX,
                y: panelFrame.minY
                    + CGFloat(index) * rowHeight,
                width: panelFrame.width,
                height: rowHeight
            )
        }
    }
}

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
        let panelFrame = panelFrame()
        let rowFrames = panelFrame.flatMap {
            SquirrelCandidateGeometry.rowFrames(
                in: $0,
                candidateCount: candidateTexts.count
            )
        }
        let selectedFrame =
            rowFrames.flatMap {
                $0.indices.contains(selectedIndex)
                    ? $0[selectedIndex]
                    : nil
            } ?? panelFrame
        let layoutOrientation: CandidateLayoutOrientation =
            if rowFrames != nil {
                .vertical
            } else if panelFrame != nil {
                .horizontal
            } else {
                .unknown
            }
        let options =
            includeVisibleCandidates
            ? candidateTexts.enumerated().map { index, text in
                AXCandidateOption(
                    text:
                        includeVisibleTexts || index == selectedIndex
                        ? text
                        : "",
                    frame: rowFrames.flatMap {
                        $0.indices.contains(index)
                            ? $0[index]
                            : nil
                    },
                    isSelected: index == selectedIndex
                )
            }
            : []
        let geometry = selectedFrame.map {
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
            frame: selectedFrame,
            candidateWindowFrame: panelFrame,
            candidateListFrame: panelFrame,
            geometry: geometry,
            selectedIndex: selectedIndex,
            selectionIsExact: true,
            usesInputCaretFrameFallback: true,
            layoutOrientation: layoutOrientation
        )
    }
}
