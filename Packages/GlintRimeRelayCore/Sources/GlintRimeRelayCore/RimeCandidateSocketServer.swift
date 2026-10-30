import Darwin
import Foundation
import os

public final class RimeCandidateSocketServer: @unchecked Sendable {
    private struct State: Sendable {
        var listener: Int32 = -1
        var isStarting = false
        var stopped = false
    }

    private let socketPath: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start(
        onLine: @escaping @Sendable (Data) -> Void
    ) -> Bool {
        let claimed = state.withLock { current -> Bool in
            guard
                current.listener < 0,
                !current.isStarting,
                !current.stopped
            else {
                return false
            }
            current.isStarting = true
            return true
        }
        guard claimed else { return false }
        var installed = false
        defer {
            if !installed {
                state.withLock { $0.isStarting = false }
            }
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard
            !socketPath.isEmpty,
            pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path),
            prepareSocketPath()
        else {
            return false
        }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { return false }
        _ = Darwin.fcntl(
            listener,
            F_SETFD,
            FD_CLOEXEC
        )
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    listener,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard
            bindResult == 0,
            chmod(socketPath, S_IRUSR | S_IWUSR) == 0,
            Darwin.listen(listener, 4) == 0
        else {
            Darwin.close(listener)
            unlink(socketPath)
            return false
        }
        let accepted = state.withLock { current -> Bool in
            guard
                current.isStarting,
                current.listener < 0,
                !current.stopped
            else {
                return false
            }
            current.isStarting = false
            current.listener = listener
            return true
        }
        installed = accepted
        guard accepted else {
            Darwin.close(listener)
            unlink(socketPath)
            return false
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            acceptLoop(onLine: onLine)
        }
        return true
    }

    public func stop() {
        let listener = state.withLock { current -> Int32 in
            guard !current.stopped else { return -1 }
            current.stopped = true
            let listener = current.listener
            current.listener = -1
            return listener
        }
        guard listener >= 0 else { return }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
    }

    private func acceptLoop(
        onLine: @escaping @Sendable (Data) -> Void
    ) {
        while true {
            let listener = state.withLock { current -> Int32 in
                current.stopped ? -1 : current.listener
            }
            guard listener >= 0 else { return }
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else {
                if state.withLock({ $0.stopped }) {
                    return
                }
                if errno == EINTR { continue }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            DispatchQueue.global(qos: .utility).async {
                _ = Darwin.fcntl(
                    client,
                    F_SETFD,
                    FD_CLOEXEC
                )
                Self.handleClient(client, onLine: onLine)
            }
        }
    }

    private static func handleClient(
        _ client: Int32,
        onLine: @escaping @Sendable (Data) -> Void
    ) {
        defer { Darwin.close(client) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(client, $0.baseAddress, $0.count)
            }
            if count == 0 {
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                if !line.isEmpty {
                    onLine(Data(line))
                }
            }
            if pending.count > 1_048_576 {
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    private func prepareSocketPath() -> Bool {
        let parent = URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        var status = stat()
        guard lstat(socketPath, &status) == 0 else {
            return true
        }
        guard
            (status.st_mode & S_IFMT) == S_IFSOCK,
            status.st_uid == getuid()
        else {
            return false
        }
        return unlink(socketPath) == 0
    }
}
