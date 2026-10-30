import Foundation
import GlintCore

public final class RimeCandidateBridgeReceiver: @unchecked Sendable {
    public static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(
                "Application Support",
                isDirectory: true
            )
            .appendingPathComponent(
                "Glint/RimeCandidateLab",
                isDirectory: true
            )
            .appendingPathComponent("bridge.sock")
            .path
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
