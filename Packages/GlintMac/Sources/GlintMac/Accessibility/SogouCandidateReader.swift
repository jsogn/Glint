import AppKit
import ApplicationServices
import Foundation
import GlintCore

struct SogouCandidateObservation: Sendable, Equatable {
    let text: String
    let frame: CGRect
}

enum SogouCandidateParser {
    static func candidates(
        from observations: [SogouCandidateObservation]
    ) -> [SogouCandidateObservation]? {
        let sorted = observations.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 1 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        guard
            CandidateCountPolicy.runtimeRange.contains(sorted.count),
            visibleRowCount(for: sorted.map(\.frame)) == 1
        else {
            return nil
        }
        return sorted
    }

    static func hasUnsupportedLayout(
        _ observations: [SogouCandidateObservation]
    ) -> Bool {
        guard !observations.isEmpty else {
            return false
        }
        return observations.count
            > CandidateCountPolicy.runtimeRange.upperBound
            || visibleRowCount(
                for: observations.map(\.frame)
            ) > 1
    }

    private static func visibleRowCount(
        for frames: [CGRect]
    ) -> Int {
        var rows: [CGRect] = []
        for frame in frames {
            if let index = rows.firstIndex(where: {
                sharesVisibleRow($0, frame)
            }) {
                rows[index] = rows[index].union(frame)
            } else {
                rows.append(frame)
            }
        }
        return rows.count
    }

    private static func sharesVisibleRow(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let overlap =
            min(lhs.maxY, rhs.maxY)
            - max(lhs.minY, rhs.minY)
        return overlap >= min(lhs.height, rhs.height) * 0.5
    }
}

public final class SogouCandidateReader {
    public static let inputSourceID =
        InputMethodIdentifier.sogouPinyinMode
    private static let windowVerticalInset: CGFloat = 8

    private let bundleIdentifier: String
    private let accessLimits: AXAccessLimits
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int
    private(set) var missReason: AXCandidateReadMissReason = .unavailable

    public convenience init(
        bundleIdentifier: String = InputMethodIdentifier.sogouBundle,
        messagingTimeout: Float = 0.25,
        maximumWindowCount: Int = 3,
        maximumNodeCount: Int = 24
    ) {
        self.init(
            bundleIdentifier: bundleIdentifier,
            accessLimits: AXAccessLimits(
                messagingTimeout: messagingTimeout,
                maximumAttributeCalls:
                    AXAccessLimits.interactive
                    .maximumAttributeCalls,
                maximumDuration:
                    AXAccessLimits.interactive.maximumDuration
            ),
            maximumWindowCount: maximumWindowCount,
            maximumNodeCount: maximumNodeCount
        )
    }

    init(
        bundleIdentifier: String,
        accessLimits: AXAccessLimits,
        maximumWindowCount: Int,
        maximumNodeCount: Int
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.accessLimits = accessLimits
        self.maximumWindowCount = max(1, maximumWindowCount)
        self.maximumNodeCount = max(1, maximumNodeCount)
    }

