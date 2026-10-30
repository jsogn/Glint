import Foundation
import XCTest
@testable import GlintMac

final class ExternalProcessRunnerTests: XCTestCase {
    func testReturnsTerminationStatus() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 7"]

        let status = try ExternalProcessRunner.run(
            process,
            timeout: 1
        )

        XCTAssertEqual(status, 7)
    }

    func testTerminatesProcessThatExceedsTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]

        XCTAssertThrowsError(
            try ExternalProcessRunner.run(
                process,
                timeout: 0.1
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalProcessRunnerError,
                .timedOut
            )
        }
        XCTAssertFalse(process.isRunning)
    }
}
