import CoreGraphics
import Dispatch
import Foundation
import GlintCore

extension MonitoringController {
    func tick() async -> UInt64 {
        switch permissionGate() {
        case .poll(let interval):
            return interval
        case .ready:
            break
        }

        let activeInputSource: ActiveInputSource
        switch await activeInputSourceGate() {
        case .poll(let interval):
            return interval
        case .ready(let source):
            activeInputSource = source
        }

        let focusSnapshot: FocusSnapshot
        switch focusGate(for: activeInputSource) {
        case .poll(let interval):
            return interval
        case .ready(let snapshot):
            focusSnapshot = snapshot
        }
        if let inputCaretRect = focusSnapshot.caretRect {
            latestInputCaretRect = inputCaretRect
        }
        let inputFieldRect =
            focusSnapshot.isEditableTextInput
            ? focusSnapshot.elementFrame.flatMap {
                $0.width > 0 && $0.height > 0 ? $0 : nil
            }
            : nil
        if let inputFieldRect {
            latestInputFieldRect = inputFieldRect
        }

        let observationStartedAt = ContinuousClock.now
        let observation: CandidateObservation
        switch await candidateObservationGate(
            source: activeInputSource,
            focus: focusSnapshot
        ) {
        case .poll(let interval):
            return interval
        case .ready(let value):
            observation = value
        }

        return await processCandidateObservation(
            observation: observation,
            inputCaretRect: focusSnapshot.caretRect,
            inputFieldRect: inputFieldRect,
            observationStartedAt: observationStartedAt
        )
    }

    func permissionGate() -> TickGate<Void> {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let shouldCheck =
            lastPermissionCheck == 0
            || timestamp >= lastPermissionCheck
                && timestamp - lastPermissionCheck >= 1_000_000_000
        guard shouldCheck else { return .ready(()) }
        lastPermissionCheck = timestamp
        guard accessibilityIsTrusted() else {
            invalidateCandidate(immediate: true)
            emitStatus("需要辅助功能权限")
            return .poll(1_000_000_000)
        }
        return .ready(())
    }

    func activeInputSourceGate() async -> TickGate<ActiveInputSource> {
        let source = await currentInputSource()
        reportInputSourceIfNeeded(source.identity)
        guard source.kind != .keyboardLayout else {
            invalidateCandidate(immediate: true)
            emitStatus("等待中文输入")
            return .poll(250_000_000)
        }
        guard !secureInputIsEnabled() else {
            invalidateCandidate(immediate: true)
            emitStatus("安全输入场景已跳过")
            return .poll(500_000_000)
        }
        return .ready(source)
    }

