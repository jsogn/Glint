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

    public var chineseDisplayName: String {
        switch self {
        case .english: "英语"
        case .japanese: "日语"
        }
    }

    public var supportsPartsOfSpeech: Bool {
        self == .english
    }

    public var supportsMultipleMeanings: Bool {
        self == .english
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
