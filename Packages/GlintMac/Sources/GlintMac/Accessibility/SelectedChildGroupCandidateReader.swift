import AppKit
import ApplicationServices
import Foundation
import GlintCore

struct SelectedChildGroupCandidateObservation: Sendable, Equatable {
    let text: String
    let frame: CGRect
    let isSelected: Bool
}

struct SelectedChildGroupCandidateRow: Sendable, Equatable {
    let items: [SelectedChildGroupCandidateObservation]
    let selectedIndex: Int

    var selected: SelectedChildGroupCandidateObservation {
        items[selectedIndex]
    }
}

enum SelectedChildGroupCandidateParser {
    static func row(
        from observations: [SelectedChildGroupCandidateObservation]
    ) -> SelectedChildGroupCandidateRow? {
        let sorted = observations.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 1 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        let selectedIndices = sorted.indices.filter {
            sorted[$0].isSelected
        }
        guard
            CandidateCountPolicy.runtimeRange.contains(sorted.count),
            selectedIndices.count == 1,
            !sorted[selectedIndices[0]].text.isEmpty,
            visibleRowCount(for: sorted.map(\.frame)) == 1
        else {
            return nil
        }
        return SelectedChildGroupCandidateRow(
            items: sorted,
            selectedIndex: selectedIndices[0]
        )
    }