    func focusGate(
        for source: ActiveInputSource
    ) -> TickGate<FocusSnapshot> {
        guard
            let snapshot = FocusResolutionPolicy.resolve(
                direct: focus.snapshot(),
                allowsProcessFallback:
                    candidateReaders.allowsProcessFallback(for: source),
                fallback: {
                    focus.processFallbackSnapshot()
                }
            )
        else {
            return .poll(
                observeCandidateMiss(
                    status: "未找到文本光标",
                    pollInterval: 60_000_000
                )
            )
        }
        guard snapshot.processIdentifier != ownProcessIdentifier else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过 Glint 自身窗口")
            return .poll(250_000_000)
        }
        if insertionHostProcessIdentifier != snapshot.processIdentifier {
            insertionOffer = nil
        }
        insertionHostProcessIdentifier = snapshot.processIdentifier
        guard !snapshot.hasTextSelection else {
            invalidateCandidate(immediate: true)
            emitStatus("已跳过文字选区")
            return .poll(100_000_000)
        }
        if compositionTransitions.observe(snapshot.compositionState) {
            invalidateCandidate(immediate: true)
            emitStatus("候选会话已结束")
            return .poll(40_000_000)
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
            return .poll(200_000_000)
        }
        guard
            snapshot.usesProcessFallback
                || snapshot.caretRect != nil
                || snapshot.elementFrame != nil
        else {
            return .poll(
                observeCandidateMiss(
                    status: "未找到文本光标",
                    pollInterval: 60_000_000
                )
            )
        }
        return .ready(snapshot)
    }

    func candidateObservationGate(
        source: ActiveInputSource,
        focus snapshot: FocusSnapshot
    ) async -> TickGate<CandidateObservation> {
        let outcome = readCandidate(source: source, focus: snapshot)
        switch outcome {
        case .found(let observation):
            return .ready(observation)
        case .miss(let status, let reason):
            if Self.shouldEndCandidateImmediately(for: reason) {
                emitStatus(status)
                invalidateCandidate(immediate: true)
                return .poll(CandidatePollingPolicy.stableInterval)
            }
            if await activateHostAccessibilityIfNeeded(
                source: source,
                focus: snapshot
            ) {
                return .poll(40_000_000)
            }
            return .poll(
                observeCandidateMiss(
                    status: status,
                    pollInterval: 60_000_000
                )
            )
        }
    }

    func processCandidateObservation(
        observation: CandidateObservation,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        observationStartedAt: ContinuousClock.Instant
    ) async -> UInt64 {
        candidateMissDebouncer.observeCandidate()
        let selection = candidateSelectionContext(
            observation: observation
        )
        latestCandidateHighlight = selection.displayAnchor
        if let candidateSurfaceFrame =
            observation.candidateSurfaceFrame
        {
            latestCandidateSurfaceFrame = candidateSurfaceFrame
        }
        latestCandidateLayoutOrientation =
            observation.candidateLayoutOrientation
        let context = candidateActivityContext(
            selection: selection,
            inputCaretRect: inputCaretRect,
            inputFieldRect: inputFieldRect,
            candidateSurfaceRect:
                latestCandidateSurfaceFrame,
            candidateLayoutOrientation:
                latestCandidateLayoutOrientation
        )
        await startCandidatePrefetchIfNeeded(
            candidates: context.selection.candidates,
            revision: typingTracker.revision
        )

        switch context.activity {
        case .changed(let revision):
            handleChangedActivity(context, revision: revision)
        case .dwelling(let revision):
            if let interval = handleDwellingActivity(
                context,
                revision: revision,
                observationStartedAt: observationStartedAt
            ) {
                return interval
            }
        case .observing:
            break
        }
        if candidateSessionActive,
            !context.changed,
            selectedCandidateIndexIsExact,
            context.selection.previousSelectedIndex
                != context.selection.selectedIndex
        {
            continuation.yield(
                .selectionChanged(
                    index: context.selection.selectedIndex,
                    revision: typingTracker.revision
                )
            )
        }
        publishLayoutIfNeeded(
            highlight: context.selection.displayAnchor,
            inputCaretRect: latestInputCaretRect,
            inputFieldRect: latestInputFieldRect,
            candidateSurfaceRect:
                latestCandidateSurfaceFrame,
            candidateLayoutOrientation:
                latestCandidateLayoutOrientation
        )
        return nextCandidatePollInterval(after: context.timestamp)
    }

    func candidateSelectionContext(
        observation: CandidateObservation
    ) -> CandidateSelectionContext {
        let axCandidate = observation.snapshot
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
            Candidate(text: $0, kind: CandidateClassifier.classify($0))
        }
        let trackingIdentity = CandidateTrackingIdentity.make(
            scope: translationScope,
            selectedText: axCandidate.text,
            selectedFrame: observation.selectedFrame,
            rowTexts: candidateTexts,
            rowFrame: observation.displayFrame
        )
        let previousSelectedIndex = selectedCandidateIndex
        selectedCandidateIndex = selectedIndex
        selectedCandidateIndexIsExact = axCandidate.selectionIsExact
        return CandidateSelectionContext(
            candidates: candidates,
            selectedIndex: selectedIndex,
            previousSelectedIndex: previousSelectedIndex,
            selectionIsExact: axCandidate.selectionIsExact,
            displayAnchor: observation.displayAnchor,
            trackingText: trackingIdentity.text,
            trackingFrame: trackingIdentity.frame
        )
    }

    func candidateActivityContext(
        selection: CandidateSelectionContext,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation
    ) -> CandidateActivityContext {
        let observationTimestamp = DispatchTime.now().uptimeNanoseconds
        let activity = typingTracker.observe(
            text: selection.trackingText,
            highlightRect: selection.trackingFrame,
            timestamp: observationTimestamp,
            dwellDurationNanoseconds: candidateDwellNanoseconds
        )
        return CandidateActivityContext(
            selection: selection,
            activity: activity,
            timestamp: observationTimestamp,
            changed: {
                if case .changed = activity { return true }
                return false
            }(),
            inputCaretRect: inputCaretRect,
            inputFieldRect: inputFieldRect,
            candidateSurfaceRect: candidateSurfaceRect,
            candidateLayoutOrientation:
                candidateLayoutOrientation
        )
    }

    func handleChangedActivity(
        _ context: CandidateActivityContext,
        revision: UInt64
    ) {
        handledRevision = nil
        dwellDetectedAt = nil
        translationStartedAt = nil
        dwellConfirmedAtNanoseconds = nil
        candidateChangedAtNanoseconds = context.timestamp
        cancelTranslationTask()
        emitCandidateChanged(revision: revision)
        let selected = context.selection.candidates[
            context.selection.selectedIndex
        ]
        monitoringLogger.debug(
            "candidate source=accessibility kind=\(selected.kind.rawValue, privacy: .public) length=\(selected.text.count, privacy: .public) row_count=\(context.selection.candidates.count, privacy: .public) revision=\(revision, privacy: .public) changed"
        )
    }

    func handleDwellingActivity(
        _ context: CandidateActivityContext,
        revision: UInt64,
        observationStartedAt: ContinuousClock.Instant
    ) -> UInt64? {
        guard handledRevision != revision else {
            return CandidatePollingPolicy.stableInterval
        }
        handledRevision = revision
        dwellDetectedAt = .now
        dwellConfirmedAtNanoseconds = context.timestamp
        if let candidateChangedAtNanoseconds {
            monitoringLogger.debug(
                "perf latency phase=dwell revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(context.selection.candidates.count, privacy: .public) dwell_ms=\(Self.elapsedMilliseconds(from: candidateChangedAtNanoseconds, to: context.timestamp), privacy: .public)"
            )
        }
        monitoringLogger.debug(
            "perf candidate_detect_ms=\(observationStartedAt.duration(to: .now).inMilliseconds, privacy: .public)"
        )
        startTranslation(
            candidates: context.selection.candidates,
            selectedIndex: context.selection.selectedIndex,
            selectionIsExact: context.selection.selectionIsExact,
            highlight: context.selection.displayAnchor,
            revision: revision,
            inputCaretRect: context.inputCaretRect,
            inputFieldRect: context.inputFieldRect,
            candidateSurfaceRect:
                context.candidateSurfaceRect,
            candidateLayoutOrientation:
                context.candidateLayoutOrientation,
            dictionaryPrefetchTasks: dictionaryPrefetchTasks,
            cachedPrefetchResults: cachedPrefetchResults
        )
        return nil
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
