import CoreGraphics
import Dispatch
import Foundation
import GlintCore
import OSLog

let monitoringLogger = Logger(
    subsystem: "com.local.glint",
    category: "Monitoring"
)

public actor MonitoringController {
    let inputSource: any InputSourceReading
    let focus: any FocusReading
    let candidateReaders: any CandidateReaderRouting
    let hostAccessibilityActivator: any HostAccessibilityActivating
    let accessibilityIsTrusted: @Sendable () -> Bool
    let secureInputIsEnabled: @Sendable () -> Bool
    let translationTextInserter: any TranslationTextInserting
    let ownProcessIdentifier: pid_t
    let router: SmartRouter
    let stream: AsyncStream<MonitoringEvent>
    let continuation: AsyncStream<MonitoringEvent>.Continuation
    let translationMemo = TranslationMemo()
    var task: Task<Void, Never>?
    var translationTask: Task<Void, Never>?
    var mode: TranslationMode = .dictionaryFirst
    var translationTarget: TranslationTarget = .english
    var translationScope: CandidateTranslationScope = .selected
    var showsPartsOfSpeech = true
    var maximumTranslationCount = 4
    var candidateDwellNanoseconds: UInt64 = 100_000_000
    var translationConfigurationToken = "target=en"
    var typingTracker = TypingActivityTracker()
    var handledRevision: UInt64?
    var dwellDetectedAt: ContinuousClock.Instant?
    var translationStartedAt: ContinuousClock.Instant?
    var candidateChangedAtNanoseconds: UInt64?
    var dwellConfirmedAtNanoseconds: UInt64?
    var translationAttempts: UInt64 = 0
    var cancelledTranslationAttempts: UInt64 = 0
    var lastPermissionCheck: UInt64 = 0
    var lastStatus = ""
    var cachedInputSource: ActiveInputSource?
    var lastInputSourceCheck: UInt64 = 0
    var lastReportedInputMethod: InputMethodIdentity?
    var candidateSessionActive = false
    var latestInputCaretRect: CGRect?
    var latestInputFieldRect: CGRect?
    var latestCandidateSurfaceFrame: CGRect?
    var latestCandidateLayoutOrientation: CandidateLayoutOrientation = .unknown
    var lastPublishedLayout: CandidateLayoutSnapshot?
    var selectedCandidateIndex: Int?
    var selectedCandidateIndexIsExact = false
    var latestCandidateHighlight: CandidateRegion?
    var insertionOffer: TranslationChoiceOffer?
    var insertionHostProcessIdentifier: pid_t?
    var dictionaryPrefetchRevision: UInt64?
    var dictionaryPrefetchTasks: [Int: Task<TranslationResult?, Never>] = [:]
    var cachedPrefetchResults: [Int: TranslationResult] = [:]
    var candidateMissDebouncer = CandidateMissDebouncer()
    var compositionTransitions = CompositionTransitionTracker()
    var hostAccessibilityAttempts: [HostProcessSession: HostAccessibilityAttempt] = [:]

    public init(router: SmartRouter) {
        self.init(router: router, rimeCandidateStore: nil)
    }

    public init(
        router: SmartRouter,
        rimeCandidateStore: RimeCandidateSnapshotStore?
    ) {
        self.init(
            router: router,
            inputSource: InputSourceMonitor(),
            focus: FocusMonitor(),
            candidateReaders:
                CandidateReaderConfiguration.standard(
                    rimeCandidateStore: rimeCandidateStore
                ),
            hostAccessibilityActivator:
                AXHostAccessibilityActivator(),
            accessibilityIsTrusted: {
                FocusMonitor.isAccessibilityTrusted()
            },
            secureInputIsEnabled: {
                FocusMonitor.isSecureInputEnabled()
            },
            translationTextInserter: SystemTranslationTextInserter()
        )
    }

    init(
        router: SmartRouter,
        inputSource: any InputSourceReading,
        focus: any FocusReading,
        candidateReaders: any CandidateReaderRouting,
        hostAccessibilityActivator:
            any HostAccessibilityActivating =
            DisabledHostAccessibilityActivator(),
        accessibilityIsTrusted: @escaping @Sendable () -> Bool,
        secureInputIsEnabled: @escaping @Sendable () -> Bool,
        translationTextInserter: any TranslationTextInserting =
            SystemTranslationTextInserter(),
        ownProcessIdentifier: pid_t =
            ProcessInfo.processInfo.processIdentifier
    ) {
        self.inputSource = inputSource
        self.focus = focus
        self.candidateReaders = candidateReaders
        self.hostAccessibilityActivator =
            hostAccessibilityActivator
        self.accessibilityIsTrusted = accessibilityIsTrusted
        self.secureInputIsEnabled = secureInputIsEnabled
        self.translationTextInserter = translationTextInserter
        self.ownProcessIdentifier = ownProcessIdentifier
        self.router = router
        let pair = AsyncStream.makeStream(of: MonitoringEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation
    }

    public var events: AsyncStream<MonitoringEvent> {
        stream
    }

    public func setMode(_ mode: TranslationMode) {
        guard self.mode != mode else { return }
        self.mode = mode
        invalidateCandidate(immediate: true)
    }

    public func setTranslationTarget(
        _ target: TranslationTarget
    ) {
        guard translationTarget != target else { return }
        translationTarget = target
        invalidateCandidate(immediate: true)
    }

    public func setCandidateDwellDuration(_ seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = min(max(seconds, 0.08), 0.3)
        candidateDwellNanoseconds = UInt64(clamped * 1_000_000_000)
    }

    var configuredCandidateDwellNanoseconds: UInt64 {
        candidateDwellNanoseconds
    }

    public func setTranslationScope(
        _ scope: CandidateTranslationScope
    ) {
        guard translationScope != scope else { return }
        translationScope = scope
        invalidateCandidate(immediate: true)
    }

    public func setMaximumTranslationCount(_ count: Int) {
        let clamped = min(
            max(
                count,
                CandidateTranslationPipeline
                    .maximumTranslationCountRange.lowerBound
            ),
            CandidateTranslationPipeline
                .maximumTranslationCountRange.upperBound
        )
        guard maximumTranslationCount != clamped else { return }
        maximumTranslationCount = clamped
        invalidateCandidate(immediate: true)
    }

    var configuredMaximumTranslationCount: Int {
        maximumTranslationCount
    }

    public func setShowsPartsOfSpeech(_ enabled: Bool) {
        guard showsPartsOfSpeech != enabled else { return }
        showsPartsOfSpeech = enabled
        invalidateCandidate(immediate: true)
    }

    var configuredShowsPartsOfSpeech: Bool {
        showsPartsOfSpeech
    }

    public func setTranslationConfigurationToken(_ token: String) async {
        guard token != translationConfigurationToken else { return }
        translationConfigurationToken = token
        invalidateCandidate(immediate: true)
        await translationMemo.clear()
    }

}
