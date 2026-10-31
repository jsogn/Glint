import AVFAudio

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
    private let preferredLanguages: () -> [String]
    private var activeSource: TranslationSpeechSource?

    public convenience init() {
        self.init(
            synthesizer: AVSpeechSynthesizer(),
            voiceForLanguage: { language in
                AVSpeechSynthesisVoice(language: language)
            },
            preferredLanguages: { Locale.preferredLanguages }
        )
    }

    init(
        synthesizer: any TranslationSpeechSynthesizing,
        voiceForLanguage: @escaping (String) -> AVSpeechSynthesisVoice?,
        preferredLanguages: @escaping () -> [String] = {
            Locale.preferredLanguages
        }
    ) {
        self.synthesizer = synthesizer
        self.voiceForLanguage = voiceForLanguage
        self.preferredLanguages = preferredLanguages
    }

    public func speak(
        _ text: String,
        accent: TranslationSpeechAccent,
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
        let languageCode = accent.languageCode(
            preferredLanguages: preferredLanguages()
        )
        let voice =
            voiceForLanguage(languageCode)
            ?? (accent == .system && languageCode != "en-US"
                ? voiceForLanguage("en-US")
                : nil)
        guard let voice else {
            return
        }
        utterance.voice = voice
        utterance.rate = Self.utteranceRate(for: rate)
        activeSource = source
        synthesizer.speak(utterance)
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
