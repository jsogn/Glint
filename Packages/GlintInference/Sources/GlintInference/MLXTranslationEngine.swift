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
    case incompatibleAdapter
    case unsupportedTarget

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "未找到本地 MLX 翻译模型"
        case .emptyOutput:
            return "翻译模型没有返回内容"
        case .invalidOutput:
            return "翻译模型返回了无效内容"
        case .incompatibleAdapter:
            return "模型未通过目标语言兼容性验证"
        case .unsupportedTarget:
            return "模型不支持目标语言"
        }
    }
}

internal enum MLXPromptProfile: Sendable, Equatable {
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

    var defaultAdapterMode: TranslationAdapterMode {
        switch self {
        case .qwenGeneral:
            .systemInstruction
        case .hyMT2, .indexTranslate:
            .translationInstruction
        case .generic:
            .directSource
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

    func instructions(
        for adapterMode: TranslationAdapterMode,
        target: TranslationTarget
    ) -> String? {
        if adapterMode == .systemInstruction {
            return MLXTranslationEngine.qwenSystemPrompt(
                for: target
            )
        }
        return nil
    }

    func prompt(
        for input: String,
        target: TranslationTarget,
        adapterMode: TranslationAdapterMode
    ) -> String {
        guard adapterMode == .translationInstruction else {
            return input
        }
        let language = target.chineseDisplayName
        return switch self {
        case .hyMT2:
            "将以下文本翻译为\(language)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(input)"
        case .indexTranslate:
            "请将以下中文文本翻译为\(language)，直接输出翻译结果，不要进行任何解释。\n\n\(input)"
        case .qwenGeneral, .generic:
            "将以下文本翻译为\(language)，只输出翻译结果，不要解释：\n\n\(input)"
        }
    }

    func generationParameters(maxTokens: Int) -> GenerateParameters {
        switch self {
        case .qwenGeneral:
            GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.7,
                topP: 0.8,
                topK: 20
            )
        case .hyMT2:
            GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.7,
                topP: 0.6,
                topK: 20,
                repetitionPenalty: 1.05
            )
        case .indexTranslate, .generic:
            GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0
            )
        }
    }

    func probeGenerationParameters(maxTokens: Int) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0
        )
    }

    func batchPrompt(
        for inputs: [String],
        target: TranslationTarget
    ) -> String {
        let numberedInputs = inputs.enumerated().map { index, input in
            "\(index + 1). \(input)"
        }.joined(separator: "\n")
        switch self {
        case .qwenGeneral, .generic:
            return """
                Translate each numbered Chinese item below into natural \(target.englishDisplayName).
                Output exactly one \(target.englishDisplayName) line per item, preserving the original number.
                Never explain, merge items, reorder items, or repeat the Chinese input.

                \(numberedInputs)
                """
        case .hyMT2:
            return """
                将以下编号文本分别翻译为\(target.chineseDisplayName)。必须保持原编号和顺序，每条只输出\(target.chineseDisplayName)翻译，不要解释、不要合并、不要遗漏。每行格式为“编号. \(target.chineseDisplayName)译文”。

                \(numberedInputs)
                """
        case .indexTranslate:
            return """
                请逐条将以下编号文本翻译为\(target.chineseDisplayName)。保持原编号和顺序，每行只输出“编号. \(target.chineseDisplayName)译文”，不要解释或合并。

                \(numberedInputs)
                """
        }
    }
}

private struct CachedTranslationAdapter: Codable {
    static let legacyFileName = ".glint-translation-adapter.json"
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let target: TranslationTarget?
    let mode: TranslationAdapterMode

    static func fileName(for target: TranslationTarget) -> String {
        ".glint-translation-adapter-\(target.rawValue).json"
    }
}

