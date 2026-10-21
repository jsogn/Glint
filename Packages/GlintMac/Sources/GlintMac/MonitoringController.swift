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

struct CompositionTransitionTracker: Sendable {
    private var previousState: TextCompositionState = .unknown

    mutating func observe(_ state: TextCompositionState) -> Bool {
        let ended = previousState == .composing && state == .inactive
        previousState = state
        return ended
    }

    mutating func reset() {
        previousState = .unknown
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
    case selectionChanged(index: Int, revision: UInt64)
    case candidateEnded(immediate: Bool)
    case results(
        [CandidateTranslationPresentation],
        CaptureRegion,
        revision: UInt64
    )
}

struct CandidateTrackingIdentity: Sendable, Equatable {
    let text: String
    let frame: CGRect

    static func make(
        scope: CandidateTranslationScope,
        selectedText: String,
        selectedFrame: CGRect,
        rowTexts: [String],
        rowFrame: CGRect
    ) -> CandidateTrackingIdentity {
        switch scope {
        case .selected:
            return CandidateTrackingIdentity(
                text: selectedText,
                frame: selectedFrame
            )
        case .row:
            return CandidateTrackingIdentity(
                text: rowTexts.joined(separator: "\u{1F}"),
                frame: rowFrame
            )
        }
    }
}

public struct CandidateTranslationPresentation: Sendable, Equatable {
    public let index: Int
    public let candidateText: String
    public let translation: String?
    public let isSelected: Bool

