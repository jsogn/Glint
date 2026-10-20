import AppKit
import SwiftUI

@MainActor
public final class HUDController {
    private let panel: NSPanel
    private let panelSize = NSSize(width: 440, height: 36)

    public init(text: String = "hello") {
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
        panel.contentView = NSHostingView(rootView: HUDView(text: text))
        self.panel = panel
    }

    public func show() {
        panel.orderFrontRegardless()
    }

    public func show(
        text: String,
        near screenRect: CGRect,
        position: HUDPosition = .automatic,
        spacing: Double = 8,
        opacity: Double = 0.92
    ) {
        present(
            text: text,
            near: screenRect,
            position: position,
            spacing: spacing,
            opacity: opacity
        )
    }

    private func present(
        text: String,
        near screenRect: CGRect,
        position: HUDPosition,
        spacing: Double,
        opacity: Double
    ) {
        panel.contentView = NSHostingView(
            rootView: HUDView(text: text, backgroundOpacity: opacity)
        )
        guard let mainScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main else {
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
        let visible = targetScreen.visibleFrame
        let gap = CGFloat(max(0, spacing))
        var x = appKitRect.minX
        x = max(visible.minX + 8, min(x, visible.maxX - panelSize.width - 8))
        let below = appKitRect.minY - panelSize.height - gap
        let above = appKitRect.maxY + gap
        var y: CGFloat
        switch position {
        case .automatic:
            y = below >= visible.minY + 8 ? below : above
        case .above:
            y = above
        case .below:
            y = below
        }
        y = max(visible.minY + 8, min(y, visible.maxY - panelSize.height - 8))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }
}