    public func snapshot(
        processIdentifier: pid_t? = nil,
        includeVisibleCandidates: Bool = false,
        includeVisibleTexts: Bool = true
    ) -> AXCandidateSnapshot? {
        missReason = .unavailable
        guard
            let application =
                NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: bundleIdentifier
                )
                .first(where: { !$0.isTerminated })
        else {
            missReason = .candidateEnded
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
        guard !windows.isEmpty else {
            missReason = .candidateEnded
            return nil
        }
        var foundCandidateList = false
        let candidates = windows.prefix(maximumWindowCount)
            .compactMap { window -> AXCandidateWindowSnapshot? in
                guard
                    let candidate = snapshot(
                        from: window,
                        includeVisibleCandidates:
                            includeVisibleCandidates,
                        includeVisibleTexts: includeVisibleTexts,
                        session: session
                    )
                else {
                    return nil
                }
                foundCandidateList = true
                return AXCandidateWindowSnapshot(
                    candidateCount: candidate.candidateCount,
                    snapshot: candidate.snapshot,
                    isVisible:
                        !(session.boolAttribute(
                            window,
                            kAXHiddenAttribute
                        ) ?? false)
                )
            }
        if missReason == .temporaryLayout {
            return nil
        }
        if let candidate =
            AXCandidateWindowSelector.preferred(from: candidates)
        {
            return candidate
        }
        if !foundCandidateList {
            missReason = .candidateEnded
        }
        return nil
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> (candidateCount: Int, snapshot: AXCandidateSnapshot)? {
        for list in candidateLists(in: window, session: session) {
            let visibleElements = session.elementsAttribute(
                list,
                kAXVisibleChildrenAttribute
            )
            let candidateElements =
                visibleElements.isEmpty
                ? session.elementsAttribute(
                    list,
                    kAXChildrenAttribute
                )
                : visibleElements
            let observations =
                candidateElements
                .prefix(maximumNodeCount)
                .compactMap {
                    Self.observation($0, session: session)
                }
            guard
                let candidates = SogouCandidateParser.candidates(
                    from: observations
                ),
                let first = candidates.first
            else {
                if SogouCandidateParser.hasUnsupportedLayout(
                    observations
                ) {
                    missReason = .temporaryLayout
                    return nil
                }
                continue
            }
            let candidateWindowFrame = session.frame(of: window)
            let candidateListFrame = session.frame(of: list)
            let presentationFrames = candidates.map {
                AXCandidateTextFrame.presentationFrame(for: $0.frame)
            }
            let geometry = Self.geometry(
                selectedFrame: presentationFrames[0],
                candidateWindowFrame: candidateWindowFrame,
                candidateListFrame: candidateListFrame
            )
            if !includeVisibleCandidates {
                return (
                    candidates.count,
                    AXCandidateSnapshot(
                        text: first.text,
                        visibleTexts: [],
                        options: [],
                        frame: first.frame,
                        candidateWindowFrame: candidateWindowFrame,
                        candidateListFrame: candidateListFrame,
                        geometry: geometry,
                        selectedIndex: 0,
                        selectionIsExact: false
                    )
                )
            }
            let options = candidates.enumerated().map {
                index,
                candidate in
                AXCandidateOption(
                    text:
                        includeVisibleTexts || index == 0
                        ? candidate.text
                        : "",
                    frame: presentationFrames[index],
                    isSelected: false
                )
            }
            return (
                candidates.count,
                AXCandidateSnapshot(
                    text: first.text,
                    visibleTexts:
                        includeVisibleTexts
                        ? candidates.map(\.text)
                        : [],
                    options: options,
                    frame: first.frame,
                    candidateWindowFrame: candidateWindowFrame,
                    candidateListFrame: candidateListFrame,
                    geometry: geometry,
                    selectedIndex: 0,
                    selectionIsExact: false
                )
            )
        }
        return nil
    }

    private func candidateLists(
        in window: AXUIElement,
        session: AXReadSession
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in session.elementsAttribute(
            window,
            kAXChildrenAttribute
        ).prefix(maximumNodeCount) {
            if session.stringAttribute(
                child,
                kAXRoleAttribute
            ) == kAXListRole as String {
                result.append(child)
            }
            for grandchild in session.elementsAttribute(
                child,
                kAXChildrenAttribute
            ).prefix(maximumNodeCount)
            where session.stringAttribute(
                grandchild,
                kAXRoleAttribute
            ) == kAXListRole as String {
                result.append(grandchild)
            }
        }
        return result
    }

    private static func geometry(
        selectedFrame: CGRect,
        candidateWindowFrame: CGRect?,
        candidateListFrame: CGRect?
    ) -> AXCandidateGeometry {
        let verticalFrame: CGRect
        let verticalSource: AXCandidateFrameKind
        if let candidateWindowFrame {
            verticalFrame =
                candidateWindowFrame.height
                    > windowVerticalInset * 2
                ? candidateWindowFrame.insetBy(
                    dx: 0,
                    dy: windowVerticalInset
                )
                : candidateWindowFrame
            verticalSource = .window
        } else if let candidateListFrame {
            verticalFrame = candidateListFrame
            verticalSource = .list
        } else {
            verticalFrame = selectedFrame
            verticalSource = .text
        }
        return AXCandidateGeometry(
            horizontalFrame: selectedFrame,
            horizontalSource: .text,
            verticalFrame: verticalFrame,
            verticalSource: verticalSource
        )
    }

    private static func observation(
        _ element: AXUIElement,
        session: AXReadSession
    ) -> SogouCandidateObservation? {
        guard
            session.stringAttribute(element, kAXRoleAttribute)
                == kAXStaticTextRole as String,
            let text = session.text(of: element),
            let frame = session.frame(of: element),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }
        return SogouCandidateObservation(
            text: text,
            frame: frame
        )
    }
}

extension SogouCandidateReader: AXCandidateReading {}
