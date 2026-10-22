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
        horizontalOrigin: CGFloat? = nil
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

        let placesBelow: Bool
        let proposedY: CGFloat
        switch position {
        case .automatic:
            placesBelow = below >= visibleFrame.minY + screenEdgeInset
            proposedY = placesBelow ? below : above
        case .above:
            placesBelow = false
            proposedY = above
        case .below:
            placesBelow = true
            proposedY = below
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
