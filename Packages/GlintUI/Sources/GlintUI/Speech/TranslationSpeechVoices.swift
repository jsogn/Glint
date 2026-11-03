import AVFAudio
import Foundation
import GlintCore

public struct TranslationSpeechVoiceOption:
    Identifiable, Hashable, Sendable
{
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum TranslationSpeechVoiceCatalog {
    public static func voices(
        for target: TranslationTarget
    )
        -> [TranslationSpeechVoiceOption]
    {
        var seen: Set<String> = []
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                matchesTargetLanguage($0.language, target: target)
            }
            .filter { seen.insert($0.identifier).inserted }
        let nameCounts = Dictionary(
            grouping: voices,
            by: \.name
        )
        .mapValues(\.count)
        return
            voices
            .map {
                TranslationSpeechVoiceOption(
                    id: $0.identifier,
                    name: displayName(
                        for: $0,
                        nameCount: nameCounts[$0.name] ?? 1
                    )
                )
            }
            .sorted {
                let comparison =
                    $0.name.localizedCaseInsensitiveCompare($1.name)
                guard comparison == .orderedSame else {
                    return comparison == .orderedAscending
                }
                return $0.id.localizedCaseInsensitiveCompare($1.id)
                    == .orderedAscending
            }
    }

    public static func voice(
        identifier: String,
        for target: TranslationTarget
    ) -> AVSpeechSynthesisVoice? {
        guard
            let voice = AVSpeechSynthesisVoice(
                identifier: identifier
            ),
            isVoice(voice, for: target)
        else {
            return nil
        }
        return voice
    }

    static func isVoice(
        _ voice: AVSpeechSynthesisVoice,
        for target: TranslationTarget
    ) -> Bool {
        matchesTargetLanguage(voice.language, target: target)
    }

    private static func matchesTargetLanguage(
        _ language: String,
        target: TranslationTarget
    ) -> Bool {
        language == target.speechLocaleIdentifier
            || language.hasPrefix(target.rawValue + "-")
    }

    private static func displayName(
        for voice: AVSpeechSynthesisVoice,
        nameCount: Int
    ) -> String {
        guard nameCount > 1 else { return voice.name }
        let localeName =
            Locale.current.localizedString(
                forIdentifier: voice.language
            ) ?? voice.language
        return "\(voice.name) · \(localeName)"
    }
}
