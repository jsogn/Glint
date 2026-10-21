import AppKit
import SwiftUI

@MainActor
public final class HUDController {
    private enum Timing {
        static let enter = 0.08
        static let leave = 0.06
        static let staleDimNanoseconds: UInt64 = 80_000_000
        static let staleOpacity = 0.3
    }

    private let panel: NSPanel
    private let contentModel: HUDPresentationModel
    private var panelSize = NSSize(width: 440, height: 36)
    private var transitionGeneration = 0
    private var stalePresentationTask: Task<Void, Never>?
    private var stalePresentationGeneration = 0

    public init(text: String = "hello") {
        let contentModel = HUDPresentationModel(
            text: text,
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
        panel.contentView = NSHostingView(
            rootView: HUDLiveView(model: contentModel)
        )
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
        guard panel.isVisible else { return }
        transitionGeneration &+= 1
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        if reduceMotion {
            panel.alphaValue = 1
        } else if panel.alphaValue < 0.999 {
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
        contentModel.items = updated
    }

    public func show(
        text: String,
        near screenRect: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.92
    ) {
        present(
            items: [HUDItem(id: 0, text: text)],
            near: screenRect,
            position: position,
            spacing: spacing,
            opacity: opacity
        )
    }

    public func show(
        items: [HUDItem],
        near screenRect: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.92
    ) {
        present(
            items: items,
            near: screenRect,
            position: position,
            spacing: spacing,
            opacity: opacity
        )
    }

    private func present(
        items: [HUDItem],
        near screenRect: CGRect,
        position: HUDPosition,
        spacing: Double,
        opacity: Double
    ) {
        cancelStalePresentation()
        let reduceMotion =
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        contentModel.animatesTransitions = !reduceMotion
        transitionGeneration &+= 1
        guard let mainScreen = NSScreen.screens.first(where: {
            $0.frame.origin == .zero
        })
            ?? NSScreen.main else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        let appKitRect = CGRect(
            x: screenRect.minX,
            y: mainScreen.frame.maxY - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
        let targetScreen = NSScreen.screens.first {
            $0.frame.contains(NSPoint(x: appKitRect.midX, y: appKitRect.midY))
        } ?? mainScreen
        let maximumWidth = targetScreen.visibleFrame.width - 16
        let showsOnlySelectedItem = HUDItemRow.requiresSelectedOnly(
            for: items,
            maximumWidth: maximumWidth
        )
        contentModel.items = items
        contentModel.backgroundOpacity = opacity
        contentModel.textOpacity = 1
        contentModel.showsOnlySelectedItem = showsOnlySelectedItem
        let proposedPanelSize = Self.panelSize(
            for: items,
            maximumWidth: maximumWidth,
            selectedOnly: showsOnlySelectedItem
        )
        panelSize = Self.resolvedPanelSize(
            current: panelSize,
            proposed: proposedPanelSize,
            isVisible: panel.isVisible
        )
        let layout = HUDLayout.placement(
            near: appKitRect,
            panelSize: panelSize,
            visibleFrame: targetScreen.visibleFrame,
            position: position,
            spacing: spacing
        )
        let targetFrame = layout.frame
        let placesBelow = layout.placesBelow

        if !panel.isVisible {
            let entryOffset: CGFloat = placesBelow ? 2 : -2
            let entryFrame = reduceMotion
                ? targetFrame
                : targetFrame.offsetBy(dx: 0, dy: entryOffset)
            panel.setFrame(entryFrame, display: false)
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.orderFrontRegardless()
            guard !reduceMotion else { return }
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: targetFrame
            )
            return
        }

        if reduceMotion {
            panel.alphaValue = 1
        } else if panel.alphaValue < 0.999 {
            animate(
                duration: Timing.enter,
                alpha: 1,
                frame: nil
            )
        } else {
            panel.alphaValue = 1
        }
        panel.setFrame(targetFrame, display: true)
    }

    public func hide(animated: Bool = true) {
        cancelStalePresentation()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        guard panel.isVisible else {
            panel.alphaValue = 0
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
                self.contentModel.textOpacity = Timing.staleOpacity
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

    static func panelSize(
        for items: [HUDItem],
        maximumWidth: CGFloat,
        selectedOnly: Bool = false
    ) -> NSSize {
        let height: CGFloat = 36
        let widthLimit = max(120, maximumWidth)
        let width: CGFloat
        if selectedOnly {
            width = items.map {
                HUDItemRow.naturalPanelWidth(for: [$0])
            }.max() ?? 120
        } else {
            width = HUDItemRow.naturalPanelWidth(for: items)
        }
        let minimumWidth: CGFloat
        if selectedOnly || items.count <= 1 {
            minimumWidth = 120
        } else {
            minimumWidth = max(
                220,
                HUDItemRow.minimumPanelWidth(for: items.count)
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

    static func resolvedPanelSize(
        current: NSSize,
        proposed: NSSize,
        isVisible: Bool
    ) -> NSSize {
        NSSize(
            width: isVisible
                ? max(current.width, proposed.width)
                : proposed.width,
            height: proposed.height
        )
    }
}
