import Foundation
import GlintCore

public enum MonitoringSessionState: Sendable, Equatable {
    case idle
    case starting
    case running
    case stopping
}

public enum MonitoringSessionEvent: Sendable {
    case state(MonitoringSessionState)
    case monitoring(MonitoringEvent)
}

public struct MonitoringSettings: Sendable, Equatable {
    public let mode: TranslationMode
    public let candidateDwellDuration: Double
    public let translationScope: CandidateTranslationScope
    public let maximumTranslationCount: Int
    public let configurationToken: String

    public init(
        mode: TranslationMode,
        candidateDwellDuration: Double,
        translationScope: CandidateTranslationScope,
        maximumTranslationCount: Int = 4,
        configurationToken: String
    ) {
        self.mode = mode
        self.candidateDwellDuration = candidateDwellDuration
        self.translationScope = translationScope
        self.maximumTranslationCount = maximumTranslationCount
        self.configurationToken = configurationToken
    }
}

/// Owns one long-lived observation stream for the monitoring controller.
///
/// The controller's stream can only be consumed once, and cancelling that
/// consumer terminates it permanently. The session keeps its pump for the
/// lifetime of the app; start/stop only control the controller loop.
public actor MonitoringSession {
    public private(set) var state: MonitoringSessionState = .idle

    private let controller: MonitoringController
    private let stream: AsyncStream<MonitoringSessionEvent>
    private let continuation: AsyncStream<MonitoringSessionEvent>.Continuation
    private var pending: [Intent] = []
    private var isProcessing = false

    private enum Intent: Sendable {
        case start(MonitoringSettings)
        case stop
    }

    public init(controller: MonitoringController) {
        self.controller = controller

        let pair = AsyncStream.makeStream(of: MonitoringSessionEvent.self)
        self.stream = pair.stream
        self.continuation = pair.continuation

        let continuation = pair.continuation
        Task {
            let events = await controller.events
            for await event in events {
                continuation.yield(.monitoring(event))
            }
        }
    }

    public var events: AsyncStream<MonitoringSessionEvent> {
        stream
    }

    public func start(_ settings: MonitoringSettings) {
        enqueue(.start(settings))
    }

    public func stop() {
        enqueue(.stop)
    }

    public func insertTranslation(
        _ offer: TranslationChoiceOffer,
        choiceIndex: Int
    ) async -> Bool {
        await controller.insertTranslation(
            offer,
            choiceIndex: choiceIndex
        )
    }

    private func enqueue(_ intent: Intent) {
        pending.append(intent)
        guard !isProcessing else { return }
        isProcessing = true
        Task { await self.processPending() }
    }

    private func processPending() async {
        while !pending.isEmpty {
            let intent = pending.removeFirst()
            switch intent {
            case .start(let settings):
                await applyStart(settings)
            case .stop:
                await applyStop()
            }
        }
        isProcessing = false
    }

    private func applyStart(_ settings: MonitoringSettings) async {
        guard state == .idle else { return }

        state = .starting
        continuation.yield(.state(.starting))
        await controller.setMode(settings.mode)
        await controller.setCandidateDwellDuration(
            settings.candidateDwellDuration
        )
        await controller.setTranslationScope(settings.translationScope)
        await controller.setMaximumTranslationCount(
            settings.maximumTranslationCount
        )
        await controller.setTranslationConfigurationToken(
            settings.configurationToken
        )
        await controller.start()
        state = .running
        continuation.yield(.state(.running))
    }

    private func applyStop() async {
        guard state != .idle else { return }

        state = .stopping
        continuation.yield(.state(.stopping))
        await controller.stop()
        state = .idle
        continuation.yield(.state(.idle))
    }
}
