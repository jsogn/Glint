import AppKit
import ApplicationServices
import Foundation
import GlintMac

private struct ProbeOptions {
    let bundleIdentifier: String
    let seconds: Double
    let pollInterval: TimeInterval
}

private enum AXProbe {
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

    static func parameterized(
        _ element: AXUIElement,
        _ name: String,
        parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                name as CFString,
                parameter,
                &value
            ) == .success
        else {
            return nil
        }
        return value
    }

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func string(
        _ element: AXUIElement,
        _ name: String
    ) -> String? {
        attribute(element, name) as? String
    }

    static func int(
        _ element: AXUIElement,
        _ name: String
    ) -> Int? {
        (attribute(element, name) as? NSNumber)?.intValue
    }

    static func range(
        _ element: AXUIElement,
        _ name: String
    ) -> NSRange? {
        guard
            let value = attribute(element, name),
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var range = CFRange()
        guard
            AXValueGetValue(
                value as! AXValue,
                .cfRange,
                &range
            ),
            range.location != kCFNotFound
        else {
            return nil
        }
        return NSRange(
            location: range.location,
            length: max(0, range.length)
        )
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard
            let value,
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var rect = CGRect.zero
        guard
            AXValueGetValue(
                value as! AXValue,
                .cgRect,
                &rect
            ),
            rect.height > 0,
            rect.width.isFinite,
            rect.height.isFinite
        else {
            return nil
        }
        return rect
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        let position = attribute(element, kAXPositionAttribute)
        let size = attribute(element, kAXSizeAttribute)
        guard
            let position,
            let size,
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var sizeValue = CGSize.zero
        guard
            AXValueGetValue(
                position as! AXValue,
                .cgPoint,
                &point
            ),
            AXValueGetValue(
                size as! AXValue,
                .cgSize,
                &sizeValue
            )
        else {
            return nil
        }
        return CGRect(origin: point, size: sizeValue)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement]
            ?? []
    }

    static func processIdentifier(
        of element: AXUIElement
    ) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard
            AXUIElementGetPid(
                element,
                &processIdentifier
            ) == .success,
            processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }

    static func attributeNames(
        _ element: AXUIElement,
        parameterized: Bool
    ) -> Set<String> {
        var names: CFArray?
        let result =
            parameterized
            ? AXUIElementCopyParameterizedAttributeNames(
                element,
                &names
            )
            : AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names else {
            return []
        }
        return Set(names as? [String] ?? [])
    }

    static func rangeValue(_ range: NSRange) -> AXValue? {
        var range = CFRange(
            location: range.location,
            length: range.length
        )
        return AXValueCreate(.cfRange, &range)
    }

    static func bounds(
        for range: NSRange,
        in element: AXUIElement
    ) -> CGRect? {
        guard let value = rangeValue(range) else { return nil }
        return rect(
            parameterized(
                element,
                kAXBoundsForRangeParameterizedAttribute as String,
                parameter: value
            )
        )
    }

    static func markerBounds(
        _ marker: CFTypeRef,
        in element: AXUIElement
    ) -> CGRect? {
        guard
            CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID()
        else {
            return nil
        }
        return rect(
            parameterized(
                element,
                kAXBoundsForTextMarkerRangeParameterizedAttribute
                    as String,
                parameter: marker
            )
        )
    }
}

private func options() -> ProbeOptions {
    let arguments = CommandLine.arguments
    var bundleIdentifier = "com.openai.codex"
    var seconds = 30.0
    var pollInterval = 0.05
    var index = 1
    while index + 1 < arguments.count {
        switch arguments[index] {
        case "--bundle":
            bundleIdentifier = arguments[index + 1]
        case "--seconds":
            seconds = min(
                max(Double(arguments[index + 1]) ?? 30, 1),
                120
            )
        case "--poll-ms":
            pollInterval = min(
                max(
                    (Double(arguments[index + 1]) ?? 50) / 1_000,
                    0.02
                ),
                0.5
            )
        default:
            break
        }
        index += 2
    }
    return ProbeOptions(
        bundleIdentifier: bundleIdentifier,
        seconds: seconds,
        pollInterval: pollInterval
    )
}

private func findTextElement(
    in root: AXUIElement
) -> AXUIElement? {
    let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    while index < min(queue.count, 180) {
        let (element, depth) = queue[index]
        index += 1
        if textRoles.contains(
            AXProbe.string(element, kAXRoleAttribute) ?? ""
        ) {
            return element
        }
        guard depth < 8 else { continue }
        queue.append(
            contentsOf: AXProbe.children(element)
                .reversed()
                .map { ($0, depth + 1) }
        )
    }
    return nil
}

