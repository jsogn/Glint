import XCTest
@testable import GlintCore

final class OpenAICompatibleConfigurationTests: XCTestCase {
    func testBuildsChatCompletionsURL() {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "http://localhost:11434/v1/",
            model: "qwen3:8b"
        )

        XCTAssertEqual(
            configuration.chatCompletionsURL?.absoluteString,
            "http://localhost:11434/v1/chat/completions"
        )
    }

    func testKeepsCompleteChatCompletionsURL() {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "https://example.com/v1/chat/completions?token=ignored",
            model: "model"
        )

        XCTAssertEqual(
            configuration.chatCompletionsURL?.absoluteString,
            "https://example.com/v1/chat/completions"
        )
    }

    func testRejectsInvalidScheme() {
        let configuration = OpenAICompatibleConfiguration(
            baseURL: "file:///tmp/model",
            model: "model"
        )

        XCTAssertNil(configuration.chatCompletionsURL)
        XCTAssertFalse(configuration.isConfigured)
    }

    func testStorePersistsMultipleProviders() throws {
        let suite = "OpenAIProviders-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OpenAICompatibleConfigurationStore(
            defaults: defaults,
            service: "GlintTests-\(suite)",
            account: "provider-key"
        )
        let first = OpenAICompatibleProvider(
            name: "本机 Ollama",
            baseURL: "http://localhost:11434/v1",
            model: "qwen3:8b"
        )
        let second = OpenAICompatibleProvider(
            name: "远程接口",
            baseURL: "https://example.com/v1",
            model: "translator"
        )

        try store.saveProvider(first, apiKey: "")
        try store.saveProvider(second, apiKey: "")

        XCTAssertEqual(store.loadProviders(), [first, second])
        XCTAssertEqual(
            store.configuration(for: second.id)?.chatCompletionsURL?.host,
            "example.com"
        )

        try store.removeProvider(id: first.id)
        XCTAssertEqual(store.loadProviders(), [second])
    }

    func testMigratesLegacySingleProviderConfiguration() throws {
        let suite = "OpenAILegacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            "http://localhost:11434/v1",
            forKey: OpenAICompatibleConfigurationStore.baseURLKey
        )
        defaults.set(
            "qwen3:8b",
            forKey: OpenAICompatibleConfigurationStore.modelKey
        )
        TranslationModelSelection.select(
            TranslationModelSelection.openAICompatibleModelID,
            in: defaults
        )
        let store = OpenAICompatibleConfigurationStore(
            defaults: defaults,
            service: "GlintTests-\(suite)",
            account: "provider-key"
        )

        let providers = store.loadProviders()

        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0].baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(providers[0].model, "qwen3:8b")
        XCTAssertEqual(
            TranslationModelSelection.selected(in: defaults),
            TranslationModelSelection.openAICompatibleSelectionID(
                for: providers[0].id
            )
        )
    }

    func testOpenAIProviderSelectionIDRoundTrips() {
        let modelID = TranslationModelSelection.openAICompatibleSelectionID(
            for: "provider-123"
        )

        XCTAssertEqual(
            TranslationModelSelection.openAIProviderID(
                fromSelectionID: modelID
            ),
            "provider-123"
        )
    }
}
