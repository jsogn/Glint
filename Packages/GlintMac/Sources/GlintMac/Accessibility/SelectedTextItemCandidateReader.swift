import AppKit
import ApplicationServices
import Foundation
import GlintCore

struct SelectedTextItemCandidateObservation: Sendable, Equatable {
    let text: String
    let frame: CGRect
    let isSelected: Bool
}

struct SelectedTextItemCandidateRow: Sendable, Equatable {
    let items: [SelectedTextItemCandidateObservation]
    let selectedIndex: Int

    var selected: SelectedTextItemCandidateObservation {
        items[selectedIndex]
    }
}

final class SelectedTextItemReaderPool: @unchecked Sendable {
    private struct Key: Hashable {
        let bundleIdentifier: String
        let inputSourceIdentifier: String
    }

    private static let maximumReaderCount = 32
    private let lock = NSLock()
    private var readers: [Key: SelectedTextItemCandidateReader] = [:]

    func reader(
        bundleIdentifier: String,
        inputSourceIdentifier: String
    ) -> SelectedTextItemCandidateReader {
        let key = Key(
            bundleIdentifier: bundleIdentifier,
            inputSourceIdentifier: inputSourceIdentifier
        )
        lock.lock()
        defer { lock.unlock() }
        if let reader = readers[key] {
            return reader
        }
        if readers.count >= Self.maximumReaderCount,
            let staleKey = readers.keys.first
        {
            readers.removeValue(forKey: staleKey)
        }
        let reader = SelectedTextItemCandidateReader(
            bundleIdentifier: bundleIdentifier
        )
        readers[key] = reader
        return reader
    }
}

public struct SelectedTextItemCandidateCacheStatistics:
    Sendable,
    Equatable
{
    public let hits: UInt64
    public let misses: UInt64

    public init(hits: UInt64, misses: UInt64) {
        self.hits = hits
        self.misses = misses
    }
}

enum SelectedTextItemCandidateParser {
    static let minimumCandidateCount =
        CandidateCountPolicy.runtimeRange.lowerBound

    static func row(
        from observations: [SelectedTextItemCandidateObservation]
    ) -> SelectedTextItemCandidateRow? {
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
            CandidateCountPolicy.runtimeRange.contains(
                sorted.count
            ),
            selectedIndices.count == 1,
            visibleRowCount(for: sorted.map(\.frame)) == 1
        else {
            return nil
        }
        return SelectedTextItemCandidateRow(
            items: sorted,
            selectedIndex: selectedIndices[0]
        )
    }