private func findCandidateList(
    in root: AXUIElement
) -> AXUIElement? {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    while index < min(queue.count, 260) {
        let (element, depth) = queue[index]
        index += 1
        if AXProbe.string(element, kAXIdentifierAttribute)
            == "InputMethodCandidateList"
        {
            return element
        }
        guard depth < 10 else { continue }
        queue.append(
            contentsOf: AXProbe.children(element)
                .map { ($0, depth + 1) }
        )
    }
    return nil
}

private func lineChildren(
    of element: AXUIElement
) -> [CGRect] {
    var result: [CGRect] = []
    var queue: [(AXUIElement, Int)] = [(element, 0)]
    var index = 0
    while index < min(queue.count, 40), result.count < 8 {
        let (child, depth) = queue[index]
        index += 1
        if !CFEqual(child, element),
            let frame = AXProbe.frame(child),
            frame.height >= 4,
            frame.height <= 80
        {
            result.append(frame)
        }
        guard depth < 5 else { continue }
        queue.append(
            contentsOf: AXProbe.children(child)
                .map { ($0, depth + 1) }
        )
    }
    return result
}

private func externalWindowFrames(
    bundleIdentifier: String
) -> [CGRect] {
    guard
        let application =
            NSRunningApplication
            .runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            .first(where: { !$0.isTerminated })
    else {
        return []
    }
    let appElement = AXUIElementCreateApplication(
        application.processIdentifier
    )
    AXUIElementSetMessagingTimeout(appElement, 0.08)
    return
        (AXProbe.attribute(
            appElement,
            kAXWindowsAttribute
        ) as? [AXUIElement] ?? [])
        .compactMap(AXProbe.frame)
}

private func describe(
    _ rect: CGRect?
) -> String {
    guard let rect else { return "nil" }
    return String(
        format: "(%.1f,%.1f %.1fx%.1f)",
        rect.minX,
        rect.minY,
        rect.width,
        rect.height
    )
}

private func describe(
    _ range: NSRange?
) -> String {
    guard let range else { return "nil" }
    return "\(range.location)+\(range.length)"
}

private func describeSystemFocus(
    _ element: AXUIElement?
) -> String {
    guard let element else {
        return "systemRole=nil systemFrame=nil systemSelected=nil systemMarker=nil systemPid=nil"
    }
    let markerBounds = AXProbe.attribute(
        element,
        kAXSelectedTextMarkerRangeAttribute as String
    ).flatMap {
        AXProbe.markerBounds($0, in: element)
    }
    return [
        "systemRole=\(AXProbe.string(element, kAXRoleAttribute) ?? "nil")",
        "systemFrame=\(describe(AXProbe.frame(element)))",
        "systemSelected=\(describe(AXProbe.range(element, kAXSelectedTextRangeAttribute)))",
        "systemMarker=\(describe(markerBounds))",
        "systemPid=\(AXProbe.processIdentifier(of: element).map(String.init) ?? "nil")",
    ]
    .joined(separator: " ")
}

