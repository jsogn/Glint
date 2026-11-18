import CoreGraphics
import Dispatch
import Foundation
import GlintCore
import OSLog

extension MonitoringController {
    func startTranslation(
        candidates: [Candidate],
        selectedIndex: Int,
        selectionIsExact: Bool,
        highlight: CandidateRegion,
        revision: UInt64,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation,
        dictionaryPrefetchTasks: [Int: Task<TranslationResult?, Never>],
        cachedPrefetchResults: [Int: TranslationResult]
    ) {
        let mode = mode
        let translationTarget = translationTarget
        let router = router
        let memo = translationMemo
        let configurationToken = translationConfigurationToken
        let displayOptionLimit =
            CandidateTranslationPipeline.displayOptionLimit(
                for: translationScope,
                maximumTranslationCount: maximumTranslationCount,
                target: translationTarget
            )
        let translationCandidates =
            translationScope == .row
            ? Array(candidates.prefix(maximumTranslationCount))
            : candidates
        let pipelineSelectedIndex =
            translationCandidates.indices.contains(selectedIndex)
            ? selectedIndex
            : 0
        let pipelineSelectionIsExact =
            selectionIsExact
            && pipelineSelectedIndex == selectedIndex
        let shouldShowPartsOfSpeech =
            showsPartsOfSpeech && translationScope == .selected
        translationAttempts &+= 1
        translationStartedAt = .now
        cancelTranslationTask()
        translationTask = Task.detached(priority: .userInitiated) {
            [
                weak self,
                router,
                memo,
                translationCandidates,
                configurationToken,
                dictionaryPrefetchTasks,
                cachedPrefetchResults,
                highlight,
                revision,
                inputCaretRect,
                inputFieldRect,
                candidateSurfaceRect,
                candidateLayoutOrientation,
                mode,
                translationTarget,
                shouldShowPartsOfSpeech,
            ] in
            guard !Task.isCancelled else { return }
            let presentations = await CandidateTranslationPipeline.translate(
                translationCandidates,
                selectedIndex: pipelineSelectedIndex,
                selectionIsExact: pipelineSelectionIsExact,
                mode: mode,
                target: translationTarget,
                configurationToken: configurationToken,
                router: router,
                memo: memo,
                displayOptionLimit: displayOptionLimit,
                showsPartsOfSpeech: shouldShowPartsOfSpeech,
                dictionaryPrefetchTasks: dictionaryPrefetchTasks,
                cachedPrefetchResults: cachedPrefetchResults,
                publishProgress: { [weak self] presentations in
                    await self?.publishPartialTranslation(
                        presentations,
                        highlight: highlight,
                        revision: revision,
                        inputCaretRect: inputCaretRect,
                        inputFieldRect: inputFieldRect,
                        candidateSurfaceRect:
                            candidateSurfaceRect,
                        candidateLayoutOrientation:
                            candidateLayoutOrientation
                    )
                }
            )
            guard !Task.isCancelled else { return }
            await self?.completeTranslation(
                presentations,
                highlight: highlight,
                revision: revision,
                inputCaretRect: inputCaretRect,
                inputFieldRect: inputFieldRect,
                candidateSurfaceRect:
                    candidateSurfaceRect,
                candidateLayoutOrientation:
                    candidateLayoutOrientation
            )
        }
    }

