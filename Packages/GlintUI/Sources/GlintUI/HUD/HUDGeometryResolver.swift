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
    let inputCaretRect: CGRect?
    let position: HUDPosition
    let spacing: Double
    let opacity: Double

    init(
        revision: UInt64?,
        items: [HUDItem],
        layoutStyle: HUDLayoutStyle,
        appearance: HUDAppearance,
        screenRect: CGRect,
        inputCaretRect: CGRect?,
        position: HUDPosition = .automatic,
        spacing: Double,
        opacity: Double
    ) {
        self.revision = revision
        self.items = items
        self.layoutStyle = layoutStyle
        self.appearance = appearance
        self.screenRect = screenRect
        self.inputCaretRect = inputCaretRect
        self.position = position
        self.spacing = spacing
        self.opacity = opacity
    }

    func updatingLayout(
        screenRect: CGRect,
        inputCaretRect: CGRect?
    ) -> Self {
        Self(
            revision: revision,
            items: items,
            layoutStyle: layoutStyle,
            appearance: appearance,
            screenRect: screenRect,
            inputCaretRect: inputCaretRect,
            position: position,
            spacing: spacing,
            opacity: opacity
        )
    }
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
    private struct ResolvedScreenContext {
        let candidateRect: CGRect
        let inputCaretRect: CGRect?
        let screen: NSScreen
        let fixedOriginX: CGFloat?
    }

    private var horizontalAnchor: HUDHorizontalAnchor?
    private var previousPlacesBelow: Bool?
    private var resolvedScreenFrame: NSRect?

    mutating func resolve(
        _ request: HUDPresentationRequest
    ) -> HUDPresentationLayout? {
        guard let context = screenContext(for: request) else {
            return nil
        }
        let maximumWidth = Self.maximumPanelWidth(
            in: context.screen.visibleFrame,
            fixedOriginX: context.fixedOriginX
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
        let layout = placement(
            context: context,
            panelSize: panelSize,
            position: request.position,
            spacing: request.spacing,
            candidateOriginX: request.screenRect.minX
        )
        return HUDPresentationLayout(
            request: request,
            showsOnlySelectedItem: showsOnlySelectedItem,
            panelSize: panelSize,
            targetFrame: layout.frame,
            placesBelow: layout.placesBelow
        )
    }

    mutating func resolveLayoutOnly(
        _ request: HUDPresentationRequest,
        panelSize: NSSize
    ) -> NSRect? {
        guard let context = screenContext(for: request) else {
            return nil
        }
        let maximumWidth = Self.maximumPanelWidth(
            in: context.screen.visibleFrame,
            fixedOriginX: context.fixedOriginX
        )
        // Nil asks the controller to run the full content layout when the
        // current panel is wider than the remaining target-screen space.
        guard panelSize.width <= maximumWidth + 0.5 else {
            return nil
        }
        return placement(
            context: context,
            panelSize: panelSize,
            position: request.position,
            spacing: request.spacing,
            candidateOriginX: request.screenRect.minX
        ).frame
    }

    mutating func reset() {
        horizontalAnchor = nil
        previousPlacesBelow = nil
        resolvedScreenFrame = nil
    }

    static func maximumPanelWidth(
        in visibleFrame: CGRect,
        fixedOriginX: CGFloat?
    ) -> CGFloat {
        let fullWidth = visibleFrame.width
        guard let fixedOriginX else {
            return max(HUDGeometry.minimumPanelWidth, fullWidth)
        }
        let availableWidth =
            visibleFrame.maxX - fixedOriginX
        return max(
            HUDGeometry.minimumPanelWidth,
            min(fullWidth, availableWidth)
        )
    }

    private func screenContext(
        for request: HUDPresentationRequest
    ) -> ResolvedScreenContext? {
        guard
            let mainScreen = NSScreen.screens.first(where: {
                $0.frame.origin == .zero
            })
                ?? NSScreen.main
        else {
            return nil
        }
        let candidateRect = CGRect(
            x: request.screenRect.minX,
            y: mainScreen.frame.maxY - request.screenRect.maxY,
            width: request.screenRect.width,
            height: request.screenRect.height
        )
        let inputCaretRect = request.inputCaretRect.map {
            CGRect(
                x: $0.minX,
                y: mainScreen.frame.maxY - $0.maxY,
                width: $0.width,
                height: $0.height
            )
        }
        let targetScreen =
            NSScreen.screens.first {
                $0.frame.contains(
                    NSPoint(
                        x: candidateRect.midX,
                        y: candidateRect.midY
                    )
                )
            } ?? mainScreen
        let candidateOriginX = candidateRect.minX
        let fixedOriginX =
            request.position == .automatic
            ? horizontalAnchor.flatMap { anchor -> CGFloat? in
                guard anchor.screenFrame == targetScreen.frame else {
                    return nil
                }
                let hudOriginX = anchor.resolvedHUDOriginX(
                    candidateOriginX: candidateOriginX
                )
                let availableWidth =
                    targetScreen.visibleFrame.maxX
                    - hudOriginX
                return availableWidth >= HUDGeometry.minimumPanelWidth
                    ? hudOriginX
                    : nil
            }
            : nil
        return ResolvedScreenContext(
            candidateRect: candidateRect,
            inputCaretRect: inputCaretRect,
            screen: targetScreen,
            fixedOriginX: fixedOriginX
        )
    }

    private mutating func placement(
        context: ResolvedScreenContext,
        panelSize: NSSize,
        position: HUDPosition,
        spacing: Double,
        candidateOriginX: CGFloat
    ) -> HUDLayoutResult {
        let stablePlacesBelow =
            resolvedScreenFrame == context.screen.frame
            ? previousPlacesBelow
            : nil
        let layout = HUDLayout.placement(
            near: context.candidateRect,
            panelSize: panelSize,
            visibleFrame: context.screen.visibleFrame,
            position: position,
            spacing: spacing,
            horizontalOrigin: context.fixedOriginX,
            inputCaretRect: context.inputCaretRect,
            stablePlacesBelow: stablePlacesBelow
        )
        let alignedFrame = Self.pixelAligned(
            layout.frame,
            scale: context.screen.backingScaleFactor
        )
        let alignedLayout = HUDLayoutResult(
            frame: alignedFrame,
            placesBelow: layout.placesBelow,
            placementMode: layout.placementMode
        )
        if position == .above {
            horizontalAnchor = nil
        } else if alignedLayout.placementMode == .candidate {
            if let horizontalAnchor,
                context.fixedOriginX != nil,
                horizontalAnchor.screenFrame == context.screen.frame
            {
                self.horizontalAnchor =
                    horizontalAnchor.following(
                        candidateOriginX: candidateOriginX
                    )
            } else {
                self.horizontalAnchor =
                    HUDHorizontalAnchor.initial(
                        screenFrame: context.screen.frame,
                        hudOriginX: alignedLayout.frame.minX,
                        candidateOriginX: candidateOriginX
                    )
            }
        } else {
            horizontalAnchor = nil
        }
        resolvedScreenFrame = context.screen.frame
        previousPlacesBelow = alignedLayout.placesBelow
        return alignedLayout
    }

    private static func pixelAligned(
        _ frame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        guard scale.isFinite, scale > 0 else { return frame }
        return CGRect(
            x: (frame.minX * scale).rounded() / scale,
            y: (frame.minY * scale).rounded() / scale,
            width: frame.width,
            height: frame.height
        )
    }
}