private func drawSample(
    application: AXUIElement,
    appFocus: AXUIElement?,
    systemFocus: AXUIElement?
) -> String {
    guard let appFocus else {
        return "focus=nil " + describeSystemFocus(systemFocus)
    }
    let textElement = findTextElement(in: appFocus) ?? appFocus
    let role = AXProbe.string(textElement, kAXRoleAttribute) ?? "?"
    let selected = AXProbe.range(
        textElement,
        kAXSelectedTextRangeAttribute
    )
    let marked = AXProbe.range(
        textElement,
        "AXTextInputMarkedRange"
    )
    let count = AXProbe.int(
        textElement,
        kAXNumberOfCharactersAttribute
    )
    let selectedBounds = selected.flatMap {
        AXProbe.bounds(for: $0, in: textElement)
    }
    let zeroBounds = selected.flatMap {
        AXProbe.bounds(
            for: NSRange(location: $0.location, length: 0),
            in: textElement
        )
    }
    let nextCharacterBounds = selected.flatMap { range -> CGRect? in
        let allowed =
            count.map { range.location < $0 } ?? true
        return allowed
            ? AXProbe.bounds(
                for: NSRange(location: range.location, length: 1),
                in: textElement
            )
            : nil
    }
    let previousCharacterBounds = selected.flatMap {
        $0.location > 0
            ? AXProbe.bounds(
                for: NSRange(
                    location: $0.location - 1,
                    length: 1
                ),
                in: textElement
            )
            : nil
    }
    let selectedMarker = AXProbe.attribute(
        textElement,
        kAXSelectedTextMarkerRangeAttribute as String
    )
    let selectedMarkerBounds = selectedMarker.flatMap {
        AXProbe.markerBounds($0, in: textElement)
    }
    var lineMarkerBounds: CGRect?
    if let selectedMarker,
        CFGetTypeID(selectedMarker) == AXTextMarkerRangeGetTypeID()
    {
        let start =
            AXTextMarkerRangeCopyStartMarker(
                unsafeDowncast(
                    selectedMarker,
                    to: AXTextMarkerRange.self
                )
            ) as CFTypeRef
        if let line = AXProbe.parameterized(
            textElement,
            kAXLineTextMarkerRangeForTextMarkerParameterizedAttribute
                as String,
            parameter: start
        ) {
            lineMarkerBounds = AXProbe.markerBounds(
                line,
                in: textElement
            )
        }
    }
    let candidateList =
        (AXProbe.attribute(
            application,
            kAXWindowsAttribute
        ) as? [AXUIElement] ?? [])
        .lazy
        .compactMap { findCandidateList(in: $0) }
        .first
    let candidateFrame = candidateList.flatMap(AXProbe.frame)
    let selectedCandidateFrame = candidateList.flatMap {
        (AXProbe.attribute(
            $0,
            kAXSelectedChildrenAttribute
        ) as? [AXUIElement])?.first
    }
    .flatMap(AXProbe.frame)
    return [
        "role=\(role)",
        "frame=\(describe(AXProbe.frame(textElement)))",
        "selected=\(describe(selected))",
        "marked=\(describe(marked))",
        "count=\(count.map(String.init) ?? "nil")",
        "selBounds=\(describe(selectedBounds))",
        "zeroBounds=\(describe(zeroBounds))",
        "nextBounds=\(describe(nextCharacterBounds))",
        "prevBounds=\(describe(previousCharacterBounds))",
        "markerBounds=\(describe(selectedMarkerBounds))",
        "lineBounds=\(describe(lineMarkerBounds))",
        "lines=\(lineChildren(of: textElement).map(describe).joined(separator: ","))",
        "candidateFrame=\(describe(candidateFrame))",
        "selectedCandidate=\(describe(selectedCandidateFrame))",
        "weTypeWindows=\(externalWindowFrames(bundleIdentifier: "com.tencent.inputmethod.wetype").map(describe).joined(separator: ","))",
        describeSystemFocus(systemFocus),
    ]
    .joined(separator: " ")
}

@main
struct FocusGeometryProbe {
    static func main() {
        let options = options()
        guard
            let application =
                NSRunningApplication
                .runningApplications(
                    withBundleIdentifier: options.bundleIdentifier
                )
                .first
        else {
            print("No running application")
            return
        }
        _ = application.activate(options: [])
        Thread.sleep(forTimeInterval: 0.25)
        let appElement = AXUIElementCreateApplication(
            application.processIdentifier
        )
        AXUIElementSetMessagingTimeout(appElement, 0.08)
        print(
            "screens="
                + NSScreen.screens.enumerated().map {
                    "\($0.offset):\(describe($0.element.frame))"
                        + "/visible:\(describe($0.element.visibleFrame))"
                }
                .joined(separator: ",")
        )
        let deadline = Date().addingTimeInterval(options.seconds)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var lastSample = ""
        var samples = 0
        while Date() < deadline {
            let focus = AXProbe.element(
                AXProbe.attribute(
                    appElement,
                    kAXFocusedUIElementAttribute
                )
            )
            if let focus {
                AXUIElementSetMessagingTimeout(focus, 0.08)
            }
            let systemFocus = AXProbe.element(
                AXProbe.attribute(
                    system,
                    kAXFocusedUIElementAttribute
                )
            )
            if let systemFocus {
                AXUIElementSetMessagingTimeout(
                    systemFocus,
                    0.08
                )
            }
            let sample = drawSample(
                application: appElement,
                appFocus: focus,
                systemFocus: systemFocus
            )
            let focusSnapshot = FocusMonitor().snapshot()
            let productionSnapshot = [
                "productionCaret=\(String(describing: focusSnapshot?.caretRect))",
                "productionFrame=\(String(describing: focusSnapshot?.elementFrame))",
                "productionEditable=\(focusSnapshot?.isEditableTextInput ?? false)",
            ]
            .joined(separator: " ")
            let completeSample =
                sample + " " + productionSnapshot
            if completeSample != lastSample {
                samples += 1
                let timestamp = String(
                    format: "%.3f",
                    Date().timeIntervalSince1970
                )
                print(
                    "sample=\(samples) ts=\(timestamp) \(completeSample)"
                )
                lastSample = completeSample
            }
            Thread.sleep(forTimeInterval: options.pollInterval)
        }
        print("finished samples=\(samples)")
    }
}
