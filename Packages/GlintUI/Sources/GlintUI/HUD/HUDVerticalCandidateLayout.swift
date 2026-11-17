import CoreGraphics

enum HUDCandidateSide: Equatable {
    case left
    case right
}

struct HUDVerticalCandidatePlacement: Equatable {
    let origin: CGPoint
    let side: HUDCandidateSide
}

enum HUDVerticalCandidateLayout {
    private static let sideSwitchHysteresis: CGFloat = 8
    private static let rowContainmentTolerance: CGFloat = 1

    static func placement(
        candidateRect: CGRect,
        surfaceRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat,
        stableSide: HUDCandidateSide?
    ) -> HUDVerticalCandidatePlacement? {
        guard
            let side = preferredSide(
                for: surfaceRect,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                gap: gap,
                stableSide: stableSide
            )
        else {
            return nil
        }
        let minimumY = visibleFrame.minY
        let maximumY = max(
            minimumY,
            visibleFrame.maxY - panelSize.height
        )
        let candidateIsRow =
            candidateRect.height
            < surfaceRect.height - rowContainmentTolerance
            && candidateRect.minY
                >= surfaceRect.minY - rowContainmentTolerance
            && candidateRect.maxY
                <= surfaceRect.maxY + rowContainmentTolerance
        let preferredY =
            candidateIsRow
            ? candidateRect.midY - panelSize.height / 2
            : surfaceRect.maxY - panelSize.height
        let originY = max(
            minimumY,
            min(preferredY, maximumY)
        )
        let originX: CGFloat =
            switch side {
            case .right:
                surfaceRect.maxX + gap
            case .left:
                surfaceRect.minX - gap - panelSize.width
            }
        return HUDVerticalCandidatePlacement(
            origin: CGPoint(x: originX, y: originY),
            side: side
        )
    }

    private static func preferredSide(
        for surfaceRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat,
        stableSide: HUDCandidateSide?
    ) -> HUDCandidateSide? {
        let rightOriginX = surfaceRect.maxX + gap
        let leftOriginX =
            surfaceRect.minX - gap - panelSize.width
        let rightSlack =
            visibleFrame.maxX
            - (rightOriginX + panelSize.width)
        let rightFits = rightSlack >= 0
        let leftFits = leftOriginX >= visibleFrame.minX
        if stableSide == .left,
            leftFits,
            rightSlack < Self.sideSwitchHysteresis
        {
            return .left
        }
        if rightFits {
            return .right
        }
        if leftFits {
            return .left
        }
        return nil
    }
}
