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
    private struct CachedContext {
        let displayFrame: CGRect
        let scale: CGFloat
        let filter: SCContentFilter
    }

    private var cachedContext: CachedContext?

    public init() {}

    @available(macOS 14.0, *)
    public func capture(region: CaptureRegion) async throws -> CGImage {
        let center = CGPoint(
            x: region.x + region.width / 2,
            y: region.y + region.height / 2
        )
        if let cachedContext,
           cachedContext.displayFrame.contains(center) {
            do {
                return try await capture(region: region, using: cachedContext)
            } catch {
                self.cachedContext = nil
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
            ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }

        let ownApplications = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let context = CachedContext(
            displayFrame: display.frame,
            scale: CGFloat(display.width) / max(1, display.frame.width),
            filter: SCContentFilter(
                display: display,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
        )
        cachedContext = context
        return try await capture(region: region, using: context)
    }

    @available(macOS 14.0, *)
    private func capture(
        region: CaptureRegion,
        using context: CachedContext
    ) async throws -> CGImage {
        var sourceRect = region.cgRect.offsetBy(
            dx: -context.displayFrame.minX,
            dy: -context.displayFrame.minY
        )
        sourceRect = sourceRect.intersection(
            CGRect(origin: .zero, size: context.displayFrame.size)
        )
        guard sourceRect.width > 8, sourceRect.height > 8 else {
            throw ScreenCaptureError.emptyRegion
        }

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * context.scale))
        configuration.height = max(1, Int(sourceRect.height * context.scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        return try await SCScreenshotManager.captureImage(
            contentFilter: context.filter,
            configuration: configuration
        )
    }
}
