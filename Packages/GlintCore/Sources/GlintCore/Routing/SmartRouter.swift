import Foundation

public struct SmartRouter: Sendable {
    private let dictionary: any DictionaryEngine
    private let translation: any TranslationEngine
    private let partOfSpeechProvider: (any PartOfSpeechProviding)?

    public init(
        dictionary: any DictionaryEngine,
        translation: any TranslationEngine,
        partOfSpeechProvider: (any PartOfSpeechProviding)? = nil
    ) {
        self.dictionary = dictionary
        self.translation = translation
        self.partOfSpeechProvider = partOfSpeechProvider
    }

    public func route(
        _ request: TranslationRequest,
        mode: TranslationMode = .dictionaryFirst,
        includesAlternatives: Bool = true,
        dictionaryPrefetch: Task<TranslationResult?, Never>? = nil
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        guard !request.candidate.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return nil
        }
        if !request.direction.target.supportsDictionaryRouting {
            return try await translation.translate(request)
        }
        let routed = try await routeWithoutPartOfSpeech(
            request,
            mode: mode,
            includesAlternatives: includesAlternatives,
            dictionaryPrefetch: dictionaryPrefetch
        )
        return await enrichingPartsOfSpeech(
            routed,
            direction: request.direction
        )
    }

    private func routeWithoutPartOfSpeech(
        _ request: TranslationRequest,
        mode: TranslationMode,
        includesAlternatives: Bool,
        dictionaryPrefetch: Task<TranslationResult?, Never>?
    ) async throws -> TranslationResult? {
        let candidate = request.candidate
        switch mode {
        case .smartFusion:
            if candidate.kind == .sentence {
                if let modelResult = try? await translation.translate(request),
                    !modelResult.options.isEmpty
                {
                    return modelResult
                }
                try Task.checkCancellation()
                return await dictionaryResult(
                    for: request,
                    prefetch: dictionaryPrefetch
                )
            }
            async let modelResultTask = translation.translate(request)
            async let dictionaryResultTask = dictionaryResult(
                for: request,
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
                let modelResult = try? await translation.translate(request),
                !modelResult.options.isEmpty
            {
                return modelResult
            }
            try Task.checkCancellation()
            if let dictionaryResult = await dictionaryResult(
                for: request,
                prefetch: dictionaryPrefetch
            ) {
                return dictionaryResult
            }
            try Task.checkCancellation()
            return try await translation.translate(request)
        case .modelFirst:
            if let modelResult = try? await translation.translate(request),
                !modelResult.options.isEmpty
            {
                guard includesAlternatives,
                    candidate.kind != .sentence,
                    let dictionaryResult = await dictionaryResult(
                        for: request,
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
                for: request,
                prefetch: dictionaryPrefetch
            )
        }
    }

    private func enrichingPartsOfSpeech(
        _ result: TranslationResult?,
        direction: TranslationDirection
    ) async -> TranslationResult? {
        guard direction.target.supportsPartsOfSpeech,
            let result,
            let partOfSpeechProvider
        else {
            return result
        }
        var enriched = result.options
        for index in enriched.indices {
            let option = enriched[index]
            guard PartOfSpeech.singleEnglishWordKey(option.text) != nil else {
                continue
            }
            let resolved = await partOfSpeechProvider.partsOfSpeech(
                forEnglish: option.text
            )
            guard !resolved.isEmpty else { continue }
            enriched[index] = TranslationOption(
                text: option.text,
                score: option.score,
                partsOfSpeech: option.partsOfSpeech + resolved
            )
        }
        return TranslationResult(options: enriched)
    }

    public func prefetchDictionary(
        _ request: TranslationRequest
    ) async -> TranslationResult? {
        guard !Task.isCancelled,
            request.direction.target.supportsDictionaryRouting
        else {
            return nil
        }
        let result = try? await dictionary.lookup(request)
        return Task.isCancelled ? nil : result
    }

    private func dictionaryResult(
        for request: TranslationRequest,
        prefetch: Task<TranslationResult?, Never>?
    ) async -> TranslationResult? {
        if let prefetch {
            return await prefetch.value
        }
        return try? await dictionary.lookup(request)
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
                score: firstDictionaryScore - Double(index) * 0.000001,
                partsOfSpeech: option.partsOfSpeech
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
        var dictionaryMetadata: [String: (rank: Int, partsOfSpeech: [PartOfSpeech])] = [:]
        for (index, option) in dictionary.options.enumerated() {
            guard let key = surfaceKey(option.text) else { continue }
            dictionaryMetadata[key] =
                dictionaryMetadata[key]
                ?? (
                    rank: index,
                    partsOfSpeech: option.partsOfSpeech
                )
        }
        let modelKeys = Set(
            model.options.compactMap {
                surfaceKey($0.text)
            }
        )
        var options: [TranslationOption] = []

        for (index, option) in model.options.enumerated() {
            let key = surfaceKey(option.text)
            let dictionaryEntry = key.flatMap {
                dictionaryMetadata[$0]
            }
            let dictionaryRank = dictionaryEntry?.rank
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
                        + consensusBonus,
                    partsOfSpeech: PartOfSpeech.normalized(
                        (dictionaryEntry?.partsOfSpeech ?? [])
                            + option.partsOfSpeech
                    )
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
                        / Double(index + 1),
                    partsOfSpeech: option.partsOfSpeech
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
