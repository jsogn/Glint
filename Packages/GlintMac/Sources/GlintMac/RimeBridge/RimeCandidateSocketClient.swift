import Darwin
import Foundation

public enum RimeCandidateSocketClientError:
    Error,
    Equatable
{
    case invalidSocketPath
    case socketCreationFailed
    case connectionFailed
    case writeFailed
}

public final class RimeCandidateSocketClient: @unchecked Sendable {
    private let socketPath: String
    private var descriptor: Int32 = -1

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public var isConnected: Bool {
        descriptor >= 0
    }

    deinit {
        close()
    }

    public func send(_ line: Data) throws {
        if descriptor < 0 {
            try connect()
        }
        do {
            try writeAll(line)
            try writeAll(Data([0x0A]))
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func connect() throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard
            !socketPath.isEmpty,
            pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path)
        else {
            throw RimeCandidateSocketClientError.invalidSocketPath
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw RimeCandidateSocketClientError.socketCreationFailed
        }
        var noSignal: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        )
        var sendTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout.size(ofValue: sendTimeout))
        )
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            Darwin.close(socketDescriptor)
            throw RimeCandidateSocketClientError.connectionFailed
        }
        descriptor = socketDescriptor
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw RimeCandidateSocketClientError.writeFailed
                }
                offset += written
            }
        }
    }
}
