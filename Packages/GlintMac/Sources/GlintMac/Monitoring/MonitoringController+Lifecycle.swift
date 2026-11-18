import Foundation
import GlintCore

extension MonitoringController {
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
            let insertionHostProcessIdentifier
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

    func run() async {
        monitoringLogger.info("monitor loop started")
        while !Task.isCancelled {
            let interval = await tick()
            try? await Task.sleep(nanoseconds: interval)
        }
    }
}
