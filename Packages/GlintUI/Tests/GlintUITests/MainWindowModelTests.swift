import Foundation
import GlintPlugins
import XCTest
@testable import GlintUI

final class MainWindowModelTests: XCTestCase {
    @MainActor
    func testRequestPermissionsForwardsToAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GlintMainWindowModelTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "GlintMainWindowModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        var requestCount = 0
        model.requestPermissionsAction = {
            requestCount += 1
        }

        model.requestPermissions()

        XCTAssertEqual(requestCount, 1)
    }
}
