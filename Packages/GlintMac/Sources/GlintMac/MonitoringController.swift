import CoreGraphics
import Dispatch
import Foundation
import GlintCore
import OSLog

private let monitoringLogger = Logger(
    subsystem: "com.local.glint",
    category: "Monitoring"
)

public struct CandidateRegion: Sendable, Equatable {
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

struct CandidatePollingPolicy: Sendable {
    static let activeInterval: UInt64 = 40_000_000
    static let stableInterval: UInt64 = 80_000_000
    static let minimumPreDwellInterval: UInt64 = 10_000_000

    static func interval(
        isDwelling: Bool,
        nanosecondsUntilDwell: UInt64?
    ) -> UInt64 {
        guard !isDwelling else {
            return stableInterval
        }
        guard let nanosecondsUntilDwell else {
            return activeInterval
        }
        return min(
            activeInterval,
            max(
                minimumPreDwellInterval,
                nanosecondsUntilDwell
            )
        )
    }
}

public enum MonitoringEvent: Sendable {
    case status(String)
    case inputSourceChanged(InputMethodIdentity)
    case candidateChanged(revision: UInt64)
    case selectionChanged(index: Int, revision: UInt64)
    case candidateEnded(immediate: Bool)
    case results(
        [CandidateTranslationPresentation],
        CandidateRegion,
        revision: UInt64,
        isProgressive: Bool
    )
    case insertionOffer(TranslationChoiceOffer)
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
    public let insertionOptions: [String]
    public let isSelected: Bool

