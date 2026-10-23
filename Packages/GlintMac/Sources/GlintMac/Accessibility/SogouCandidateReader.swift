import AppKit
import ApplicationServices
import Foundation
import GlintCore

struct SogouCandidateObservation: Sendable, Equatable {
    let text: String
    let frame: CGRect
}

enum SogouCandidateParser {
    static let maximumCandidateCount = 9

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
            (1...maximumCandidateCount).contains(sorted.count),
            visibleRowCount(for: sorted.map(\.frame)) == 1
        else {
            return nil
        }
        return sorted
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

    private let bundleIdentifier: String
    private let messagingTimeout: Float
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int

    public init(
        bundleIdentifier: String = InputMethodIdentifier.sogouBundle,
        messagingTimeout: Float = 0.25,
        maximumWindowCount: Int = 3,
        maximumNodeCount: Int = 24
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.messagingTimeout = messagingTimeout
        self.maximumWindowCount = max(1, maximumWindowCount)
        self.maximumNodeCount = max(1, maximumNodeCount)
    }

    public func snapshot(
        processIdentifier: pid_t? = nil,
        includeVisibleCandidates: Bool = false,
        includeVisibleTexts: Bool = true
    ) -> AXCandidateSnapshot? {
        guard
            let application =
                NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: bundleIdentifier
                )
                .first(where: { !$0.isTerminated })
        else {
            return nil
        }
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        let windows = Self.elementsAttribute(
            appElement,
            kAXWindowsAttribute
        )
        return windows.prefix(maximumWindowCount)
            .compactMap {
                snapshot(
                    from: $0,
                    includeVisibleCandidates:
                        includeVisibleCandidates,
                    includeVisibleTexts: includeVisibleTexts
                )
            }
            .max {
                $0.candidateCount < $1.candidateCount
            }?
            .snapshot
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> (candidateCount: Int, snapshot: AXCandidateSnapshot)? {
        for list in candidateLists(in: window) {
            let visibleElements = Self.elementsAttribute(
                list,
                kAXVisibleChildrenAttribute
            )
            let candidateElements =
                visibleElements.isEmpty
                ? Self.elementsAttribute(
                    list,
                    kAXChildrenAttribute
                )
                : visibleElements
            let observations =
                candidateElements
                .prefix(maximumNodeCount)
                .compactMap(Self.observation)
            guard
                let candidates = SogouCandidateParser.candidates(
                    from: observations
                ),
                let first = candidates.first
            else {
                continue
            }
            let candidateWindowFrame = Self.frame(of: window)
            let candidateListFrame = Self.frame(of: list)
            let geometry = Self.geometry(
                selectedFrame: first.frame,
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
                    frame: candidate.frame,
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
        in window: AXUIElement
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for child in Self.elementsAttribute(
            window,
            kAXChildrenAttribute
        ).prefix(maximumNodeCount) {
            if Self.stringAttribute(
                child,
                kAXRoleAttribute
            ) == kAXListRole as String {
                result.append(child)
            }
            for grandchild in Self.elementsAttribute(
                child,
                kAXChildrenAttribute
            ).prefix(maximumNodeCount)
            where Self.stringAttribute(
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
            verticalFrame = candidateWindowFrame
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
        _ element: AXUIElement
    ) -> SogouCandidateObservation? {
        guard
            stringAttribute(element, kAXRoleAttribute)
                == kAXStaticTextRole as String,
            let text = text(of: element),
            let frame = frame(of: element),
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

    private static func text(
        of element: AXUIElement
    ) -> String? {
        for name in [
            kAXValueAttribute,
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            "AXValueDescription",
        ] {
            guard let value = attribute(element, name) as? String
            else {
                continue
            }
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
    }

    private static func frame(
        of element: AXUIElement
    ) -> CGRect? {
        if let frame = AXValueReader.rect(
            attribute(element, "AXFrame")
        ) {
            return frame
        }
        guard
            let position = AXValueReader.point(
                attribute(element, kAXPositionAttribute)
            ),
            let size = AXValueReader.size(
                attribute(element, kAXSizeAttribute)
            )
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> String? {
        attribute(element, name) as? String
    }

    private static func elementsAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    private static func attribute(
        _ element: AXUIElement,
        _ name: String
    ) -> Any? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                name as CFString,
                &value
            ) == .success
        else {
            return nil
        }
        return value
    }
}

extension SogouCandidateReader: AXCandidateReading {}
