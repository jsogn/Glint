import Foundation

/// How a dictionary source participates in the lookup chain.
public enum DictionaryRouteRole: Sendable, Equatable {
    /// Trusted sources are merged; a match prevents all fallback lookups.
    case authoritative
    /// Sources are tried by priority until one returns a result.
    case fallback
}

public struct DictionaryRoute: Sendable {
    public let id: String
    public let priority: Int
    public let role: DictionaryRouteRole
    public let directions: Set<TranslationDirection>
    public let engine: any DictionaryEngine

    public init(
        id: String,
        priority: Int,
        role: DictionaryRouteRole = .fallback,
        directions: Set<TranslationDirection> = [
            .simplifiedChineseToEnglish
        ],
        engine: any DictionaryEngine
    ) {
        self.id = id
        self.priority = priority
        self.role = role
        self.directions = directions
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

    public func lookup(
        _ request: TranslationRequest
    ) async -> TranslationResult? {
        let text = request.candidate.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !blocked.contains(text) else { return nil }

        var options: [TranslationOption] = []
        for route in routes
        where route.role == .authoritative
            && route.directions.contains(request.direction)
        {
            if Task.isCancelled { return nil }
            options.append(
                contentsOf: await routeOptions(
                    from: route,
                    request: request
                )
            )
        }
        if !options.isEmpty {
            return TranslationResult(options: options)
        }

        for route in routes
        where route.role == .fallback
            && route.directions.contains(request.direction)
        {
            if Task.isCancelled { return nil }
            let fallbackOptions = await routeOptions(
                from: route,
                request: request
            )
            if !fallbackOptions.isEmpty {
                return TranslationResult(options: fallbackOptions)
            }
        }
        return nil
    }

    private func routeOptions(
        from route: DictionaryRoute,
        request: TranslationRequest
    ) async -> [TranslationOption] {
        guard
            let result = try? await route.engine.lookup(request)
        else {
            return []
        }
        let routeBoost = max(0, 0.2 - Double(route.priority) * 0.02)
        return result.options.flatMap { option in
            let surfaces = DictionarySurface.split(option.text)
                .filter(DictionarySurface.isDisplayable)
            let partsOfSpeech =
                surfaces.count == 1
                ? option.partsOfSpeech
                : []

            return
                surfaces
                .enumerated()
                .map { index, surface in
                    TranslationOption(
                        text: surface,
                        score: option.score + routeBoost
                            - DictionarySurface.penalty(for: surface)
                            - Double(index) * 0.01,
                        partsOfSpeech: partsOfSpeech
                    )
                }
        }
    }
}
