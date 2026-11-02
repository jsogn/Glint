import AppKit
import GlintCore
import GlintPlugins
import SwiftUI
import XCTest

@testable import GlintUI

final class OverviewUpdatePromptRenderingTests: XCTestCase {
    @MainActor
    func testAvailableUpdatePromptRendersAtOverviewWidth() throws {
        let prompt = AppUpdateOverviewPrompt(
            releaseVersion: "0.8.0",
            currentVersion: "0.7.5",
            destinationURL: URL(
                string: "https://example.com/releases/v0.8.0"
            )!
        )
        let hostingView = NSHostingView(
            rootView: OverviewUpdatePrompt(prompt: prompt)
                .environment(\.colorScheme, .dark)
                .frame(width: 729)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 729, height: 96)
        hostingView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hostingView.fittingSize.height, 56)
        XCTAssertLessThan(hostingView.fittingSize.height, 88)

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
            "GLINT_OVERVIEW_UPDATE_SNAPSHOT"
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

    @MainActor
    func testOverviewRendersWithAvailableUpdate() throws {
        let suiteName =
            "OverviewUpdatePromptRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "OverviewUpdatePromptRenderingTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let displayPreferences = DisplayPreferences(defaults: defaults)
        displayPreferences.hudOpacity = 0.8
        displayPreferences.candidateSpacing = 7
        let model = MainWindowModel(
            displayPreferences: displayPreferences,
            pluginManager: PluginManager(baseDirectory: root),
            builtInPlugins: [
                Self.translationManifest,
                Self.dictionaryManifest(
                    id: "dict-cedict",
                    name: "CC-CEDICT"
                ),
                Self.dictionaryManifest(
                    id: "dict-ecdict",
                    name: "ECDICT Rank Index"
                ),
            ],
            catalogURL: nil,
            defaults: defaults
        )
        model.accessibilityGranted = true
        model.isMonitoring = true
        model.setTranslationMode(.dictionaryFirst)
        let updateModel = AppUpdateModel(
            currentVersion: "0.7.5",
            initialStatus: .available(
                AppRelease(
                    version: "v0.8.0",
                    pageURL: URL(
                        string:
                            "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
                    )!
                )
            ),
            fetchLatestRelease: {
                throw URLError(.notConnectedToInternet)
            }
        )
        try renderOverview(
            model: model,
            updateModel: updateModel,
            colorScheme: .dark,
            snapshotEnvironmentKey: "GLINT_OVERVIEW_PAGE_SNAPSHOT"
        )
        try renderOverview(
            model: model,
            updateModel: updateModel,
            colorScheme: .light,
            snapshotEnvironmentKey:
                "GLINT_OVERVIEW_PAGE_LIGHT_SNAPSHOT"
        )
    }

    @MainActor
    private func renderOverview(
        model: MainWindowModel,
        updateModel: AppUpdateModel,
        colorScheme: ColorScheme,
        snapshotEnvironmentKey: String
    ) throws {
        let hostingView = NSHostingView(
            rootView: OverviewPage(
                model: model,
                appUpdateModel: updateModel,
                selection: .constant(.overview),
                openTranslationModels: {}
            )
            .environment(\.colorScheme, colorScheme)
        )
        hostingView.appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 729, height: 700)
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

    private static let translationManifest = PluginManifest(
        id: TranslationModelSelection.defaultModelID,
        type: .translation,
        name: "OPUS-MT Chinese-English",
        version: "0.1.0",
        runtime: "ctranslate2",
        sizeBytes: 0,
        sha256: "PREVIEW",
        url: URL(fileURLWithPath: "/preview/mt-opus-zh-en"),
        license: "CC-BY-4.0",
        minRAMBytes: 0,
        summary: "速度快、占用低，适合轻量日常翻译。",
        source: .bundled
    )

    private static func dictionaryManifest(
        id: String,
        name: String
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            type: .dictionary,
            name: name,
            version: "0.1.0",
            runtime: "sqlite-v1",
            sizeBytes: 0,
            sha256: "PREVIEW",
            url: URL(fileURLWithPath: "/preview/\(id)"),
            license: "CC-BY-4.0",
            minRAMBytes: 0,
            source: .bundled
        )
    }
}
