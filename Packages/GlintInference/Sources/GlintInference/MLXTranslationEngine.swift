import Foundation
import GlintCore
import MLX
import MLXLLM
import MLXLMCommon
import OSLog

private let inferenceLogger = Logger(
    subsystem: "com.local.glint",
    category: "Inference"
)

public enum MLXTranslationError: Error, LocalizedError, Sendable {
    case modelNotFound
    case emptyOutput
    case invalidOutput

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到本地 MLX 翻译模型"
        case .emptyOutput:
            return "翻译模型没有返回内容"
        case .invalidOutput:
            return "翻译模型返回了无效内容"
        }
    }
}

internal enum MLXPromptProfile: Sendable {
    case qwenGeneral
    case hyMT2
    case indexTranslate
    case generic

    init(modelID: String) {
        self.init(profile: .inferred(from: modelID))
    }

    init(profile: TranslationPromptProfile) {
        switch profile {
        case .hyMT2:
            self = .hyMT2
        case .indexTranslate:
            self = .indexTranslate
        case .qwenGeneral:
            self = .qwenGeneral
        case .generic:
            self = .generic
        }
    }

    var instructions: String? {
        switch self {
        case .qwenGeneral, .generic:
            MLXTranslationEngine.qwenSystemPrompt
        case .hyMT2, .indexTranslate:
            nil
        }
    }

    var additionalContext: [String: any Sendable]? {
        switch self {
        case .qwenGeneral, .indexTranslate:
            ["enable_thinking": false]
        case .hyMT2, .generic:
            nil
        }
    }

    func prompt(for input: String) -> String {
        switch self {
        case .qwenGeneral:
            input
        case .hyMT2:
            "将以下文本翻译为英语，注意只需要输出翻译后的结果，不要额外解释：\n\n\(input)"
        case .indexTranslate:
            "请将以下文本翻译为英语，直接输出翻译结果，不要进行任何解释。\n\n\(input)"
        case .generic:
            input
        }
    }

    func batchPrompt(for inputs: [String]) -> String {
        let numberedInputs = inputs.enumerated().map { index, input in
            "\(index + 1). \(input)"
        }.joined(separator: "\n")
        switch self {
        case .qwenGeneral, .generic:
            return """
                Translate each numbered Chinese item below into natural English.
                Output exactly one English line per item, preserving the original number.
                Never explain, merge items, reorder items, or repeat the Chinese input.

                \(numberedInputs)
                """
        case .hyMT2:
            return """
                将以下编号文本分别翻译为英语。必须保持原编号和顺序，每条只输出英文翻译，不要解释、不要合并、不要遗漏。每行格式为“编号. 英文”。

                \(numberedInputs)
                """
        case .indexTranslate:
            return """
                请逐条将以下编号文本翻译为英语。保持原编号和顺序，每行只输出“编号. 英文”，不要解释或合并。

                \(numberedInputs)
                """
        }
    }
}

