import AppKit
import ApplicationServices
import Foundation

public struct AXCandidateOption: Sendable, Equatable {
    public let text: String
    public let frame: CGRect?
    public let isSelected: Bool

    public init(text: String, frame: CGRect?, isSelected: Bool) {
        self.text = text
        self.frame = frame
        self.isSelected = isSelected
    }
}

public struct AXCandidateSnapshot: Sendable, Equatable {
    public let text: String
    public let visibleTexts: [String]
    public let options: [AXCandidateOption]
    public let frame: CGRect?
    public let candidateWindowFrame: CGRect?
    public let candidateListFrame: CGRect?
    public let geometry: AXCandidateGeometry?
    public let selectedIndex: Int?
    public let selectionIsExact: Bool

    public init(
        text: String,
        visibleTexts: [String],
        options: [AXCandidateOption] = [],
        frame: CGRect?,
        candidateWindowFrame: CGRect? = nil,
        candidateListFrame: CGRect?,
        geometry: AXCandidateGeometry? = nil,
        selectedIndex: Int? = nil,
        selectionIsExact: Bool = true
    ) {
        self.text = text
        self.visibleTexts = visibleTexts
        self.options = options
        self.frame = frame
        self.candidateWindowFrame = candidateWindowFrame
        self.candidateListFrame = candidateListFrame
        self.geometry = geometry
        self.selectedIndex = selectedIndex
        self.selectionIsExact = selectionIsExact
    }
}

struct AXCandidateItem: Sendable, Equatable {
    let text: String
    let frame: CGRect?

    var identity: AXCandidateIdentity {
        AXCandidateIdentity(text: text, frame: frame)
    }
}

struct AXCandidateIdentity: Hashable {
    let text: String
    let frame: AXCandidateFrameIdentity?

    init(text: String, frame: CGRect?) {
        self.text = text
        self.frame = frame.flatMap(AXCandidateFrameIdentity.init)
    }
}

struct AXCandidateFrameIdentity: Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init?(_ frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return nil }
        x = Int((frame.minX * 2).rounded())
        y = Int((frame.minY * 2).rounded())
        width = Int((frame.width * 2).rounded())
        height = Int((frame.height * 2).rounded())
    }
}

struct AXCandidateVisibleRow: Sendable, Equatable {
    let items: [AXCandidateItem]
    let selectedIndex: Int
}

enum AXCandidateVisibleRowSelector {
    static let maximumRowCount = 9

    static func select(
        selected: AXCandidateItem,
        visible: [AXCandidateItem]
    ) -> AXCandidateVisibleRow? {
        var seen: Set<AXCandidateIdentity> = []
        let unique = visible.filter {
            seen.insert($0.identity).inserted
        }
        let framed: [(item: AXCandidateItem, frame: CGRect)] =
            unique.compactMap { item in
                guard let frame = item.frame,
                    frame.width > 0,
                    frame.height > 0
                else {
                    return nil
                }
                return (item: item, frame: frame)
            }
        guard framed.count > 1 else {
            return fallbackRow(selected: selected)
        }
        guard visibleRowCount(for: framed.map { $0.frame }) == 1,
            framed.count <= maximumRowCount,
            let matchedIndex = selectedIndex(
                in: framed.map { $0.item },
                selected: selected
            )
        else {
            return nil
        }
        let sorted = framed.enumerated().sorted { lhs, rhs in
            if lhs.element.frame.minX != rhs.element.frame.minX {
                return lhs.element.frame.minX < rhs.element.frame.minX
            }
            return lhs.offset < rhs.offset
        }
        let sortedSelectedIndex =
            sorted.firstIndex {
                $0.offset == matchedIndex
            } ?? 0
        return AXCandidateVisibleRow(
            items: sorted.map { $0.element.item },
            selectedIndex: sortedSelectedIndex
        )
    }

    private static func visibleRowCount(for frames: [CGRect]) -> Int {
        var rows: [CGRect] = []
        for frame in frames.sorted(by: {
            if $0.minY != $1.minY {
                return $0.minY < $1.minY
            }
            return $0.minX < $1.minX
        }) {
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
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let minimumHeight = min(lhs.height, rhs.height)
        return overlap >= minimumHeight * 0.5
    }

    private static func fallbackRow(
        selected: AXCandidateItem
    ) -> AXCandidateVisibleRow {
        AXCandidateVisibleRow(
            items: [selected],
            selectedIndex: 0
        )
    }

    private static func selectedIndex(
        in items: [AXCandidateItem],
        selected: AXCandidateItem
    ) -> Int? {
        let exactMatches = items.indices.filter {
            items[$0].identity == selected.identity
        }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        let textMatches = items.indices.filter {
            items[$0].text == selected.text
        }
        return textMatches.count == 1 ? textMatches[0] : nil
    }
}

public final class AXCandidateReader {
    private static let candidateListIdentifier = "InputMethodCandidateList"