    static func isSingleVisibleRow(
        _ frames: [CGRect]
    ) -> Bool {
        !frames.isEmpty
            && visibleRowCount(for: frames) == 1
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

public final class SelectedTextItemCandidateReader:
    @unchecked Sendable
{
    private struct CandidateItemElement {
        let element: AXUIElement
        let textElement: AXUIElement
        let observation: SelectedTextItemCandidateObservation
    }

    private struct CandidateItemSet {
        let container: AXUIElement
        let containerChildCount: Int
        let items: [CandidateItemElement]
        let layoutFrames: [CGRect]
        let windowChildCount: Int
    }

    private struct CachedCandidateSet {
        let applicationSession: HostProcessSession
        let window: AXUIElement
        let windowChildCount: Int
        let container: AXUIElement
        let containerChildCount: Int
        let items: [CandidateItemElement]
        let candidateWindowFrame: CGRect?
    }

    private struct WindowCandidateRead {
        let candidateCount: Int
        let snapshot: AXCandidateSnapshot
        let isVisible: Bool
        let candidateSet: CachedCandidateSet
    }

    private let bundleIdentifier: String
    private let accessLimits: AXAccessLimits
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int
    private let snapshotLock = NSLock()
    private var cachedCandidateSet: CachedCandidateSet?
    private var cacheHits: UInt64 = 0
    private var cacheMisses: UInt64 = 0
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
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotLocked(
            processIdentifier: processIdentifier,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
    }

    private func snapshotLocked(
        processIdentifier: pid_t?,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
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
            cachedCandidateSet = nil
            missReason = .candidateEnded
            return nil
        }
        let applicationSession = HostProcessSession.current(
            processIdentifier: application.processIdentifier
        )
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        let session = AXReadSession(limits: accessLimits)
        let windows =
            session.attribute(
                appElement,
                kAXWindowsAttribute
            ) as? [AXUIElement]
        if let cachedCandidateSet,
            cachedCandidateSet.applicationSession
                == applicationSession,
            let windows,
            !windows.contains(where: {
                CFEqual($0, cachedCandidateSet.window)
            })
                || (session.boolAttribute(
                    cachedCandidateSet.window,
                    kAXHiddenAttribute
                ) ?? false)
        {
            self.cachedCandidateSet = nil
            missReason = .candidateEnded
            return nil
        }
        guard let windows else {
            return nil
        }
        if let cachedSnapshot = cachedSnapshot(
            applicationSession: applicationSession,
            windows: windows,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts,
            session: session
        ) {
            cacheHits &+= 1
            return cachedSnapshot
        }
        if missReason == .temporaryLayout {
            return nil
        }
        cachedCandidateSet = nil
        var sawTemporaryLayout = false
        var sawCandidateStructure = false
        let candidates = windows.prefix(maximumWindowCount)
            .compactMap { window -> WindowCandidateRead? in
                guard
                    let candidate = snapshot(
                        from: window,
                        includeVisibleCandidates:
                            includeVisibleCandidates,
                        includeVisibleTexts: includeVisibleTexts,
                        session: session,
                        sawTemporaryLayout: &sawTemporaryLayout,
                        sawCandidateStructure: &sawCandidateStructure
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
                        ) ?? false),
                    candidateSet: CachedCandidateSet(
                        applicationSession: applicationSession,
                        window: window,
                        windowChildCount:
                            candidate.windowChildCount,
                        container: candidate.container,
                        containerChildCount:
                            candidate.containerChildCount,
                        items: candidate.items,
                        candidateWindowFrame:
                            candidate.snapshot.candidateWindowFrame
                    )
                )
            }
        let preferred = candidates.max {
            Self.isPreferredWindow($1, over: $0)
        }
        cachedCandidateSet = preferred?.candidateSet
        if preferred != nil {
            cacheMisses &+= 1
        } else if sawTemporaryLayout {
            missReason = .temporaryLayout
        } else if sawCandidateStructure {
            missReason = .structureMismatch
        }
        return preferred?.snapshot
    }

    public func cacheStatistics()
        -> SelectedTextItemCandidateCacheStatistics
    {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return SelectedTextItemCandidateCacheStatistics(
            hits: cacheHits,
            misses: cacheMisses
        )
    }

    private func cachedSnapshot(
        applicationSession: HostProcessSession,
        windows: [AXUIElement],
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> AXCandidateSnapshot? {
        guard
            let cachedCandidateSet,
            session.elementsAttribute(
                cachedCandidateSet.window,
                kAXChildrenAttribute
            ).count == cachedCandidateSet.windowChildCount
        else {
            return nil
        }
        guard
            cachedCandidateSet.applicationSession
                == applicationSession,
            windows.contains(where: {
                CFEqual($0, cachedCandidateSet.window)
            }),
            Self.candidateContainer(
                cachedCandidateSet.container,
                belongsTo: cachedCandidateSet.window,
                session: session
            )
        else {
            return nil
        }
        let children = session.elementsAttribute(
            cachedCandidateSet.container,
            kAXChildrenAttribute
        )
        if children.count != cachedCandidateSet.containerChildCount {
            let layoutFrames =
                children
                .prefix(maximumNodeCount)
                .compactMap {
                    session.frame(of: $0)
                }
                .filter {
                    $0.width > 0 && $0.height > 0
                }
            if !SelectedTextItemCandidateParser
                .isSingleVisibleRow(layoutFrames)
            {
                missReason = .temporaryLayout
                return nil
            }
        }
        let containsCachedItems =
            cachedCandidateSet.items.allSatisfy { item in
                children.contains {
                    CFEqual($0, item.element)
                }
            }
        guard
            children.count == cachedCandidateSet.containerChildCount,
            containsCachedItems
        else {
            return nil
        }
        let framesAndSelections = cachedCandidateSet.items.compactMap {
            item -> (
                item: CandidateItemElement,
                frame: CGRect,
                isSelected: Bool
            )? in
            guard
                let frame = session.frame(of: item.element),
                frame.width > 0,
                frame.height > 0
            else {
                return nil
            }
            return (
                item,
                frame,
                session.boolAttribute(
                    item.element,
                    kAXSelectedAttribute
                ) ?? false
            )
        }
        guard
            framesAndSelections.count
                == cachedCandidateSet.items.count
        else {
            return nil
        }
        let selectedIndices = framesAndSelections.indices.filter {
            framesAndSelections[$0].isSelected
        }
        guard selectedIndices.count == 1 else {
            return nil
        }
        let observations = framesAndSelections.enumerated().map {
            index,
            value -> SelectedTextItemCandidateObservation? in
            let text: String
            if includeVisibleTexts || index == selectedIndices[0] {
                guard
                    let selectedText = session.text(
                        of: value.item.textElement
                    )
                else {
                    return nil
                }
                text = selectedText
            } else {
                text = ""
            }
            return SelectedTextItemCandidateObservation(
                text: text,
                frame: value.frame,
                isSelected: value.isSelected
            )
        }
        guard
            let row = SelectedTextItemCandidateParser.row(
                from: observations.compactMap { $0 }
            ),
            row.items.count == cachedCandidateSet.items.count
        else {
            return nil
        }
        return Self.snapshot(
            from: row,
            candidateWindowFrame:
                cachedCandidateSet.candidateWindowFrame,
            includeVisibleCandidates: includeVisibleCandidates,
            includeVisibleTexts: includeVisibleTexts
        )
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        session: AXReadSession,
        sawTemporaryLayout: inout Bool,
        sawCandidateStructure: inout Bool
    ) -> (
        candidateCount: Int,
        snapshot: AXCandidateSnapshot,
        windowChildCount: Int,
        container: AXUIElement,
        containerChildCount: Int,
        items: [CandidateItemElement]
    )? {
        for candidateSet in candidateItemSets(
            in: window,
            session: session
        ) {
            guard
                SelectedTextItemCandidateParser
                    .isSingleVisibleRow(candidateSet.layoutFrames)
            else {
                sawTemporaryLayout = true
                continue
            }
            sawCandidateStructure = true
            guard
                let row = SelectedTextItemCandidateParser.row(
                    from: candidateSet.items.map(\.observation)
                )
            else {
                continue
            }
            let candidateWindowFrame = session.frame(of: window)
            return (
                row.items.count,
                Self.snapshot(
                    from: row,
                    candidateWindowFrame: candidateWindowFrame,
                    includeVisibleCandidates:
                        includeVisibleCandidates,
                    includeVisibleTexts: includeVisibleTexts
                ),
                candidateSet.windowChildCount,
                candidateSet.container,
                candidateSet.containerChildCount,
                candidateSet.items
            )
        }
        return nil
    }

    private func candidateItemSets(
        in window: AXUIElement,
        session: AXReadSession
    ) -> [CandidateItemSet] {
        let children = session.elementsAttribute(
            window,
            kAXChildrenAttribute
        )
        let visibleChildren = children.prefix(maximumNodeCount)
        var directItems: [CandidateItemElement] = []
        var nestedItems: [CandidateItemSet] = []

        for child in visibleChildren {
            if let item = Self.candidateItemElement(
                child,
                session: session
            ) {
                directItems.append(item)
                continue
            }
            let nestedChildren = session.elementsAttribute(
                child,
                kAXChildrenAttribute
            )
            let observations =
                nestedChildren
                .prefix(maximumNodeCount)
                .compactMap {
                    Self.candidateItemElement($0, session: session)
                }
            let layoutFrames =
                nestedChildren
                .prefix(maximumNodeCount)
                .compactMap {
                    session.frame(of: $0)
                }
                .filter {
                    $0.width > 0 && $0.height > 0
                }
            if observations.count
                >= SelectedTextItemCandidateParser
                .minimumCandidateCount
            {
                nestedItems.append(
                    CandidateItemSet(
                        container: child,
                        containerChildCount: nestedChildren.count,
                        items: observations,
                        layoutFrames: layoutFrames,
                        windowChildCount: children.count
                    )
                )
            }
        }
        if directItems.count
            >= SelectedTextItemCandidateParser.minimumCandidateCount
        {
            nestedItems.append(
                CandidateItemSet(
                    container: window,
                    containerChildCount: children.count,
                    items: directItems,
                    layoutFrames:
                        directItems.map(\.observation.frame),
                    windowChildCount: children.count
                )
            )
        }
        return nestedItems
    }

    private static func snapshot(
        from row: SelectedTextItemCandidateRow,
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
        let geometry = AXCandidateGeometry(
            horizontalFrame: selected.frame,
            horizontalSource: .item,
            verticalFrame: selected.frame,
            verticalSource: .item
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

    private static func isPreferredWindow(
        _ candidate: WindowCandidateRead,
        over current: WindowCandidateRead
    ) -> Bool {
        if candidate.isVisible != current.isVisible {
            return candidate.isVisible
        }
        let candidateHasFrame =
            candidate.snapshot.candidateWindowFrame.map {
                $0.width > 0 && $0.height > 0
            } ?? false
        let currentHasFrame =
            current.snapshot.candidateWindowFrame.map {
                $0.width > 0 && $0.height > 0
            } ?? false
        if candidateHasFrame != currentHasFrame {
            return candidateHasFrame
        }
        return candidate.candidateCount > current.candidateCount
    }

    private static func candidateContainer(
        _ container: AXUIElement,
        belongsTo window: AXUIElement,
        session: AXReadSession
    ) -> Bool {
        if CFEqual(container, window) {
            return true
        }
        var current = container
        for _ in 0..<3 {
            guard
                let parent = session.elementAttribute(
                    current,
                    kAXParentAttribute
                )
            else {
                return false
            }
            if CFEqual(parent, window) {
                return true
            }
            current = parent
        }
        return false
    }

    private static func candidateItemElement(
        _ element: AXUIElement,
        session: AXReadSession
    ) -> CandidateItemElement? {
        guard
            let frame = session.frame(of: element),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }
        let children = session.elementsAttribute(
            element,
            kAXChildrenAttribute
        )
        guard children.count == 2 else {
            return nil
        }
        let texts = children.compactMap {
            session.text(of: $0)
        }
        guard texts.count == 2,
            isShortcut(texts[0]),
            !texts[1].isEmpty
        else {
            return nil
        }
        return CandidateItemElement(
            element: element,
            textElement: children[1],
            observation: SelectedTextItemCandidateObservation(
                text: texts[1],
                frame: frame,
                isSelected:
                    session.boolAttribute(
                        element,
                        kAXSelectedAttribute
                    ) ?? false
            )
        )
    }

    private static func isShortcut(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.count == 1
            && trimmed.first?.isNumber == true
    }
}

extension SelectedTextItemCandidateReader: AXCandidateReading {}
