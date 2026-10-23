import AppKit
import ApplicationServices
import Foundation

private let weTypeBundleIdentifier =
    "com.tencent.inputmethod.wetype"

private struct ProbeOptions {
    let pid: pid_t?
    let seconds: Double
}

private struct RectValue: Encodable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ rect: CGRect) {
        x = Int(rect.minX.rounded())
        y = Int(rect.minY.rounded())
        width = Int(rect.width.rounded())
        height = Int(rect.height.rounded())
    }
}

private struct RangeValue: Encodable {
    let location: Int
    let length: Int
}

private struct ElementNode: Encodable {
    let role: String?
    let subrole: String?
    let identifier: String?
    let attributeNames: [String]
    let actionNames: [String]
    let isSelected: Bool?
    let isFocused: Bool?
    let isEnabled: Bool?
    let titleLength: Int?
    let valueLength: Int?
    let descriptionLength: Int?
    let roleDescriptionLength: Int?
    let foregroundBrightness: Double?
    let selectedTextLength: Int?
    let numberOfCharacters: Int?
    let selectedTextRange: RangeValue?
    let visibleCharacterRange: RangeValue?
    let insertionPointLineNumber: Int?
    let frame: RectValue?
    let childCount: Int
    let selectedChildCount: Int
    let visibleChildCount: Int
    let navigationOrderCount: Int
    let titleUIElementRole: String?
    let titleUIElementFrame: RectValue?
    let children: [ElementNode]
    let sectionCount: Int
    let sections: [ElementNode]

    var hasText: Bool {
        (titleLength ?? 0) > 0
            || (valueLength ?? 0) > 0
            || (descriptionLength ?? 0) > 0
    }
}

private struct WindowNode: Encodable {
    let root: ElementNode
    let nodeCount: Int
    let textNodeCount: Int
    let staticTextNodeCount: Int
    let framedTextNodeCount: Int
    let listCount: Int
    let selectedListCount: Int
    let selectedTextNodeCount: Int
    let focusedTextNodeCount: Int
    let selectedRangeTextNodeCount: Int
    let styleSelectedCandidateIndex: Int?
}

private struct ProbeResult: Encodable {
    let pid: pid_t
    let candidateWindowAvailable: Bool
    let selectedSemanticsAvailable: Bool
    let reason: String?
    let windowCount: Int
    let windows: [WindowNode]
}

