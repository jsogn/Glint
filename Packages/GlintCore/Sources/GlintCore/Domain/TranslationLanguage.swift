import Foundation

public enum TranslationSourceLanguage:
    String, Codable, Sendable, Equatable, Hashable
{
    case simplifiedChinese = "zh-Hans"
}

public enum TranslationTarget:
    String, CaseIterable, Codable, Sendable, Equatable, Hashable
{
    case english = "en"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case russian = "ru"

    private struct Profile: Sendable {
        let chineseDisplayName: String
        let englishDisplayName: String
        let speechLocaleIdentifier: String
        let supportsDictionaryRouting: Bool
        let supportsPartsOfSpeech: Bool
        let supportsMultipleMeanings: Bool
        let supportsSpeechAccents: Bool
        let allowsHanOutput: Bool
    }

    private var profile: Profile {
        switch self {
        case .english:
            Profile(
                chineseDisplayName: "英语",
                englishDisplayName: "English",
                speechLocaleIdentifier: "en-US",
                supportsDictionaryRouting: true,
                supportsPartsOfSpeech: true,
                supportsMultipleMeanings: true,
                supportsSpeechAccents: true,
                allowsHanOutput: false
            )
        case .japanese:
            Profile(
                chineseDisplayName: "日语",
                englishDisplayName: "Japanese",
                speechLocaleIdentifier: "ja-JP",
                supportsDictionaryRouting: false,
                supportsPartsOfSpeech: false,
                supportsMultipleMeanings: false,
                supportsSpeechAccents: false,
                allowsHanOutput: true
            )
        case .spanish:
            Self.modelOnlyProfile(
                chineseDisplayName: "西班牙语",
                englishDisplayName: "Spanish",
                speechLocaleIdentifier: "es-ES"
            )
        case .french:
            Self.modelOnlyProfile(
                chineseDisplayName: "法语",
                englishDisplayName: "French",
                speechLocaleIdentifier: "fr-FR"
            )
        case .german:
            Self.modelOnlyProfile(
                chineseDisplayName: "德语",
                englishDisplayName: "German",
                speechLocaleIdentifier: "de-DE"
            )
        case .russian:
            Self.modelOnlyProfile(
                chineseDisplayName: "俄语",
                englishDisplayName: "Russian",
                speechLocaleIdentifier: "ru-RU"
            )
        }
    }

    public var chineseDisplayName: String {
        profile.chineseDisplayName
    }

    public var englishDisplayName: String {
        profile.englishDisplayName
    }

    public var speechLocaleIdentifier: String {
        profile.speechLocaleIdentifier
    }

    public var supportsDictionaryRouting: Bool {
        profile.supportsDictionaryRouting
    }

    public var supportsPartsOfSpeech: Bool {
        profile.supportsPartsOfSpeech
    }

    public var supportsMultipleMeanings: Bool {
        profile.supportsMultipleMeanings
    }

    public var supportsSpeechAccents: Bool {
        profile.supportsSpeechAccents
    }

    public var allowsHanOutput: Bool {
        profile.allowsHanOutput
    }

    private static func modelOnlyProfile(
        chineseDisplayName: String,
        englishDisplayName: String,
        speechLocaleIdentifier: String
    ) -> Profile {
        Profile(
            chineseDisplayName: chineseDisplayName,
            englishDisplayName: englishDisplayName,
            speechLocaleIdentifier: speechLocaleIdentifier,
            supportsDictionaryRouting: false,
            supportsPartsOfSpeech: false,
            supportsMultipleMeanings: false,
            supportsSpeechAccents: false,
            allowsHanOutput: false
        )
    }
}

public struct TranslationDirection:
    Codable, Sendable, Equatable, Hashable
{
    public let source: TranslationSourceLanguage
    public let target: TranslationTarget

    public init(
        source: TranslationSourceLanguage = .simplifiedChinese,
        target: TranslationTarget
    ) {
        self.source = source
        self.target = target
    }
}

public extension TranslationDirection {
    static let simplifiedChineseToEnglish =
        TranslationDirection(target: .english)
    static let simplifiedChineseToJapanese =
        TranslationDirection(target: .japanese)
    static let simplifiedChineseToSpanish =
        TranslationDirection(target: .spanish)
    static let simplifiedChineseToFrench =
        TranslationDirection(target: .french)
    static let simplifiedChineseToGerman =
        TranslationDirection(target: .german)
    static let simplifiedChineseToRussian =
        TranslationDirection(target: .russian)
}

public struct TranslationRequest: Sendable, Equatable {
    public let candidate: Candidate
    public let direction: TranslationDirection

    public init(
        candidate: Candidate,
        direction: TranslationDirection
    ) {
        self.candidate = candidate
        self.direction = direction
    }
}

public enum TranslationReadiness:
    Sendable, Equatable
{
    case idle
    case preparing(TranslationTarget)
    case ready(TranslationTarget)
    case needsSetup(TranslationTarget, String)
    case failed(TranslationTarget, String)
    case unsupported(TranslationTarget)
    case superseded
}
