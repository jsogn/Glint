import ApplicationServices
import Carbon
import CoreGraphics

public struct FocusSnapshot: Sendable, Equatable {
    public let caretRect: CGRect?
    public let elementFrame: CGRect?

    public init(caretRect: CGRect?, elementFrame: CGRect?) {
        self.caretRect = caretRect
        self.elementFrame = elementFrame
    }
}

public struct FocusMonitor: Sendable {
    public init() {}

    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": prompt,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func requestAccessibility() {
        _ = isAccessibilityTrusted(prompt: true)
    }

    public static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    public func snapshot() -> FocusSnapshot? {
        let system = AXUIElementCreateSystemWide()
        guard let focused = Self.axAttribute(system, kAXFocusedUIElementAttribute) else {
            return nil
        }
        let element = focused as! AXUIElement
        let caret = Self.caretRect(of: element)
        let frame = Self.elementFrame(of: element)
        guard caret != nil || frame != nil else { return nil }
        return FocusSnapshot(caretRect: caret, elementFrame: frame)
    }

    private static func axAttribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private static func rangeValue(_ value: Any?) -> NSRange? {
        guard let value, CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        guard range.location != NSNotFound else { return nil }
        return NSRange(location: range.location, length: max(0, range.length))
    }

    private static func caretRect(of element: AXUIElement) -> CGRect? {
        guard let range = rangeValue(axAttribute(element, kAXSelectedTextRangeAttribute)) else {
            return nil
        }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else {
            return nil
        }
        return rect
    }

    private static func elementFrame(of element: AXUIElement) -> CGRect? {
        if let frameValue = axAttribute(element, "AXFrame"),
           CFGetTypeID(frameValue as CFTypeRef) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(frameValue as! AXValue, .cgRect, &rect) {
                return rect
            }
        }

        guard let positionValue = axAttribute(element, kAXPositionAttribute),
              let sizeValue = axAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}
