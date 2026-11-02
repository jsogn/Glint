import Foundation
import XCTest

@testable import GlintUI

@MainActor
final class AppUpdateModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private actor ReleaseFetchCounter {
        private var count = 0
        private let release: AppRelease?
        private let succeedsOnlyOnce: Bool

        init(
            release: AppRelease? = nil,
            succeedsOnlyOnce: Bool = false
        ) {
            self.release = release
            self.succeedsOnlyOnce = succeedsOnlyOnce
        }

        func next() throws -> AppRelease {
            count += 1
            guard
                let release,
                !succeedsOnlyOnce || count == 1
            else {
                throw URLError(.notConnectedToInternet)
            }
            return release
        }

        var callCount: Int { count }
    }

    func testNewerReleaseBecomesAvailable() async {
        let release = AppRelease(
            version: "v0.8.0",
            pageURL: URL(string: "https://example.com/releases/v0.8.0")!
        )
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            fetchLatestRelease: { release }
        )

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .available(release))
    }

    func testNewerReleaseExposesOverviewPrompt() async {
        let release = AppRelease(
            version: "v0.8.0",
            pageURL: URL(string: "https://example.com/releases/v0.8.0")!
        )
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            fetchLatestRelease: { release }
        )

        await model.checkForUpdates()

        XCTAssertEqual(
            model.overviewPrompt,
            AppUpdateOverviewPrompt(
                releaseVersion: "0.8.0",
                currentVersion: "0.7.5",
                destinationURL: release.pageURL
            )
        )
    }

    func testSameReleaseVersionBecomesUpToDate() async {
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            fetchLatestRelease: {
                AppRelease(
                    version: "v0.7.5",
                    pageURL: URL(string: "https://example.com/releases/v0.7.5")!
                )
            }
        )

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .upToDate)
        XCTAssertNil(model.overviewPrompt)
    }

    func testFailedReleaseRequestBecomesFailedState() async {
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            fetchLatestRelease: {
                throw URLError(.notConnectedToInternet)
            }
        )

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .failed)
    }

    func testInvalidCurrentVersionDoesNotReportUpToDate() async {
        let model = AppUpdateModel(
            currentVersion: "未知",
            fetchLatestRelease: {
                AppRelease(
                    version: "v0.8.0",
                    pageURL: URL(string: "https://example.com/releases/v0.8.0")!
                )
            }
        )

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .failed)
    }

    func testInvalidReleaseVersionFails() async {
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            fetchLatestRelease: {
                AppRelease(
                    version: "latest",
                    pageURL: URL(string: "https://example.com/releases")!
                )
            }
        )

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .failed)
    }

    func testAutomaticCheckPersistsAvailableRelease() async throws {
        let suiteName = "AppUpdateModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let release = AppRelease(
            version: "v0.8.0",
            pageURL: URL(string: "https://example.com/releases/v0.8.0")!
        )
        let now = now
        let fetches = ReleaseFetchCounter(release: release)
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now },
            fetchLatestRelease: { try await fetches.next() }
        )

        await model.automaticallyCheckForUpdates()

        XCTAssertEqual(model.status, .available(release))
        let callCount = await fetches.callCount
        XCTAssertEqual(callCount, 1)
        let restored = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now.addingTimeInterval(60 * 60) },
            fetchLatestRelease: {
                throw URLError(.notConnectedToInternet)
            }
        )
        XCTAssertEqual(restored.status, .available(release))
    }

    func testAutomaticCheckSkipsWithinCooldown() async throws {
        let suiteName = "AppUpdateModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let release = AppRelease(
            version: "v0.8.0",
            pageURL: URL(string: "https://example.com/releases/v0.8.0")!
        )
        let now = now
        let fetches = ReleaseFetchCounter(release: release)
        let first = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now },
            fetchLatestRelease: { try await fetches.next() }
        )
        await first.automaticallyCheckForUpdates()

        let second = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now.addingTimeInterval(23 * 60 * 60) },
            fetchLatestRelease: { try await fetches.next() }
        )
        await second.automaticallyCheckForUpdates()

        let callCount = await fetches.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(second.status, .available(release))
    }

    func testAutomaticCheckFailureStaysSilent() async throws {
        let suiteName = "AppUpdateModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = now
        let fetches = ReleaseFetchCounter()
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now },
            fetchLatestRelease: { try await fetches.next() }
        )

        await model.automaticallyCheckForUpdates()
        await model.automaticallyCheckForUpdates()

        XCTAssertEqual(model.status, .idle)
        let callCount = await fetches.callCount
        XCTAssertEqual(callCount, 1)
    }

    func testManualCheckBypassesCooldownAndReportsFailure()
        async throws
    {
        let suiteName = "AppUpdateModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetches = ReleaseFetchCounter(
            release: AppRelease(
                version: "v0.8.0",
                pageURL: URL(
                    string: "https://example.com/releases/v0.8.0"
                )!
            ),
            succeedsOnlyOnce: true
        )
        let now = now
        let model = AppUpdateModel(
            currentVersion: "0.7.5",
            defaults: defaults,
            now: { now },
            fetchLatestRelease: { try await fetches.next() }
        )
        await model.automaticallyCheckForUpdates()

        await model.checkForUpdates()

        XCTAssertEqual(model.status, .failed)
        let callCount = await fetches.callCount
        XCTAssertEqual(callCount, 2)
    }
}
