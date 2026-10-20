import CoreGraphics
import Foundation
import ScreenCaptureKit

public struct CaptureRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum ScreenCaptureError: Error, Sendable, Equatable {
    case noDisplay
    case emptyRegion
}

public actor CandidateCapture {
    public init() {}

    @available(macOS 14.0, *)
    public func capture(region: CaptureRegion) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let center = CGPoint(x: region.x + region.width / 2, y: region.y + region.height / 2)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        var sourceRect = region.cgRect.offsetBy(
            dx: -display.frame.minX,
            dy: -display.frame.minY
        )
        sourceRect = sourceRect.intersection(
            CGRect(origin: .zero, size: display.frame.size)
        )
        guard sourceRect.width > 8, sourceRect.height > 8 else {
            throw ScreenCaptureError.emptyRegion
        }

        let scale = CGFloat(display.width) / max(1, display.frame.width)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scale))
        configuration.height = max(1, Int(sourceRect.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}
