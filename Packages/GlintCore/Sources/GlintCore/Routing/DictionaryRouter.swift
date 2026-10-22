public struct DictionaryRoute: Sendable {
    public let id: String
    public let priority: Int
    public let engine: any DictionaryEngine

    public init(id: String, priority: Int, engine: any DictionaryEngine) {
        self.id = id
        self.priority = priority
        self.engine = engine
    }
}

public struct DictionaryRouter: DictionaryEngine {
    private let routes: [DictionaryRoute]
    private let blocked: Set<String>

    public init(
        routes: [DictionaryRoute],
        blocked: Set<String> = DictionaryPolicy.blockedTerms
    ) {
        self.routes = routes.sorted { $0.priority < $1.priority }
        self.blocked = blocked
    }

    public func lookup(_ candidate: Candidate) async throws -> TranslationResult? {
        guard !blocked.contains(candidate.text) else { return nil }
        var options: [TranslationOption] = []
        var highestConfidence = 0.0
        for route in routes {
            if let result = try await route.engine.lookup(candidate) {
                highestConfidence = max(highestConfidence, result.confidence)
                let routeBoost = max(0, 0.2 - Double(route.priority) * 0.02)
                for option in result.options {
                    let surfaces = DictionarySurface.split(option.text)
                    for (index, surface) in surfaces.enumerated() {
                        options.append(
                            TranslationOption(
                                text: surface,
                                score: option.score + routeBoost
                                    - DictionarySurface.penalty(for: surface)
                                    - Double(index) * 0.01
                            )
                        )
                    }
                }
            }
        }
        guard !options.isEmpty else { return nil }
        return TranslationResult(
            options: options,
            source: .dictionary,
            confidence: highestConfidence
        )
    }
}
