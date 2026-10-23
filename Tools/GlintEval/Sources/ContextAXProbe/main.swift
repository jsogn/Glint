import ApplicationServices
import Foundation

private struct ProbeResult: Encodable {
    let pid: pid_t
    let supported: Bool
    let role: String?
    let selectedRange: RangeValue?
    let markedRange: RangeValue?
    let characterCount: Int?
    let hasStringForRange: Bool
    let beforeContext: String?
    let afterContext: String?
    let reason: String?
}

private struct RangeValue: Encodable {
    let location: Int
    let length: Int
}

private enum AXReader {
    static func attribute(
        _ element: AXUIElement,
        _ name: String
    ) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        )
        return result == .success ? value : nil
    }

    static func range(
        _ element: AXUIElement,
        _ name: String
    ) -> CFRange? {
        guard let value = attribute(element, name),
            CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard
            AXValueGetValue(
                value as! AXValue,
                .cfRange,
                &range
            ), range.location != kCFNotFound
        else {
            return nil
        }
        return range
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func focusedElement(
        for app: AXUIElement
    ) -> AXUIElement? {
        if let value = attribute(app, kAXFocusedUIElementAttribute),
            CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID()
        {
            return (value as! AXUIElement)
        }
        let windows =
            attribute(
                app,
                kAXWindowsAttribute
            ) as? [AXUIElement] ?? []
        for window in windows {
            if let element = focusedTextElement(
                in: window,
                depth: 0
            ) {
                return element
            }
        }
        return nil
    }

    private static func focusedTextElement(
        in element: AXUIElement,
        depth: Int
    ) -> AXUIElement? {
        let role = attribute(element, kAXRoleAttribute) as? String
        let focused =
            attribute(
                element,
                kAXFocusedAttribute
            ) as? Bool ?? false
        if focused,
            role == kAXTextFieldRole as String
                || role == kAXTextAreaRole as String
        {
            return element
        }
        guard depth < 12 else { return nil }
        for child in children(element) {
            if let result = focusedTextElement(
                in: child,
                depth: depth + 1
            ) {
                return result
            }
        }
        return nil
    }

    static func parameterizedNames(
        _ element: AXUIElement
    ) -> [String] {
        var names: CFArray?
        guard
            AXUIElementCopyParameterizedAttributeNames(
                element,
                &names
            ) == .success
        else {
            return []
        }
        return names as? [String] ?? []
    }

    static func string(
        _ element: AXUIElement,
        range: CFRange
    ) -> String? {
        var range = range
        guard
            let parameter = AXValueCreate(
                .cfRange,
                &range
            )
        else {
            return nil
        }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )
        return result == .success ? value as? String : nil
    }
}

private func arguments() -> (
    pid: pid_t,
    before: Int,
    after: Int
) {
    let args = CommandLine.arguments
    var pid: Int32?
    var before = 24
    var after = 8
    var index = 1
    while index + 1 < args.count {
        let value = args[index + 1]
        switch args[index] {
        case "--pid":
            pid = Int32(value)
        case "--before":
            before = max(0, Int(value) ?? 24)
        case "--after":
            after = max(0, Int(value) ?? 8)
        default:
            break
        }
        index += 2
    }
    guard let pid else {
        fputs(
            "usage: ContextAXProbe --pid <pid> "
                + "[--before 24] [--after 8]\n",
            stderr
        )
        exit(2)
    }
    return (pid, before, after)
}

@main
struct ContextAXProbe {
    static func main() throws {
        let options = arguments()
        let app = AXUIElementCreateApplication(options.pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let element = AXReader.focusedElement(for: app) else {
            try write(
                ProbeResult(
                    pid: options.pid,
                    supported: false,
                    role: nil,
                    selectedRange: nil,
                    markedRange: nil,
                    characterCount: nil,
                    hasStringForRange: false,
                    beforeContext: nil,
                    afterContext: nil,
                    reason: "focused_element_unavailable"
                )
            )
            return
        }

        let names = AXReader.parameterizedNames(element)
        let hasStringForRange = names.contains(
            kAXStringForRangeParameterizedAttribute as String
        )
        let selectedRange = AXReader.range(
            element,
            kAXSelectedTextRangeAttribute
        )
        let markedRange = AXReader.range(
            element,
            "AXTextInputMarkedRange"
        )
        let characterCount =
            AXReader.attribute(
                element,
                kAXNumberOfCharactersAttribute
            ) as? Int
        let anchor =
            markedRange?.length ?? 0 > 0
            ? markedRange
            : selectedRange

        guard hasStringForRange, let anchor else {
            try write(
                ProbeResult(
                    pid: options.pid,
                    supported: false,
                    role: AXReader.attribute(
                        element,
                        kAXRoleAttribute
                    ) as? String,
                    selectedRange: selectedRange.map(RangeValue.init),
                    markedRange: markedRange.map(RangeValue.init),
                    characterCount: characterCount,
                    hasStringForRange: hasStringForRange,
                    beforeContext: nil,
                    afterContext: nil,
                    reason: hasStringForRange
                        ? "text_range_unavailable"
                        : "string_for_range_unavailable"
                )
            )
            return
        }

        let start = max(0, anchor.location - options.before)
        let beforeRange = CFRange(
            location: start,
            length: anchor.location - start
        )
        let afterStart = min(
            characterCount ?? anchor.location + anchor.length,
            anchor.location + anchor.length
        )
        let afterRange = CFRange(
            location: afterStart,
            length: min(
                options.after,
                max(0, (characterCount ?? afterStart + options.after) - afterStart)
            )
        )
        let before: String? =
            beforeRange.length > 0
            ? AXReader.string(element, range: beforeRange)
            : ""
        let after: String? =
            afterRange.length > 0
            ? AXReader.string(element, range: afterRange)
            : ""
        let supported = before != nil || after != nil
        let reason: String? =
            if before != nil && after != nil {
                nil
            } else {
                "partial_context"
            }

        try write(
            ProbeResult(
                pid: options.pid,
                supported: supported,
                role: AXReader.attribute(
                    element,
                    kAXRoleAttribute
                ) as? String,
                selectedRange: selectedRange.map(RangeValue.init),
                markedRange: markedRange.map(RangeValue.init),
                characterCount: characterCount,
                hasStringForRange: hasStringForRange,
                beforeContext: before,
                afterContext: after,
                reason: reason
            )
        )
    }

    private static func write(_ result: ProbeResult) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

private extension RangeValue {
    init(_ range: CFRange) {
        self.init(
            location: range.location,
            length: range.length
        )
    }
}
