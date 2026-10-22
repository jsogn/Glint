import AppKit
import SwiftUI

enum HUDContentUpdate: Equatable {
    case entry
    case patch
    case transition
}

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

@MainActor
public final class HUDController {
    private enum Timing {
        static let enter = 0.06
        static let leave = 0.06
        static let textTransition = 0.06
        static let presentationCoalescingNanoseconds: UInt64 = 8_000_000
        static let staleDimNanoseconds: UInt64 = 80_000_000
        static let staleOpacity = 0.3
    }

    private struct PresentationRequest {
        let revision: UInt64?
        let items: [HUDItem]
        let appearance: HUDAppearance
        let screenRect: CGRect
        let position: HUDPosition
        let spacing: Double
        let opacity: Double
    }

    private struct PresentationLayout {
        let request: PresentationRequest
        let showsOnlySelectedItem: Bool
        let panelSize: NSSize
        let targetFrame: NSRect
        let placesBelow: Bool
        let screenFrame: NSRect
        let usesHorizontalAnchor: Bool
    }

    private let panel: NSPanel
    private let contentModel: HUDPresentationModel
    private var panelSize = NSSize(width: 440, height: 36)
    private var displayedRevision: UInt64?
    private var pendingPresentation: PresentationRequest?
    private var coalescedPresentation: PresentationRequest?
    private var presentationCoalescingTask: Task<Void, Never>?
    private var horizontalAnchor: HUDHorizontalAnchor?
    private var preferredPlacesBelow: Bool?
    private var entryAnimationIsActive = false
    private var entryAnimationGeneration = 0
    private var transitionGeneration = 0
    private var stalePresentationTask: Task<Void, Never>?
    private var stalePresentationGeneration = 0

