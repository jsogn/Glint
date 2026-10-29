import Foundation

public struct SmartRouter: Sendable {
    private let dictionary: any DictionaryEngine
    private let translation: any TranslationEngine

    public init(dictionary: any DictionaryEngine, translation: any TranslationEngine) {
        self.dictionary = dictionary
        self.translation = translation
    }

    public func route(
        _ candidate: Candidate,
        mode: TranslationMode = .dictionaryFirst,
        includesAlternatives: Bool = true,
        dictionaryPrefetch: Task<TranslationResult?, Never>? = nil
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        guard !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        switch mode {
        case .smartFusion:
            if candidate.kind == .sentence {
                if let modelResult = try? await translation.translate(candidate),
                    !modelResult.options.isEmpty
                {
                    return modelResult
                }
                try Task.checkCancellation()
                return await dictionaryResult(
                    for: candidate,
                    prefetch: dictionaryPrefetch
                )
            }
            async let modelResultTask = translation.translate(candidate)
            async let dictionaryResultTask = dictionaryResult(
                for: candidate,
                prefetch: dictionaryPrefetch
            )
            let modelResult = try? await modelResultTask
            let dictionaryResult = await dictionaryResultTask
            try Task.checkCancellation()
            if let modelResult,
                !modelResult.options.isEmpty,
                let dictionaryResult,
                !dictionaryResult.options.isEmpty
            {
                return Self.smartMerged(
                    model: modelResult,
                    dictionary: dictionaryResult
                )
            }
            if let modelResult, !modelResult.options.isEmpty {
                return modelResult
            }
            return dictionaryResult
        case .dictionaryFirst:
            if candidate.kind == .sentence,
                let modelResult = try? await translation.translate(candidate),
                !modelResult.options.isEmpty
            {
                return modelResult
            }
            try Task.checkCancellation()
            if let dictionaryResult = await dictionaryResult(
                for: candidate,
                prefetch: dictionaryPrefetch
            ) {
                return dictionaryResult
            }
            try Task.checkCancellation()
            return try await translation.translate(candidate)
        case .modelFirst:
            if let modelResult = try? await translation.translate(candidate),
                !modelResult.options.isEmpty
            {
                guard includesAlternatives,
                    candidate.kind != .sentence,
                    let dictionaryResult = await dictionaryResult(
                        for: candidate,
                        prefetch: dictionaryPrefetch
                    ),
                    !dictionaryResult.options.isEmpty
                else {
                    return modelResult
                }
                return Self.modelFirstMerged(
                    model: modelResult,
                    dictionary: dictionaryResult
                )
            }
            try Task.checkCancellation()
            return await dictionaryResult(
                for: candidate,
                prefetch: dictionaryPrefetch
            )
        }
    }

    public func prefetchDictionary(
        _ candidate: Candidate
    ) async -> TranslationResult? {
        guard !Task.isCancelled else {
            return nil
        }
        let result = try? await dictionary.lookup(candidate)
        return Task.isCancelled ? nil : result
    }

    private func dictionaryResult(
        for candidate: Candidate,
        prefetch: Task<TranslationResult?, Never>?
    ) async -> TranslationResult? {
        if let prefetch {
            return await prefetch.value
        }
        return try? await dictionary.lookup(candidate)
    }

    private static func modelFirstMerged(
        model: TranslationResult,
        dictionary: TranslationResult
    ) -> TranslationResult {
        guard let lastModelScore = model.options.last?.score else {
            return dictionary
        }
        let firstDictionaryScore = lastModelScore - 0.0001
        let dictionaryOptions = dictionary.options.enumerated().map {
            index, option in
            TranslationOption(
                text: option.text,
                score: firstDictionaryScore - Double(index) * 0.000001
            )
        }
        return TranslationResult(
            options: model.options + dictionaryOptions
        )
    }

    private static func smartMerged(
        model: TranslationResult,
        dictionary: TranslationResult
    ) -> TranslationResult {
        var dictionaryRanks: [String: Int] = [:]
        for (index, option) in dictionary.options.enumerated() {
            guard let key = surfaceKey(option.text) else { continue }
            dictionaryRanks[key] = dictionaryRanks[key] ?? index
        }
        let modelKeys = Set(
            model.options.compactMap {
                surfaceKey($0.text)
            }
        )
        var options: [TranslationOption] = []

        for (index, option) in model.options.enumerated() {
            let key = surfaceKey(option.text)
            let dictionaryRank = key.flatMap { dictionaryRanks[$0] }
            let modelSignal =
                FusionWeights.modelRank / Double(index + 1)
            let dictionarySignal =
                dictionaryRank.map {
                    FusionWeights.dictionaryRank / Double($0 + 1)
                } ?? 0
            let consensusBonus =
                dictionaryRank == nil
                ? 0
                : FusionWeights.consensusBonus
            options.append(
                TranslationOption(
                    text: option.text,
                    score:
                        modelSignal
                        + dictionarySignal
                        + consensusBonus
                )
            )
        }

        for (index, option) in dictionary.options.enumerated() {
            if let key = surfaceKey(option.text),
                modelKeys.contains(key)
            {
                continue
            }
            options.append(
                TranslationOption(
                    text: option.text,
                    score:
                        FusionWeights.dictionaryRank
                        / Double(index + 1)
                )
            )
        }
        return TranslationResult(options: options)
    }

    private static func surfaceKey(_ text: String) -> String? {
        DictionarySurface.normalize(text)?.lowercased()
    }

    private enum FusionWeights {
        static let modelRank = 0.55
        static let dictionaryRank = 0.60
        static let consensusBonus = 0.35
    }
}