/// Local-only translation through MLX.
///
/// The application never downloads weights from this type. A plugin installer
/// places the model files in a local directory, and this engine only loads that
/// directory. Keeping a single `ModelContainer` alive avoids reloading several
/// gigabytes for every candidate.
public actor MLXTranslationEngine: TranslationEngine {
    public static func qwenSystemPrompt(
        for target: TranslationTarget
    ) -> String {
        """
        You translate Chinese into natural \(target.englishDisplayName) for a typing companion.
        Output only one line in \(target.englishDisplayName). Never explain, quote, label, or repeat the input.
        For a word or short term, output its most common \(target.englishDisplayName) equivalent.
        For a sentence, produce a concise, natural translation.
        """
    }

    public static func configureMetalLibrary(at url: URL) {
        GPU.metallib = url
    }

    private let modelDirectory: URL?
    private var container: ModelContainer?
    private var loadTask: Task<ModelContainer, Error>?
    private var lastLoadSeconds: Double?
    private(set) public var lastWarmUpSeconds: Double?
    private let profile: MLXPromptProfile
    private let supportedTargets: Set<TranslationTarget>
    private var adapterMode = TranslationAdapterMode.directSource
    private var adapterModeIsResolved = false
    private var adapterTarget: TranslationTarget?
    private var generationIsBusy = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        modelDirectory: URL? = nil,
        modelID: String = "llm-qwen3-1.7b",
        promptProfile: TranslationPromptProfile? = nil,
        supportedTargets: Set<TranslationTarget> = [.english]
    ) {
        let profile = MLXPromptProfile(
            profile: promptProfile ?? .inferred(from: modelID)
        )
        self.profile = profile
        self.supportedTargets = supportedTargets
        let modelDirectory = Self.resolveDirectory(
            explicit: modelDirectory,
            modelID: modelID
        )
        self.modelDirectory = modelDirectory
    }

    public var loadSeconds: Double? {
        lastLoadSeconds
    }

    var resolvedAdapterMode: TranslationAdapterMode {
        adapterMode
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

    @discardableResult
    public func prepareForTranslation(
        target: TranslationTarget
    ) async throws -> ModelContainer {
        guard supportedTargets.contains(target) else {
            throw MLXTranslationError.unsupportedTarget
        }
        let container = try await prepare()
        prepareAdapterState(for: target)
        guard profile == .generic, !adapterModeIsResolved else {
            return container
        }
        adapterMode = try await detectAdapterMode(target: target)
        adapterModeIsResolved = true
        persistAdapterMode(target: target)
        return container
    }

    public func supports(
        _ direction: TranslationDirection
    ) async -> Bool {
        direction.source == .simplifiedChinese
            && supportedTargets.contains(direction.target)
    }

    public func translate(
        _ request: TranslationRequest
    ) async throws -> TranslationResult? {
        try await translateCandidate(
            request.candidate,
            target: request.direction.target
        )
    }

    private func translateCandidate(
        _ candidate: Candidate,
        target: TranslationTarget
    ) async throws -> TranslationResult? {
        try Task.checkCancellation()
        guard supportedTargets.contains(target) else {
            throw MLXTranslationError.unsupportedTarget
        }
        let input = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        let container = try await prepareForTranslation(
            target: target
        )
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let session = Self.makeSession(
            container,
            profile: profile,
            target: target,
            adapterMode: adapterMode,
            maxTokens: 64
        )
        let output = try await session.respond(
            to: profile.prompt(
                for: input,
                target: target,
                adapterMode: adapterMode
            )
        )
        guard
            let translated = Self.clean(output, target: target),
            !translated.isEmpty
        else {
            throw MLXTranslationError.emptyOutput
        }
        guard !Self.isInstructionEcho(translated, for: input) else {
            throw MLXTranslationError.invalidOutput
        }
        return TranslationResult(text: translated)
    }

    public func translateBatch(
        _ candidates: [Candidate],
        target: TranslationTarget
    ) async throws -> [TranslationResult?] {
        try Task.checkCancellation()
        guard supportedTargets.contains(target) else {
            throw MLXTranslationError.unsupportedTarget
        }
        guard !candidates.isEmpty else { return [] }
        guard candidates.count > 1 else {
            return [
                try await translateCandidate(
                    candidates[0],
                    target: target
                )
            ]
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

        let container = try await prepareForTranslation(
            target: target
        )
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let maximumTokens = min(256, max(64, inputs.count * 24 + 16))
        let session = Self.makeSession(
            container,
            profile: profile,
            target: target,
            adapterMode: adapterMode,
            maxTokens: maximumTokens
        )
        let output = try await session.respond(
            to: profile.batchPrompt(
                for: inputs,
                target: target
            )
        )
        let translations = try Self.parseBatchTranslations(
            output,
            expectedCount: inputs.count,
            target: target
        )
        guard
            !zip(translations, inputs).contains(where: {
                Self.isInstructionEcho($0.0, for: $0.1)
            })
        else {
            throw MLXTranslationError.invalidOutput
        }
        return translations.map {
            TranslationResult(text: $0)
        }
    }

    /// Compile and exercise the first generation path without user text.
    public func warmUp(target: TranslationTarget) async throws {
        try Task.checkCancellation()
        guard supportedTargets.contains(target) else {
            throw MLXTranslationError.unsupportedTarget
        }
        let container = try await prepareForTranslation(
            target: target
        )
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let session = Self.makeSession(
            container,
            profile: profile,
            target: target,
            adapterMode: adapterMode,
            maxTokens: 16
        )
        _ = try await session.respond(
            to: profile.prompt(
                for: "今天天气不错",
                target: target,
                adapterMode: adapterMode
            )
        )
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
        target: TranslationTarget,
        adapterMode: TranslationAdapterMode,
        maxTokens: Int
    ) -> ChatSession {
        makeSession(
            container,
            profile: profile,
            target: target,
            adapterMode: adapterMode,
            parameters: profile.generationParameters(
                maxTokens: maxTokens
            )
        )
    }

    private nonisolated static func makeSession(
        _ container: ModelContainer,
        profile: MLXPromptProfile,
        target: TranslationTarget,
        adapterMode: TranslationAdapterMode,
        parameters: GenerateParameters
    ) -> ChatSession {
        ChatSession(
            container,
            instructions: profile.instructions(
                for: adapterMode,
                target: target
            ),
            generateParameters: parameters,
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

    private func detectAdapterMode(
        target: TranslationTarget
    ) async throws -> TranslationAdapterMode {
        guard let container else {
            throw MLXTranslationError.modelNotFound
        }
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }

        let modes: [TranslationAdapterMode] = [
            .directSource,
            .translationInstruction,
            .systemInstruction,
        ]
        for mode in modes {
            try Task.checkCancellation()
            let session = Self.makeSession(
                container,
                profile: profile,
                target: target,
                adapterMode: mode,
                parameters: profile.probeGenerationParameters(
                    maxTokens: 32
                )
            )
            var passed = true
            for probe in Self.adapterProbes(target: target) {
                do {
                    let raw = try await session.respond(
                        to: profile.prompt(
                            for: probe.source,
                            target: target,
                            adapterMode: mode
                        )
                    )
                    guard
                        let translated = Self.clean(
                            raw,
                            target: target
                        ),
                        !Self.isInstructionEcho(
                            translated,
                            for: probe.source
                        ),
                        Self.isAcceptedProbeOutput(
                            translated,
                            expected: probe.expected
                        )
                    else {
                        passed = false
                        break
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    passed = false
                    break
                }
            }
            if passed {
                return mode
            }
        }
        throw MLXTranslationError.incompatibleAdapter
    }

    private func prepareAdapterState(
        for target: TranslationTarget
    ) {
        guard adapterTarget != target else { return }
        adapterTarget = target
        adapterMode = profile.defaultAdapterMode
        adapterModeIsResolved = profile != .generic

        guard profile == .generic,
            let modelDirectory,
            let cached = Self.cachedAdapter(
                in: modelDirectory,
                target: target
            )
        else {
            return
        }
        adapterMode = cached.mode
        adapterModeIsResolved = true
    }

    private func persistAdapterMode(target: TranslationTarget) {
        guard let modelDirectory else { return }
        let cached = CachedTranslationAdapter(
            schemaVersion: CachedTranslationAdapter.currentSchemaVersion,
            target: target,
            mode: adapterMode
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cached).write(
                to: modelDirectory.appendingPathComponent(
                    CachedTranslationAdapter.fileName(
                        for: target
                    )
                ),
                options: .atomic
            )
        } catch {
            inferenceLogger.notice(
                "adapter cache write failed model=\(modelDirectory.lastPathComponent, privacy: .public)"
            )
        }
    }

    private static func cachedAdapter(
        in modelDirectory: URL,
        target: TranslationTarget
    ) -> CachedTranslationAdapter? {
        let targetURL = modelDirectory.appendingPathComponent(
            CachedTranslationAdapter.fileName(for: target)
        )
        let legacyURL = modelDirectory.appendingPathComponent(
            CachedTranslationAdapter.legacyFileName
        )
        let url =
            FileManager.default.fileExists(atPath: targetURL.path)
            ? targetURL
            : legacyURL
        guard
            let data = try? Data(
                contentsOf: url
            ),
            let cached = try? JSONDecoder().decode(
                CachedTranslationAdapter.self,
                from: data
            ),
            cached.schemaVersion
                == CachedTranslationAdapter.currentSchemaVersion
        else {
            return nil
        }
        guard
            cached.target == target
                || (cached.target == nil && target == .english)
        else {
            return nil
        }
        return cached
    }

    private struct AdapterProbe {
        let source: String
        let expected: Set<String>
    }

    private static func adapterProbes(
        target: TranslationTarget
    ) -> [AdapterProbe] {
        switch target {
        case .english:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["hello", "hi"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["weather"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["translate", "translation"]
                ),
            ]
        case .japanese:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["こんにちは", "ハロー"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["天気", "天候"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["翻訳", "訳す"]
                ),
            ]
        case .spanish:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["hola"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["tiempo", "clima"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["traducción", "traducir"]
                ),
            ]
        case .french:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["bonjour", "salut"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["temps", "météo"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["traduction", "traduire"]
                ),
            ]
        case .german:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["hallo"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["wetter"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["übersetzung", "übersetzen"]
                ),
            ]
        case .russian:
            [
                AdapterProbe(
                    source: "你好",
                    expected: ["привет", "здравствуйте"]
                ),
                AdapterProbe(
                    source: "天气",
                    expected: ["погода"]
                ),
                AdapterProbe(
                    source: "翻译",
                    expected: ["перевод", "перевести"]
                ),
            ]
        }
    }

    static func isAcceptedProbeOutput(
        _ output: String,
        expected: Set<String>
    ) -> Bool {
        let usesNonLatinScript = expected.contains {
            $0.unicodeScalars.contains { $0.value > 127 }
        }
        if usesNonLatinScript {
            let normalized =
                output
                .lowercased()
                .unicodeScalars
                .filter(CharacterSet.alphanumerics.contains)
                .map(String.init)
                .joined()
            return expected.contains {
                let value =
                    $0
                    .lowercased()
                    .unicodeScalars
                    .filter(CharacterSet.alphanumerics.contains)
                    .map(String.init)
                    .joined()
                return !value.isEmpty && normalized.contains(value)
            }
        }

        let normalized =
            output
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
            .joined(separator: " ")
        let words = normalized.split(separator: " ")
        guard !words.isEmpty, words.count <= 6 else {
            return false
        }
        return expected.contains {
            words.contains(Substring($0))
        }
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
        if let explicit {
            return containsModelFiles(explicit) ? explicit : nil
        }
        var candidates: [URL] = []
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

    static func containsModelFiles(_ directory: URL) -> Bool {
        let directory = directory.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }
        let names = Set(files.map(\.lastPathComponent))
        let hasTokenizer =
            names.contains("tokenizer.json")
            || names.contains("tokenizer.model")
            || names.contains { $0.hasSuffix(".spm") }
        let hasWeights = names.contains { $0.hasSuffix(".safetensors") }
        return names.contains("config.json") && hasTokenizer && hasWeights
    }

    static func clean(
        _ raw: String,
        target: TranslationTarget
    ) -> String? {
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
        guard
            let firstLine =
                value
                .split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty })
        else {
            return nil
        }

        var output = firstLine
        var prefixes = [
            "Translation:",
            "\(target.englishDisplayName):",
            "翻译：",
            "\(target.chineseDisplayName)：",
        ]
        if target == .english {
            prefixes.append("英文：")
        }
        if target == .japanese {
            prefixes += ["翻訳：", "日文：", "日语："]
        }
        for prefix in prefixes {
            if output.lowercased().hasPrefix(prefix.lowercased()) {
                output = String(output.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        output = output.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'“”‘’")
        )
        output = output.replacingOccurrences(of: "**", with: "")

        guard
            TranslationTextPolicy.isDisplayable(
                output,
                target: target
            )
        else {
            return nil
        }
        return output
    }

    static func isInstructionEcho(
        _ output: String,
        for input: String
    ) -> Bool {
        let source = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count <= 8 else { return false }

        let value =
            output
            .lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .joined(separator: " ")
        let markers = [
            "translate the following",
            "translated result",
            "additional explanation",
            "directly output the translation",
            "word or short word",
            "most common concise english equivalent",
            "just output one answer",
            "list of synonyms",
        ]
        let markerCount = markers.count {
            value.contains($0)
        }
        let wordCount = value.split(separator: " ").count
        if markerCount >= 2, wordCount >= 8 {
            return true
        }

        return wordCount >= 12
            && (value.contains("translation") || value.contains("translate"))
            && (value.contains("explanation") || value.contains("synonym"))
    }

    static func parseBatchTranslations(
        _ raw: String,
        expectedCount: Int,
        target: TranslationTarget
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

        let lines =
            value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var numbered: [Int: String] = [:]
        for line in lines {
            guard let (index, translation) = numberedLine(line),
                (1...expectedCount).contains(index),
                numbered[index] == nil,
                let cleaned = clean(
                    translation,
                    target: target
                )
            else {
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

        let sequential = lines.compactMap {
            clean($0, target: target)
        }
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
        guard
            let separatorIndex = line.firstIndex(where: {
                [".", ")", "、", ":", "：", "-", "—"].contains($0)
            })
        else {
            return nil
        }
        let prefix = line[..<separatorIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty,
            prefix.allSatisfy(\.isNumber),
            let index = Int(prefix)
        else {
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
