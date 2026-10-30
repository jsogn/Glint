import Foundation
import GlintCore
import GlintRimeRelayCore
import os

public final class RimeCandidateSnapshotStore: @unchecked Sendable {
    private struct Entry: Sendable {
        let envelope: RimeCandidateEnvelope
        let timestamp: UInt64
    }

    private struct State: Sendable {
        var entry: Entry?
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let clock: @Sendable () -> UInt64

    public convenience init() {
        self.init(clock: {
            DispatchTime.now().uptimeNanoseconds
        })
    }

    init(
        clock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) {
        self.clock = clock
        lock = OSAllocatedUnfairLock(initialState: State())
    }

    public func record(_ envelope: RimeCandidateEnvelope) {
        guard envelope.isValid else { return }
        lock.withLock { state in
            if envelope.heartbeat {
                guard
                    let entry = state.entry,
                    entry.envelope.sessionID == envelope.sessionID,
                    entry.envelope.sequence == envelope.sequence
                else {
                    return
                }
                state.entry = Entry(
                    envelope: entry.envelope,
                    timestamp: clock()
                )
                return
            }
            if !envelope.active {
                if let entry = state.entry,
                    entry.envelope.sessionID == envelope.sessionID,
                    envelope.sequence >= entry.envelope.sequence
                {
                    state.entry = nil
                }
                return
            }
            if let entry = state.entry,
                entry.envelope.sessionID == envelope.sessionID,
                envelope.sequence < entry.envelope.sequence
            {
                return
            }
            state.entry = Entry(
                envelope: envelope,
                timestamp: clock()
            )
        }
    }

    func latest(
        maxAgeNanoseconds: UInt64
    ) -> RimeCandidateEnvelope? {
        let now = clock()
        return lock.withLock { state in
            guard let entry = state.entry,
                entry.envelope.active,
                now >= entry.timestamp,
                now - entry.timestamp <= maxAgeNanoseconds
            else {
                return nil
            }
            return entry.envelope
        }
    }
}
