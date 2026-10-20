import Foundation
import GlintCore

public enum OpenAICompatibleTranslationError: Error, LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case server(String)
    case emptyOutput

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "OpenAI 兼容接口配置无效"
        case .invalidResponse:
            "OpenAI 兼容接口返回了无效响应"
        case let .server(message):
            message
        case .emptyOutput:
            "OpenAI 兼容接口没有返回翻译结果"
        }
    }
}

public actor OpenAICompatibleTranslationEngine: TranslationEngine {
    private static let systemPrompt = """
        You are a Chinese-to-English translation engine for a typing companion.
        Translate the user's Chinese text into natural English.
        Output only one line of English. Never explain, quote, label, or repeat the input.
        For a word or short term, output its most common English equivalent.
        For a sentence, produce a concise, natural translation.
        """

    private let configuration: OpenAICompatibleConfiguration
    private let session: URLSession

    public init(
        configuration: OpenAICompatibleConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
    }

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        let input = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        guard configuration.isConfigured,
              let endpoint = configuration.chatCompletionsURL else {
            throw OpenAICompatibleTranslationError.invalidConfiguration
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue(
                "Bearer \(configuration.apiKey)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: configuration.model,
                messages: [
                    .init(role: "system", content: Self.systemPrompt),
                    .init(role: "user", content: input),
                ]
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OpenAICompatibleTranslationError.server(
                "无法连接接口：\(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleTranslationError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(
                ErrorResponse.self,
                from: data
            ))?.error.message
            throw OpenAICompatibleTranslationError.server(
                message ?? "接口请求失败（HTTP \(http.statusCode)）"
            )
        }

        guard let content = try? JSONDecoder().decode(
            ChatResponse.self,
            from: data
        ).choices.first?.message.content,
              let translated = MLXTranslationEngine.clean(content),
              !translated.isEmpty else {
            throw OpenAICompatibleTranslationError.emptyOutput
        }

        return TranslationResult(
            text: translated,
            source: .translation,
            confidence: 0.9
        )
    }
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature = 0.0
    let maxTokens = 96
    let stream = false

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case stream
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct ErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
