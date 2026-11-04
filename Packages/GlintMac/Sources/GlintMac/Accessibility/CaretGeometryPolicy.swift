import CoreGraphics
import Foundation

enum CaretGeometryPolicy {
    private static let maximumMarkerWidth: CGFloat = 4
    // Reject fallback bounds that cover a whole text element rather than
    // the final composed character and its line.
    private static let maximumFallbackGlyphWidth: CGFloat = 80
    private static let maximumFallbackGlyphWidthRatio: CGFloat = 0.4
    private static let maximumFallbackLineHeight: CGFloat = 24
    private static let maximumFallbackLineHeightRatio: CGFloat = 0.6
    private static let frameTolerance: CGFloat = 2

    static func preferredRange(
        selectedRange: NSRange?,
        markedRange: NSRange?
    ) -> NSRange? {
        if let selectedRange,
            selectedRange.location != NSNotFound
        {
            return selectedRange
        }
        guard
            let markedRange,
            markedRange.location != NSNotFound,
            markedRange.location >= 0,
            markedRange.length > 0,
            markedRange.location
                <= Int.max - markedRange.length
        else {
            return nil
        }
        return NSRange(
            location: markedRange.location + markedRange.length,
            length: 0
        )
    }

    static func lastMarkedCharacterRange(
        _ markedRange: NSRange?
    ) -> NSRange? {
        guard
            let markedRange,
            markedRange.location != NSNotFound,
            markedRange.location >= 0,
            markedRange.length > 0,
            markedRange.location
                <= Int.max - markedRange.length
        else {
            return nil
        }
        return NSRange(
            location:
                markedRange.location
                + markedRange.length
                - 1,
            length: 1
        )
    }

    static func caretFromTextBounds(
        _ bounds: CGRect?,
        elementFrame: CGRect?
    ) -> CGRect? {
        guard
            let bounds,
            let elementFrame,
            isFinite(bounds),
            isFinite(elementFrame),
            elementFrame.width > 0,
            elementFrame.height > 0,
            bounds.width > 0,
            bounds.height > 0,
            bounds.width
                <= max(
                    maximumFallbackGlyphWidth,
                    elementFrame.width
                        * maximumFallbackGlyphWidthRatio
                ),
            bounds.height
                <= max(
                    maximumFallbackLineHeight,
                    elementFrame.height
                        * maximumFallbackLineHeightRatio
                )
        else {
            return nil
        }
        let allowed = elementFrame.insetBy(
            dx: -frameTolerance,
            dy: -frameTolerance
        )
        guard
            allowed.contains(
                CGPoint(x: bounds.minX, y: bounds.midY)
            ),
            allowed.contains(
                CGPoint(x: bounds.maxX, y: bounds.midY)
            )
        else {
            return nil
        }
        return CGRect(
            x: bounds.maxX,
            y: bounds.minY,
            width: 0,
            height: bounds.height
        )
    }

    static func shouldReadMarker(
        rangeBounds: CGRect?,
        rangeLength: Int
    ) -> Bool {
        guard rangeLength == 0 else { return false }
        guard let rangeBounds else { return true }
        return !isFinite(rangeBounds) || rangeBounds.height <= 0
    }

    static func preferred(
        rangeBounds: CGRect?,
        markerBounds: CGRect?,
        elementFrame: CGRect?
    ) -> CGRect? {
        if let rangeBounds, isFinite(rangeBounds),
            rangeBounds.height > 0
        {
            return rangeBounds
        }
        guard
            let markerBounds,
            let elementFrame,
            isFinite(markerBounds),
            isFinite(elementFrame),
            markerBounds.width >= 0,
            markerBounds.width <= maximumMarkerWidth,
            markerBounds.height > 0
        else {
            return nil
        }
        let allowed = elementFrame.insetBy(
            dx: -frameTolerance,
            dy: -frameTolerance
        )
        guard
            allowed.contains(
                CGPoint(
                    x: markerBounds.minX,
                    y: markerBounds.midY
                )
            ),
            allowed.contains(
                CGPoint(
                    x: markerBounds.maxX,
                    y: markerBounds.midY
                )
            )
        else {
            return nil
        }
        return markerBounds
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
    }
}
