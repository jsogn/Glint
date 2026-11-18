import CoreGraphics
import Foundation
import GlintCore

extension MonitoringController {
    func invalidateCandidate(immediate: Bool = false) {
        typingTracker.reset()
        candidateMissDebouncer.reset()
        compositionTransitions.reset()
        selectedCandidateIndex = nil
        selectedCandidateIndexIsExact = false
        latestCandidateHighlight = nil
        latestInputCaretRect = nil
        latestInputFieldRect = nil
        latestCandidateSurfaceFrame = nil
        latestCandidateLayoutOrientation = .unknown
        lastPublishedLayout = nil
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

    func observeCandidateMiss(
        status: String,
        pollInterval: UInt64
    ) -> UInt64 {
        emitStatus(status)
        if candidateMissDebouncer.observeMiss() {
            invalidateCandidate(immediate: true)
        }
        return pollInterval
    }

    static func elapsedMilliseconds(
        from start: UInt64,
        to end: UInt64
    ) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    static func elapsedMilliseconds(
        from start: UInt64?,
        to end: UInt64
    ) -> Double {
        guard let start else { return 0 }
        return elapsedMilliseconds(from: start, to: end)
    }

    static func dwellLatencyMilliseconds(
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

    func cancelTranslationTask() {
        guard let translationTask else { return }
        translationTask.cancel()
        self.translationTask = nil
        cancelledTranslationAttempts &+= 1
    }

    func publishInsertionOffer(
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
                ordered.allSatisfy(\.hasTranslation)
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

    func emitStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        monitoringLogger.info("status=\(status, privacy: .public)")
        continuation.yield(.status(status))
    }

    func emitCandidateChanged(revision: UInt64) {
        candidateSessionActive = true
        continuation.yield(.candidateChanged(revision: revision))
    }

    func publishLayoutIfNeeded(
        highlight: CandidateRegion,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation
    ) {
        guard candidateSessionActive else { return }
        let next = CandidateLayoutSnapshot(
            highlight: highlight,
            inputCaretRect: inputCaretRect,
            inputFieldRect: inputFieldRect,
            candidateSurfaceRect: candidateSurfaceRect,
            candidateLayoutOrientation:
                candidateLayoutOrientation
        )
        if let lastPublishedLayout,
            next.approximatelyEquals(
                lastPublishedLayout,
                tolerance: 2
            )
        {
            return
        }
        lastPublishedLayout = next
        continuation.yield(
            .layoutChanged(
                highlight,
                inputCaretRect: inputCaretRect,
                inputFieldRect: inputFieldRect,
                candidateSurfaceRect: candidateSurfaceRect,
                candidateLayoutOrientation:
                    candidateLayoutOrientation
            )
        )
    }

    func emitCandidateEnded(immediate: Bool) {
        guard candidateSessionActive else { return }
        candidateSessionActive = false
        continuation.yield(.candidateEnded(immediate: immediate))
    }
}
