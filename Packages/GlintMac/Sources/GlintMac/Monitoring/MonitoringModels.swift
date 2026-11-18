import CoreGraphics
import Foundation
import GlintCore

public struct CandidateRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct CandidateMissDebouncer: Sendable {
    private let threshold: Int
    private var consecutiveMisses = 0

    init(threshold: Int = 2) {
        self.threshold = max(1, threshold)
    }

    mutating func observeCandidate() {
        consecutiveMisses = 0
    }

    mutating func observeMiss() -> Bool {
        consecutiveMisses += 1
        return consecutiveMisses >= threshold
    }

    mutating func reset() {
        consecutiveMisses = 0
    }
}

struct CompositionTransitionTracker: Sendable {
    private var previousState: TextCompositionState = .unknown

    mutating func observe(_ state: TextCompositionState) -> Bool {
        let ended = previousState == .composing && state == .inactive
        previousState = state
        return ended
    }

    mutating func reset() {
        previousState = .unknown
    }
}

struct CandidatePollingPolicy: Sendable {
    static let activeInterval: UInt64 = 40_000_000
    static let stableInterval: UInt64 = 80_000_000
    static let minimumPreDwellInterval: UInt64 = 10_000_000

    static func interval(
        isDwelling: Bool,
        nanosecondsUntilDwell: UInt64?
    ) -> UInt64 {
        guard !isDwelling else {
            return stableInterval
        }
        guard let nanosecondsUntilDwell else {
            return activeInterval
        }
        return min(
            activeInterval,
            max(
                minimumPreDwellInterval,
                nanosecondsUntilDwell
            )
        )
    }
}

public enum MonitoringEvent: Sendable {
    case status(String)
    case inputSourceChanged(InputMethodIdentity)
    case candidateChanged(revision: UInt64)
    case selectionChanged(index: Int, revision: UInt64)
    case layoutChanged(
        CandidateRegion,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation
    )
    case candidateEnded(immediate: Bool)
    case results(
        [CandidateTranslationPresentation],
        CandidateRegion,
        inputCaretRect: CGRect?,
        inputFieldRect: CGRect?,
        candidateSurfaceRect: CGRect?,
        candidateLayoutOrientation: CandidateLayoutOrientation,
        revision: UInt64,
        isProgressive: Bool
    )
    case insertionOffer(TranslationChoiceOffer)
}

struct CandidateTrackingIdentity: Sendable, Equatable {
    let text: String
    let frame: CGRect

    static func make(
        scope: CandidateTranslationScope,
        selectedText: String,
        selectedFrame: CGRect,
        rowTexts: [String],
        rowFrame: CGRect
    ) -> CandidateTrackingIdentity {
        switch scope {
        case .selected:
            return CandidateTrackingIdentity(
                text: selectedText,
                frame: selectedFrame
            )
        case .row:
            return CandidateTrackingIdentity(
                text: rowTexts.joined(separator: "\u{1F}"),
                frame: rowFrame
            )
        }
    }
}

public struct CandidateTranslationOptionPresentation:
    Sendable, Equatable
{
    public let text: String
    public let partsOfSpeech: [PartOfSpeech]

    public init(text: String, partsOfSpeech: [PartOfSpeech]) {
        self.text = text
        self.partsOfSpeech =
            PartOfSpeech.singleEnglishWordKey(text) != nil
            ? PartOfSpeech.normalized(partsOfSpeech)
            : []
    }
}

public struct CandidateTranslationPresentation: Sendable, Equatable {
    public let index: Int
    public let candidateText: String
    public let translation: String?
    public let insertionOptions: [String]
    public let displayOptions: [CandidateTranslationOptionPresentation]
    public let isSelected: Bool

    public var hasTranslation: Bool {
        translation != nil
    }

    public init(
        index: Int,
        candidateText: String,
        translation: String?,
        insertionOptions: [String] = [],
        displayOptions: [CandidateTranslationOptionPresentation] = [],
        isSelected: Bool
    ) {
        self.index = index
        self.candidateText = candidateText
        self.translation = translation
        self.insertionOptions = insertionOptions
        self.displayOptions = displayOptions
        self.isSelected = isSelected
    }
}
