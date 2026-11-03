import AVFAudio
import GlintCore

@MainActor
protocol TranslationSpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: TranslationSpeechSynthesizing {}

public enum TranslationSpeechSource: Sendable, Equatable {
    case automatic
    case manual
}

@MainActor
public final class TranslationSpeechController {
    private static let slowerRateScale: Float = 0.8
    private static let fasterRateScale: Float = 1.2

    private let synthesizer: any TranslationSpeechSynthesizing
    private let voiceForLanguage: (String) -> AVSpeechSynthesisVoice?
    private let voiceForIdentifier: (String) -> AVSpeechSynthesisVoice?
    private let preferredLanguages: () -> [String]
    private var activeSource: TranslationSpeechSource?

    public convenience init() {
        self.init(
            synthesizer: AVSpeechSynthesizer(),
            voiceForLanguage: { language in
                AVSpeechSynthesisVoice(language: language)
            },
            voiceForIdentifier: { identifier in
                AVSpeechSynthesisVoice(identifier: identifier)
            },
            preferredLanguages: { Locale.preferredLanguages }
        )
    }

    init(
        synthesizer: any TranslationSpeechSynthesizing,
        voiceForLanguage: @escaping (String) -> AVSpeechSynthesisVoice?,
        voiceForIdentifier: @escaping (String) ->
            AVSpeechSynthesisVoice? = { identifier in
                AVSpeechSynthesisVoice(identifier: identifier)
            },
        preferredLanguages: @escaping () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.synthesizer = synthesizer
        self.voiceForLanguage = voiceForLanguage
        self.voiceForIdentifier = voiceForIdentifier
        self.preferredLanguages = preferredLanguages
    }

    public func speak(
        _ text: String,
        target: TranslationTarget,
        accent: TranslationSpeechAccent,
        voiceIdentifier: String? = nil,
        rate: TranslationSpeechRate = .standard,
        source: TranslationSpeechSource = .manual
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeSource = nil
        let utterance = AVSpeechUtterance(string: trimmed)
        let voice =
            target.supportsSpeechAccents
            ? englishVoice(accent: accent)
            : targetVoice(
                identifier: voiceIdentifier,
                target: target
            )
        guard let voice else {
            return
        }
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(for: rate)
        activeSource = source
        synthesizer.speak(utterance)
    }

    public func speakPreview(
        target: TranslationTarget,
        accent: TranslationSpeechAccent,
        voiceIdentifier: String? = nil,
        rate: TranslationSpeechRate = .standard
    ) {
        speak(
            Self.previewText(for: target),
            target: target,
            accent: accent,
            voiceIdentifier: voiceIdentifier,
            rate: rate,
            source: .manual
        )
    }

    static func previewText(for target: TranslationTarget) -> String {
        switch target {
        case .english:
            "Hello. It's a beautiful day, isn't it?"
        case .japanese:
            "こんにちは。今日はいい天気ですね。"
        case .spanish:
            "Hola. Hoy hace un día precioso, ¿verdad?"
        case .french:
            "Bonjour. Il fait très beau aujourd'hui, n'est-ce pas ?"
        case .german:
            "Hallo. Heute ist es wirklich schön, nicht wahr?"
        case .russian:
            "Здравствуйте. Сегодня прекрасная погода, не так ли?"
        }
    }

    public func stop() {
        activeSource = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    public func stopAutomatic() {
        guard activeSource == .automatic else { return }
        stop()
    }

    public func stopManual() {
        guard activeSource == .manual else { return }
        stop()
    }

    private func englishVoice(
        accent: TranslationSpeechAccent
    ) -> AVSpeechSynthesisVoice? {
        let languageCode = accent.languageCode(
            preferredLanguages: preferredLanguages()
        )
        return voiceForLanguage(languageCode)
            ?? (accent == .system && languageCode != "en-US"
                ? voiceForLanguage("en-US")
                : nil)
    }

    private func targetVoice(
        identifier: String?,
        target: TranslationTarget
    ) -> AVSpeechSynthesisVoice? {
        if let identifier,
            let selected = voiceForIdentifier(identifier),
            TranslationSpeechVoiceCatalog.isVoice(
                selected,
                for: target
            )
        {
            return selected
        }
        return voiceForLanguage(target.speechLocaleIdentifier)
    }

    private static func utteranceRate(
        for rate: TranslationSpeechRate
    ) -> Float {
        let defaultRate = AVSpeechUtteranceDefaultSpeechRate
        let adjustedRate: Float
        switch rate {
        case .slower:
            adjustedRate = defaultRate * slowerRateScale
        case .standard:
            adjustedRate = defaultRate
        case .faster:
            adjustedRate = defaultRate * fasterRateScale
        }
        return min(
            max(adjustedRate, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }
}
