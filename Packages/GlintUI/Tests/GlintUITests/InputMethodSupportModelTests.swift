import Foundation
import GlintCore
import GlintPlugins
import XCTest
@testable import GlintUI

final class InputMethodSupportModelTests: XCTestCase {
    @MainActor
    func testStartsWithNativeApplePinyinStatus() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        XCTAssertEqual(
            context.model.inputMethodSupportStatuses.map(\.id),
            [InputMethodSupportStatus.applePinyin.id]
        )
        XCTAssertEqual(
            context.model.inputMethodSupportStatuses.first?.state,
            .native
        )
    }

    @MainActor
    func testRefreshPublishesSquirrelAvailability() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let squirrel = InputMethodSupportStatus(
            id: "squirrel",
            name: "Rime",
            detail: "Rime 候选读取尚未连接",
            state: .available,
            schemaIDs: ["luna_pinyin"],
            protocolVersion: 3
        )
        context.model.refreshInputMethodSupportAction = {
            [.applePinyin, squirrel]
        }

        await context.model.refreshInputMethodSupport()

        XCTAssertEqual(
            context.model.inputMethodSupportStatuses,
            [.applePinyin, squirrel]
        )
        XCTAssertFalse(context.model.isLoadingInputMethodSupport)
        XCTAssertNil(context.model.inputMethodSupportError)
    }

    @MainActor
    func testSupportPageExcludesNativeApplePinyinStatus() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let rime = InputMethodSupportStatus(
            id: "squirrel",
            name: "Rime",
            detail: "Rime 候选读取尚未连接",
            state: .available,
            schemaIDs: ["luna_pinyin"],
            protocolVersion: 3
        )
        context.model.refreshInputMethodSupportAction = {
            [.applePinyin, rime]
        }

        await context.model.refreshInputMethodSupport()

        XCTAssertEqual(
            context.model.inputMethodSupportPageStatuses,
            [rime]
        )
    }

    func testInputMethodsSidebarUsesSupportTitle() {
        XCTAssertEqual(
            SidebarItem.inputMethods.title,
            "输入法支持"
        )
    }

    @MainActor
    func testInstallPublishesInstalledState() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let installed = InputMethodSupportStatus(
            id: "squirrel",
            name: "Rime",
            detail: "已启用",
            state: .installed,
            schemaIDs: ["luna_pinyin"],
            protocolVersion: 3
        )
        context.model.installSquirrelSupportAction = {
            [.applePinyin, installed]
        }

        await context.model.installSquirrelSupport()

        XCTAssertEqual(
            context.model.squirrelSupportStatus?.state,
            .installed
        )
        XCTAssertFalse(context.model.isUpdatingInputMethodSupport)
    }

    @MainActor
    func testInstallFailureSurfacesActionableMessage() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        context.model.installSquirrelSupportAction = {
            throw InputMethodSupportTestError.unsupportedYAML
        }

        await context.model.installSquirrelSupport()

        XCTAssertEqual(
            context.model.inputMethodSupportError,
            "输入方案配置无法安全合并"
        )
        XCTAssertFalse(context.model.isUpdatingInputMethodSupport)
    }

    @MainActor
    func testUninstallRefreshesToAvailableState() async throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let available = InputMethodSupportStatus(
            id: "squirrel",
            name: "Rime",
            detail: "Rime 候选读取尚未连接",
            state: .available,
            schemaIDs: ["luna_pinyin"],
            protocolVersion: 3
        )
        context.model.uninstallSquirrelSupportAction = {
            [.applePinyin, available]
        }

        await context.model.uninstallSquirrelSupport()

        XCTAssertEqual(
            context.model.squirrelSupportStatus?.state,
            .available
        )
        XCTAssertFalse(context.model.isUpdatingInputMethodSupport)
    }

    @MainActor
    private func makeContext() throws -> ModelTestContext {
        let suiteName = "InputMethodSupportModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InputMethodSupportModelTests-\(UUID().uuidString)",
                isDirectory: true
            )
        return ModelTestContext(
            model: MainWindowModel(
                pluginManager: PluginManager(baseDirectory: root),
                defaults: defaults
            ),
            suiteName: suiteName,
            defaults: defaults,
            root: root
        )
    }
}

private enum InputMethodSupportTestError:
    LocalizedError,
    Equatable
{
    case unsupportedYAML

    var errorDescription: String? {
        "输入方案配置无法安全合并"
    }
}

private struct ModelTestContext {
    let model: MainWindowModel
    let suiteName: String
    let defaults: UserDefaults
    let root: URL

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
