import CoreGraphics

enum HUDPlacementMode: Equatable {
    case candidate
    case rightOfCaret
    case verticalClearance
}

struct HUDLayoutResult: Equatable {
    let frame: CGRect
    let placesBelow: Bool
    let placementMode: HUDPlacementMode
}

enum HUDLayout {
    private static let directionHysteresis: CGFloat = 3

    static func placement(
        near candidateRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        spacing: Double,
        horizontalOrigin: CGFloat? = nil,
        inputCaretRect: CGRect? = nil,
        stablePlacesBelow: Bool? = nil
    ) -> HUDLayoutResult {
        let gap = CGFloat(max(0, spacing))
        let minimumX = visibleFrame.minX
        let maximumX = max(
            minimumX,
            visibleFrame.maxX - panelSize.width
        )
        let preferredX = horizontalOrigin ?? candidateRect.minX
        let baseX = max(
            minimumX,
            min(preferredX, maximumX)
        )
        let below = candidateRect.minY - panelSize.height - gap
        let above = candidateRect.maxY + gap
        let belowFits = below >= visibleFrame.minY
        let aboveFits =
            above + panelSize.height
            <= visibleFrame.maxY

        // Without reliable caret geometry, prefer below because macOS
        // commonly places the candidate bar under the edited line.
        let rawDesiredPlacesBelow =
            inputCaretRect.map {
                candidateRect.midY <= $0.midY
            } ?? true
        let desiredPlacesBelow: Bool
        if let stablePlacesBelow,
            let inputCaretRect,
            abs(candidateRect.midY - inputCaretRect.midY)
                < Self.directionHysteresis
        {
            desiredPlacesBelow = stablePlacesBelow
        } else {
            desiredPlacesBelow = rawDesiredPlacesBelow
        }
        let placesBelow: Bool
        if desiredPlacesBelow, belowFits {
            placesBelow = true
        } else if !desiredPlacesBelow, aboveFits {
            placesBelow = false
        } else {
            placesBelow = belowFits
        }
        let proposedY = placesBelow ? below : above

        let minimumY = visibleFrame.minY
        let maximumY = max(
            minimumY,
            visibleFrame.maxY - panelSize.height
        )
        let baseY = max(
            minimumY,
            min(proposedY, maximumY)
        )

        var x = baseX
        var y = baseY
        var mode = HUDPlacementMode.candidate
        let baseFrame = CGRect(
            x: baseX,
            y: baseY,
            width: panelSize.width,
            height: panelSize.height
        )
        if let inputCaretRect,
            overlapsInputLine(baseFrame, caret: inputCaretRect),
            baseX < inputCaretRect.maxX + gap
        {
            // LTR input text usually occupies the caret's left side. Keep the
            // candidate spacing and move right; otherwise clear the whole
            // input row vertically.
            let rightOfCaret = inputCaretRect.maxX + gap
            if rightOfCaret <= maximumX {
                x = max(minimumX, rightOfCaret)
                mode = .rightOfCaret
            } else {
                let clearAbove = inputCaretRect.maxY + gap
                let clearBelow =
                    inputCaretRect.minY - panelSize.height - gap
                let clearance =
                    placesBelow ? clearBelow : clearAbove
                y = max(
                    minimumY,
                    min(clearance, maximumY)
                )
                mode = .verticalClearance
            }
        }
        return HUDLayoutResult(
            frame: CGRect(
                x: x,
                y: y,
                width: panelSize.width,
                height: panelSize.height
            ),
            placesBelow: placesBelow,
            placementMode: mode
        )
    }

    private static func overlapsInputLine(
        _ frame: CGRect,
        caret: CGRect
    ) -> Bool {
        frame.minY < caret.maxY
            && frame.maxY > caret.minY
    }
}
