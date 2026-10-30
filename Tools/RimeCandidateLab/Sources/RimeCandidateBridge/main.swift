import CryptoKit
import Darwin
import Foundation
import GlintRimeRelayCore

signal(SIGPIPE, SIG_IGN)

private struct Options {
    let mode: String
    let socketPath: String
    let showText: Bool
}

private func parseOptions() -> Options? {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard !arguments.isEmpty else { return nil }
    let mode = arguments.removeFirst()
    guard mode == "relay" || mode == "monitor" else {
        return nil
    }
    var socketPath: String?
    var showText = false
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--socket":
            guard !arguments.isEmpty else { return nil }
            socketPath = arguments.removeFirst()
        case "--show-text":
            showText = true
        default:
            return nil
        }
    }
    guard let socketPath else { return nil }
    return Options(
        mode: mode,
        socketPath: socketPath,
        showText: showText
    )
}

private func makeHeartbeatLine(from line: Data) -> Data? {
    guard
        let json = try? JSONSerialization.jsonObject(with: line),
        let dictionary = json as? [String: Any]
    else {
        return nil
    }
    var heartbeat = dictionary
    heartbeat["heartbeat"] = true
    return try? JSONSerialization.data(withJSONObject: heartbeat)
}

private func runRelay(socketPath: String) -> Never {
    let client = RimeCandidateSocketClient(socketPath: socketPath)
    var pending = Data()
    var lastLine: Data?
    var lastHeartbeat: Data?
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        var descriptor = pollfd(
            fd: STDIN_FILENO,
            events: Int16(POLLIN),
            revents: 0
        )
        let pollResult = Darwin.poll(&descriptor, 1, 1_000)
        if pollResult < 0 {
            if errno == EINTR { continue }
            break
        }
        if pollResult == 0 {
            if client.isConnected, let lastHeartbeat {
                do {
                    try client.send(lastHeartbeat)
                } catch {
                    client.close()
                }
            } else if let lastLine {
                do {
                    try client.send(lastLine)
                } catch {
                    client.close()
                }
            }
            continue
        }
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            break
        }
        pending.append(contentsOf: buffer.prefix(count))
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            lastLine = line
            lastHeartbeat = makeHeartbeatLine(from: line)
            do {
                try client.send(line)
            } catch {
                client.close()
            }
        }
        if pending.count > 1_048_576 {
            pending.removeAll(keepingCapacity: true)
        }
    }
    client.close()
    exit(EXIT_SUCCESS)
}

private func digestPrefix(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8))
        .prefix(8)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func runMonitor(
    socketPath: String,
    showText: Bool
) -> Never {
    do {
        let server = RimeCandidateSocketServer(
            socketPath: socketPath
        )
        let outputQueue = DispatchQueue(
            label: "com.local.glint.rime-candidate-output"
        )
        guard
            server.start(onLine: { line in
                outputQueue.async {
                    do {
                        let envelope = try RimeCandidateEnvelope.decode(
                            line: line
                        )
                        let selected: String
                        if let text = envelope.selectedText {
                            selected =
                                showText
                                ? "text=\(text) "
                                : "hash=\(digestPrefix(text)) "
                        } else {
                            selected = "selected=none "
                        }
                        print(
                            "rime-bridge active=\(envelope.active) "
                                + "heartbeat=\(envelope.heartbeat) "
                                + "session=\(envelope.sessionID) "
                                + "sequence=\(envelope.sequence) "
                                + "schema=\(envelope.schemaID ?? "-") "
                                + "count=\(envelope.candidates.count) "
                                + "index=\(envelope.selectedIndex.map(String.init) ?? "-") "
                                + selected
                        )
                        fflush(stdout)
                    } catch {
                        print("rime-bridge invalid=envelope")
                        fflush(stdout)
                    }
                }
            })
        else {
            throw UnixSocketMonitorError.startFailed
        }
        print("rime-bridge listening=\(socketPath)")
        fflush(stdout)
        withExtendedLifetime(server) {
            dispatchMain()
        }
    } catch {
        fputs("rime-bridge error=\(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

private enum UnixSocketMonitorError: Error {
    case startFailed
}

guard let options = parseOptions() else {
    fputs(
        "usage: RimeCandidateBridge relay --socket <path>\n"
            + "       RimeCandidateBridge monitor --socket <path> [--show-text]\n",
        stderr
    )
    exit(EXIT_FAILURE)
}

switch options.mode {
case "relay":
    runRelay(socketPath: options.socketPath)
case "monitor":
    runMonitor(
        socketPath: options.socketPath,
        showText: options.showText
    )
default:
    exit(EXIT_FAILURE)
}
