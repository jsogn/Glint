import ApplicationServices
import AppKit
import Foundation

private struct AttributeValue: Encodable {
    let name: String
    let value: String
}

private struct ElementDump: Encodable {
    let role: String?
    let identifier: String?
    let attributes: [AttributeValue]
}

private struct ProbeResult: Encodable {
    let pid: pid_t
    let supported: Bool
    let reason: String?
    let list: ElementDump?
    let selected: [ElementDump]
    let visibleChildren: [ElementDump]
}

private enum AXReader {
    static func attribute(
        _ element: AXUIElement,
        _ name: String
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            name as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    static func stringAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> String? {
        attribute(element, name) as? String
    }

    static func elementsAttribute(
        _ element: AXUIElement,
        _ name: String
    ) -> [AXUIElement] {
        attribute(element, name) as? [AXUIElement] ?? []
    }

    static func attributeNames(
        _ element: AXUIElement
    ) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(
            element,
            &names
        ) == .success else {
            return []
        }
        return names as? [String] ?? []
    }

    static func dump(_ element: AXUIElement) -> ElementDump {
        let attributes = attributeNames(element)
            .sorted()
            .map {
                AttributeValue(
                    name: $0,
                    value: describe(attribute(element, $0))
                )
            }
        return ElementDump(
            role: stringAttribute(element, kAXRoleAttribute),
            identifier: stringAttribute(
                element,
                kAXIdentifierAttribute
            ),
            attributes: attributes
        )
    }

    static func findCandidateList(
        in element: AXUIElement,
        depth: Int = 0
    ) -> AXUIElement? {
        if stringAttribute(element, kAXIdentifierAttribute)
            == "InputMethodCandidateList" {
            return element
        }
        guard depth < 8 else { return nil }
        for child in elementsAttribute(
            element,
            kAXChildrenAttribute
        ) {
            if let found = findCandidateList(
                in: child,
                depth: depth + 1
            ) {
                return found
            }
        }
        return nil
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else {
            return "<nil>"
        }
        let typeID = CFGetTypeID(value)
        if typeID == CFStringGetTypeID() {
            return value as? String ?? "<CFString>"
        }
        if typeID == CFNumberGetTypeID() {
            return (value as? NSNumber)?.stringValue ?? "<CFNumber>"
        }
        if typeID == CFArrayGetTypeID() {
            let array = unsafeDowncast(value, to: CFArray.self)
            return "<array count=\(CFArrayGetCount(array))>"
        }
        if typeID == AXUIElementGetTypeID() {
            return "<AXUIElement>"
        }
        if typeID == AXValueGetTypeID() {
            return "<AXValue>"
        }
        return "<CFType \(typeID)>"
    }
}

private func probeArguments() -> (pid: pid_t?, seconds: Double) {
    let arguments = CommandLine.arguments
    var pid: pid_t?
    var seconds = 20.0
    var index = 1
    while index + 1 < arguments.count {
        switch arguments[index] {
        case "--pid":
            pid = pid_t(arguments[index + 1])
        case "--seconds":
            seconds = min(
                max(Double(arguments[index + 1]) ?? 20, 1),
                120
            )
        default:
            break
        }
        index += 2
    }
    return (pid, seconds)
}

private func write(_ result: ProbeResult) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(result)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

@main
struct CandidateAXProbe {
    static func main() throws {
        let options = probeArguments()
        let deadline = Date().addingTimeInterval(options.seconds)
        var fallback = ProbeResult(
            pid: options.pid ?? 0,
            supported: false,
            reason: "candidate_list_unavailable",
            list: nil,
            selected: [],
            visibleChildren: []
        )

        while Date() < deadline {
            let pid = options.pid
                ?? NSWorkspace.shared.frontmostApplication?
                    .processIdentifier
            guard let pid else {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }
            let result = probe(pid: pid)
            fallback = result
            if result.supported {
                try write(result)
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try write(fallback)
    }

    private static func probe(pid: pid_t) -> ProbeResult {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var list: AXUIElement?
        for window in AXReader.elementsAttribute(
            application,
            kAXWindowsAttribute
        ) {
            list = AXReader.findCandidateList(in: window)
            if list != nil { break }
        }
        guard let list else {
            return ProbeResult(
                pid: pid,
                supported: false,
                reason: "candidate_list_unavailable",
                list: nil,
                selected: [],
                visibleChildren: []
            )
        }

        let selected = AXReader.elementsAttribute(
            list,
            kAXSelectedChildrenAttribute
        )
        let visible = Array(
            AXReader.elementsAttribute(
                list,
                kAXVisibleChildrenAttribute
            ).prefix(12)
        )
        return ProbeResult(
            pid: pid,
            supported: !selected.isEmpty,
            reason: selected.isEmpty
                ? "selected_candidate_unavailable"
                : nil,
            list: AXReader.dump(list),
            selected: selected.map(AXReader.dump),
            visibleChildren: visible.map(AXReader.dump)
        )
    }
}