    private var cachedApplicationPID: pid_t?
    private var cachedApplication: AXUIElement?
    private var cachedCandidateListPID: pid_t?
    private var cachedCandidateWindow: AXUIElement?
    private var cachedCandidateList: AXUIElement?

    public init() {}

    public func snapshot(
        processIdentifier: pid_t? = nil,
        includeVisibleCandidates: Bool = false,
        includeVisibleTexts: Bool = true
    ) -> AXCandidateSnapshot? {
        let session = AXReadSession(limits: .interactive)
        guard
            let application = applicationElement(
                processIdentifier: processIdentifier,
                session: session
            )
        else {
            return nil
        }
        let applicationPID =
            processIdentifier
            ?? Self.processIdentifier(
                of: application
            )
        let windows = session.elementsAttribute(
            application,
            kAXWindowsAttribute
        )
        guard !windows.isEmpty else {
            clearCandidateCache()
            return nil
        }
        if cachedCandidateListPID == applicationPID,
            let cachedCandidateWindow,
            let cachedCandidateList,
            windows.contains(where: {
                CFEqual($0, cachedCandidateWindow)
            }),
            Self.candidateList(
                cachedCandidateList,
                belongsTo: cachedCandidateWindow,
                session: session
            )
        {
            if let snapshot = Self.snapshot(
                from: cachedCandidateList,
                candidateWindow: cachedCandidateWindow,
                includeVisibleCandidates: includeVisibleCandidates,
                includeVisibleTexts: includeVisibleTexts,
                session: session
            ) {
                return snapshot
            }
        }
        clearCandidateCache()
        for window in windows {
            guard
                let list = Self.candidateList(
                    in: window,
                    session: session
                ),
                let snapshot = Self.snapshot(
                    from: list,
                    candidateWindow: window,
                    includeVisibleCandidates: includeVisibleCandidates,
                    includeVisibleTexts: includeVisibleTexts,
                    session: session
                )
            else {
                continue
            }
            cachedCandidateWindow = window
            cachedCandidateList = list
            cachedCandidateListPID = applicationPID
            return snapshot
        }
        return nil
    }

    private func clearCandidateCache() {
        cachedCandidateWindow = nil
        cachedCandidateList = nil
        cachedCandidateListPID = nil
    }

    private func applicationElement(
        processIdentifier: pid_t?,
        session: AXReadSession
    ) -> AXUIElement? {
        guard
            let resolvedPID = processIdentifier
                ?? Self.focusedProcessIdentifier(session: session)
        else {
            return nil
        }
        if cachedApplicationPID != resolvedPID
            || cachedApplication == nil
        {
            let application = AXUIElementCreateApplication(resolvedPID)
            AXUIElementSetMessagingTimeout(application, 0.25)
            cachedApplication = application
            cachedApplicationPID = resolvedPID
        }
        return cachedApplication
    }

