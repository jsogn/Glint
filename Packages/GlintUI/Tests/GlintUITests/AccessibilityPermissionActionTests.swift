import Foundation
import XCTest

@testable import GlintUI

final class AccessibilityPermissionActionTests: XCTestCase {
    @MainActor
    func testPerformRequestsPermissionBeforeUserHasBeenAsked() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        var requested = false
        var openedSettings = false
        model.requestPermissionsAction = { requested = true }
        model.openAccessibilitySettingsAction = { openedSettings = true }

        let action = AccessibilityPermissionAction(model: model)
        XCTAssertEqual(action.title, "授权辅助功能")
        XCTAssertEqual(action.symbol, "lock.open")
        XCTAssertEqual(
            action.guidance,
            "macOS 会请求你允许 Glint 使用辅助功能。"
        )

        action.perform()

        XCTAssertTrue(requested)
        XCTAssertFalse(openedSettings)
    }

    @MainActor
    func testPerformOpensSettingsAfterUserHasBeenAsked() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        model.hasRequestedAccessibilityPermission = true
        var requested = false
        var openedSettings = false
        model.requestPermissionsAction = { requested = true }
        model.openAccessibilitySettingsAction = { openedSettings = true }

        let action = AccessibilityPermissionAction(model: model)
        XCTAssertEqual(action.title, "打开辅助功能设置")
        XCTAssertEqual(action.symbol, "gearshape")
        XCTAssertEqual(
            action.guidance,
            "在系统设置中开启 Glint，返回后会自动更新状态。"
        )

        action.perform()

        XCTAssertFalse(requested)
        XCTAssertTrue(openedSettings)
    }

    @MainActor
    private func makeModel() throws -> (
        MainWindowModel, UserDefaults, String
    ) {
        let suite = "GlintPermissionActionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = DisplayPreferences(defaults: defaults)
        let model = MainWindowModel(
            displayPreferences: preferences,
            defaults: defaults
        )
        return (model, defaults, suite)
    }
}
