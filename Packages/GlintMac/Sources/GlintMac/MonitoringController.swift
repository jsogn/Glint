import CoreGraphics
import Foundation
import GlintCore
import OSLog

private let monitoringLogger = Logger(
    subsystem: "com.local.glint",
    category: "Monitoring"
)

public enum MonitoringEvent: Sendable {
    case status(String)
    case result(Candidate, TranslationResult, CaptureRegion)
    case hidden
}

public actor MonitoringController {
    private let inputSource = InputSourceMonitor()
    private let focus = FocusMonitor()
    private let capture = CandidateCapture()
    private var ocr = OCRService()
    private var ocrConfiguration = OCRRuntimeConfiguration.appleVision
    private let router: SmartRouter
    private let stream: AsyncStream<MonitoringEvent>
    private let continuation: AsyncStream<MonitoringEvent>.Continuation
    private var task: Task<Void, Never>?
    private var mode: TranslationMode = .dictionaryFirst
    private var lastStatus = ""
    private var lastWasHidden = false
    private var lastDetectedCandidate: String?

    public init(router: SmartRouter) {
        self.router = router
        let pair = AsyncStream.makeStream(of: MonitoringEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    public var events: AsyncStream<MonitoringEvent> {
        stream
    }

    public func setMode(_ mode: TranslationMode) {
        self.mode = mode
    }

    public func setOCRConfiguration(_ configuration: OCRRuntimeConfiguration) {
        guard configuration != ocrConfiguration else { return }
        ocrConfiguration = configuration
        ocr = OCRService(configuration: configuration)
        let configuredOCR = ocr
        Task.detached(priority: .userInitiated) {
            configuredOCR.warmUpPreferredBackend()
        }
    }

    public func start() {
        guard task == nil else { return }
        monitoringLogger.info("monitor start requested")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        emitHidden()
    }

    private func run() async {
        monitoringLogger.info("monitor loop started")
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: 160_000_000)
        }
    }

    private func tick() async {
        guard CGPreflightScreenCaptureAccess() else {
            lastDetectedCandidate = nil
            emitStatus("需要屏幕录制权限")
            emitHidden()
            return
        }
        guard FocusMonitor.isAccessibilityTrusted() else {
            lastDetectedCandidate = nil
            emitStatus("需要辅助功能权限")
            emitHidden()
            return
        }
        guard await inputSource.isApplePinyinActive() else {
            lastDetectedCandidate = nil
            emitStatus("等待苹果拼音")
            emitHidden()
            return
        }
        guard !FocusMonitor.isSecureInputEnabled() else {
            lastDetectedCandidate = nil
            emitStatus("安全输入场景已跳过")
            emitHidden()
            return
        }
        guard let snapshot = focus.snapshot(),
              let caret = snapshot.caretRect ?? snapshot.elementFrame else {
            lastDetectedCandidate = nil
            emitStatus("未找到文本光标")
            emitHidden()
            return
        }

        let region = Self.captureRegion(
            caret: caret,
            elementFrame: snapshot.elementFrame
        )
        do {
            let image = try await capture.capture(region: region)
            let anchor = CGPoint(
                x: (caret.midX - region.x) * CGFloat(image.width) / CGFloat(region.width),
                y: (caret.midY - region.y) * CGFloat(image.height) / CGFloat(region.height)
            )
            guard let detection = ocr.detect(in: image, anchor: anchor) else {
                lastDetectedCandidate = nil
                emitStatus("未检测到高亮候选")
                emitHidden()
                return
            }
            if detection.text != lastDetectedCandidate {
                lastDetectedCandidate = detection.text
                emitHidden()
            }

            let candidate = Candidate(
                text: detection.text,
                kind: CandidateClassifier.classify(detection.text),
                confidence: Double(detection.confidence)
            )
            monitoringLogger.debug(
                "candidate kind=\(candidate.kind.rawValue, privacy: .public) length=\(candidate.text.count, privacy: .public)"
            )
            guard let result = try await router.route(candidate, mode: mode) else {
                emitStatus("有候选，但未找到可靠翻译")
                emitHidden()
                return
            }
            monitoringLogger.debug(
                "result source=\(result.source.rawValue, privacy: .public) length=\(result.text.count, privacy: .public)"
            )

            let scaleX = region.width / Double(image.width)
            let scaleY = region.height / Double(image.height)
            let highlight = CaptureRegion(
                x: region.x + Double(detection.highlightRect.minX) * scaleX,
                y: region.y + Double(detection.highlightRect.minY) * scaleY,
                width: Double(detection.highlightRect.width) * scaleX,
                height: Double(detection.highlightRect.height) * scaleY
            )
            emitStatus("已生成翻译显示")
            lastWasHidden = false
            continuation.yield(.result(candidate, result, highlight))
        } catch {
            lastDetectedCandidate = nil
            emitStatus("截取失败：\(error.localizedDescription)")
            emitHidden()
        }
    }

    private func emitStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        monitoringLogger.info("status=\(status, privacy: .public)")
        continuation.yield(.status(status))
    }

    private func emitHidden() {
        guard !lastWasHidden else { return }
        lastWasHidden = true
        continuation.yield(.hidden)
    }

    public static func captureRegion(
        caret: CGRect,
        elementFrame: CGRect?
    ) -> CaptureRegion {
        let display = displayBounds(containing: CGPoint(x: caret.midX, y: caret.midY))
        let width = min(1400, max(300, display.width - 16))
        let height: CGFloat = 180
        let left = min(caret.minX, elementFrame?.minX ?? (caret.minX - 300)) - 24
        let x = max(display.minX + 8, min(left, display.maxX - width - 8))

        // The IME candidate bar can sit above or below the caret depending on
        // the application and available screen space, so capture a band around it.
        var y = caret.midY - height / 2
        y = max(display.minY + 8, min(y, display.maxY - height - 8))

        return CaptureRegion(
            x: Double(x),
            y: Double(y),
            width: Double(width),
            height: Double(height)
        )
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CGRect(x: 0, y: 0, width: 1440, height: 900)
        }
        for display in displays {
            let bounds = CGDisplayBounds(display)
            if bounds.contains(point) {
                return bounds
            }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }
}
