import AppKit
import SwiftUI

@MainActor
public final class HUDController {
    private enum Timing {
        static let enter = 0.06
        static let leave = 0.06
        static let textTransition = 0.06
        static let staleOpacity = 0.3
    }

    private let panel: NSPanel
    private let contentModel: HUDPresentationModel
    private var geometryResolver = HUDGeometryResolver()
    private lazy var scheduler = HUDPresentationScheduler(
        present: { [weak self] request in
            self?.present(request)
        },
        dimStaleContent: { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.animateTextOpacity(Timing.staleOpacity)
        }
    )
    private var panelSize = HUDGeometry.initialPanelSize
    private var displayedRevision: UInt64?
    private var entryAnimationIsActive = false
    private var entryAnimationGeneration = 0
    private var transitionGeneration = 0

    public init() {
        let contentModel = HUDPresentationModel(
            text: "",
            appearance: .default,
            backgroundOpacity: 0.8,
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
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let hostingView = NSHostingView(
            rootView: HUDLiveView(model: contentModel)
        )
        // HUDGeometryResolver owns the panel geometry. Without this,
        // NSHostingView can shrink the panel to its intrinsic content height
        // after ordering it on screen, moving the candidate-facing edge.
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        self.contentModel = contentModel
        self.panel = panel
    }

    public func beginUpdate() {
        scheduler.cancelQueuedPresentations()
        guard panel.isVisible else { return }
        transitionGeneration &+= 1
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        if reduceMotion {
            panel.alphaValue = 1
        } else if !entryAnimationIsActive,
            panel.alphaValue < 0.999
        {
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: nil
            )
        }
        guard !scheduler.isStaleDimPending,
            contentModel.textOpacity >= 0.999
        else {
            return
        }
        scheduler.startStaleDimmingIfNeeded()
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
        items: [HUDItem],
        near screenRect: CGRect,
        inputCaretRect: CGRect? = nil,
        layoutStyle: HUDLayoutStyle = .candidateRow,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.8,
        appearance: HUDAppearance = .default,
        revision: UInt64? = nil
    ) {
        scheduler.enqueue(
            HUDPresentationRequest(
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
        )
    }

    private func present(_ request: HUDPresentationRequest) {
        scheduler.cancelStaleDimming()
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        transitionGeneration &+= 1

        if panel.isVisible, entryAnimationIsActive {
            scheduler.deferUntilPresentationReady(request)
            return
        }

        guard let layout = geometryResolver.resolve(request) else {
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
        let update = HUDPresentationScheduler.contentUpdate(
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

    private func presentEntry(
        _ layout: HUDPresentationLayout,
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
        let entryFrame =
            reduceMotion
            ? layout.targetFrame
            : layout.targetFrame.offsetBy(dx: 0, dy: entryOffset)
        panel.setFrame(entryFrame, display: false)
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.orderFrontRegardless()
        displayedRevision = layout.request.revision
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
            entryAnimationIsActive
        else {
            return
        }
        entryAnimationIsActive = false
        panel.alphaValue = 1
        guard let request = scheduler.takePendingRequest() else { return }
        present(request)
    }

    private func presentVisible(
        _ layout: HUDPresentationLayout,
        update: HUDContentUpdate,
        reduceMotion: Bool
    ) {
        panelSize = layout.panelSize
        if reduceMotion {
            panel.alphaValue = 1
        } else if !entryAnimationIsActive,
            panel.alphaValue < 0.999
        {
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: nil
            )
        } else {
            panel.alphaValue = 1
        }
        let animatesText =
            update == .transition
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
        displayedRevision = layout.request.revision
    }

    public func hide(animated: Bool = true) {
        scheduler.reset()
        entryAnimationGeneration &+= 1
        entryAnimationIsActive = false
        transitionGeneration &+= 1
        let generation = transitionGeneration
        guard panel.isVisible else {
            panel.alphaValue = 0
            geometryResolver.reset()
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
        geometryResolver.reset()
    }

    private func applyContent(
        _ request: HUDPresentationRequest,
        showsOnlySelectedItem: Bool? = nil,
        textOpacity: Double,
        animatesText: Bool
    ) {
        let changes = {
            self.contentModel.items = request.items
            self.contentModel.layoutStyle = request.layoutStyle
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

}
