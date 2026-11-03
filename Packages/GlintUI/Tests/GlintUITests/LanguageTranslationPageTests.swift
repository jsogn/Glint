import AppKit
import GlintCore
import GlintPlugins
import SwiftUI
import XCTest

@testable import GlintUI

@MainActor
final class LanguageTranslationPageTests: XCTestCase {
    func testPageRendersEnglishAndJapaneseStates() async throws {
        let suite = "GlintLanguagePage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )
        model.changeTranslationTargetAction = { target in
            .ready(target)
        }

        let hostingView = NSHostingView(
            rootView: LanguageTranslationPage(
                model: model,
                onManageModels: {}
            )
        )
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: 900,
            height: 760
        )
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)

        await model.setTranslationTarget(.japanese)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.translationTarget, .japanese)
        XCTAssertEqual(model.translationReadiness, .ready(.japanese))
        XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
    }
}
