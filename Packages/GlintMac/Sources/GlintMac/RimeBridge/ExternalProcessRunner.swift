import Darwin
import Foundation

enum ExternalProcessRunnerError: Error, Equatable {
    case launchFailed
    case timedOut
}

enum ExternalProcessRunner {
    static func run(
        _ process: Process,
        timeout: TimeInterval
    ) throws -> Int32 {
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw ExternalProcessRunnerError.launchFailed
        }
        let deadline =
            DispatchTime.now()
            + .milliseconds(Int(max(timeout, 0.001) * 1_000))
        guard finished.wait(timeout: deadline) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning {
                    _ = Darwin.kill(
                        process.processIdentifier,
                        SIGKILL
                    )
                }
                _ = finished.wait(timeout: .now() + 1)
            }
            throw ExternalProcessRunnerError.timedOut
        }
        return process.terminationStatus
    }
}
