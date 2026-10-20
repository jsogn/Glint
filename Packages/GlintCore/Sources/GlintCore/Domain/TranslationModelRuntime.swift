import Foundation
import Security

public enum TranslationPromptProfile: String, Codable, Sendable {
    case qwenGeneral = "qwen-general"
    case hyMT2 = "hy-mt2"
    case indexTranslate = "index-translate"
    case generic = "generic"

    public static func inferred(from modelID: String) -> Self {
        if modelID.hasPrefix("mt-hy-mt2-") {
            return .hyMT2
        }
        if modelID.hasPrefix("mt-index-translate-") {
            return .indexTranslate
        }
        if modelID.hasPrefix("llm-qwen3-") {
            return .qwenGeneral
        }
        return .generic
    }
}

public struct OpenAICompatibleConfiguration: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var apiKey: String

    public init(
        baseURL: String = "",
        model: String = "",
        apiKey: String = ""
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public var isConfigured: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && chatCompletionsURL != nil
    }

    public var chatCompletionsURL: URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if !path.hasSuffix("/chat/completions") {
            path += "/chat/completions"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct OpenAICompatibleProvider: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var baseURL: String
    public var model: String

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        model: String = ""
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
    }
}

public enum ResolvedTranslationModel: Sendable, Equatable {
    case mlx(
        modelID: String,
        directory: URL,
        promptProfile: TranslationPromptProfile
    )
    case ctranslate2(modelID: String, directory: URL)
    case openAICompatible(
        modelID: String,
        configuration: OpenAICompatibleConfiguration
    )

    public var modelID: String {
        switch self {
        case let .mlx(modelID, _, _):
            modelID
        case let .ctranslate2(modelID, _):
            modelID
        case let .openAICompatible(modelID, _):
            modelID
        }
    }
}

public enum OpenAICompatibleConfigurationError: Error, LocalizedError {
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "无法保存 API Key（Keychain 错误 \(status)）"
        }
    }
}

public final class OpenAICompatibleConfigurationStore: @unchecked Sendable {
    public static let defaultService = "com.local.glint.openai-compatible"
    public static let defaultAccount = "api-key"
    public static let providersKey = "translation.openAICompatible.providers"
    public static let baseURLKey = "translation.openAICompatible.baseURL"
    public static let modelKey = "translation.openAICompatible.model"

    private let defaults: UserDefaults
    private let service: String
    private let account: String

    public init(
        defaults: UserDefaults = .standard,
        service: String = OpenAICompatibleConfigurationStore.defaultService,
        account: String = OpenAICompatibleConfigurationStore.defaultAccount
    ) {
        self.defaults = defaults
        self.service = service
        self.account = account
    }

    public func loadProviders() -> [OpenAICompatibleProvider] {
        if let data = defaults.data(forKey: Self.providersKey),
           let providers = try? JSONDecoder().decode(
               [OpenAICompatibleProvider].self,
               from: data
           ) {
            return providers
        }

        let baseURL = defaults.string(forKey: Self.baseURLKey) ?? ""
        let model = defaults.string(forKey: Self.modelKey) ?? ""
        guard !baseURL.isEmpty || !model.isEmpty else {
            return []
        }

        let provider = OpenAICompatibleProvider(
            name: "OpenAI 兼容接口",
            baseURL: baseURL,
            model: model
        )
        let legacyKey = Self.readKeychain(service: service, account: account)
        try? Self.writeKeychain(
            legacyKey,
            service: service,
            account: keychainAccount(for: provider.id)
        )
        try? persist([provider])
        defaults.removeObject(forKey: Self.baseURLKey)
        defaults.removeObject(forKey: Self.modelKey)
        try? Self.writeKeychain("", service: service, account: account)
        if TranslationModelSelection.selected(in: defaults)
            == TranslationModelSelection.openAICompatibleModelID {
            TranslationModelSelection.select(
                TranslationModelSelection.openAICompatibleSelectionID(
                    for: provider.id
                ),
                in: defaults
            )
        }
        return [provider]
    }

    public func provider(id: String) -> OpenAICompatibleProvider? {
        loadProviders().first(where: { $0.id == id })
    }

    public func configuration(
        for providerID: String
    ) -> OpenAICompatibleConfiguration? {
        guard let provider = provider(id: providerID) else { return nil }
        return OpenAICompatibleConfiguration(
            baseURL: provider.baseURL,
            model: provider.model,
            apiKey: Self.readKeychain(
                service: service,
                account: keychainAccount(for: providerID)
            )
        )
    }

    public func apiKey(for providerID: String) -> String {
        Self.readKeychain(
            service: service,
            account: keychainAccount(for: providerID)
        )
    }

    public func saveProvider(
        _ provider: OpenAICompatibleProvider,
        apiKey: String
    ) throws {
        try Self.writeKeychain(
            apiKey,
            service: service,
            account: keychainAccount(for: provider.id)
        )
        var providers = loadProviders()
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        try persist(providers)
    }

    public func removeProvider(id: String) throws {
        try Self.writeKeychain(
            "",
            service: service,
            account: keychainAccount(for: id)
        )
        let providers = loadProviders().filter { $0.id != id }
        try persist(providers)
    }

    public func load() -> OpenAICompatibleConfiguration {
        guard let first = loadProviders().first,
              let configuration = configuration(for: first.id) else {
            return OpenAICompatibleConfiguration()
        }
        return configuration
    }

    public func save(_ configuration: OpenAICompatibleConfiguration) throws {
        let provider = loadProviders().first ?? OpenAICompatibleProvider(
            name: "OpenAI 兼容接口"
        )
        var updated = provider
        updated.baseURL = configuration.baseURL
        updated.model = configuration.model
        try saveProvider(updated, apiKey: configuration.apiKey)
    }

    private func persist(_ providers: [OpenAICompatibleProvider]) throws {
        let data = try JSONEncoder().encode(providers)
        defaults.set(data, forKey: Self.providersKey)
    }

    private func keychainAccount(for providerID: String) -> String {
        "\(account)-\(providerID)"
    }

    private static func readKeychain(service: String, account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func writeKeychain(
        _ value: String,
        service: String,
        account: String
    ) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        guard !value.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OpenAICompatibleConfigurationError.keychain(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenAICompatibleConfigurationError.keychain(addStatus)
        }
    }
}