    public init(
        index: Int,
        candidateText: String,
        translation: String?,
        insertionOptions: [String] = [],
        isSelected: Bool
    ) {
        self.index = index
        self.candidateText = candidateText
        self.translation = translation
        self.insertionOptions = insertionOptions
        self.isSelected = isSelected
    }
}

@MainActor
protocol InputSourceReading: Sendable {
    func currentInputSource() -> ActiveInputSource
}

extension InputSourceMonitor: InputSourceReading {}

protocol FocusReading {
    func snapshot() -> FocusSnapshot?
    func processFallbackSnapshot() -> FocusSnapshot?
}

extension FocusReading {
    func processFallbackSnapshot() -> FocusSnapshot? {
        nil
    }
}

extension FocusMonitor: FocusReading {}

extension AXCandidateReader: AXCandidateReading {}

public actor MonitoringController {
    private struct CandidateObservation {
        let snapshot: AXCandidateSnapshot
        let selectedFrame: CGRect
        let displayFrame: CGRect
        let displayAnchor: CandidateRegion
    }

    private enum CandidateReadOutcome {
        case found(CandidateObservation)
        case miss(
            status: String,
            reason: AXCandidateReadMissReason
        )
    }

    private let inputSource: any InputSourceReading
    private let focus: any FocusReading
    private let candidateReaders: any CandidateReaderRouting
    private let hostAccessibilityActivator: any HostAccessibilityActivating
    private let accessibilityIsTrusted: @Sendable () -> Bool
    private let secureInputIsEnabled: @Sendable () -> Bool
    private let translationTextInserter: any TranslationTextInserting
    private let ownProcessIdentifier: pid_t
    private let router: SmartRouter
    private let stream: AsyncStream<MonitoringEvent>
    private let continuation: AsyncStream<MonitoringEvent>.Continuation
    private let translationMemo = TranslationMemo()
    private var task: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var mode: TranslationMode = .dictionaryFirst
    private var translationScope: CandidateTranslationScope = .selected
    private var maximumTranslationCount = 4
    private var candidateDwellNanoseconds: UInt64 = 120_000_000
    private var translationConfigurationToken =
        TranslationModelSelection.selected()
    private var typingTracker = TypingActivityTracker()
    private var handledRevision: UInt64?
    private var dwellDetectedAt: ContinuousClock.Instant?
    private var translationStartedAt: ContinuousClock.Instant?
    private var candidateChangedAtNanoseconds: UInt64?
    private var dwellConfirmedAtNanoseconds: UInt64?
    private var translationAttempts: UInt64 = 0
    private var cancelledTranslationAttempts: UInt64 = 0
    private var lastPermissionCheck: UInt64 = 0
    private var lastStatus = ""
    private var cachedInputSource: ActiveInputSource?
    private var lastInputSourceCheck: UInt64 = 0
    private var lastReportedInputMethod: InputMethodIdentity?
    private var candidateSessionActive = false
    private var selectedCandidateIndex: Int?
    private var selectedCandidateIndexIsExact = false
    private var latestCandidateHighlight: CandidateRegion?
    private var insertionOffer: TranslationChoiceOffer?
    private var insertionHostProcessIdentifier: pid_t?
    private var dictionaryPrefetchRevision: UInt64?
    private var dictionaryPrefetchTasks: [Int: Task<TranslationResult?, Never>] = [:]
    private var cachedPrefetchResults: [Int: TranslationResult] = [:]
    private var candidateMissDebouncer = CandidateMissDebouncer()
    private var compositionTransitions = CompositionTransitionTracker()
    private var hostAccessibilityAttempts: [HostProcessSession: HostAccessibilityAttempt] = [:]

    private struct HostAccessibilityAttempt {
        let timestamp: UInt64
        let outcome: HostAccessibilityActivation
    }

    public init(router: SmartRouter) {
        self.init(
            router: router,
            inputSource: InputSourceMonitor(),
            focus: FocusMonitor(),
            candidateReaders:
                CandidateReaderConfiguration.standard(),
            hostAccessibilityActivator:
                AXHostAccessibilityActivator(),
            accessibilityIsTrusted: {
                FocusMonitor.isAccessibilityTrusted()
            },
            secureInputIsEnabled: {
                FocusMonitor.isSecureInputEnabled()
            },
            translationTextInserter: SystemTranslationTextInserter()
        )
    }

    init(
        router: SmartRouter,
        inputSource: any InputSourceReading,
        focus: any FocusReading,
        candidateReaders: any CandidateReaderRouting,
        hostAccessibilityActivator:
            any HostAccessibilityActivating =
            DisabledHostAccessibilityActivator(),
        accessibilityIsTrusted: @escaping @Sendable () -> Bool,
        secureInputIsEnabled: @escaping @Sendable () -> Bool,
        translationTextInserter: any TranslationTextInserting =
            SystemTranslationTextInserter(),
        ownProcessIdentifier: pid_t =
            ProcessInfo.processInfo.processIdentifier
    ) {
        self.inputSource = inputSource
        self.focus = focus
        self.candidateReaders = candidateReaders
        self.hostAccessibilityActivator =
            hostAccessibilityActivator
        self.accessibilityIsTrusted = accessibilityIsTrusted
        self.secureInputIsEnabled = secureInputIsEnabled
        self.translationTextInserter = translationTextInserter
        self.ownProcessIdentifier = ownProcessIdentifier
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

    var configuredCandidateDwellNanoseconds: UInt64 {
        candidateDwellNanoseconds
    }

    public func setTranslationScope(
        _ scope: CandidateTranslationScope
    ) {
        guard translationScope != scope else { return }
        translationScope = scope
        invalidateCandidate(immediate: true)
    }

    public func setMaximumTranslationCount(_ count: Int) {
        let clamped = min(
            max(
                count,
                CandidateTranslationPipeline
                    .maximumTranslationCountRange.lowerBound
            ),
            CandidateTranslationPipeline
                .maximumTranslationCountRange.upperBound
        )
        guard maximumTranslationCount != clamped else { return }
        maximumTranslationCount = clamped
        invalidateCandidate(immediate: true)
    }

    var configuredMaximumTranslationCount: Int {
        maximumTranslationCount
    }

    public func setTranslationConfigurationToken(_ token: String) async {
        guard token != translationConfigurationToken else { return }
        translationConfigurationToken = token
        invalidateCandidate(immediate: true)
        await translationMemo.clear()
    }

    public func insertTranslation(
        _ offer: TranslationChoiceOffer,
        choiceIndex: Int
    ) async -> Bool {
        guard
            offer == insertionOffer,
            offer.revision == typingTracker.revision,
            typingTracker.isDwelling,
            candidateSessionActive,
            offer.choices.indices.contains(choiceIndex),
            !secureInputIsEnabled(),
            let insertionHostProcessIdentifier,
            let snapshot = focus.snapshot(),
            snapshot.processIdentifier == insertionHostProcessIdentifier,
            snapshot.isEditableTextInput,
            !snapshot.hasTextSelection,
            !snapshot.usesProcessFallback
        else {
            monitoringLogger.notice(
                "translation insertion result=rejected"
            )
            return false
        }

        let inserted = await translationTextInserter.insert(
            offer.choices[choiceIndex],
            into: insertionHostProcessIdentifier
        )
        guard inserted else {
            monitoringLogger.notice(
                "translation insertion result=failed"
            )
            return false
        }
        insertionOffer = nil
        invalidateCandidate(immediate: true)
        monitoringLogger.notice(
            "translation insertion result=success choices=\(offer.choices.count, privacy: .public)"
        )
        return true
    }

    public func start() {
        guard task == nil else { return }
        lastPermissionCheck = 0
        lastStatus = ""
        cachedInputSource = nil
        lastInputSourceCheck = 0
        lastReportedInputMethod = nil
        translationAttempts = 0
        cancelledTranslationAttempts = 0
        monitoringLogger.info("monitor start requested")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lastPermissionCheck = 0
        lastStatus = ""
        invalidateCandidate(immediate: true)
        let memo = translationMemo
        Task {
            let statistics = await memo.statistics()
            monitoringLogger.notice(
                "cache stats entries=\(statistics.entries, privacy: .public) max_entries=\(statistics.maximumEntries, privacy: .public) estimated_bytes=\(statistics.estimatedBytes, privacy: .public) max_bytes=\(statistics.maximumEstimatedBytes, privacy: .public) hits=\(statistics.hits, privacy: .public) misses=\(statistics.misses, privacy: .public) in_flight_hits=\(statistics.inFlightHits, privacy: .public) insertions=\(statistics.insertions, privacy: .public) evictions=\(statistics.evictions, privacy: .public) rejected=\(statistics.rejectedEntries, privacy: .public)"
            )
        }
    }

    private func run() async {
        monitoringLogger.info("monitor loop started")
        while !Task.isCancelled {
            let interval = await tick()
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    func tick() async -> UInt64 {
        let permissionCheckTimestamp = DispatchTime.now().uptimeNanoseconds
        let shouldCheckPermissions =
            lastPermissionCheck == 0
            || permissionCheckTimestamp >= lastPermissionCheck
                && permissionCheckTimestamp - lastPermissionCheck
                    >= 1_000_000_000
        if shouldCheckPermissions {
            lastPermissionCheck = permissionCheckTimestamp
            guard accessibilityIsTrusted() else {
                invalidateCandidate(immediate: true)
                emitStatus("需要辅助功能权限")
                return 1_000_000_000
            }
        }
        let activeInputSource = await currentInputSource()
        reportInputSourceIfNeeded(
            activeInputSource.identity
        )
        if activeInputSource.kind == .keyboardLayout {
            invalidateCandidate(immediate: true)
            emitStatus("等待中文输入")
            return 250_000_000
        }
        guard !secureInputIsEnabled() else {
            invalidateCandidate(immediate: true)
            emitStatus("安全输入场景已跳过")
            return 500_000_000
        }
        guard
            let snapshot = FocusResolutionPolicy.resolve(
                direct: focus.snapshot(),
                allowsProcessFallback:
                    candidateReaders.allowsProcessFallback(
                        for: activeInputSource
                    ),
                fallback: {
                    focus.processFallbackSnapshot()
                }
            )
        else {
            return observeCandidateMiss(
                status: "未找到文本光标",
                pollInterval: 60_000_000
            )
        }
        guard snapshot.processIdentifier != ownProcessIdentifier else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过 Glint 自身窗口")
            return 250_000_000
        }
        if insertionHostProcessIdentifier != snapshot.processIdentifier {
            insertionOffer = nil
        }
        insertionHostProcessIdentifier = snapshot.processIdentifier
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
        guard
            CandidateScanGate.allowsScanning(
                compositionState: snapshot.compositionState,
                isEditableTextInput: snapshot.isEditableTextInput,
                hasCaret: snapshot.caretRect != nil,
                allowsProcessFallback: snapshot.usesProcessFallback
            )
        else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过非文本控件")
            return 200_000_000
        }
        guard
            snapshot.usesProcessFallback
                || snapshot.caretRect != nil
                || snapshot.elementFrame != nil
        else {
            return observeCandidateMiss(
                status: "未找到文本光标",
                pollInterval: 60_000_000
            )
        }

        let observationStartedAt = ContinuousClock.now
        let outcome = readCandidate(
            source: activeInputSource,
            focus: snapshot
        )
        let observation: CandidateObservation
        switch outcome {
        case .found(let candidate):
            observation = candidate
        case .miss(let status, let reason):
            if Self.shouldEndCandidateImmediately(
                for: reason
            ) {
                emitStatus(status)
                invalidateCandidate(immediate: true)
                return CandidatePollingPolicy.stableInterval
            }
            if await activateHostAccessibilityIfNeeded(
                source: activeInputSource,
                focus: snapshot
            ) {
                return 40_000_000
            }
            return observeCandidateMiss(
                status: status,
                pollInterval: 60_000_000
            )
        }
        let axCandidate = observation.snapshot
        let candidateFrame = observation.selectedFrame
        let displayFrame = observation.displayFrame
        let displayAnchor = observation.displayAnchor
        candidateMissDebouncer.observeCandidate()
        latestCandidateHighlight = displayAnchor

        let candidateTexts =
            translationScope == .row
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
                kind: CandidateClassifier.classify($0)
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
        selectedCandidateIndexIsExact =
            axCandidate.selectionIsExact
        let observationTimestamp = DispatchTime.now().uptimeNanoseconds
        let activity = typingTracker.observe(
            text: trackingIdentity.text,
            highlightRect: trackingIdentity.frame,
            timestamp: observationTimestamp,
            dwellDurationNanoseconds: candidateDwellNanoseconds
        )
        let candidateChanged: Bool
        switch activity {
        case .changed:
            candidateChanged = true
        case .observing, .dwelling:
            candidateChanged = false
        }
        await startCandidatePrefetchIfNeeded(
            candidates: candidates,
            revision: typingTracker.revision
        )

        switch activity {
        case .changed(let revision):
            handledRevision = nil
            dwellDetectedAt = nil
            translationStartedAt = nil
            dwellConfirmedAtNanoseconds = nil
            candidateChangedAtNanoseconds = observationTimestamp
            cancelTranslationTask()
            emitCandidateChanged(revision: revision)
            let selectedCandidate = candidates[selectedIndex]
            monitoringLogger.debug(
                "candidate source=accessibility kind=\(selectedCandidate.kind.rawValue, privacy: .public) length=\(selectedCandidate.text.count, privacy: .public) row_count=\(candidates.count, privacy: .public) revision=\(revision, privacy: .public) changed"
            )
        case .dwelling(let revision):
            guard handledRevision != revision else {
                return CandidatePollingPolicy.stableInterval
            }
            handledRevision = revision
            dwellDetectedAt = .now
            dwellConfirmedAtNanoseconds = observationTimestamp
            if let candidateChangedAtNanoseconds {
                monitoringLogger.debug(
                    "perf latency phase=dwell revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(candidates.count, privacy: .public) dwell_ms=\(Self.elapsedMilliseconds(from: candidateChangedAtNanoseconds, to: observationTimestamp), privacy: .public)"
                )
            }
            monitoringLogger.debug(
                "perf candidate_detect_ms=\(Self.elapsedMilliseconds(observationStartedAt.duration(to: .now)), privacy: .public)"
            )
            startTranslation(
                candidates: candidates,
                selectedIndex: selectedIndex,
                selectionIsExact:
                    axCandidate.selectionIsExact,
                highlight: displayAnchor,
                revision: revision,
                dictionaryPrefetchTasks: dictionaryPrefetchTasks,
                cachedPrefetchResults: cachedPrefetchResults
            )
        case .observing:
            break
        }
        if candidateSessionActive,
            !candidateChanged,
            selectedCandidateIndexIsExact,
            previousSelectedIndex != selectedIndex
        {
            continuation.yield(
                .selectionChanged(
                    index: selectedIndex,
                    revision: typingTracker.revision
                )
            )
        }
        return nextCandidatePollInterval(after: observationTimestamp)
    }

    private func activateHostAccessibilityIfNeeded(
        source: ActiveInputSource,
        focus: FocusSnapshot
    ) async -> Bool {
        guard
            source.kind == .applePinyin,
            let processIdentifier = focus.processIdentifier
        else {
            return false
        }

        let session = HostProcessSession.current(
            processIdentifier: processIdentifier
        )
        let timestamp = DispatchTime.now().uptimeNanoseconds
        if let attempt = hostAccessibilityAttempts[session] {
            switch attempt.outcome {
            case .activated, .alreadyEnhanced, .unavailable:
                return false
            case .transientFailure:
                guard
                    timestamp >= attempt.timestamp,
                    timestamp - attempt.timestamp
                        >= HostAccessibilityPolicy
                        .transientRetryNanoseconds
                else {
                    return false
                }
            case .failed:
                guard
                    timestamp >= attempt.timestamp,
                    timestamp - attempt.timestamp
                        >= HostAccessibilityPolicy
                        .failureRetryNanoseconds
                else {
                    return false
                }
            }
        }

        let outcome =
            await hostAccessibilityActivator.activate(
                processIdentifier: processIdentifier
            )
        recordHostAccessibilityAttempt(
            HostAccessibilityAttempt(
                timestamp: timestamp,
                outcome: outcome
            ),
            for: session
        )

        switch outcome {
        case .activated:
            monitoringLogger.info(
                "host_ax mode=enhanced action=enabled pid=\(processIdentifier, privacy: .public)"
            )
            return true
        case .failed:
            monitoringLogger.error(
                "host_ax mode=enhanced action=failed pid=\(processIdentifier, privacy: .public)"
            )
            return false
        case .transientFailure, .alreadyEnhanced, .unavailable:
            return false
        }
    }

    private func recordHostAccessibilityAttempt(
        _ attempt: HostAccessibilityAttempt,
        for session: HostProcessSession
    ) {
        if hostAccessibilityAttempts.count
            >= HostAccessibilityPolicy.maximumCachedProcessCount,
            let oldest = hostAccessibilityAttempts.min(by: {
                $0.value.timestamp < $1.value.timestamp
            })?.key
        {
            hostAccessibilityAttempts.removeValue(forKey: oldest)
        }
        hostAccessibilityAttempts[session] = attempt
    }

    private func readCandidate(
        source: ActiveInputSource,
        focus: FocusSnapshot
    ) -> CandidateReadOutcome {
        // Both translation scopes need visible-row evidence so an expanded
        // candidate grid is rejected before translation or HUD presentation.
        let candidateReader = candidateReaders.reader(
            for: source,
            allowProfileDiscovery: focus.compositionState == .composing
        )
        guard
            let candidate = candidateReader.snapshot(
                processIdentifier: focus.processIdentifier,
                includeVisibleCandidates: true,
                includeVisibleTexts: translationScope == .row
            )
        else {
            return .miss(
                status: "未检测到候选",
                reason: candidateReader.missReason
            )
        }
        guard
            let selectedFrame = candidate.frame
                ?? candidate.candidateWindowFrame
                ?? candidate.candidateListFrame,
            let displayFrame = Self.candidateDisplayFrame(
                scope: translationScope,
                selectedFrame: selectedFrame,
                options: candidate.options,
                geometry: candidate.geometry
                    ?? AXCandidateGeometry(
                        horizontalFrame: selectedFrame,
                        horizontalSource: .item,
                        verticalFrame: selectedFrame,
                        verticalSource: .item
                    )
            ),
            let displayAnchor = Self.candidateRegion(
                for: displayFrame
            )
        else {
            return .miss(
                status: "未找到候选位置",
                reason: .unavailable
            )
        }
        return .found(
            CandidateObservation(
                snapshot: candidate,
                selectedFrame: selectedFrame,
                displayFrame: displayFrame,
                displayAnchor: displayAnchor
            )
        )
    }

    private func nextCandidatePollInterval(after timestamp: UInt64) -> UInt64 {
        CandidatePollingPolicy.interval(
            isDwelling: typingTracker.isDwelling,
            nanosecondsUntilDwell:
                typingTracker.nanosecondsUntilDwell(
                    at: timestamp,
                    dwellDurationNanoseconds:
                        candidateDwellNanoseconds
                )
        )
    }

    private func currentInputSource() async -> ActiveInputSource {
        let now = DispatchTime.now().uptimeNanoseconds
        if let cachedInputSource,
            now >= lastInputSourceCheck,
            now - lastInputSourceCheck < 200_000_000
        {
            return cachedInputSource
        }
        let source = await inputSource.currentInputSource()
        cachedInputSource = source
        lastInputSourceCheck = now
        return source
    }

    private func reportInputSourceIfNeeded(
        _ identity: InputMethodIdentity
    ) {
        guard identity != lastReportedInputMethod else {
            return
        }
        lastReportedInputMethod = identity
        continuation.yield(
            .inputSourceChanged(identity)
        )
    }

    static func shouldPrefetchDictionary(
        mode: TranslationMode,
        scope: CandidateTranslationScope
    ) -> Bool {
        switch mode {
        case .dictionaryFirst:
            return true
        case .modelFirst:
            return scope == .selected
        }
    }

    static func shouldEndCandidateImmediately(
        for reason: AXCandidateReadMissReason
    ) -> Bool {
        reason == .temporaryLayout
            || reason == .candidateEnded
    }

    private func startCandidatePrefetchIfNeeded(
        candidates: [Candidate],
        revision: UInt64
    ) async {
        guard dictionaryPrefetchRevision != revision else { return }

        cancelDictionaryPrefetch()
        dictionaryPrefetchRevision = revision
        let shouldPrefetchDictionary = Self.shouldPrefetchDictionary(
            mode: mode,
            scope: translationScope
        )
        let mode = mode
        let configurationToken = translationConfigurationToken
        let includesAlternatives =
            CandidateTranslationPipeline.displayOptionLimit(
                for: translationScope,
                maximumTranslationCount: maximumTranslationCount
            ) > 1
        let memo = translationMemo
        let router = router
        for (index, candidate) in candidates.enumerated()
        where translationScope != .row
            || index < maximumTranslationCount
        {
            let key = CandidateTranslationPipeline.memoKey(
                candidate: candidate,
                mode: mode,
                configurationToken: configurationToken,
                includesAlternatives: includesAlternatives
            )
            if let result = await memo.peek(for: key) {
                cachedPrefetchResults[index] = result
            } else if shouldPrefetchDictionary {
                dictionaryPrefetchTasks[index] = Task.detached(
                    priority: .utility
                ) {
                    await router.prefetchDictionary(candidate)
                }
            }
        }
    }

    private func cancelDictionaryPrefetch() {
        for task in dictionaryPrefetchTasks.values {
            task.cancel()
        }
        dictionaryPrefetchTasks.removeAll()
        cachedPrefetchResults.removeAll()
        dictionaryPrefetchRevision = nil
    }

    private func startTranslation(
        candidates: [Candidate],
        selectedIndex: Int,
        selectionIsExact: Bool,
        highlight: CandidateRegion,
        revision: UInt64,
        dictionaryPrefetchTasks: [Int: Task<TranslationResult?, Never>],
        cachedPrefetchResults: [Int: TranslationResult]
    ) {
        let mode = mode
        let router = router
        let memo = translationMemo
        let configurationToken = translationConfigurationToken
        let displayOptionLimit =
            CandidateTranslationPipeline.displayOptionLimit(
                for: translationScope,
                maximumTranslationCount: maximumTranslationCount
            )
        let translationCandidates =
            translationScope == .row
            ? Array(candidates.prefix(maximumTranslationCount))
            : candidates
        translationAttempts &+= 1
        translationStartedAt = .now
        cancelTranslationTask()
        translationTask = Task.detached(priority: .userInitiated) {
            [
                weak self,
                router,
                memo,
                translationCandidates,
                selectedIndex,
                selectionIsExact,
                configurationToken,
                dictionaryPrefetchTasks,
                cachedPrefetchResults,
                highlight,
                revision,
                mode,
            ] in
            guard !Task.isCancelled else { return }
            let presentations = await CandidateTranslationPipeline.translate(
                translationCandidates,
                selectedIndex: selectedIndex,
                selectionIsExact: selectionIsExact,
                mode: mode,
                configurationToken: configurationToken,
                router: router,
                memo: memo,
                displayOptionLimit: displayOptionLimit,
                dictionaryPrefetchTasks: dictionaryPrefetchTasks,
                cachedPrefetchResults: cachedPrefetchResults,
                publishProgress: { [weak self] presentations in
                    await self?.publishPartialTranslation(
                        presentations,
                        highlight: highlight,
                        revision: revision
                    )
                }
            )
            guard !Task.isCancelled else { return }
            await self?.completeTranslation(
                presentations,
                highlight: highlight,
                revision: revision
            )
        }
    }

    private func publishPartialTranslation(
        _ translations: [CandidateTranslationPresentation],
        highlight: CandidateRegion,
        revision: UInt64
    ) {
        guard revision == typingTracker.revision,
            typingTracker.isDwelling,
            translations.contains(where: { $0.translation != nil })
        else {
            return
        }
        let presentationHighlight = latestCandidateHighlight ?? highlight
        if let translationStartedAt {
            let now = DispatchTime.now().uptimeNanoseconds
            let total =
                candidateChangedAtNanoseconds.map {
                    Self.elapsedMilliseconds(from: $0, to: now)
                } ?? 0
            let dwell = Self.elapsedMilliseconds(
                from: dwellConfirmedAtNanoseconds,
                to: now
            )
            monitoringLogger.debug(
                "perf latency phase=selected_ready revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(translations.count, privacy: .public) dwell_ms=\(Self.dwellLatencyMilliseconds(from: self.candidateChangedAtNanoseconds, to: self.dwellConfirmedAtNanoseconds), privacy: .public) route_ms=\(Self.elapsedMilliseconds(translationStartedAt.duration(to: .now)), privacy: .public) dwell_to_selected_ms=\(dwell, privacy: .public) total_to_selected_ms=\(total, privacy: .public) attempts=\(self.translationAttempts, privacy: .public) cancelled=\(self.cancelledTranslationAttempts, privacy: .public)"
            )
        }
        continuation.yield(
            .results(
                translations,
                presentationHighlight,
                revision: revision,
                isProgressive: true
            )
        )
        publishInsertionOffer(
            from: translations,
            revision: revision
        )
    }

    private func completeTranslation(
        _ translations: [CandidateTranslationPresentation],
        highlight: CandidateRegion,
        revision: UInt64
    ) {
        guard revision == typingTracker.revision,
            typingTracker.isDwelling
        else {
            return
        }
        let presentationHighlight = latestCandidateHighlight ?? highlight
        translationTask = nil
        let finishedAt = ContinuousClock.now
        if let translationStartedAt {
            let now = DispatchTime.now().uptimeNanoseconds
            let phase =
                translationScope == .row
                ? "row_ready"
                : "selected_ready"
            let total =
                candidateChangedAtNanoseconds.map {
                    Self.elapsedMilliseconds(from: $0, to: now)
                } ?? 0
            let dwell = Self.elapsedMilliseconds(
                from: dwellConfirmedAtNanoseconds,
                to: now
            )
            let resultCount = translations.filter {
                $0.translation != nil
            }.count
            monitoringLogger.debug(
                "perf latency phase=\(phase, privacy: .public) revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(translations.count, privacy: .public) result_count=\(resultCount, privacy: .public) dwell_ms=\(Self.dwellLatencyMilliseconds(from: self.candidateChangedAtNanoseconds, to: self.dwellConfirmedAtNanoseconds), privacy: .public) route_ms=\(Self.elapsedMilliseconds(translationStartedAt.duration(to: finishedAt)), privacy: .public) dwell_to_ready_ms=\(dwell, privacy: .public) total_to_ready_ms=\(total, privacy: .public) attempts=\(self.translationAttempts, privacy: .public) cancelled=\(self.cancelledTranslationAttempts, privacy: .public)"
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
                insertionOptions: item.insertionOptions,
                isSelected:
                    selectedCandidateIndexIsExact
                    && item.index == latestSelectedIndex
            )
        }

        monitoringLogger.debug(
            "results count=\(presentations.count, privacy: .public) revision=\(revision, privacy: .public)"
        )
        emitStatus("已生成翻译显示")
        continuation.yield(
            .results(
                presentations,
                presentationHighlight,
                revision: revision,
                isProgressive: false
            )
        )
        publishInsertionOffer(
            from: presentations,
            revision: revision
        )
    }

    private func invalidateCandidate(immediate: Bool = false) {
        typingTracker.reset()
        candidateMissDebouncer.reset()
        compositionTransitions.reset()
        selectedCandidateIndex = nil
        selectedCandidateIndexIsExact = false
        latestCandidateHighlight = nil
        insertionOffer = nil
        insertionHostProcessIdentifier = nil
        cancelDictionaryPrefetch()
        handledRevision = nil
        dwellDetectedAt = nil
        translationStartedAt = nil
        candidateChangedAtNanoseconds = nil
        dwellConfirmedAtNanoseconds = nil
        cancelTranslationTask()
        emitCandidateEnded(immediate: immediate)
    }

    private func observeCandidateMiss(
        status: String,
        pollInterval: UInt64
    ) -> UInt64 {
        emitStatus(status)
        if candidateMissDebouncer.observeMiss() {
            invalidateCandidate(immediate: true)
        }
        return pollInterval
    }

    private static func elapsedMilliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private static func elapsedMilliseconds(
        from start: UInt64,
        to end: UInt64
    ) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    private static func elapsedMilliseconds(
        from start: UInt64?,
        to end: UInt64
    ) -> Double {
        guard let start else { return 0 }
        return elapsedMilliseconds(from: start, to: end)
    }

    private static func dwellLatencyMilliseconds(
        from candidateChangedAt: UInt64?,
        to dwellConfirmedAt: UInt64?
    ) -> Double {
        guard let candidateChangedAt,
            let dwellConfirmedAt
        else {
            return 0
        }
        return elapsedMilliseconds(
            from: candidateChangedAt,
            to: dwellConfirmedAt
        )
    }

    private func cancelTranslationTask() {
        guard let translationTask else { return }
        translationTask.cancel()
        self.translationTask = nil
        cancelledTranslationAttempts &+= 1
    }

    private func publishInsertionOffer(
        from presentations: [CandidateTranslationPresentation],
        revision: UInt64
    ) {
        guard insertionHostProcessIdentifier != nil else {
            insertionOffer = nil
            return
        }

        let choices: [String]
        switch translationScope {
        case .selected:
            guard
                let selected = presentations.first(where: \.isSelected),
                let translation = selected.translation
            else {
                insertionOffer = nil
                return
            }
            let options =
                selected.insertionOptions.isEmpty
                ? [translation]
                : selected.insertionOptions
            choices = Array(options.prefix(maximumTranslationCount))
        case .row:
            let ordered =
                presentations
                .sorted { $0.index < $1.index }
                .prefix(maximumTranslationCount)
            guard
                !ordered.isEmpty,
                ordered.allSatisfy({ $0.translation != nil })
            else {
                insertionOffer = nil
                return
            }
            choices = ordered.compactMap(\.translation)
        }
        guard !choices.isEmpty else {
            insertionOffer = nil
            return
        }
        let offer = TranslationChoiceOffer(
            revision: revision,
            choices: choices
        )
        insertionOffer = offer
        continuation.yield(.insertionOffer(offer))
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

    static func candidateRegion(
        for frame: CGRect
    ) -> CandidateRegion? {
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }
        return CandidateRegion(
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
        geometry: AXCandidateGeometry
    ) -> CGRect? {
        let horizontalFrame: CGRect
        if scope == .row {
            let rowFrames = options.compactMap(\.frame).filter {
                $0.width > 0 && $0.height > 0
            }
            guard
                let rowFrame = rowFrames.reduce(
                    nil,
                    { partial, frame in
                        partial?.union(frame) ?? frame
                    })
            else {
                return candidateDisplayFrame(
                    scope: .selected,
                    selectedFrame: selectedFrame,
                    options: [],
                    geometry: geometry
                )
            }
            horizontalFrame = rowFrame
        } else {
            guard
                selectedFrame.width > 0,
                selectedFrame.height > 0
            else {
                return nil
            }
            horizontalFrame = geometry.horizontalAnchor
        }
        return geometry.displayFrame(
            horizontalFrame: horizontalFrame
        )
    }

}