/// Local-only translation through MLX.
///
/// The application never downloads weights from this type. A plugin installer
/// places the model files in a local directory, and this engine only loads that
/// directory. Keeping a single `ModelContainer` alive avoids reloading several
/// gigabytes for every candidate.
public actor MLXTranslationEngine: TranslationEngine {
    public static let qwenSystemPrompt = """
        You translate Chinese into natural English for a typing companion.
        Output only one line of English. Never explain, quote, label, or repeat the input.
        For a word or short term, output its most common English equivalent.
        For a sentence, produce a concise, natural translation.
        """

    public static func configureMetalLibrary(at url: URL) {
        GPU.metallib = url
    }

    private let modelDirectory: URL?
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var lastLoadSeconds: Double?
    private(set) public var lastWarmUpSeconds: Double?
    private let profile: MLXPromptProfile
    private var generationIsBusy = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        modelDirectory: URL? = nil,
        modelID: String = "llm-qwen3-1.7b",
        promptProfile: TranslationPromptProfile? = nil
    ) {
        self.profile = MLXPromptProfile(
            profile: promptProfile ?? .inferred(from: modelID)
        )
        self.modelDirectory = Self.resolveDirectory(
            explicit: modelDirectory,
            modelID: modelID
        )
    }

    public var isLoaded: Bool {
        container != nil
    }

    public var loadSeconds: Double? {
        lastLoadSeconds
    }

    @discardableResult
    public func prepare() async throws -> ModelContainer {
        if let container {
            return container
        }
        if let loadTask {
            let loaded = try await loadTask.value
            container = loaded
            return loaded
        }
        guard let modelDirectory else {
            throw MLXTranslationError.modelNotFound
        }

        let started = ContinuousClock.now
        let task = Task<ModelContainer, Error> {
            try await LLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: LocalTokenizerLoader()
            )
        }
        loadTask = task
        do {
            let loaded = try await task.value
            container = loaded
            loadTask = nil
            lastLoadSeconds = started.duration(to: .now).seconds
            return loaded
        } catch {
            loadTask = nil
            throw error
        }
    }

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        try Task.checkCancellation()
        let input = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let container = try await prepare()
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let session = Self.makeSession(
            container,
            profile: profile,
            maxTokens: 64
        )
        let output = try await session.respond(to: profile.prompt(for: input))
        guard let translated = Self.clean(output), !translated.isEmpty else {
            throw MLXTranslationError.emptyOutput
        }
        return TranslationResult(
            text: translated,
            source: .translation,
            confidence: 0.92
        )
    }

    public func translateBatch(
        _ candidates: [Candidate]
    ) async throws -> [TranslationResult?] {
        try Task.checkCancellation()
        guard !candidates.isEmpty else { return [] }
        guard candidates.count > 1 else {
            return [try await translate(candidates[0])]
        }
        let inputs = candidates.compactMap {
            let text = $0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return text.isEmpty ? nil : text
        }
        guard inputs.count == candidates.count else {
            throw MLXTranslationError.invalidOutput
        }

        let container = try await prepare()
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let maximumTokens = min(256, max(64, inputs.count * 24 + 16))
        let session = Self.makeSession(
            container,
            profile: profile,
            maxTokens: maximumTokens
        )
        let output = try await session.respond(
            to: profile.batchPrompt(for: inputs)
        )
        let translations = try Self.parseBatchTranslations(
            output,
            expectedCount: inputs.count
        )
        return translations.map {
            TranslationResult(
                text: $0,
                source: .translation,
                confidence: 0.9
            )
        }
    }

    /// Compile and exercise the first generation path without user text.
    public func warmUp() async throws {
        try Task.checkCancellation()
        let container = try await prepare()
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let session = Self.makeSession(
            container,
            profile: profile,
            maxTokens: 16
        )
        _ = try await session.respond(to: profile.prompt(for: "今天天气不错"))
        lastWarmUpSeconds = started.duration(to: .now).seconds
        if let lastWarmUpSeconds {
            inferenceLogger.notice(
                "perf latency phase=warmup model=mlx ms=\(lastWarmUpSeconds * 1_000, privacy: .public)"
            )
        }
    }

    private nonisolated static func makeSession(
        _ container: ModelContainer,
        profile: MLXPromptProfile,
        maxTokens: Int
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: profile.instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0
            ),
            additionalContext: profile.additionalContext
        )
    }

    private func acquireGenerationSlot() async {
        if !generationIsBusy {
            generationIsBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            generationWaiters.append(continuation)
        }
    }

    private func releaseGenerationSlot() {
        guard !generationWaiters.isEmpty else {
            generationIsBusy = false
            return
        }
        generationWaiters.removeFirst().resume()
    }

    public static func availableModelDirectory(
        modelID: String = "llm-qwen3-1.7b"
    ) -> URL? {
        resolveDirectory(explicit: nil, modelID: modelID)
    }

    private static func resolveDirectory(
        explicit: URL?,
        modelID: String
    ) -> URL? {
        var candidates: [URL] = [
            explicit,
            Bundle.main.resourceURL?
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(modelID, isDirectory: true),
        ].compactMap { $0 }
        for pluginsDirectory in applicationSupportPluginsDirectories {
            let pluginDirectory = pluginsDirectory.appendingPathComponent(
                modelID,
                isDirectory: true
            )
            candidates.append(
                pluginDirectory.appendingPathComponent("model", isDirectory: true)
            )
            candidates.append(pluginDirectory)
        }

        return candidates.first(where: containsModelFiles)
    }

    private static var applicationSupportPluginsDirectories: [URL] {
        let fromSystem = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return (fromSystem + [home]).map {
            $0.appendingPathComponent("Glint/plugins", isDirectory: true)
        }
    }

    private static func containsModelFiles(_ directory: URL) -> Bool {
        let directory = directory.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let config = directory.appendingPathComponent("config.json")
        let tokenizer = directory.appendingPathComponent("tokenizer.json")
        guard fileManager.fileExists(atPath: config.path),
              fileManager.fileExists(atPath: tokenizer.path) else {
            return false
        }
        return (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.contains { $0.pathExtension == "safetensors" } == true
    }

    static func clean(_ raw: String) -> String? {
        let markers = ["<|im_end|>", "<|endoftext|>", "</s>", "<|im_start|>"]
        var value = raw
        for marker in markers {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        if let closing = value.range(of: "</think>", options: .backwards) {
            value = String(value[closing.upperBound...])
        }
        guard !value.contains("<think>") else {
            return nil
        }
        guard let firstLine = value
            .split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }

        var output = firstLine
        for prefix in ["Translation:", "English:", "翻译：", "英文："] {
            if output.lowercased().hasPrefix(prefix.lowercased()) {
                output = String(output.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        output = output.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'“”‘’")
        )
        output = output.replacingOccurrences(of: "**", with: "")

        let han = output.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value)
        }.count
        guard !output.isEmpty else { return nil }
        guard han <= max(1, output.count / 5) else { return nil }
        return output
    }

    static func parseBatchTranslations(
        _ raw: String,
        expectedCount: Int
    ) throws -> [String] {
        guard expectedCount > 0 else {
            return []
        }
        var value = raw
        let markers = ["<|im_end|>", "<|endoftext|>", "</s>", "<|im_start|>"]
        for marker in markers {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        if let closing = value.range(of: "</think>", options: .backwards) {
            value = String(value[closing.upperBound...])
        }
        guard !value.contains("<think>") else {
            throw MLXTranslationError.invalidOutput
        }

        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var numbered: [Int: String] = [:]
        for line in lines {
            guard let (index, translation) = numberedLine(line),
                  (1...expectedCount).contains(index),
                  numbered[index] == nil,
                  let cleaned = clean(translation) else {
                continue
            }
            numbered[index] = cleaned
        }
        if numbered.count == expectedCount {
            return (1...expectedCount).compactMap { numbered[$0] }
        }
        guard !lines.contains(where: { numberedLine($0) != nil }) else {
            throw MLXTranslationError.invalidOutput
        }

        let sequential = lines.compactMap(clean)
        guard sequential.count == expectedCount else {
            throw MLXTranslationError.invalidOutput
        }
        return sequential
    }

    private static func numberedLine(
        _ raw: String
    ) -> (Int, String)? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* "] where line.hasPrefix(prefix) {
            line = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard let separatorIndex = line.firstIndex(where: {
            [".", ")", "、", ":", "：", "-", "—"].contains($0)
        }) else {
            return nil
        }
        let prefix = line[..<separatorIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty,
              prefix.allSatisfy(\.isNumber),
              let index = Int(prefix) else {
            return nil
        }
        let content = line[line.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return (index, content)
    }
}

private extension Duration {
    var seconds: Double {
        Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
