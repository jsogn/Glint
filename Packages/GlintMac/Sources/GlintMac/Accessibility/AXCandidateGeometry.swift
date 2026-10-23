import CoreGraphics

public enum AXCandidateFrameKind: String, Sendable, Equatable {
    case window
    case list
    case item
    case text
}

public struct AXCandidateGeometry: Sendable, Equatable {
    public let horizontalAnchor: CGRect
    public let verticalBounds: CGRect
    public let horizontalSource: AXCandidateFrameKind
    public let verticalSource: AXCandidateFrameKind

    public init(
        horizontalFrame: CGRect,
        horizontalSource: AXCandidateFrameKind,
        verticalFrame: CGRect,
        verticalSource: AXCandidateFrameKind
    ) {
        self.horizontalSource = horizontalSource
        self.verticalSource = verticalSource
        horizontalAnchor = horizontalFrame
        verticalBounds = verticalFrame
    }

    func displayFrame(horizontalFrame: CGRect) -> CGRect {
        let verticalFrame =
            usesContainerVerticalBounds
            ? verticalBounds
            : horizontalFrame
        return CGRect(
            x: horizontalFrame.minX,
            y: verticalFrame.minY,
            width: horizontalFrame.width,
            height: verticalFrame.height
        )
    }

    private var usesContainerVerticalBounds: Bool {
        verticalSource == .window || verticalSource == .list
    }

}

enum AXCandidateTextFrame {
    static func presentationFrame(for frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else {
            return frame
        }
        let leadingInset = min(
            8,
            max(3, (frame.height * 0.18).rounded())
        )
        return CGRect(
            x: frame.minX - leadingInset,
            y: frame.minY,
            width: frame.width + leadingInset,
            height: frame.height
        )
    }
}
