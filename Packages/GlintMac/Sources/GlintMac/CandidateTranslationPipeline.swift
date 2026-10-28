import Foundation
import GlintCore

enum CandidateTranslationPipeline {
    static let maximumTranslationCountRange = 1...9

    static func translate(
        _ candidates: [Candidate],
        selectedIndex: Int,
        selectionIsExact: Bool = true,
        mode: TranslationMode,
        configurationToken: String,
        router: SmartRouter,
        memo: TranslationMemo,
        displayOptionLimit: Int = 4,
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
                            displayOptionLimit: displayOptionLimit
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
                displayOptionLimit: displayOptionLimit
            )
        }
    }

    static func displayOptionLimit(
        for scope: CandidateTranslationScope,
        maximumTranslationCount: Int
    ) -> Int {
        guard scope == .selected else { return 1 }
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
        mode: TranslationMode,
        configurationToken: String,
        includesAlternatives: Bool
    ) -> TranslationMemoKey {
        TranslationMemoKey(
            text: candidate.text,
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
            mode: mode,
            configurationToken: configurationToken,
            includesAlternatives: includesAlternatives
        )
        let result = try? await memo.resolve(for: key) {
            let routed = try await router.route(
                candidate,
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
        displayOptionLimit: Int
    ) -> CandidateTranslationPresentation {
        let result = results[index].flatMap { result -> TranslationResult? in
            guard isDisplayable(result) else { return nil }
            return result
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
        return CandidateTranslationPresentation(
            index: index,
            candidateText: candidates[index].text,
            translation: translation,
            insertionOptions: insertionOptions,
            isSelected:
                selectionIsExact
                && index == selectedIndex
        )
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
}
