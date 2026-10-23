import ApplicationServices
import Foundation

enum AXValueReader {
    static func range(_ value: Any?) -> CFRange? {
        guard let axValue = axValue(value, type: .cfRange) else {
            return nil
        }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let axValue = axValue(value, type: .cgRect) else {
            return nil
        }
        var rect = CGRect.zero
        return AXValueGetValue(axValue, .cgRect, &rect) ? rect : nil
    }

    static func point(_ value: Any?) -> CGPoint? {
        guard let axValue = axValue(value, type: .cgPoint) else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    static func size(_ value: Any?) -> CGSize? {
        guard let axValue = axValue(value, type: .cgSize) else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    static func element(_ value: Any?) -> AXUIElement? {
        guard let value,
            CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func axValue(
        _ value: Any?,
        type: AXValueType
    ) -> AXValue? {
        guard let value,
            CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        let axValue = value as! AXValue
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}
