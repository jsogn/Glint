import AppKit
import GlintPlugins
import SwiftUI
import XCTest
@testable import GlintUI

final class ManualRimeSetupGuideRenderingTests: XCTestCase {
    @MainActor
    func testManualGuideRendersAtSheetSize() throws {
        let suiteName =
            "ManualRimeSetupGuideRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualRimeSetupGuideRenderingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let model = MainWindowModel(
            pluginManager: PluginManager(baseDirectory: root),
            defaults: defaults
        )
        try render(
            ManualRimeSetupGuide(
                model: model,
                schemaIDs: ["luna_pinyin", "luna_pinyin_simp"]
            ),
            colorScheme: .dark,
            snapshotEnvironmentKey: "GLINT_MANUAL_GUIDE_SNAPSHOT"
        )
        try render(
            ManualRimeSetupGuide(
                model: model,
                schemaIDs: ["luna_pinyin", "luna_pinyin_simp"]
            ),
            colorScheme: .light,
            snapshotEnvironmentKey:
                "GLINT_MANUAL_GUIDE_LIGHT_SNAPSHOT"
        )
        try render(
            ManualRimeSetupGuide(
                model: model,
                schemaIDs: []
            ),
            colorScheme: .light,
            snapshotEnvironmentKey:
                "GLINT_MANUAL_GUIDE_EMPTY_SNAPSHOT"
        )
    }

    @MainActor
    private func render<Content: View>(
        _ content: Content,
        colorScheme: ColorScheme,
        snapshotEnvironmentKey: String
    ) throws {
        let hostingView = NSHostingView(
            rootView: content.environment(\.colorScheme, colorScheme)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 650)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        )
        hostingView.cacheDisplay(
            in: hostingView.bounds,
            to: representation
        )
        if let path = ProcessInfo.processInfo.environment[
            snapshotEnvironmentKey
        ] {
            let data = try XCTUnwrap(
                representation.representation(
                    using: .png,
                    properties: [:]
                )
            )
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
