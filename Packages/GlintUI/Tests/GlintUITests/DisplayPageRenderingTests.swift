import AppKit
import SwiftUI
import XCTest
@testable import GlintUI

final class DisplayPageRenderingTests: XCTestCase {
    @MainActor
    func testDisplayPageRendersAcrossPositionsAppearancesAndWidths()
        throws
    {
        _ = NSApplication.shared
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = DisplayPreferences(defaults: defaults)

        for position in HUDPosition.allCases {
            preferences.position = position
            let hostingView = NSHostingView(
                rootView: DisplayPage(preferences: preferences)
            )
            for appearanceName in [
                NSAppearance.Name.aqua,
                NSAppearance.Name.darkAqua,
            ] {
                hostingView.appearance = try XCTUnwrap(
                    NSAppearance(named: appearanceName)
                )
                for width in [760.0, 1_000.0] {
                    hostingView.frame = NSRect(
                        x: 0,
                        y: 0,
                        width: width,
                        height: 900
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

                    XCTAssertGreaterThan(
                        hostingView.fittingSize.height,
                        0
                    )
                    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                    XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                }
            }
        }
    }
}