    private static func focusedProcessIdentifier(
        session: AXReadSession
    ) -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        if let application = session.elementAttribute(
            system,
            kAXFocusedApplicationAttribute
        ) {
            return processIdentifier(of: application)
        }
        if let focusedElement = session.elementAttribute(
            system,
            kAXFocusedUIElementAttribute
        ) {
            var element = focusedElement
            for _ in 0..<64 {
                if session.stringAttribute(
                    element,
                    kAXRoleAttribute
                )
                    == kAXApplicationRole as String
                {
                    return processIdentifier(of: element)
                }
                guard
                    let parent = session.elementAttribute(
                        element,
                        kAXParentAttribute
                    )
                else {
                    break
                }
                element = parent
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private static func processIdentifier(
        of element: AXUIElement
    ) -> pid_t {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier
    }

    private static func isCandidateList(
        _ element: AXUIElement,
        session: AXReadSession
    ) -> Bool {
        session.stringAttribute(
            element,
            kAXIdentifierAttribute
        ) == candidateListIdentifier
    }

    private static func candidateList(
        in window: AXUIElement,
        session: AXReadSession
    ) -> AXUIElement? {
        for child in session.elementsAttribute(
            window,
            kAXChildrenAttribute
        ) {
            if isCandidateList(child, session: session) {
                return child
            }
            for grandchild in session.elementsAttribute(
                child,
                kAXChildrenAttribute
            )
            where isCandidateList(
                grandchild,
                session: session
            ) {
                return grandchild
            }
        }
        return nil
    }

    private static func candidateList(
        _ list: AXUIElement,
        belongsTo window: AXUIElement,
        session: AXReadSession
    ) -> Bool {
        for child in session.elementsAttribute(
            window,
            kAXChildrenAttribute
        ) {
            if CFEqual(child, list) {
                return true
            }
            if (session.elementsAttribute(
                child,
                kAXChildrenAttribute
            )).contains(where: {
                CFEqual($0, list)
            }) {
                return true
            }
        }
        return false
    }

    private static func snapshot(
        from list: AXUIElement,
        candidateWindow: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> AXCandidateSnapshot? {
        let selectedElements =
            session.elementsAttribute(
                list,
                kAXSelectedChildrenAttribute
            )
        let visibleElements =
            session.elementsAttribute(
                list,
                kAXVisibleChildrenAttribute
            )
        let selectionIsExact = !selectedElements.isEmpty
        let fallbackCandidates =
            visibleElements.isEmpty
            ? session.elementsAttribute(
                list,
                kAXChildrenAttribute
            )
            : visibleElements
        if !includeVisibleCandidates,
            let selectedElement =
                selectedElements.first
                ?? firstCandidateElement(
                    in: fallbackCandidates,
                    session: session
                ),
            let selected = candidateItem(
                of: selectedElement,
                session: session
            )
        {
            return AXCandidateSnapshot(
                text: selected.text,
                visibleTexts: [],
                options: [],
                frame: selected.frame,
                candidateWindowFrame: nil,
                candidateListFrame: nil,
                geometry: Self.geometry(for: selected.frame),
                selectedIndex: 0,
                selectionIsExact: selectionIsExact
            )
        }
        guard
            let selectedElement =
                selectedElements.first
                ?? firstCandidateElement(
                    in: fallbackCandidates,
                    session: session
                ),
            let selected = candidateItem(
                of: selectedElement,
                session: session
            )
        else {
            return nil
        }
        let candidateWindowFrame = session.frame(of: candidateWindow)
        let candidateListFrame = session.frame(of: list)
        let visibleItems = visibleElements.compactMap { element in
            if CFEqual(element, selectedElement) {
                return selected
            }
            if includeVisibleTexts {
                return candidateItem(
                    of: element,
                    session: session
                )
            }
            return candidateFrameItem(
                of: element,
                session: session
            )
        }
        guard
            let row = AXCandidateVisibleRowSelector.select(
                selected: selected,
                visible: visibleItems
            )
        else {
            return nil
        }
        let options = row.items.enumerated().map { index, item in
            AXCandidateOption(
                text: item.text,
                frame: item.frame,
                isSelected:
                    selectionIsExact
                    && index == row.selectedIndex
            )
        }
        let selectedItem = row.items[row.selectedIndex]
        return AXCandidateSnapshot(
            text: selectedItem.text,
            visibleTexts: row.items.map(\.text),
            options: options,
            frame: selectedItem.frame,
            candidateWindowFrame: candidateWindowFrame,
            candidateListFrame: candidateListFrame,
            geometry: Self.geometry(for: selectedItem.frame),
            selectedIndex: row.selectedIndex,
            selectionIsExact: selectionIsExact
        )
    }

    private static func geometry(
        for selectedFrame: CGRect?
    ) -> AXCandidateGeometry? {
        guard let selectedFrame else {
            return nil
        }
        return AXCandidateGeometry(
            horizontalFrame: selectedFrame,
            horizontalSource: .item,
            verticalFrame: selectedFrame,
            verticalSource: .item
        )
    }

    private static func firstCandidateElement(
        in elements: [AXUIElement],
        session: AXReadSession
    ) -> AXUIElement? {
        elements.first {
            session.text(of: $0) != nil
        }
    }

    private static func candidateItem(
        of element: AXUIElement,
        session: AXReadSession
    ) -> AXCandidateItem? {
        guard let text = session.text(of: element) else {
            return nil
        }
        return AXCandidateItem(
            text: text,
            frame: session.frame(of: element)
        )
    }

    private static func candidateFrameItem(
        of element: AXUIElement,
        session: AXReadSession
    ) -> AXCandidateItem? {
        guard let frame = session.frame(of: element),
            frame.width > 0,
            frame.height > 0
        else {
            return nil
        }
        return AXCandidateItem(text: "", frame: frame)
    }
}