    public init(
        index: Int,
        candidateText: String,
        translation: String?,
        isSelected: Bool
    ) {
        self.index = index
        self.candidateText = candidateText
        self.translation = translation
        self.isSelected = isSelected
    }
}

public actor MonitoringController {
    private let inputSource = InputSourceMonitor()
    private let focus = FocusMonitor()
    private let capture = CandidateCapture()
    private let axCandidates = AXCandidateReader()
    private var ocr = OCRService()
    private var ocrConfiguration = OCRRuntimeConfiguration.appleVision
    private let router: SmartRouter
    private let stream: AsyncStream<MonitoringEvent>
    private let continuation: AsyncStream<MonitoringEvent>.Continuation
    private let translationMemo = TranslationMemo()
    private var task: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var mode: TranslationMode = .dictionaryFirst
    private var translationScope: CandidateTranslationScope = .selected
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
    private var selectedCandidateIndex: Int?
    private var candidateMissDebouncer = CandidateMissDebouncer()
    private var compositionTransitions = CompositionTransitionTracker()

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

    public func setTranslationScope(
        _ scope: CandidateTranslationScope
    ) {
        guard translationScope != scope else { return }
        translationScope = scope
        invalidateCandidate(immediate: true)
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
        if compositionTransitions.observe(snapshot.compositionState) {
            invalidateCandidate(immediate: true)
            emitStatus("候选会话已结束")
            return 40_000_000
        }
        guard CandidateScanGate.allowsScanning(
            compositionState: snapshot.compositionState,
            isEditableTextInput: snapshot.isEditableTextInput,
            hasCaret: snapshot.caretRect != nil
        ) else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过非文本控件")
            return 200_000_000
        }
        guard snapshot.caretRect != nil || snapshot.elementFrame != nil else {
            return observeCandidateMiss(
                status: "未找到文本光标",
                pollInterval: 60_000_000
            )
        }

        let observationStartedAt = ContinuousClock.now
        guard var axCandidate = axCandidates.snapshot(
            includeVisibleCandidates: translationScope == .row
        ) else {
            return observeCandidateMiss(
                status: "未检测到候选",
                pollInterval: 60_000_000
            )
        }
        if axCandidate.frame == nil
            || (translationScope == .row && axCandidate.visibleTexts.isEmpty) {
            axCandidate = axCandidates.snapshot(
                includeVisibleCandidates: true
            ) ?? axCandidate
        }
        guard let candidateFrame = axCandidate.frame
                ?? axCandidate.candidateWindowFrame
                ?? axCandidate.candidateListFrame,
              let displayFrame = Self.candidateDisplayFrame(
                  scope: translationScope,
                  selectedFrame: candidateFrame,
                  options: axCandidate.options,
                  windowFrame: axCandidate.candidateWindowFrame,
                  listFrame: axCandidate.candidateListFrame
              ),
              let displayAnchor = Self.candidateRegion(
                  for: displayFrame
              ) else {
            return observeCandidateMiss(
                status: "未找到候选位置",
                pollInterval: 60_000_000
            )
        }
        candidateMissDebouncer.observeCandidate()

        let candidateTexts = translationScope == .row
            && !axCandidate.visibleTexts.isEmpty
            ? axCandidate.visibleTexts
            : [axCandidate.text]
        let selectedIndex = min(
            max(
                axCandidate.selectedIndex
                    ?? candidateTexts.firstIndex(of: axCandidate.text)
                    ?? 0,
                0
            ),
            candidateTexts.count - 1
        )
        let candidates = candidateTexts.map {
            Candidate(
                text: $0,
                kind: CandidateClassifier.classify($0),
                confidence: 1
            )
        }
        let trackingIdentity = CandidateTrackingIdentity.make(
            scope: translationScope,
            selectedText: axCandidate.text,
            selectedFrame: candidateFrame,
            rowTexts: candidateTexts,
            rowFrame: displayFrame
        )
        let previousSelectedIndex = selectedCandidateIndex
        selectedCandidateIndex = selectedIndex
        let activity = typingTracker.observe(
            text: trackingIdentity.text,
            highlightRect: trackingIdentity.frame,
            timestamp: DispatchTime.now().uptimeNanoseconds,
            dwellDurationNanoseconds: candidateDwellNanoseconds
        )
        let candidateChanged: Bool
        switch activity {
        case .changed:
            candidateChanged = true
        case .observing, .dwelling:
            candidateChanged = false
        }

        switch activity {
        case .changed(let revision):
            handledRevision = nil
            dwellDetectedAt = nil
            translationStartedAt = nil
            translationTask?.cancel()
            translationTask = nil
            emitCandidateChanged(revision: revision)
            let selectedCandidate = candidates[selectedIndex]
            monitoringLogger.debug(
                "candidate source=accessibility kind=\(selectedCandidate.kind.rawValue, privacy: .public) length=\(selectedCandidate.text.count, privacy: .public) row_count=\(candidates.count, privacy: .public) revision=\(revision, privacy: .public) changed"
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
                candidates: candidates,
                selectedIndex: selectedIndex,
                highlight: displayAnchor,
                revision: revision
            )
        case .observing:
            break
        }
        if candidateSessionActive,
           !candidateChanged,
           previousSelectedIndex != selectedIndex {
            continuation.yield(
                .selectionChanged(
                    index: selectedIndex,
                    revision: typingTracker.revision
                )
            )
        }
        return 40_000_000
    }

    private func startTranslation(
        candidates: [Candidate],
        selectedIndex: Int,
        highlight: CaptureRegion,
        revision: UInt64
    ) {
        let mode = mode
        let router = router
        let memo = translationMemo
        let configurationToken = translationConfigurationToken
        translationStartedAt = .now
        translationTask?.cancel()
        translationTask = Task.detached(priority: .userInitiated) {
            [
                weak self,
                router,
                memo,
                candidates,
                selectedIndex,
                configurationToken,
                highlight,
                revision,
                mode,
            ] in
            let presentations = await Self.translateCandidates(
                candidates,
                selectedIndex: selectedIndex,
                mode: mode,
                configurationToken: configurationToken,
                router: router,
                memo: memo
            )
            guard !Task.isCancelled else { return }
            await self?.completeTranslation(
                presentations,
                highlight: highlight,
                revision: revision
            )
        }
    }