    public init(text: String = "hello") {
        let contentModel = HUDPresentationModel(
            text: text,
            appearance: .default,
            backgroundOpacity: 0.92,
            animatesTransitions: !NSWorkspace.shared
                .accessibilityDisplayShouldReduceMotion
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let hostingView = NSHostingView(
            rootView: HUDLiveView(model: contentModel)
        )
        panel.contentView = hostingView
        self.contentModel = contentModel
        self.panel = panel
    }

    public func show() {
        cancelStalePresentation()
        transitionGeneration &+= 1
        contentModel.textOpacity = 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    public func beginUpdate() {
        cancelCoalescedPresentation()
        pendingPresentation = nil
        guard panel.isVisible else { return }
        transitionGeneration &+= 1
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        if reduceMotion {
            panel.alphaValue = 1
        } else if !entryAnimationIsActive,
                  panel.alphaValue < 0.999 {
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: nil
            )
        }
        guard stalePresentationTask == nil,
              contentModel.textOpacity >= 0.999 else {
            return
        }
        beginStalePresentation()
    }

    public func updateSelection(itemID: Int) {
        let updated = contentModel.items.map { item in
            HUDItem(
                id: item.id,
                number: item.number,
                text: item.text,
                isSelected: item.id == itemID
            )
        }
        guard updated != contentModel.items else { return }
        withoutAnimation {
            contentModel.items = updated
        }
    }

    public func show(
        text: String,
        near screenRect: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.92,
        appearance: HUDAppearance = .default,
        revision: UInt64? = nil
    ) {
        enqueuePresentation(
            PresentationRequest(
                revision: revision,
                items: [HUDItem(id: 0, text: text)],
                appearance: appearance,
                screenRect: screenRect,
                position: position,
                spacing: spacing,
                opacity: opacity
            )
        )
    }

    public func show(
        items: [HUDItem],
        near screenRect: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.92,
        appearance: HUDAppearance = .default,
        revision: UInt64? = nil
    ) {
        enqueuePresentation(
            PresentationRequest(
                revision: revision,
                items: items,
                appearance: appearance,
                screenRect: screenRect,
                position: position,
                spacing: spacing,
                opacity: opacity
            )
        )
    }

    private func enqueuePresentation(_ request: PresentationRequest) {
        coalescedPresentation = request
        guard presentationCoalescingTask == nil else { return }

        presentationCoalescingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Timing.presentationCoalescingNanoseconds
                )
                guard let self else { return }
                self.presentationCoalescingTask = nil
                guard let request = self.coalescedPresentation else {
                    return
                }
                self.coalescedPresentation = nil
                self.present(request)
            } catch {
                return
            }
        }
    }

    private func present(_ request: PresentationRequest) {
        cancelStalePresentation()
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        transitionGeneration &+= 1

        if panel.isVisible, entryAnimationIsActive {
            pendingPresentation = request
            return
        }

        guard let layout = resolveLayout(for: request) else {
            applyContent(
                request,
                textOpacity: 1,
                animatesText: false
            )
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            displayedRevision = request.revision
            return
        }
        let update = Self.contentUpdate(
            displayedRevision: displayedRevision,
            incomingRevision: request.revision,
            isVisible: panel.isVisible
        )
        if update == .entry {
            presentEntry(layout, reduceMotion: reduceMotion)
        } else {
            presentVisible(
                layout,
                update: update,
                reduceMotion: reduceMotion
            )
        }
    }

    private func resolveLayout(
        for request: PresentationRequest
    ) -> PresentationLayout? {
        guard let mainScreen = NSScreen.screens.first(where: {
            $0.frame.origin == .zero
        })
            ?? NSScreen.main else {
            return nil
        }
        let appKitRect = CGRect(
            x: request.screenRect.minX,
            y: mainScreen.frame.maxY - request.screenRect.maxY,
            width: request.screenRect.width,
            height: request.screenRect.height
        )
        let targetScreen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: appKitRect.midX, y: appKitRect.midY))
        } ?? mainScreen
        let candidateOriginX = appKitRect.minX
        // Follow meaningful candidate-row movement while ignoring IME jitter.
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
            return availableWidth >= 120 ? hudOriginX : nil
        }
        let maximumWidth = Self.maximumPanelWidth(
            in: targetScreen.visibleFrame,
            fixedOriginX: fixedOriginX
        )
        let showsOnlySelectedItem = HUDItemRow.requiresSelectedOnly(
            for: request.items,
            maximumWidth: maximumWidth,
            appearance: request.appearance
        )
        let proposedPanelSize = Self.panelSize(
            for: request.items,
            maximumWidth: maximumWidth,
            selectedOnly: showsOnlySelectedItem,
            appearance: request.appearance
        )
        let resolvedPanelSize = proposedPanelSize
        let preferredSide =
            horizontalAnchor?.screenFrame == targetScreen.frame
                ? preferredPlacesBelow
                : nil
        let layout = HUDLayout.placement(
            near: appKitRect,
            panelSize: resolvedPanelSize,
            visibleFrame: targetScreen.visibleFrame,
            position: request.position,
            spacing: request.spacing,
            horizontalOrigin: fixedOriginX,
            preferredPlacesBelow: preferredSide
        )
        return PresentationLayout(
            request: request,
            showsOnlySelectedItem: showsOnlySelectedItem,
            panelSize: resolvedPanelSize,
            targetFrame: layout.frame,
            placesBelow: layout.placesBelow,
            screenFrame: targetScreen.frame,
            usesHorizontalAnchor: fixedOriginX != nil
        )
    }

    private func presentEntry(
        _ layout: PresentationLayout,
        reduceMotion: Bool
    ) {
        panelSize = layout.panelSize
        applyContent(
            layout.request,
            showsOnlySelectedItem: layout.showsOnlySelectedItem,
            textOpacity: 1,
            animatesText: false
        )
        let entryOffset: CGFloat = layout.placesBelow ? 2 : -2
        let entryFrame = reduceMotion
            ? layout.targetFrame
            : layout.targetFrame.offsetBy(dx: 0, dy: entryOffset)
        panel.setFrame(entryFrame, display: false)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        displayedRevision = layout.request.revision
        horizontalAnchor = HUDHorizontalAnchor.initial(
            screenFrame: layout.screenFrame,
            hudOriginX: layout.targetFrame.minX,
            candidateOriginX: layout.request.screenRect.minX
        )
        preferredPlacesBelow = layout.placesBelow
        guard !reduceMotion else { return }

        entryAnimationGeneration &+= 1
        let generation = entryAnimationGeneration
        entryAnimationIsActive = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Timing.enter
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(layout.targetFrame, display: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.finishEntryAnimation(generation: generation)
            }
        }
    }

    private func finishEntryAnimation(generation: Int) {
        guard generation == entryAnimationGeneration,
              entryAnimationIsActive else {
            return
        }
        entryAnimationIsActive = false
        panel.alphaValue = 1
        guard let pendingPresentation else { return }
        self.pendingPresentation = nil
        present(pendingPresentation)
    }

    private func presentVisible(
        _ layout: PresentationLayout,
        update: HUDContentUpdate,
        reduceMotion: Bool
    ) {
        panelSize = layout.panelSize
        if reduceMotion {
            panel.alphaValue = 1
        } else if !entryAnimationIsActive,
                  panel.alphaValue < 0.999 {
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: nil
            )
        } else {
            panel.alphaValue = 1
        }
        let animatesText = update == .transition
            && contentModel.textOpacity < 0.999
        applyContent(
            layout.request,
            showsOnlySelectedItem: layout.showsOnlySelectedItem,
            textOpacity: 1,
            animatesText: animatesText
        )
        // Commit content and geometry in one display pass so the old capsule
        // cannot appear clipped by the resized panel for a frame.
        panel.contentView?.layoutSubtreeIfNeeded()
        if panel.frame != layout.targetFrame {
            panel.setFrame(layout.targetFrame, display: true)
        }
        let candidateOriginX = layout.request.screenRect.minX
        if layout.usesHorizontalAnchor,
           let anchor = horizontalAnchor,
           anchor.screenFrame == layout.screenFrame {
            horizontalAnchor = anchor.following(
                candidateOriginX: candidateOriginX
            )
        } else {
            horizontalAnchor = HUDHorizontalAnchor.initial(
                screenFrame: layout.screenFrame,
                hudOriginX: layout.targetFrame.minX,
                candidateOriginX: candidateOriginX
            )
        }
        preferredPlacesBelow = layout.placesBelow
        displayedRevision = layout.request.revision
    }

    public func hide(animated: Bool = true) {
        cancelStalePresentation()
        cancelCoalescedPresentation()
        pendingPresentation = nil
        entryAnimationGeneration &+= 1
        entryAnimationIsActive = false
        transitionGeneration &+= 1
        let generation = transitionGeneration
        guard panel.isVisible else {
            panel.alphaValue = 0
            horizontalAnchor = nil
            preferredPlacesBelow = nil
            return
        }
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            finishHiding(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Timing.leave
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.finishHiding(generation: generation)
            }
        }
    }

    private func animate(
        duration: TimeInterval,
        alpha: CGFloat,
        frame: NSRect?
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
            if let frame {
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    private func finishHiding(generation: Int) {
        guard generation == transitionGeneration else { return }
        panel.orderOut(nil)
        panel.alphaValue = 0
        displayedRevision = nil
        horizontalAnchor = nil
        preferredPlacesBelow = nil
    }

    private func beginStalePresentation() {
        stalePresentationGeneration &+= 1
        let generation = stalePresentationGeneration

        stalePresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Timing.staleDimNanoseconds
                )
                guard let self,
                      self.stalePresentationGeneration == generation,
                      self.panel.isVisible else {
                    return
                }
                self.animateTextOpacity(Timing.staleOpacity)
                self.stalePresentationTask = nil
            } catch {
                return
            }
        }
    }

    private func cancelStalePresentation() {
        stalePresentationGeneration &+= 1
        stalePresentationTask?.cancel()
        stalePresentationTask = nil
    }

    private func cancelCoalescedPresentation() {
        presentationCoalescingTask?.cancel()
        presentationCoalescingTask = nil
        coalescedPresentation = nil
    }

    private func applyContent(
        _ request: PresentationRequest,
        showsOnlySelectedItem: Bool? = nil,
        textOpacity: Double,
        animatesText: Bool
    ) {
        let changes = {
            self.contentModel.items = request.items
            self.contentModel.appearance = request.appearance
            self.contentModel.backgroundOpacity = request.opacity
            if let showsOnlySelectedItem {
                self.contentModel.showsOnlySelectedItem =
                    showsOnlySelectedItem
            }
            self.contentModel.textOpacity = textOpacity
        }
        if animatesText {
            withAnimation(
                .easeOut(duration: Timing.textTransition)
            ) {
                changes()
            }
        } else {
            withoutAnimation(changes)
        }
    }

    private func animateTextOpacity(_ opacity: Double) {
        if contentModel.animatesTransitions {
            withAnimation(
                .easeOut(duration: Timing.textTransition)
            ) {
                contentModel.textOpacity = opacity
            }
        } else {
            withoutAnimation {
                contentModel.textOpacity = opacity
            }
        }
    }

    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    static func contentUpdate(
        displayedRevision: UInt64?,
        incomingRevision: UInt64?,
        isVisible: Bool
    ) -> HUDContentUpdate {
        guard isVisible else { return .entry }
        guard let displayedRevision,
              let incomingRevision,
              displayedRevision == incomingRevision else {
            return .transition
        }
        return .patch
    }

    static func maximumPanelWidth(
        in visibleFrame: CGRect,
        fixedOriginX: CGFloat?
    ) -> CGFloat {
        let fullWidth =
            visibleFrame.width - HUDLayout.screenEdgeInset * 2
        guard let fixedOriginX else { return max(120, fullWidth) }
        let availableWidth =
            visibleFrame.maxX - HUDLayout.screenEdgeInset - fixedOriginX
        return max(120, min(fullWidth, availableWidth))
    }

    static func panelSize(
        for items: [HUDItem],
        maximumWidth: CGFloat,
        selectedOnly: Bool = false,
        appearance: HUDAppearance = .default
    ) -> NSSize {
        let metrics = HUDLayoutMetrics(appearance: appearance)
        let height = metrics.panelHeight
        let widthLimit = max(120, maximumWidth)
        let width: CGFloat
        if selectedOnly {
            width = items.map {
                HUDItemRow.naturalPanelWidth(
                    for: [$0],
                    appearance: appearance
                )
            }.max() ?? 120
        } else {
            width = HUDItemRow.naturalPanelWidth(
                for: items,
                appearance: appearance
            )
        }
        let minimumWidth: CGFloat
        if selectedOnly || items.count <= 1 {
            minimumWidth = 120
        } else {
            minimumWidth = max(
                220,
                HUDItemRow.minimumPanelWidth(
                    for: items.count,
                    appearance: appearance
                )
            )
        }
        return NSSize(
            width: min(
                widthLimit,
                max(minimumWidth, width)
            ),
            height: height
        )
    }

}
