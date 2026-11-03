import Foundation
import GlintCore

enum CandidateTranslationPipeline {
    static let maximumTranslationCountRange = 1...9

    static func translate(
        _ candidates: [Candidate],
        selectedIndex: Int,
        selectionIsExact: Bool = true,
        mode: TranslationMode,
        target: TranslationTarget,
        configurationToken: String,
        router: SmartRouter,
        memo: TranslationMemo,
        displayOptionLimit: Int = 4,
        showsPartsOfSpeech: Bool = false,
        dictionaryPrefetchTasks: [Int: Task<TranslationResult?, Never>] = [:],
        cachedPrefetchResults: [Int: TranslationResult] = [:],
        publishProgress: (
            @Sendable ([CandidateTranslationPresentation]) async -> Void
        )? = nil
    ) async -> [CandidateTranslationPresentation] {
        guard candidates.indices.contains(selectedIndex) else { return [] }
        var results = [TranslationResult?](
            repeating: nil,
            count: candidates.count
        )
        var selectedWasPublished = false
        await withTaskGroup(of: (Int, TranslationResult?).self) { group in
            for index in taskOrder(
                candidateCount: candidates.count,
                selectedIndex: selectedIndex
            ) {
                let candidate = candidates[index]
                let dictionaryPrefetch = dictionaryPrefetchTasks[index]
                let cachedResult = cachedPrefetchResults[index]
                group.addTask {
                    let result = await translateCandidate(
                        candidate,
                        target: target,
                        mode: mode,
                        configurationToken: configurationToken,
                        router: router,
                        memo: memo,
                        includesAlternatives: displayOptionLimit > 1,
                        dictionaryPrefetch: dictionaryPrefetch,
                        cachedResult: cachedResult
                    )
                    return (index, result)
                }
            }
            for await (index, result) in group {
                results[index] = result
                if candidates.count > 1,
                    index == selectedIndex,
                    !selectedWasPublished,
                    result != nil
                {
                    selectedWasPublished = true
                    let partialPresentations = candidates.indices.map {
                        presentation(
                            for: $0,
                            candidates: candidates,
                            results: results,
                            selectedIndex: selectedIndex,
                            selectionIsExact: selectionIsExact,
                            displayOptionLimit: displayOptionLimit,
                            showsPartsOfSpeech: showsPartsOfSpeech,
                            target: target
                        )
                    }
                    await publishProgress?(partialPresentations)
                }
            }
        }
        return candidates.indices.map {
            presentation(
                for: $0,
                candidates: candidates,
                results: results,
                selectedIndex: selectedIndex,
                selectionIsExact: selectionIsExact,
                displayOptionLimit: displayOptionLimit,
                showsPartsOfSpeech: showsPartsOfSpeech,
                target: target
            )
        }
    }

    static func displayOptionLimit(
        for scope: CandidateTranslationScope,
        maximumTranslationCount: Int,
        target: TranslationTarget
    ) -> Int {
        guard scope == .selected else { return 1 }
        guard target.supportsMultipleMeanings else { return 1 }
        return min(
            max(
                maximumTranslationCount,
                maximumTranslationCountRange.lowerBound
            ),
            maximumTranslationCountRange.upperBound
        )
    }

    static func memoKey(
        candidate: Candidate,
        target: TranslationTarget,
        mode: TranslationMode,
        configurationToken: String,
        includesAlternatives: Bool
    ) -> TranslationMemoKey {
        TranslationMemoKey(
            text: candidate.text,
            direction: TranslationDirection(target: target),
            mode: mode,
            configuration: configurationToken,
            includesAlternatives: includesAlternatives
        )
    }

    static func taskOrder(
        candidateCount: Int,
        selectedIndex: Int
    ) -> [Int] {
        guard candidateCount > 0,
            (0..<candidateCount).contains(selectedIndex)
        else {
            return []
        }
        return [selectedIndex]
            + (0..<candidateCount).filter {
                $0 != selectedIndex
            }
    }

    private static func translateCandidate(
        _ candidate: Candidate,
        target: TranslationTarget,
        mode: TranslationMode,
        configurationToken: String,
        router: SmartRouter,
        memo: TranslationMemo,
        includesAlternatives: Bool,
        dictionaryPrefetch: Task<TranslationResult?, Never>?,
        cachedResult: TranslationResult?
    ) async -> TranslationResult? {
        guard !Task.isCancelled else { return nil }
        if let cachedResult {
            return cachedResult
        }
        let key = memoKey(
            candidate: candidate,
            target: target,
            mode: mode,
            configurationToken: configurationToken,
            includesAlternatives: includesAlternatives
        )
        let result = try? await memo.resolve(for: key) {
            let routed = try await router.route(
                TranslationRequest(
                    candidate: candidate,
                    direction: TranslationDirection(
                        target: target
                    )
                ),
                mode: mode,
                includesAlternatives: includesAlternatives,
                dictionaryPrefetch: dictionaryPrefetch
            )
            return includesAlternatives ? routed : routed?.primaryOnly
        }
        return Task.isCancelled ? nil : result
    }

    private static func presentation(
        for index: Int,
        candidates: [Candidate],
        results: [TranslationResult?],
        selectedIndex: Int,
        selectionIsExact: Bool,
        displayOptionLimit: Int,
        showsPartsOfSpeech: Bool,
        target: TranslationTarget
    ) -> CandidateTranslationPresentation {
        let result = results[index].flatMap {
            presentationResult(
                for: candidates[index],
                result: $0,
                displayOptionLimit: displayOptionLimit,
                target: target
            )
        }
        let translation: String? = result.flatMap { result -> String? in
            let text =
                displayOptionLimit <= 1
                ? result.text
                : result.displayText
            return text.isEmpty ? nil : text
        }
        let insertionOptions =
            displayOptionLimit > 1
            ? Array(result?.options.prefix(displayOptionLimit) ?? [])
                .map(\.text)
            : []
        let displayOptions =
            showsPartsOfSpeech && target.supportsPartsOfSpeech
            ? Array(
                result?.options.prefix(displayOptionLimit) ?? []
            ).map {
                CandidateTranslationOptionPresentation(
                    text: $0.text,
                    partsOfSpeech: $0.partsOfSpeech
                )
            }
            : []
        return CandidateTranslationPresentation(
            index: index,
            candidateText: candidates[index].text,
            translation: translation,
            insertionOptions: insertionOptions,
            displayOptions: displayOptions,
            isSelected:
                selectionIsExact
                && index == selectedIndex
        )
    }

    private static func presentationResult(
        for candidate: Candidate,
        result: TranslationResult,
        displayOptionLimit: Int,
        target: TranslationTarget
    ) -> TranslationResult? {
        let conciseOptions: [TranslationOption]
        if displayOptionLimit > 1, candidate.text.count <= 4 {
            conciseOptions = result.options.filter {
                isConciseOption($0.text)
            }
        } else {
            conciseOptions = result.options
        }
        let filtered =
            conciseOptions.count >= 2
            ? TranslationResult(options: conciseOptions)
            : result
        return isDisplayable(filtered, target: target)
            ? filtered
            : nil
    }

    private static func isConciseOption(_ text: String) -> Bool {
        text.count <= 48
            && text.split(whereSeparator: \.isWhitespace).count <= 8
    }

    private static func isDisplayable(
        _ result: TranslationResult,
        target: TranslationTarget
    ) -> Bool {
        TranslationTextPolicy.isDisplayable(
            result.displayText,
            target: target
        )
    }
}