    private static func translateCandidates(
        _ candidates: [Candidate],
        selectedIndex: Int,
        mode: TranslationMode,
        configurationToken: String,
        router: SmartRouter,
        memo: TranslationMemo
    ) async -> [CandidateTranslationPresentation] {
        guard !candidates.isEmpty else { return [] }
        var results = [TranslationResult?](
            repeating: nil,
            count: candidates.count
        )
        let indices = [selectedIndex] + candidates.indices.filter {
            $0 != selectedIndex
        }
        await withTaskGroup(of: (Int, TranslationResult?).self) { group in
            for index in indices {
                let candidate = candidates[index]
                let key = TranslationMemoKey(
                    text: candidate.text,
                    mode: mode,
                    configuration: configurationToken
                )
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    let result = try? await memo.resolve(for: key) {
                        try await router.route(candidate, mode: mode)
                    }
                    return (index, result)
                }
            }
            for await (index, result) in group {
                results[index] = result
            }
        }
        return candidates.enumerated().map { index, candidate in
            let translation = results[index].flatMap {
                isDisplayable($0) ? $0.displayText : nil
            }
            return CandidateTranslationPresentation(
                index: index,
                candidateText: candidate.text,
                translation: translation,
                isSelected: index == selectedIndex
            )
        }
    }

    private func completeTranslation(
        _ translations: [CandidateTranslationPresentation],
        highlight: CaptureRegion,
        revision: UInt64
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
        guard translations.contains(where: { $0.translation != nil }) else {
            emitStatus("有候选，但未找到可靠翻译")
            return
        }
        let latestSelectedIndex = selectedCandidateIndex ?? 0
        let presentations = translations.map { item in
            CandidateTranslationPresentation(
                index: item.index,
                candidateText: item.candidateText,
                translation: item.translation,
                isSelected: item.index == latestSelectedIndex
            )
        }

        monitoringLogger.debug(
            "results count=\(presentations.count, privacy: .public) revision=\(revision, privacy: .public)"
        )
        emitStatus("已生成翻译显示")
        continuation.yield(
            .results(
                presentations,
                highlight,
                revision: revision
            )
        )
    }

    private func invalidateCandidate(immediate: Bool = false) {
        typingTracker.reset()
        candidateMissDebouncer.reset()
        compositionTransitions.reset()
        selectedCandidateIndex = nil
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
        if candidateSessionActive {
            invalidateCandidate(immediate: true)
            return pollInterval
        }
        if candidateMissDebouncer.observeMiss() {
            invalidateCandidate(immediate: true)
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

    static func candidateRegion(
        for frame: CGRect
    ) -> CaptureRegion? {
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }
        return CaptureRegion(
            x: Double(frame.minX),
            y: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }

    static func candidateDisplayFrame(
        scope: CandidateTranslationScope,
        selectedFrame: CGRect,
        options: [AXCandidateOption],
        windowFrame: CGRect? = nil,
        listFrame: CGRect?
    ) -> CGRect? {
        guard scope == .row else {
            return selectedFrame.width > 0 && selectedFrame.height > 0
                ? selectedFrame
                : nil
        }
        let rowFrames = options.compactMap(\.frame).filter {
            $0.width > 0 && $0.height > 0
        }
        guard let rowFrame = rowFrames.reduce(nil, { partial, frame in
            partial?.union(frame) ?? frame
        }) else {
            return candidateDisplayFrame(
                scope: .selected,
                selectedFrame: selectedFrame,
                options: [],
                windowFrame: nil,
                listFrame: listFrame
            )
        }
        let widthFrame = [windowFrame, listFrame].compactMap { $0 }.first {
            $0.width > 0
        }
        let width = max(rowFrame.width, widthFrame?.width ?? 0)
        return CGRect(
            x: widthFrame?.minX ?? rowFrame.minX,
            y: rowFrame.minY,
            width: width,
            height: rowFrame.height
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
