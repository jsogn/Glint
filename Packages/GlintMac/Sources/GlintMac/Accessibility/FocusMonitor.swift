import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

public enum TextCompositionState: Sendable, Equatable {
    case unknown
    case composing
    case inactive
}

public struct FocusSnapshot: Sendable, Equatable {
    public let caretRect: CGRect?
    public let elementFrame: CGRect?
    public let hasTextSelection: Bool
    public let compositionState: TextCompositionState
    public let isEditableTextInput: Bool

    public init(
        caretRect: CGRect?,
        elementFrame: CGRect?,
        hasTextSelection: Bool = false,
        compositionState: TextCompositionState = .unknown,
        isEditableTextInput: Bool = false
    ) {
        self.caretRect = caretRect
        self.elementFrame = elementFrame
        self.hasTextSelection = hasTextSelection
        self.compositionState = compositionState
        self.isEditableTextInput = isEditableTextInput
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
        let selectedRange = Self.selectedRange(of: element)
        let markedRange = Self.markedRange(of: element)
        let compositionState = Self.compositionState(for: markedRange)
        let isEditableTextInput = Self.isEditableTextInput(
            role: Self.role(of: element),
            editable: Self.boolAttribute(
                Self.axAttribute(element, "AXEditable")
            )
        )
        let hasTextSelection = Self.isTextSelection(
            selectedRange,
            markedRange: markedRange
        )
        let caret = hasTextSelection
            ? nil
            : selectedRange.flatMap { Self.caretRect(for: $0, in: element) }
        let frame = Self.elementFrame(of: element)
        guard hasTextSelection || caret != nil || frame != nil else {
            return nil
        }
        return FocusSnapshot(
            caretRect: caret,
            elementFrame: frame,
            hasTextSelection: hasTextSelection,
            compositionState: compositionState,
            isEditableTextInput: isEditableTextInput
        )
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

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        rangeValue(axAttribute(element, kAXSelectedTextRangeAttribute))
    }

    private static func markedRange(of element: AXUIElement) -> NSRange? {
        rangeValue(
            axAttribute(
                element,
                "AXTextInputMarkedRange"
            )
        )
    }

    static func isTextSelection(
        _ selectedRange: NSRange?,
        markedRange: NSRange?
    ) -> Bool {
        guard let selectedRange, selectedRange.length > 0 else {
            return false
        }
        // IME composition also exposes a non-empty selected range. Only
        // selections outside the marked-text range are real user selections.
        guard let markedRange,
              markedRange.length > 0,
              selectedRange.location >= markedRange.location,
              NSMaxRange(selectedRange) <= NSMaxRange(markedRange) else {
            return true
        }
        return false
    }

    static func compositionState(
        for markedRange: NSRange?
    ) -> TextCompositionState {
        guard let markedRange else { return .unknown }
        return markedRange.length > 0 ? .composing : .inactive
    }

    static func isEditableTextInput(
        role: String?,
        editable: Bool?
    ) -> Bool {
        if editable == true {
            return true
        }
        guard let role else { return false }
        return [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
        ]
        .map { $0 as String }
        .contains(role)
    }

    private static func role(of element: AXUIElement) -> String? {
        axAttribute(element, kAXRoleAttribute) as? String
    }

    private static func boolAttribute(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func caretRect(
        for range: NSRange,
        in element: AXUIElement
    ) -> CGRect? {
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
