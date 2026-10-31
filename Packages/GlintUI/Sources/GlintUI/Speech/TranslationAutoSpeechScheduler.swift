import Foundation

@MainActor
public final class TranslationAutoSpeechScheduler {
    typealias Sleep = @MainActor (Duration) async throws -> Void

    private let sleep: Sleep
    private var pendingTask: Task<Void, Never>?
    private var generation = 0
    private var currentRevision: UInt64?
    private var selectedIndex: Int?
    private var translations: [Int: String] = [:]
    private var delayElapsed = false
    private var selectionWasSpecified = false
    private var handledRevision: UInt64?

    public var onSpeak: (@MainActor (String) -> Void)?

    public convenience init() {
        self.init { duration in
            try await Task.sleep(for: duration)
        }
    }

    init(
        sleep: @escaping Sleep
    ) {
        self.sleep = sleep
    }

    public func candidateChanged(
        revision: UInt64,
        delay: Double
    ) {
        currentRevision = revision
        selectedIndex = nil
        translations = [:]
        delayElapsed = false
        selectionWasSpecified = false
        handledRevision = nil
        restartDelay(seconds: delay)
    }

    public func selectionChanged(
        index: Int,
        revision: UInt64,
        delay: Double
    ) {
        guard currentRevision == revision,
            handledRevision != revision
        else {
            return
        }
        selectedIndex = index
        selectionWasSpecified = true
        restartDelay(seconds: delay)
    }

    public func updateTranslations(
        _ values: [Int: String],
        revision: UInt64,
        selectedIndex: Int? = nil
    ) {
        guard currentRevision == revision,
            handledRevision != revision
        else {
            return
        }
        for (index, value) in values {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty {
                translations[index] = trimmed
            }
        }
        if !selectionWasSpecified,
            let selectedIndex
        {
            self.selectedIndex = selectedIndex
        }
        speakIfReady()
    }

    public func setDelay(_ delay: Double) {
        guard currentRevision != nil,
            handledRevision != currentRevision
        else {
            return
        }
        restartDelay(seconds: delay)
    }

    public func manualSpeechStarted() {
        guard let currentRevision else { return }
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        delayElapsed = false
        handledRevision = currentRevision
    }

    public func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        currentRevision = nil
        translations = [:]
        delayElapsed = false
        selectionWasSpecified = false
        handledRevision = nil
    }

    func waitForPendingTimer() async {
        await pendingTask?.value
    }

    private func restartDelay(seconds: Double) {
        pendingTask?.cancel()
        generation += 1
        let currentGeneration = generation
        delayElapsed = false
        let duration = Duration.milliseconds(
            Int64((max(seconds, 0) * 1_000).rounded())
        )
        pendingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard !Task.isCancelled,
                generation == currentGeneration
            else {
                return
            }
            pendingTask = nil
            delayElapsed = true
            speakIfReady()
        }
    }

    private func speakIfReady() {
        guard delayElapsed,
            let currentRevision,
            handledRevision != currentRevision,
            let selectedIndex,
            let text = translations[selectedIndex]
        else {
            return
        }
        handledRevision = currentRevision
        onSpeak?(text)
    }
}