    func publishPartialTranslation(
        _ translations: [CandidateTranslationPresentation],
        highlight: CandidateRegion,
        revision: UInt64,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation
    ) {
        guard revision == typingTracker.revision,
            typingTracker.isDwelling,
            translations.contains(where: \.hasTranslation)
        else {
            return
        }
        let presentationHighlight = latestCandidateHighlight ?? highlight
        let presentationInputCaretRect =
            latestInputCaretRect ?? inputCaretRect
        let presentationInputFieldRect =
            latestInputFieldRect ?? inputFieldRect
        let presentationCandidateSurfaceRect =
            latestCandidateSurfaceFrame
            ?? candidateSurfaceRect
        let presentationCandidateLayoutOrientation =
            latestCandidateLayoutOrientation
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
                "perf latency phase=selected_ready revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(translations.count, privacy: .public) dwell_ms=\(Self.dwellLatencyMilliseconds(from: self.candidateChangedAtNanoseconds, to: self.dwellConfirmedAtNanoseconds), privacy: .public) route_ms=\(translationStartedAt.duration(to: .now).inMilliseconds, privacy: .public) dwell_to_selected_ms=\(dwell, privacy: .public) total_to_selected_ms=\(total, privacy: .public) attempts=\(self.translationAttempts, privacy: .public) cancelled=\(self.cancelledTranslationAttempts, privacy: .public)"
            )
        }
        continuation.yield(
            .results(
                translations,
                presentationHighlight,
                inputCaretRect: presentationInputCaretRect,
                inputFieldRect: presentationInputFieldRect,
                candidateSurfaceRect:
                    presentationCandidateSurfaceRect,
                candidateLayoutOrientation:
                    presentationCandidateLayoutOrientation,
                revision: revision,
                isProgressive: true
            )
        )
        publishInsertionOffer(
            from: translations,
            revision: revision
        )
    }

    func completeTranslation(
        _ translations: [CandidateTranslationPresentation],
        highlight: CandidateRegion,
        revision: UInt64,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation
    ) {
        guard revision == typingTracker.revision,
            typingTracker.isDwelling
        else {
            return
        }
        let presentationHighlight = latestCandidateHighlight ?? highlight
        let presentationInputCaretRect =
            latestInputCaretRect ?? inputCaretRect
        let presentationInputFieldRect =
            latestInputFieldRect ?? inputFieldRect
        let presentationCandidateSurfaceRect =
            latestCandidateSurfaceFrame
            ?? candidateSurfaceRect
        let presentationCandidateLayoutOrientation =
            latestCandidateLayoutOrientation
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
            let resultCount = translations.count(where: \.hasTranslation)
            monitoringLogger.debug(
                "perf latency phase=\(phase, privacy: .public) revision=\(revision, privacy: .public) scope=\(self.translationScope.rawValue, privacy: .public) mode=\(self.mode.rawValue, privacy: .public) row_count=\(translations.count, privacy: .public) result_count=\(resultCount, privacy: .public) dwell_ms=\(Self.dwellLatencyMilliseconds(from: self.candidateChangedAtNanoseconds, to: self.dwellConfirmedAtNanoseconds), privacy: .public) route_ms=\(translationStartedAt.duration(to: finishedAt).inMilliseconds, privacy: .public) dwell_to_ready_ms=\(dwell, privacy: .public) total_to_ready_ms=\(total, privacy: .public) attempts=\(self.translationAttempts, privacy: .public) cancelled=\(self.cancelledTranslationAttempts, privacy: .public)"
            )
        }
        if let dwellDetectedAt {
            monitoringLogger.debug(
                "perf dwell_to_ready_ms=\(dwellDetectedAt.duration(to: finishedAt).inMilliseconds, privacy: .public)"
            )
        }
        self.translationStartedAt = nil
        self.dwellDetectedAt = nil
        let hasTranslatedResults = translations.contains(
            where: \.hasTranslation
        )
        if !hasTranslatedResults {
            emitStatus("有候选，但未找到可靠翻译")
        }
        let latestSelectedIndex = selectedCandidateIndex ?? 0
        let presentations = translations.map { item in
            CandidateTranslationPresentation(
                index: item.index,
                candidateText: item.candidateText,
                translation: item.translation,
                insertionOptions: item.insertionOptions,
                displayOptions: item.displayOptions,
                isSelected:
                    selectedCandidateIndexIsExact
                    && item.index == latestSelectedIndex
            )
        }

        monitoringLogger.debug(
            "results count=\(presentations.count, privacy: .public) revision=\(revision, privacy: .public)"
        )
        if hasTranslatedResults {
            emitStatus("已生成翻译显示")
        }
        continuation.yield(
            .results(
                presentations,
                presentationHighlight,
                inputCaretRect: presentationInputCaretRect,
                inputFieldRect: presentationInputFieldRect,
                candidateSurfaceRect:
                    presentationCandidateSurfaceRect,
                candidateLayoutOrientation:
                    presentationCandidateLayoutOrientation,
                revision: revision,
                isProgressive: false
            )
        )
        publishInsertionOffer(
            from: presentations,
            revision: revision
        )
    }
}