private enum AXReader {
    static func attribute(
        _ element: AXUIElement,
        _ name: String
    ) -> CFTypeRef? {
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

    static func string(
        _ element: AXUIElement,
        _ name: String
    ) -> String? {
        attribute(element, name) as? String
    }

    static func textLength(
        _ element: AXUIElement,
        _ name: String
    ) -> Int? {
        string(element, name)?.count
    }

    static func bool(
        _ element: AXUIElement,
        _ name: String
    ) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    static func integer(
        _ element: AXUIElement,
        _ name: String
    ) -> Int? {
        (attribute(element, name) as? NSNumber)?.intValue
    }

    static func foregroundBrightness(
        _ element: AXUIElement
    ) -> Double? {
        let text =
            string(element, kAXValueAttribute)
            ?? string(element, kAXTitleAttribute)
            ?? string(element, kAXDescriptionAttribute)
        guard let text, !text.isEmpty else { return nil }
        let visibleRange = self.range(
            element,
            "AXVisibleCharacterRange"
        )
        var range =
            visibleRange.map {
                CFRange(
                    location: $0.location,
                    length: $0.length
                )
            }
            ?? CFRange(location: 0, length: text.count)
        guard let parameter = AXValueCreate(.cfRange, &range)
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

    static func elements(
        _ element: AXUIElement,
        _ name: String
    ) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    static func elementAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> AXUIElement? {
        guard let value = attribute(element, name),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func attributeNames(
        _ element: AXUIElement
    ) -> [String] {
        var names: CFArray?
        guard
            AXUIElementCopyAttributeNames(
                element,
                &names
            ) == .success
        else {
            return []
        }
        return names as? [String] ?? []
    }

    static func actionNames(
        _ element: AXUIElement
    ) -> [String] {
        var names: CFArray?
        guard
            AXUIElementCopyActionNames(
                element,
                &names
            ) == .success
        else {
            return []
        }
        return names as? [String] ?? []
    }

    static func frame(
        _ element: AXUIElement
    ) -> CGRect? {
        if let raw = attribute(element, "AXFrame"),
            CFGetTypeID(raw) == AXValueGetTypeID()
        {
            var rect = CGRect.zero
            if AXValueGetValue(
                unsafeDowncast(raw, to: AXValue.self),
                .cgRect,
                &rect
            ) {
                return rect
            }
        }
        guard
            let positionValue = attribute(
                element,
                kAXPositionAttribute
            ),
            let sizeValue = attribute(
                element,
                kAXSizeAttribute
            ),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(
                unsafeDowncast(positionValue, to: AXValue.self),
                .cgPoint,
                &position
            ),
            AXValueGetValue(
                unsafeDowncast(sizeValue, to: AXValue.self),
                .cgSize,
                &size
            )
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    static func range(
        _ element: AXUIElement,
        _ name: String
    ) -> RangeValue? {
        guard let raw = attribute(element, name),
            CFGetTypeID(raw) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard
            AXValueGetValue(
                unsafeDowncast(raw, to: AXValue.self),
                .cfRange,
                &range
            )
        else {
            return nil
        }
        return RangeValue(
            location: range.location,
            length: range.length
        )
    }

    static func node(
        _ element: AXUIElement,
        depth: Int = 0
    ) -> ElementNode {
        let children = elements(
            element,
            kAXChildrenAttribute
        )
        let selectedChildren = elements(
            element,
            kAXSelectedChildrenAttribute
        )
        let visibleChildren = elements(
            element,
            kAXVisibleChildrenAttribute
        )
        let navigationChildren = elements(
            element,
            "AXChildrenInNavigationOrder"
        )
        let sections = elements(
            element,
            "AXSections"
        )
        let titleUIElement = elementAttribute(
            element,
            kAXTitleUIElementAttribute
        )
        let nested =
            depth < 12
            ? children.map {
                node($0, depth: depth + 1)
            }
            : []
        let nestedSections =
            depth < 12
            ? sections.map {
                node($0, depth: depth + 1)
            }
            : []
        return ElementNode(
            role: string(element, kAXRoleAttribute),
            subrole: string(element, kAXSubroleAttribute),
            identifier: summarizeIdentifier(
                string(element, kAXIdentifierAttribute)
            ),
            attributeNames: attributeNames(element).sorted(),
            actionNames: actionNames(element).sorted(),
            isSelected: bool(
                element,
                kAXSelectedAttribute
            ),
            isFocused: bool(
                element,
                kAXFocusedAttribute
            ),
            isEnabled: bool(
                element,
                kAXEnabledAttribute
            ),
            titleLength: textLength(
                element,
                kAXTitleAttribute
            ),
            valueLength: textLength(
                element,
                kAXValueAttribute
            ),
            descriptionLength: textLength(
                element,
                kAXDescriptionAttribute
            ),
            roleDescriptionLength: textLength(
                element,
                kAXRoleDescriptionAttribute
            ),
            foregroundBrightness: foregroundBrightness(element),
            selectedTextLength: textLength(
                element,
                kAXSelectedTextAttribute
            ),
            numberOfCharacters: integer(
                element,
                kAXNumberOfCharactersAttribute
            ),
            selectedTextRange: range(
                element,
                kAXSelectedTextRangeAttribute
            ),
            visibleCharacterRange: range(
                element,
                "AXVisibleCharacterRange"
            ),
            insertionPointLineNumber: integer(
                element,
                "AXInsertionPointLineNumber"
            ),
            frame: frame(element).map(RectValue.init),
            childCount: children.count,
            selectedChildCount: selectedChildren.count,
            visibleChildCount: visibleChildren.count,
            navigationOrderCount: navigationChildren.count,
            titleUIElementRole: titleUIElement.flatMap {
                string($0, kAXRoleAttribute)
            },
            titleUIElementFrame: titleUIElement.flatMap {
                frame($0)
            }.map(RectValue.init),
            children: nested,
            sectionCount: sections.count,
            sections: nestedSections
        )
    }

    private static func summarizeIdentifier(
        _ identifier: String?
    ) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier.lowercased()
        if normalized.contains("candidate") {
            return "<candidate-like>"
        }
        if normalized.contains("inputmethod") {
            return "<inputmethod-like>"
        }
        return "<other>"
    }
}

private func probeOptions() -> ProbeOptions {
    let arguments = CommandLine.arguments
    var pid: pid_t?
    var seconds = 20.0
    var index = 1
    while index + 1 < arguments.count {
        switch arguments[index] {
        case "--pid":
            pid = pid_t(arguments[index + 1])
        case "--seconds":
            seconds = Double(arguments[index + 1]) ?? seconds
        default:
            break
        }
        index += 2
    }
    return ProbeOptions(
        pid: pid,
        seconds: min(max(seconds, 1), 120)
    )
}

private func weTypePID(
    explicitPID: pid_t?
) -> pid_t? {
    if let explicitPID {
        return explicitPID
    }
    return NSRunningApplication.runningApplications(
        withBundleIdentifier: weTypeBundleIdentifier
    ).first?.processIdentifier
}

private func flatten(
    _ node: ElementNode
) -> [ElementNode] {
    var result: [ElementNode] = []
    result.append(node)
    for child in node.children {
        result.append(contentsOf: flatten(child))
    }
    for section in node.sections {
        result.append(contentsOf: flatten(section))
    }
    return result
}

private func summarize(
    _ root: ElementNode
) -> WindowNode {
    let nodes = flatten(root)
    let textNodes = nodes.filter(\.hasText)
    let staticTextNodes = textNodes.filter {
        $0.role == kAXStaticTextRole as String
    }
    let selectedTextNodes = staticTextNodes.filter {
        $0.isSelected == true
    }
    let focusedTextNodes = staticTextNodes.filter {
        $0.isFocused == true
    }
    let selectedRangeTextNodes = staticTextNodes.filter {
        ($0.selectedTextRange?.length ?? 0) > 0
    }
    let styleSelectedCandidateIndex =
        selectedCandidateIndexByStyle(
            staticTextNodes
        )
    return WindowNode(
        root: root,
        nodeCount: nodes.count,
        textNodeCount: textNodes.count,
        staticTextNodeCount: staticTextNodes.count,
        framedTextNodeCount: textNodes.filter {
            $0.frame != nil
        }.count,
        listCount: nodes.filter {
            $0.role == kAXListRole as String
        }.count,
        selectedListCount: nodes.filter {
            $0.selectedChildCount > 0
        }.count,
        selectedTextNodeCount: selectedTextNodes.count,
        focusedTextNodeCount: focusedTextNodes.count,
        selectedRangeTextNodeCount: selectedRangeTextNodes.count,
        styleSelectedCandidateIndex: styleSelectedCandidateIndex
    )
}

private func selectedCandidateIndexByStyle(
    _ nodes: [ElementNode]
) -> Int? {
    let sorted = nodes.sorted {
        guard let lhs = $0.frame, let rhs = $1.frame
        else {
            return false
        }
        return lhs.x < rhs.x
    }
    let shortcuts = stride(
        from: 0,
        to: sorted.count,
        by: 2
    ).compactMap { index -> (Int, Double)? in
        guard
            let brightness =
                sorted[index].foregroundBrightness
        else {
            return nil
        }
        return (index / 2, brightness)
    }
    let ranked = shortcuts.sorted {
        if $0.1 != $1.1 { return $0.1 > $1.1 }
        return $0.0 < $1.0
    }
    guard let first = ranked.first,
        let second = ranked.dropFirst().first,
        first.1 - second.1 >= 0.08,
        shortcuts.filter({
            abs($0.1 - first.1) < 0.01
        }).count == 1
    else {
        return nil
    }
    return first.0
}

private func probe(pid: pid_t) -> ProbeResult {
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.25)
    let windows = AXReader.elements(
        application,
        kAXWindowsAttribute
    )
    let summaries = windows.map {
        summarize(AXReader.node($0))
    }
    let hasCandidateWindow = summaries.contains {
        $0.staticTextNodeCount > 0
    }
    let hasSelectedSemantics = summaries.contains {
        $0.selectedListCount > 0
            || $0.selectedTextNodeCount > 0
            || $0.focusedTextNodeCount > 0
            || $0.selectedRangeTextNodeCount > 0
            || $0.styleSelectedCandidateIndex != nil
    }
    let reason: String? =
        if !hasCandidateWindow {
            "wetype_window_unavailable"
        } else if !hasSelectedSemantics {
            "selected_semantics_unavailable"
        } else {
            nil
        }
    return ProbeResult(
        pid: pid,
        candidateWindowAvailable: hasCandidateWindow,
        selectedSemanticsAvailable: hasSelectedSemantics,
        reason: reason,
        windowCount: windows.count,
        windows: summaries
    )
}

private func write(_ result: ProbeResult) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
struct WeTypeAXProbe {
    static func main() throws {
        let options = probeOptions()
        guard let pid = weTypePID(explicitPID: options.pid) else {
            try write(
                ProbeResult(
                    pid: 0,
                    candidateWindowAvailable: false,
                    selectedSemanticsAvailable: false,
                    reason: "wetype_not_running",
                    windowCount: 0,
                    windows: []
                )
            )
            return
        }

        let deadline =
            Date().addingTimeInterval(options.seconds)
        var latest = probe(pid: pid)
        while Date() < deadline {
            latest = probe(pid: pid)
            if latest.candidateWindowAvailable {
                try write(latest)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try write(latest)
    }
}
