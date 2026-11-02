import AppKit

@MainActor
public enum UpdatePanelContent {
    public static func install(_ content: NSView, in container: NSView) {
        for subview in container.subviews {
            subview.removeFromSuperview()
        }
        container.addSubview(content)
    }
}
