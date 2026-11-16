import AppKit
import GlintPlugins
import SwiftUI
import XCTest

@testable import GlintUI

final class GeneralPageRenderingTests: XCTestCase {
    @MainActor
    func testGeneralPageRendersAcrossAppearancesAndWidths() throws {
        _ = NSApplication.shared
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GeneralPageRenderingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = GeneralPreferences(defaults: defaults)
        let model = MainWindowModel(
            generalPreferences: preferences,
            pluginManager: PluginManager(baseDirectory: root),
            catalogURL: nil,
            defaults: defaults
        )

        for colorScheme in [ColorScheme.light, .dark] {
            let hostingView = NSHostingView(
                rootView: GeneralPage(model: model)
                    .environment(\.colorScheme, colorScheme)
            )
            hostingView.appearance = NSAppearance(
                named: colorScheme == .dark ? .darkAqua : .aqua
            )

            for width in [729.0, 1_000.0] {
                hostingView.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: 1_200
                )
                hostingView.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(
                    hostingView.bitmapImageRepForCachingDisplay(
                        in: hostingView.bounds
                    )
                )
                hostingView.cacheDisplay(
                    in: hostingView.bounds,
                    to: bitmap
                )

                XCTAssertGreaterThan(hostingView.fittingSize.height, 0)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            }
        }
    }
}
