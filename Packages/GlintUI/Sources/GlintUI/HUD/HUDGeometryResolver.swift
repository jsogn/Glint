import AppKit
import CoreGraphics

struct HUDHorizontalAnchor: Equatable {
    static let followThreshold: CGFloat = 8

    let screenFrame: NSRect
    let offsetX: CGFloat
    private(set) var candidateOriginX: CGFloat

    static func initial(
        screenFrame: NSRect,
        hudOriginX: CGFloat,
        candidateOriginX: CGFloat
    ) -> HUDHorizontalAnchor {
        HUDHorizontalAnchor(
            screenFrame: screenFrame,
            offsetX: hudOriginX - candidateOriginX,
            candidateOriginX: candidateOriginX
        )
    }

    func resolvedHUDOriginX(candidateOriginX: CGFloat) -> CGFloat {
        let acceptedCandidateOriginX =
            shouldFollow(candidateOriginX: candidateOriginX)
            ? candidateOriginX
            : self.candidateOriginX
        return acceptedCandidateOriginX + offsetX
    }

    func following(candidateOriginX: CGFloat) -> HUDHorizontalAnchor {
        guard shouldFollow(candidateOriginX: candidateOriginX) else {
            return self
        }
        return HUDHorizontalAnchor(
            screenFrame: screenFrame,
            offsetX: offsetX,
            candidateOriginX: candidateOriginX
        )
    }

    func shouldFollow(candidateOriginX: CGFloat) -> Bool {
        abs(candidateOriginX - self.candidateOriginX)
            >= Self.followThreshold
    }
}

struct HUDPresentationRequest {
    let revision: UInt64?
    let items: [HUDItem]
    let layoutStyle: HUDLayoutStyle
    let appearance: HUDAppearance
    let screenRect: CGRect
    let position: HUDPosition
    let spacing: Double
    let opacity: Double
}

struct HUDPresentationLayout {
    let request: HUDPresentationRequest
    let showsOnlySelectedItem: Bool
    let panelSize: NSSize
    let targetFrame: NSRect
    let placesBelow: Bool
}

@MainActor
struct HUDGeometryResolver {
    private var horizontalAnchor: HUDHorizontalAnchor?
    private var preferredPlacesBelow: Bool?

    mutating func resolve(
        _ request: HUDPresentationRequest
    ) -> HUDPresentationLayout? {
        guard
            let mainScreen = NSScreen.screens.first(where: {
                $0.frame.origin == .zero
            })
                ?? NSScreen.main
        else {
            return nil
        }
        let appKitRect = CGRect(
            x: request.screenRect.minX,
            y: mainScreen.frame.maxY - request.screenRect.maxY,
            width: request.screenRect.width,
            height: request.screenRect.height
        )
        let targetScreen =
            NSScreen.screens.first {
                $0.frame.contains(
                    NSPoint(x: appKitRect.midX, y: appKitRect.midY)
                )
            } ?? mainScreen
        let candidateOriginX = appKitRect.minX
        let fixedOriginX = horizontalAnchor.flatMap { anchor -> CGFloat? in
            guard anchor.screenFrame == targetScreen.frame else {
                return nil
            }
            let hudOriginX = anchor.resolvedHUDOriginX(
                candidateOriginX: candidateOriginX
            )
            let availableWidth =
                targetScreen.visibleFrame.maxX
                - HUDLayout.screenEdgeInset
                - hudOriginX
            return availableWidth >= HUDGeometry.minimumPanelWidth
                ? hudOriginX
                : nil
        }
        let maximumWidth = Self.maximumPanelWidth(
            in: targetScreen.visibleFrame,
            fixedOriginX: fixedOriginX
        )
        let showsOnlySelectedItem = HUDLayoutPlan.requiresSelectedOnly(
            for: request.items,
            maximumWidth: maximumWidth,
            layoutStyle: request.layoutStyle,
            appearance: request.appearance
        )
        let panelSize = HUDLayoutPlan.panelSize(
            for: request.items,
            maximumWidth: maximumWidth,
            selectedOnly: showsOnlySelectedItem,
            layoutStyle: request.layoutStyle,
            appearance: request.appearance
        )
        let preferredSide =
            horizontalAnchor?.screenFrame == targetScreen.frame
            ? preferredPlacesBelow
            : nil
        let layout = HUDLayout.placement(
            near: appKitRect,
            panelSize: panelSize,
            visibleFrame: targetScreen.visibleFrame,
            position: request.position,
            spacing: request.spacing,
            horizontalOrigin: fixedOriginX,
            preferredPlacesBelow: preferredSide
        )
        horizontalAnchor = HUDHorizontalAnchor.initial(
            screenFrame: targetScreen.frame,
            hudOriginX: layout.frame.minX,
            candidateOriginX: request.screenRect.minX
        )
        preferredPlacesBelow = layout.placesBelow
        return HUDPresentationLayout(
            request: request,
            showsOnlySelectedItem: showsOnlySelectedItem,
            panelSize: panelSize,
            targetFrame: layout.frame,
            placesBelow: layout.placesBelow
        )
    }

    mutating func reset() {
        horizontalAnchor = nil
        preferredPlacesBelow = nil
    }

    static func maximumPanelWidth(
        in visibleFrame: CGRect,
        fixedOriginX: CGFloat?
    ) -> CGFloat {
        let fullWidth =
            visibleFrame.width - HUDLayout.screenEdgeInset * 2
        guard let fixedOriginX else {
            return max(HUDGeometry.minimumPanelWidth, fullWidth)
        }
        let availableWidth =
            visibleFrame.maxX - HUDLayout.screenEdgeInset - fixedOriginX
        return max(
            HUDGeometry.minimumPanelWidth,
            min(fullWidth, availableWidth)
        )
    }
}
