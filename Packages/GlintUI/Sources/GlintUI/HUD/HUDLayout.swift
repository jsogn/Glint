import CoreGraphics

struct HUDLayoutResult: Equatable {
    let frame: CGRect
    let placesBelow: Bool
}

enum HUDLayout {
    static let screenEdgeInset: CGFloat = 8

    static func placement(
        near candidateRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        position: HUDPosition,
        spacing: Double,
        horizontalOrigin: CGFloat? = nil,
        inputLineRect: CGRect? = nil
    ) -> HUDLayoutResult {
        let gap = CGFloat(max(0, spacing))
        let minimumX = visibleFrame.minX + screenEdgeInset
        let maximumX = max(
            minimumX,
            visibleFrame.maxX - panelSize.width - screenEdgeInset
        )
        let preferredX = horizontalOrigin ?? candidateRect.minX
        let x = max(
            minimumX,
            min(preferredX, maximumX)
        )
        let below = candidateRect.minY - panelSize.height - gap
        let above = candidateRect.maxY + gap
        let belowFits =
            below >= visibleFrame.minY + screenEdgeInset
        let aboveFits =
            above + panelSize.height
            <= visibleFrame.maxY - screenEdgeInset

        let placesBelow: Bool
        let proposedY: CGFloat
        switch position {
        case .automatic:
            // Move away from the input line. Without reliable input-line
            // geometry, prefer below because macOS commonly places the
            // candidate bar under the edited line.
            let desiredPlacesBelow =
                inputLineRect.map {
                    candidateRect.midY <= $0.midY
                } ?? true
            if desiredPlacesBelow, belowFits {
                placesBelow = true
            } else if !desiredPlacesBelow, aboveFits {
                placesBelow = false
            } else {
                placesBelow = belowFits
            }
            proposedY = placesBelow ? below : above
        case .above:
            // An explicit side is preferred, but flipping to the only side
            // with room avoids silently compressing the configured gap.
            placesBelow = !aboveFits && belowFits
            proposedY = placesBelow ? below : above
        case .below:
            placesBelow = belowFits || !aboveFits
            proposedY = placesBelow ? below : above
        }

        let minimumY = visibleFrame.minY + screenEdgeInset
        let maximumY = max(
            minimumY,
            visibleFrame.maxY - panelSize.height - screenEdgeInset
        )
        let y = max(
            minimumY,
            min(proposedY, maximumY)
        )
        return HUDLayoutResult(
            frame: CGRect(
                x: x,
                y: y,
                width: panelSize.width,
                height: panelSize.height
            ),
            placesBelow: placesBelow
        )
    }
}
