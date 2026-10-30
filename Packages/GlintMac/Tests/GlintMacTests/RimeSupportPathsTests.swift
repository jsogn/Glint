import Foundation
import XCTest
@testable import GlintMac

final class RimeSupportPathsTests: XCTestCase {
    func testSupportDirectoryUsesProductionName() {
        let applicationSupport = URL(
            fileURLWithPath: "/tmp/Application Support",
            isDirectory: true
        )

        XCTAssertEqual(
            RimeSupportPaths.supportDirectory(
                applicationSupportDirectory: applicationSupport
            ),
            applicationSupport
                .appendingPathComponent("Glint", isDirectory: true)
                .appendingPathComponent(
                    "RimeCandidateSupport",
                    isDirectory: true
                )
        )
    }

    func testSocketPathIsOwnedBySupportDirectory() {
        let supportDirectory = URL(
            fileURLWithPath: "/tmp/RimeCandidateSupport",
            isDirectory: true
        )

        XCTAssertEqual(
            URL(
                fileURLWithPath: RimeSupportPaths.socketPath(
                    in: supportDirectory
                )
            ),
            supportDirectory.appendingPathComponent("bridge.sock")
        )
    }
}
