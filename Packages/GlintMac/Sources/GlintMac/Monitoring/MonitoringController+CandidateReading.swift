import CoreGraphics
import Dispatch
import Foundation
import GlintCore

extension MonitoringController {
    func readCandidate(
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
                ?? candidate.candidateListFrame
                ?? (candidate.usesInputCaretFrameFallback
                    ? focus.caretRect
                    : nil),
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
                displayAnchor: displayAnchor,
                candidateSurfaceFrame:
                    candidate.candidateWindowFrame
                    ?? candidate.candidateListFrame,
                candidateLayoutOrientation:
                    candidate.layoutOrientation
            )
        )
    }

    func nextCandidatePollInterval(after timestamp: UInt64) -> UInt64 {
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

    func currentInputSource() async -> ActiveInputSource {
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

    func reportInputSourceIfNeeded(
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
        target: TranslationTarget,
        mode: TranslationMode,
        scope: CandidateTranslationScope
    ) -> Bool {
        guard target.supportsDictionaryRouting else { return false }
        switch mode {
        case .smartFusion, .dictionaryFirst:
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

    func startCandidatePrefetchIfNeeded(
        candidates: [Candidate],
        revision: UInt64
    ) async {
        guard dictionaryPrefetchRevision != revision else { return }

        cancelDictionaryPrefetch()
        dictionaryPrefetchRevision = revision
        let shouldPrefetchDictionary = Self.shouldPrefetchDictionary(
            target: translationTarget,
            mode: mode,
            scope: translationScope
        )
        let mode = mode
        let translationTarget = translationTarget
        let configurationToken = translationConfigurationToken
        let includesAlternatives =
            CandidateTranslationPipeline.displayOptionLimit(
                for: translationScope,
                maximumTranslationCount: maximumTranslationCount,
                target: translationTarget
            ) > 1
        let memo = translationMemo
        let router = router
        for (index, candidate) in candidates.enumerated()
        where translationScope != .row
            || index < maximumTranslationCount
        {
            let key = CandidateTranslationPipeline.memoKey(
                candidate: candidate,
                target: translationTarget,
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
                    await router.prefetchDictionary(
                        TranslationRequest(
                            candidate: candidate,
                            direction: TranslationDirection(
                                target: translationTarget
                            )
                        )
                    )
                }
            }
        }
    }

    func cancelDictionaryPrefetch() {
        for task in dictionaryPrefetchTasks.values {
            task.cancel()
        }
        dictionaryPrefetchTasks.removeAll()
        cachedPrefetchResults.removeAll()
        dictionaryPrefetchRevision = nil
    }
}
