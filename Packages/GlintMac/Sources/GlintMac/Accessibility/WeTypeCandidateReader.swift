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
        while index < sorted.count {
            guard isShortcut(sorted[index].text),
                index + 1 < sorted.count
            else {
                index += 1
                continue
            }
            let shortcut = sorted[index]
            let candidate = sorted[index + 1]
            guard
                !isShortcut(candidate.text),
                candidate.frame.minX >= shortcut.frame.minX
            else {
                index += 1
                continue
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
    private let accessLimits: AXAccessLimits
    private let maximumWindowCount: Int
    private let maximumNodeCount: Int

    public convenience init(
        bundleIdentifier: String = InputMethodIdentifier.weTypeBundle,
        messagingTimeout: Float = 0.25,
        maximumWindowCount: Int = 3,
        maximumNodeCount: Int = 36
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
        let session = AXReadSession(limits: accessLimits)
        let windows = session.elementsAttribute(
            appElement,
            kAXWindowsAttribute
        )
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
        return AXCandidateWindowSelector.preferred(from: candidates)
    }

    private func snapshot(
        from window: AXUIElement,
        includeVisibleCandidates: Bool,
        includeVisibleTexts: Bool,
        session: AXReadSession
    ) -> (candidateCount: Int, snapshot: AXCandidateSnapshot)? {
        let observations = session.elementsAttribute(
            window,
            kAXChildrenAttribute
        )
        .prefix(maximumNodeCount)
        .compactMap {
            Self.observation($0, session: session)
        }
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
        let presentationFrames = groups.map {
            AXCandidateTextFrame.presentationFrame(for: $0.frame)
        }
        let selectedPresentationFrame =
            presentationFrames[selectedIndex]
        let candidateWindowFrame = session.frame(of: window)
        let candidateListFrame = groups.dropFirst().reduce(
            groups[0].frame
        ) {
            $0.union($1.frame)
        }
        let geometry = AXCandidateGeometry(
            horizontalFrame: selectedPresentationFrame,
            horizontalSource: .text,
            verticalFrame: selectedPresentationFrame,
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
                frame: presentationFrames[index],
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
        _ element: AXUIElement,
        session: AXReadSession
    ) -> WeTypeCandidateObservation? {
        guard
            session.stringAttribute(element, kAXRoleAttribute)
                == kAXStaticTextRole as String,
            let text = session.text(of: element),
            let frame = session.frame(of: element)
        else {
            return nil
        }
        return WeTypeCandidateObservation(
            text: text,
            frame: frame,
            foregroundBrightness:
                foregroundBrightness(
                    of: element,
                    textLength: text.count,
                    session: session
                )
        )
    }

    private static func foregroundBrightness(
        of element: AXUIElement,
        textLength: Int,
        session: AXReadSession
    ) -> Double? {
        var range =
            AXValueReader.range(
                session.attribute(
                    element,
                    "AXVisibleCharacterRange"
                )
            ) ?? CFRange(location: 0, length: textLength)
        guard range.length > 0,
            let parameter = AXValueCreate(.cfRange, &range)
        else {
            return nil
        }
        guard
            let attributed = session.parameterizedAttribute(
                element,
                kAXAttributedStringForRangeParameterizedAttribute,
                parameter
            ) as? NSAttributedString
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
}

extension WeTypeCandidateReader: AXCandidateReading {}
