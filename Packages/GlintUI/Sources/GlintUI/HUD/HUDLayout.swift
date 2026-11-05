import CoreGraphics

enum HUDPlacementMode: Equatable {
    case candidate
    case candidateTrailing
    case rightOfCaret
    case verticalClearance
}

struct HUDLayoutResult: Equatable {
    let frame: CGRect
    let placesBelow: Bool
    let placementMode: HUDPlacementMode
    let hidesHUD: Bool
    let fallbackCandidateHasInputRoomBelow: Bool?
}

enum HUDLayout {
    private static let directionHysteresis: CGFloat = 3
    private static let fallbackClearanceHysteresis: CGFloat = 3
    private static let minimumFallbackInputRowClearance: CGFloat = 24
    private static let fallbackInputRowClearanceRatio: CGFloat = 0.75

    static func placement(
        near candidateRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double,
        horizontalOrigin: CGFloat? = nil,
        inputCaretRect: CGRect? = nil,
        candidateSurfaceRect: CGRect? = nil,
        stablePlacesBelow: Bool? = nil,
        hidesOnAutomaticFlip: Bool = false,
        stableFallbackCandidateHasInputRoomBelow: Bool? = nil
    ) -> HUDLayoutResult {
        let gap = CGFloat(max(0, spacing))
        let minimumX = visibleFrame.minX
        let maximumX = max(
            minimumX,
            visibleFrame.maxX - panelSize.width
        )
        let preferredX =
            position == .above
            ? candidateRect.minX
            : horizontalOrigin ?? candidateRect.minX
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
        let automaticFlipProtectionEnabled =
            hidesOnAutomaticFlip && position == .automatic
        let fallbackCandidateHasInputRoomBelow =
            position == .automatic && inputCaretRect == nil
            ? Self.fallbackCandidateHasInputRoomBelow(
                candidateRect: candidateRect,
                visibleFrame: visibleFrame,
                stableValue:
                    stableFallbackCandidateHasInputRoomBelow
            )
            : nil

        let desiredPlacesBelow: Bool
        if position == .above {
            desiredPlacesBelow = false
        } else if let stablePlacesBelow,
            let inputCaretRect,
            abs(candidateRect.midY - inputCaretRect.midY)
                < Self.directionHysteresis
        {
            desiredPlacesBelow = stablePlacesBelow
        } else {
            // Without reliable caret geometry, prefer below because macOS
            // commonly places the candidate bar under the edited line.
            desiredPlacesBelow =
                inputCaretRect.map {
                    candidateRect.midY <= $0.midY
                } ?? true
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
        if position == .automatic,
            let inputCaretRect,
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
        let automaticallyFlippedAbove =
            position == .automatic
            && desiredPlacesBelow
            && !placesBelow
        if automaticallyFlippedAbove,
            inputCaretRect == nil,
            fallbackCandidateHasInputRoomBelow == false,
            let candidateSurfaceRect
        {
            let trailingX = trailingCandidateOriginX(
                candidateSurfaceRect,
                panelWidth: panelSize.width,
                gap: gap
            )
            if let trailingX, trailingX > x {
                x = max(
                    minimumX,
                    min(trailingX, maximumX)
                )
                mode = .candidateTrailing
            } else if trailingX == nil {
                let clearedY =
                    above
                    + inputRowClearance(for: candidateSurfaceRect)
                if clearedY + panelSize.height
                    <= visibleFrame.maxY
                {
                    y = clearedY
                    mode = .verticalClearance
                }
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
            placementMode: mode,
            // Only protect a forced upward flip. When the candidate bar is
            // already above the input row, its upper side is the safe side.
            hidesHUD:
                automaticFlipProtectionEnabled
                && desiredPlacesBelow
                && !placesBelow
                && (inputCaretRect != nil
                    || fallbackCandidateHasInputRoomBelow == false),
            fallbackCandidateHasInputRoomBelow:
                fallbackCandidateHasInputRoomBelow
        )
    }

    private static func overlapsInputLine(
        _ frame: CGRect,
        caret: CGRect
    ) -> Bool {
        frame.minY < caret.maxY
            && frame.maxY > caret.minY
    }

    private static func trailingCandidateOriginX(
        _ candidateSurfaceRect: CGRect,
        panelWidth: CGFloat,
        gap: CGFloat
    ) -> CGFloat? {
        let availableWidth =
            candidateSurfaceRect.width - gap
        guard
            candidateSurfaceRect.width > 0,
            availableWidth >= panelWidth
        else {
            return nil
        }
        return candidateSurfaceRect.maxX
            - gap
            - panelWidth
    }

    private static func inputRowClearance(
        for candidateRect: CGRect
    ) -> CGFloat {
        max(
            minimumFallbackInputRowClearance,
            candidateRect.height
                * fallbackInputRowClearanceRatio
        )
    }

    /// Web and accessibility hosts often omit caret geometry. When the
    /// candidate bar has visible room below it, the bar likely already
    /// flipped above the input row; when it is against the screen bottom,
    /// an upward HUD flip would have no safe input row to clear.
    private static func fallbackCandidateHasInputRoomBelow(
        candidateRect: CGRect,
        visibleFrame: CGRect,
        stableValue: Bool?
    ) -> Bool {
        let threshold = inputRowClearance(for: candidateRect)
        let clearance = candidateRect.minY - visibleFrame.minY
        switch stableValue {
        case true:
            return clearance
                >= threshold - fallbackClearanceHysteresis
        case false:
            return clearance
                > threshold + fallbackClearanceHysteresis
        case nil:
            return clearance >= threshold
        }
    }
}
