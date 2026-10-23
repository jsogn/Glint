import AppKit
import ApplicationServices
import Foundation
import GlintCore

struct WeTypeCandidateObservation: Sendable, Equatable {
    let text: String
    let frame: CGRect
    let foregroundBrightness: Double?
}

struct WeTypeCandidateGroup: Sendable, Equatable {
    let text: String
    let frame: CGRect
    let shortcutBrightness: Double?
    let candidateBrightness: Double?
}

enum WeTypeCandidateParser {
    static let minimumSelectionContrast = 0.08

    static func groups(
        from observations: [WeTypeCandidateObservation]
    ) -> [WeTypeCandidateGroup]? {
        let sorted = observations.sorted {
            if abs($0.frame.minY - $1.frame.minY) > 1 {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
        guard !sorted.isEmpty,
            visibleRowCount(for: sorted.map(\.frame)) == 1
        else {
            return nil
        }

        var groups: [WeTypeCandidateGroup] = []
        var index = 0
        while index + 1 < sorted.count {
            let shortcut = sorted[index]
            let candidate = sorted[index + 1]
            guard isShortcut(shortcut.text),
                candidate.frame.minX >= shortcut.frame.minX
            else {
                break
            }
            groups.append(
                WeTypeCandidateGroup(
                    text: candidate.text,
                    frame: shortcut.frame.union(candidate.frame),
                    shortcutBrightness: shortcut.foregroundBrightness,
                    candidateBrightness: candidate.foregroundBrightness
                )
            )
            index += 2
        }

        if groups.isEmpty,
            let firstCandidate = sorted.first(where: {
                !isShortcut($0.text)
            }) ?? sorted.first
        {
            groups.append(
                WeTypeCandidateGroup(
                    text: firstCandidate.text,
                    frame: firstCandidate.frame,
                    shortcutBrightness: nil,
                    candidateBrightness:
                        firstCandidate.foregroundBrightness
                )
            )
        }
        return groups.isEmpty ? nil : groups
    }

    static func selectedIndex(
        in groups: [WeTypeCandidateGroup]
    ) -> Int {
        selection(in: groups).index
    }

    static func selection(
        in groups: [WeTypeCandidateGroup]
    ) -> (index: Int, isExact: Bool) {
        guard groups.count > 1 else {
            return (0, true)
        }
        let brightness = groups.map {
            $0.shortcutBrightness ?? -.infinity
        }
        let ranked = brightness.enumerated().sorted {
            if $0.element != $1.element {
                return $0.element > $1.element
            }
            return $0.offset < $1.offset
        }
        guard let first = ranked.first,
            let second = ranked.dropFirst().first,
            first.element.isFinite,
            second.element.isFinite,
            first.element - second.element
                >= minimumSelectionContrast,
            brightness.filter({
                abs($0 - first.element) < 0.01
            }).count == 1
        else {
            return (0, false)
        }
        return (first.offset, true)
    }

    private static func isShortcut(_ text: String) -> Bool {
        text.count == 1 && text.first?.isNumber == true
    }

    private static func visibleRowCount(
        for frames: [CGRect]
    ) -> Int {
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
        let overlap =
            min(lhs.maxY, rhs.maxY)
            - max(lhs.minY, rhs.minY)
        return overlap >= min(lhs.height, rhs.height) * 0.5
    }
}

public final class WeTypeCandidateReader {
    public static let inputSourceID =
        InputMethodIdentifier.weTypePinyinMode

    private let bundleIdentifier: String
    private let messagingTimeout: Float
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int

    public init(
        bundleIdentifier: String = InputMethodIdentifier.weTypeBundle,
        messagingTimeout: Float = 0.25,
        maximumWindowCount: Int = 3,
        maximumNodeCount: Int = 36
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
        let snapshots = windows.prefix(maximumWindowCount).compactMap {
            snapshot(
                from: $0,
                includeVisibleCandidates: includeVisibleCandidates,
                includeVisibleTexts: includeVisibleTexts
            )
        }
        return snapshots.max {
            $0.candidateCount < $1.candidateCount
        }?.snapshot
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool
    ) -> (candidateCount: Int, snapshot: AXCandidateSnapshot)? {
        let observations = Self.elementsAttribute(
            window,
            kAXChildrenAttribute
        )
        .prefix(maximumNodeCount)
        .compactMap(Self.observation)
        guard observations.count >= 2,
            let groups = WeTypeCandidateParser.groups(
                from: observations
            )
        else {
            return nil
        }
        let selection = WeTypeCandidateParser.selection(
            in: groups
        )
        let selectedIndex = selection.index
        guard groups.indices.contains(selectedIndex)
        else {
            return nil
        }
        let selected = groups[selectedIndex]
        let selectedFrame = selected.frame
        let candidateWindowFrame = Self.frame(of: window)
        let candidateListFrame = groups.dropFirst().reduce(
            groups[0].frame
        ) {
            $0.union($1.frame)
        }
        let geometry = AXCandidateGeometry(
            horizontalFrame: selectedFrame,
            horizontalSource: .text,
            verticalFrame: selectedFrame,
            verticalSource: .text
        )
        if !includeVisibleCandidates {
            return (
                groups.count,
                AXCandidateSnapshot(
                    text: selected.text,
                    visibleTexts: [],
                    options: [],
                    frame: selectedFrame,
                    candidateWindowFrame: candidateWindowFrame,
                    candidateListFrame: candidateListFrame,
                    geometry: geometry,
                    selectedIndex: 0,
                    selectionIsExact: selection.isExact
                )
            )
        }
        let options = groups.enumerated().map { index, group in
            AXCandidateOption(
                text:
                    includeVisibleTexts || index == selectedIndex
                    ? group.text
                    : "",
                frame: group.frame,
                isSelected:
                    selection.isExact
                    && index == selectedIndex
            )
        }
        return (
            groups.count,
            AXCandidateSnapshot(
                text: selected.text,
                visibleTexts:
                    includeVisibleTexts
                    ? groups.map(\.text)
                    : [],
                options: options,
                frame: selectedFrame,
                candidateWindowFrame: candidateWindowFrame,
                candidateListFrame: candidateListFrame,
                geometry: geometry,
                selectedIndex: selectedIndex,
                selectionIsExact: selection.isExact
            )
        )
    }

    private static func observation(
        _ element: AXUIElement
    ) -> WeTypeCandidateObservation? {
        guard
            stringAttribute(element, kAXRoleAttribute)
                == kAXStaticTextRole as String,
            let text = text(of: element),
            let frame = frame(of: element)
        else {
            return nil
        }
        return WeTypeCandidateObservation(
            text: text,
            frame: frame,
            foregroundBrightness:
                foregroundBrightness(
                    of: element,
                    textLength: text.count
                )
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

    private static func foregroundBrightness(
        of element: AXUIElement,
        textLength: Int
    ) -> Double? {
        var range =
            AXValueReader.range(
                attribute(
                    element,
                    "AXVisibleCharacterRange"
                )
            ) ?? CFRange(location: 0, length: textLength)
        guard range.length > 0,
            let parameter = AXValueCreate(.cfRange, &range)
        else {
            return nil
        }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXAttributedStringForRangeParameterizedAttribute
                    as CFString,
                parameter,
                &value
            ) == .success,
            let attributed = value as? NSAttributedString
        else {
            return nil
        }

        let key = NSAttributedString.Key(
            "AXForegroundColor"
        )
        var maximum: Double?
        attributed.enumerateAttributes(
            in: NSRange(
                location: 0,
                length: attributed.length
            )
        ) { attributes, _, _ in
            guard let rawColor = attributes[key] else {
                return
            }
            let cfColor = rawColor as CFTypeRef
            guard CFGetTypeID(cfColor) == CGColor.typeID
            else {
                return
            }
            let color = unsafeDowncast(
                cfColor,
                to: CGColor.self
            )
            guard
                let rgb = NSColor(cgColor: color)?
                    .usingColorSpace(.deviceRGB)
            else {
                return
            }
            let brightness =
                (rgb.redComponent
                    + rgb.greenComponent
                    + rgb.blueComponent) / 3
            maximum = max(maximum ?? -1, brightness)
        }
        return maximum
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

extension WeTypeCandidateReader: AXCandidateReading {}
