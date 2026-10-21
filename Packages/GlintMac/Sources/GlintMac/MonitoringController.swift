import CoreGraphics
import Dispatch
import Foundation
import GlintCore
import OSLog

private let monitoringLogger = Logger(
    subsystem: "com.local.glint",
    category: "Monitoring"
)

struct CandidateMissDebouncer: Sendable {
    private let threshold: Int
    private var consecutiveMisses = 0

    init(threshold: Int = 2) {
        self.threshold = max(1, threshold)
    }

    mutating func observeCandidate() {
        consecutiveMisses = 0
    }

    mutating func observeMiss() -> Bool {
        consecutiveMisses += 1
        return consecutiveMisses >= threshold
    }

    mutating func reset() {
        consecutiveMisses = 0
    }
}

struct CandidateScanGate: Sendable {
    static func allowsScanning(
        compositionState: TextCompositionState,
        isEditableTextInput: Bool,
        hasCaret: Bool
    ) -> Bool {
        switch compositionState {
        case .composing:
            return true
        case .inactive, .unknown:
            return isEditableTextInput || hasCaret
        }
    }
}

public enum MonitoringEvent: Sendable {
    case status(String)
    case candidateChanged(revision: UInt64)
    case candidateEnded(immediate: Bool)
    case result(
        Candidate,
        TranslationResult,
        CaptureRegion,
        revision: UInt64
    )
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
    private let translationMemo = TranslationMemo()
    private var task: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var mode: TranslationMode = .dictionaryFirst
    private var candidateDwellNanoseconds: UInt64 = 120_000_000
    private var translationConfigurationToken =
        TranslationModelSelection.selected()
    private var typingTracker = TypingActivityTracker()
    private var handledRevision: UInt64?
    private var dwellDetectedAt: ContinuousClock.Instant?
    private var translationStartedAt: ContinuousClock.Instant?
    private var lastPermissionCheck: UInt64 = 0
    private var lastStatus = ""
    private var candidateSessionActive = false
    private var candidateMissDebouncer = CandidateMissDebouncer()

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
        guard self.mode != mode else { return }
        self.mode = mode
        invalidateCandidate(immediate: true)
    }

    public func setCandidateDwellDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = min(max(seconds, 0.08), 0.3)
        candidateDwellNanoseconds = UInt64(clamped * 1_000_000_000)
    }

    public func setTranslationConfigurationToken(_ token: String) async {
        guard token != translationConfigurationToken else { return }
        translationConfigurationToken = token
        invalidateCandidate(immediate: true)
        await translationMemo.clear()
    }

    public func setOCRConfiguration(_ configuration: OCRRuntimeConfiguration) {
        guard configuration != ocrConfiguration else { return }
        ocrConfiguration = configuration
        ocr = OCRService(configuration: configuration)
        invalidateCandidate(immediate: true)
        let configuredOCR = ocr
        Task.detached(priority: .userInitiated) {
            configuredOCR.warmUpConfiguredBackends()
        }
    }

    public func start() {
        guard task == nil else { return }
        lastPermissionCheck = 0
        monitoringLogger.info("monitor start requested")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lastPermissionCheck = 0
        translationTask?.cancel()
        translationTask = nil
        typingTracker.reset()
        handledRevision = nil
        emitCandidateEnded(immediate: true)
    }

    private func run() async {
        monitoringLogger.info("monitor loop started")
        while !Task.isCancelled {
            let interval = await tick()
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    private func tick() async -> UInt64 {
        let permissionCheckTimestamp = DispatchTime.now().uptimeNanoseconds
        let shouldCheckPermissions = lastPermissionCheck == 0
            || permissionCheckTimestamp >= lastPermissionCheck
                && permissionCheckTimestamp - lastPermissionCheck
                    >= 1_000_000_000
        if shouldCheckPermissions {
            lastPermissionCheck = permissionCheckTimestamp
            guard CGPreflightScreenCaptureAccess() else {
                invalidateCandidate(immediate: true)
                emitStatus("需要屏幕录制权限")
                return 1_000_000_000
            }
            guard FocusMonitor.isAccessibilityTrusted() else {
                invalidateCandidate(immediate: true)
                emitStatus("需要辅助功能权限")
                return 1_000_000_000
            }
        }
        guard await inputSource.isApplePinyinActive() else {
            invalidateCandidate(immediate: true)
            emitStatus("等待苹果拼音")
            return 250_000_000
        }
        guard !FocusMonitor.isSecureInputEnabled() else {
            invalidateCandidate(immediate: true)
            emitStatus("安全输入场景已跳过")
            return 500_000_000
        }
        guard let snapshot = focus.snapshot() else {
            return observeCandidateMiss(
                status: "未找到文本光标",
                pollInterval: 60_000_000
            )
        }
        guard !snapshot.hasTextSelection else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过文字选区")
            return 100_000_000
        }
        guard CandidateScanGate.allowsScanning(
            compositionState: snapshot.compositionState,
            isEditableTextInput: snapshot.isEditableTextInput,
            hasCaret: snapshot.caretRect != nil
        ) else {
            invalidateCandidate()
            emitStatus("已跳过非文本控件")
            return 200_000_000
        }
        guard
              let caret = snapshot.caretRect ?? snapshot.elementFrame else {
            return observeCandidateMiss(
                status: "未找到文本光标",
                pollInterval: 60_000_000
            )
        }

        let region = Self.captureRegion(
            caret: caret,
            elementFrame: snapshot.elementFrame
        )
        let observationStartedAt = ContinuousClock.now
        do {
            let image = try await capture.capture(region: region)
            let anchor = CGPoint(
                x: (caret.midX - region.x) * CGFloat(image.width) / CGFloat(region.width),
                y: (caret.midY - region.y) * CGFloat(image.height) / CGFloat(region.height)
            )
            guard let detection = ocr.detect(in: image, anchor: anchor) else {
                return observeCandidateMiss(
                    status: "未检测到高亮候选",
                    pollInterval: 60_000_000
                )
            }
            candidateMissDebouncer.observeCandidate()

            let candidate = Candidate(
                text: detection.text,
                kind: CandidateClassifier.classify(detection.text),
                confidence: Double(detection.confidence)
            )
            let scaleX = region.width / Double(image.width)
            let scaleY = region.height / Double(image.height)
            let highlight = CaptureRegion(
                x: region.x + Double(detection.highlightRect.minX) * scaleX,
                y: region.y + Double(detection.highlightRect.minY) * scaleY,
                width: Double(detection.highlightRect.width) * scaleX,
                height: Double(detection.highlightRect.height) * scaleY
            )
            let displayAnchor = highlight
            let activity = typingTracker.observe(
                text: detection.text,
                highlightRect: detection.highlightRect,
                timestamp: DispatchTime.now().uptimeNanoseconds,
                dwellDurationNanoseconds: candidateDwellNanoseconds
            )
            monitoringLogger.debug(
                "candidate kind=\(candidate.kind.rawValue, privacy: .public) length=\(candidate.text.count, privacy: .public)"
            )

            switch activity {
            case .changed(let revision):
                handledRevision = nil
                dwellDetectedAt = nil
                translationStartedAt = nil
                translationTask?.cancel()
                translationTask = nil
                emitCandidateChanged(revision: revision)
                monitoringLogger.debug(
                    "candidate revision=\(revision, privacy: .public) changed"
                )
            case .dwelling(let revision):
                guard handledRevision != revision else {
                    return 60_000_000
                }
                handledRevision = revision
                dwellDetectedAt = .now
                monitoringLogger.debug(
                    "perf candidate_detect_ms=\(Self.elapsedMilliseconds(observationStartedAt.duration(to: .now)), privacy: .public)"
                )
                startTranslation(
                    candidate: candidate,
                    highlight: displayAnchor,
                    revision: revision
                )
            case .observing:
                break
            }
            return 40_000_000
        } catch {
            lastPermissionCheck = 0
            invalidateCandidate(immediate: true)
            emitStatus("截取失败：\(error.localizedDescription)")
            return 150_000_000
        }
    }

    private func startTranslation(
        candidate: Candidate,
        highlight: CaptureRegion,
        revision: UInt64
    ) {
        let key = TranslationMemoKey(
            text: candidate.text,
            mode: mode,
            configuration: translationConfigurationToken
        )
        let mode = mode
        let router = router
        let memo = translationMemo
        translationStartedAt = .now
        translationTask?.cancel()
        translationTask = Task.detached(priority: .userInitiated) {
            [
                weak self,
                router,
                memo,
                key,
                candidate,
                highlight,
                revision,
                mode,
            ] in
            do {
                let result = try await memo.resolve(for: key) {
                    try await router.route(candidate, mode: mode)
                }
                await self?.completeTranslation(
                    result,
                    candidate: candidate,
                    highlight: highlight,
                    revision: revision,
                    errorMessage: nil
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.completeTranslation(
                    nil,
                    candidate: candidate,
                    highlight: highlight,
                    revision: revision,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func completeTranslation(
        _ result: TranslationResult?,
        candidate: Candidate,
        highlight: CaptureRegion,
        revision: UInt64,
        errorMessage: String?
    ) {
        guard revision == typingTracker.revision,
              typingTracker.isDwelling else {
            return
        }
        translationTask = nil
        let finishedAt = ContinuousClock.now
        if let translationStartedAt {
            monitoringLogger.debug(
                "perf translation_ms=\(Self.elapsedMilliseconds(translationStartedAt.duration(to: finishedAt)), privacy: .public)"
            )
        }
        if let dwellDetectedAt {
            monitoringLogger.debug(
                "perf dwell_to_ready_ms=\(Self.elapsedMilliseconds(dwellDetectedAt.duration(to: finishedAt)), privacy: .public)"
            )
        }
        self.translationStartedAt = nil
        self.dwellDetectedAt = nil
        if let errorMessage {
            monitoringLogger.debug(
                "translation failed revision=\(revision, privacy: .public) error=\(errorMessage, privacy: .private)"
            )
            emitStatus("翻译暂时失败")
            return
        }
        guard let result, Self.isDisplayable(result) else {
            emitStatus("有候选，但未找到可靠翻译")
            return
        }

        monitoringLogger.debug(
            "result source=\(result.source.rawValue, privacy: .public) length=\(result.text.count, privacy: .public)"
        )
        emitStatus("已生成翻译显示")
        continuation.yield(
            .result(
                candidate,
                result,
                highlight,
                revision: revision
            )
        )
    }

    private func invalidateCandidate(immediate: Bool = false) {
        typingTracker.reset()
        candidateMissDebouncer.reset()
        handledRevision = nil
        dwellDetectedAt = nil
        translationStartedAt = nil
        translationTask?.cancel()
        translationTask = nil
        emitCandidateEnded(immediate: immediate)
    }

    private func observeCandidateMiss(
        status: String,
        pollInterval: UInt64
    ) -> UInt64 {
        emitStatus(status)
        if candidateMissDebouncer.observeMiss() {
            invalidateCandidate()
        }
        return pollInterval
    }

    private static func isDisplayable(_ result: TranslationResult) -> Bool {
        let text = result.displayText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty, !text.contains(where: \.isNewline) else {
            return false
        }
        let hanCount = text.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value)
        }.count
        return hanCount <= max(1, text.count / 5)
    }

    private static func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private func emitStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        monitoringLogger.info("status=\(status, privacy: .public)")
        continuation.yield(.status(status))
    }

    private func emitCandidateChanged(revision: UInt64) {
        candidateSessionActive = true
        continuation.yield(.candidateChanged(revision: revision))
    }

    private func emitCandidateEnded(immediate: Bool) {
        guard candidateSessionActive else { return }
        candidateSessionActive = false
        continuation.yield(.candidateEnded(immediate: immediate))
    }

    public static func captureRegion(
        caret: CGRect,
        elementFrame: CGRect?
    ) -> CaptureRegion {
        let display = displayBounds(containing: CGPoint(x: caret.midX, y: caret.midY))
        let width = min(1_000, max(600, display.width - 16))
        let height: CGFloat = 160
        let left = caret.midX - width / 2
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