    static func hasUnsupportedLayout(
        _ observations: [SelectedChildGroupCandidateObservation]
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

public final class SelectedChildGroupCandidateReader {
    private struct CandidateItem {
        let text: String
        let frame: CGRect
        let isSelected: Bool
    }

    private struct WindowCandidateRead {
        let candidateCount: Int
        let snapshot: AXCandidateSnapshot
        let isVisible: Bool
    }

    private let bundleIdentifier: String
    private let accessLimits: AXAccessLimits
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int
    private(set) var missReason: AXCandidateReadMissReason = .unavailable

    public convenience init(
        bundleIdentifier: String,
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
        var sawCandidateStructure = false
        let candidates = windows.prefix(maximumWindowCount)
            .compactMap { window -> WindowCandidateRead? in
                guard
                    let candidate = snapshot(
                        from: window,
                        includeVisibleCandidates:
                            includeVisibleCandidates,
                        includeVisibleTexts: includeVisibleTexts,
                        sawCandidateStructure: &sawCandidateStructure,
                        session: session
                    )
                else {
                    return nil
                }
                return WindowCandidateRead(
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
        if let candidate = preferred(from: candidates) {
            return candidate
        }
        if sawCandidateStructure {
            missReason = .structureMismatch
        } else {
            missReason = .candidateEnded
        }
        return nil
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        sawCandidateStructure: inout Bool,
        session: AXReadSession
    ) -> (candidateCount: Int, snapshot: AXCandidateSnapshot)? {
        for candidateList in candidateLists(
            in: window,
            session: session
        ) {
            sawCandidateStructure = true
            let selectedElements = session.elementsAttribute(
                candidateList,
                kAXSelectedChildrenAttribute
            )
            guard !selectedElements.isEmpty else {
                continue
            }
            let items = candidateItems(
                in: candidateList,
                selectedElements: selectedElements,
                includeVisibleTexts: includeVisibleTexts,
                session: session
            )
            let observations = items.map {
                SelectedChildGroupCandidateObservation(
                    text: $0.text,
                    frame: $0.frame,
                    isSelected: $0.isSelected
                )
            }
            if SelectedChildGroupCandidateParser.hasUnsupportedLayout(
                observations
            ) {
                missReason = .temporaryLayout
                return nil
            }
            guard
                let row = SelectedChildGroupCandidateParser.row(
                    from: observations
                )
            else {
                continue
            }
            return (
                row.items.count,
                Self.snapshot(
                    from: row,
                    candidateWindowFrame: session.frame(of: window),
                    includeVisibleCandidates:
                        includeVisibleCandidates,
                    includeVisibleTexts: includeVisibleTexts
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
        let children = session.elementsAttribute(
            window,
            kAXChildrenAttribute
        ).prefix(maximumNodeCount)
        for child in children {
            if isCandidateGroupList(
                child,
                session: session
            ) {
                result.append(child)
                continue
            }
            for grandchild in session.elementsAttribute(
                child,
                kAXChildrenAttribute
            ).prefix(maximumNodeCount)
            where isCandidateGroupList(
                grandchild,
                session: session
            ) {
                result.append(grandchild)
            }
        }
        return result
    }

    private func candidateItems(
        in candidateList: AXUIElement,
        selectedElements: [AXUIElement],
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> [CandidateItem] {
        var result: [CandidateItem] = []
        var queue = [(element: candidateList, depth: 0)]
        var nodeCount = 0
        while !queue.isEmpty,
            nodeCount < maximumNodeCount,
            !session.isExhausted
        {
            let (element, depth) = queue.removeFirst()
            for child in session.elementsAttribute(
                element,
                kAXChildrenAttribute
            ).prefix(maximumNodeCount) {
                nodeCount += 1
                if session.stringAttribute(
                    child,
                    kAXRoleAttribute
                ) == kAXGroupRole as String,
                    let item = candidateItem(
                        child,
                        selectedElements: selectedElements,
                        includeVisibleTexts:
                            includeVisibleTexts,
                        session: session
                    )
                {
                    result.append(item)
                    continue
                }
                guard depth < 3 else {
                    continue
                }
                queue.append((child, depth + 1))
            }
            if session.isExhausted {
                break
            }
        }
        return result
    }

    private func isCandidateGroupList(
        _ element: AXUIElement,
        session: AXReadSession
    ) -> Bool {
        guard
            session.stringAttribute(
                element,
                kAXRoleAttribute
            ) == kAXListRole as String
        else {
            return false
        }
        let selectedElements = session.elementsAttribute(
            element,
            kAXSelectedChildrenAttribute
        )
        if selectedElements.count == 1,
            session.stringAttribute(
                selectedElements[0],
                kAXRoleAttribute
            ) == kAXGroupRole as String
        {
            return true
        }
        return session.stringAttribute(
            element,
            kAXSubroleAttribute
        ) == "AXCollectionList"
    }

    private func candidateItem(
        _ element: AXUIElement,
        selectedElements: [AXUIElement],
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> CandidateItem? {
        let children = session.elementsAttribute(
            element,
            kAXChildrenAttribute
        )
        guard children.count == 2 else {
            return nil
        }
        guard
            let frame = session.frame(of: element),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }
        let isSelected = selectedElements.contains {
            CFEqual($0, element)
        }
        let text: String
        if includeVisibleTexts || isSelected {
            guard
                let candidateText = session.text(
                    of: children[0]
                ),
                !candidateText.isEmpty
            else {
                return nil
            }
            text = candidateText
        } else {
            text = ""
        }
        return CandidateItem(
            text: text,
            frame: frame,
            isSelected: isSelected
        )
    }

    private static func snapshot(
        from row: SelectedChildGroupCandidateRow,
        candidateWindowFrame: CGRect?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> AXCandidateSnapshot {
        let selected = row.selected
        let candidateListFrame = row.items.dropFirst().reduce(
            row.items[0].frame
        ) {
            $0.union($1.frame)
        }
        let verticalFrame =
            candidateWindowFrame
            ?? candidateListFrame
        let geometry = AXCandidateGeometry(
            horizontalFrame: selected.frame,
            horizontalSource: .item,
            verticalFrame: verticalFrame,
            verticalSource:
                candidateWindowFrame == nil ? .list : .window
        )
        guard includeVisibleCandidates else {
            return AXCandidateSnapshot(
                text: selected.text,
                visibleTexts: [],
                options: [],
                frame: selected.frame,
                candidateWindowFrame: candidateWindowFrame,
                candidateListFrame: candidateListFrame,
                geometry: geometry,
                selectedIndex: 0,
                selectionIsExact: true
            )
        }
        let options = row.items.enumerated().map {
            index,
            item in
            AXCandidateOption(
                text:
                    includeVisibleTexts || index == row.selectedIndex
                    ? item.text
                    : "",
                frame: item.frame,
                isSelected: index == row.selectedIndex
            )
        }
        return AXCandidateSnapshot(
            text: selected.text,
            visibleTexts:
                includeVisibleTexts
                ? row.items.map(\.text)
                : [],
            options: options,
            frame: selected.frame,
            candidateWindowFrame: candidateWindowFrame,
            candidateListFrame: candidateListFrame,
            geometry: geometry,
            selectedIndex: row.selectedIndex,
            selectionIsExact: true
        )
    }

    private func preferred(
        from candidates: [WindowCandidateRead]
    ) -> AXCandidateSnapshot? {
        candidates.max { lhs, rhs in
            if lhs.isVisible != rhs.isVisible {
                return !lhs.isVisible
            }
            let lhsHasFrame =
                lhs.snapshot.candidateWindowFrame.map {
                    $0.width > 0 && $0.height > 0
                } ?? false
            let rhsHasFrame =
                rhs.snapshot.candidateWindowFrame.map {
                    $0.width > 0 && $0.height > 0
                } ?? false
            if lhsHasFrame != rhsHasFrame {
                return !lhsHasFrame
            }
            return lhs.candidateCount < rhs.candidateCount
        }?.snapshot
    }
}

extension SelectedChildGroupCandidateReader: AXCandidateReading {}
