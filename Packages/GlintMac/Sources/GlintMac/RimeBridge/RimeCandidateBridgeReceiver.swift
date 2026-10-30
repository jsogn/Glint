import Foundation
import GlintCore
import GlintRimeRelayCore

public final class RimeCandidateBridgeReceiver: @unchecked Sendable {
    public static var defaultSocketPath: String {
        RimeSupportPaths.socketPath(
            in: RimeSupportPaths.defaultSupportDirectory
        )
    }

    public let store: RimeCandidateSnapshotStore
    private let server: RimeCandidateSocketServer

    public init(
        socketPath: String =
            RimeCandidateBridgeReceiver.defaultSocketPath,
        store: RimeCandidateSnapshotStore =
            RimeCandidateSnapshotStore()
    ) {
        self.store = store
        server = RimeCandidateSocketServer(socketPath: socketPath)
    }

    @discardableResult
    public func start() -> Bool {
        server.start { [weak self] line in
            self?.handle(line: line)
        }
    }

    public func stop() {
        server.stop()
    }

    func handle(line: Data) {
        guard
            let envelope = try? RimeCandidateEnvelope.decode(
                line: line
            )
        else {
            return
        }
        store.record(envelope)
    }
}
