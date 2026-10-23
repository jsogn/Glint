import AppKit
import SwiftUI

@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let minimumWindowSize = NSSize(width: 1_040, height: 640)

    public init(model: MainWindowModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_040, height: 720),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        window.title = "Glint"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
        window.minSize = Self.minimumWindowSize
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        guard let window else { return }
        enforceMinimumWindowSize()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        Self.clampedWindowSize(frameSize)
    }

    static func clampedWindowSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: max(size.width, minimumWindowSize.width),
            height: max(size.height, minimumWindowSize.height)
        )
    }

    private func enforceMinimumWindowSize() {
        guard let window else { return }
        var frame = window.frame
        let clampedSize = Self.clampedWindowSize(frame.size)
        guard clampedSize != frame.size else { return }
        frame.size = clampedSize
        window.setFrame(frame, display: false)
    }
}
