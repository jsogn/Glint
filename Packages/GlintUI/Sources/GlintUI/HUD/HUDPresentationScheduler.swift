import Foundation

enum HUDContentUpdate: Equatable {
    case entry
    case patch
    case transition
}

@MainActor
final class HUDPresentationScheduler {
    private enum Timing {
        static let coalescingNanoseconds: UInt64 = 8_000_000
        static let staleDimNanoseconds: UInt64 = 80_000_000
    }

    private let present: @MainActor (HUDPresentationRequest) -> Void
    private let dimStaleContent: @MainActor () -> Void
    private var coalescedRequest: HUDPresentationRequest?
    private var pendingRequest: HUDPresentationRequest?
    private var coalescingTask: Task<Void, Never>?
    private var staleDimTask: Task<Void, Never>?
    private var staleDimGeneration = 0

    init(
        present: @escaping @MainActor (HUDPresentationRequest) -> Void,
        dimStaleContent: @escaping @MainActor () -> Void
    ) {
        self.present = present
        self.dimStaleContent = dimStaleContent
    }

    var isStaleDimPending: Bool {
        staleDimTask != nil
    }

    func enqueue(_ request: HUDPresentationRequest) {
        coalescedRequest = request
        guard coalescingTask == nil else { return }

        coalescingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Timing.coalescingNanoseconds
                )
                guard let self else { return }
                self.coalescingTask = nil
                guard let request = self.coalescedRequest else { return }
                self.coalescedRequest = nil
                self.present(request)
            } catch {
                return
            }
        }
    }

    func deferUntilPresentationReady(_ request: HUDPresentationRequest) {
        pendingRequest = request
    }

    func takePendingRequest() -> HUDPresentationRequest? {
        defer { pendingRequest = nil }
        return pendingRequest
    }

    func cancelQueuedPresentations() {
        coalescingTask?.cancel()
        coalescingTask = nil
        coalescedRequest = nil
        pendingRequest = nil
    }

    func startStaleDimmingIfNeeded() {
        guard staleDimTask == nil else { return }
        staleDimGeneration &+= 1
        let generation = staleDimGeneration

        staleDimTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Timing.staleDimNanoseconds
                )
                guard let self,
                    self.staleDimGeneration == generation
                else {
                    return
                }
                self.dimStaleContent()
                self.staleDimTask = nil
            } catch {
                return
            }
        }
    }

    func cancelStaleDimming() {
        staleDimGeneration &+= 1
        staleDimTask?.cancel()
        staleDimTask = nil
    }

    func reset() {
        cancelQueuedPresentations()
        cancelStaleDimming()
    }

    static func contentUpdate(
        displayedRevision: UInt64?,
        incomingRevision: UInt64?,
        isVisible: Bool
    ) -> HUDContentUpdate {
        guard isVisible else { return .entry }
        guard let displayedRevision,
            let incomingRevision,
            displayedRevision == incomingRevision
        else {
            return .transition
        }
        return .patch
    }
}
