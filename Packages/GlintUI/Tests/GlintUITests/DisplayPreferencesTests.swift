import Foundation
import XCTest
@testable import GlintUI

final class DisplayPreferencesTests: XCTestCase {
    @MainActor
    func testPreferencesPersistAcrossInstances() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DisplayPreferences(defaults: defaults)
        first.position = .above
        first.stabilityDelay = 0.35
        first.candidateSpacing = 14
        first.hudOpacity = 0.72

        let second = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(second.position, .above)
        XCTAssertEqual(second.stabilityDelay, 0.35)
        XCTAssertEqual(second.candidateSpacing, 14)
        XCTAssertEqual(second.hudOpacity, 0.72)
    }

    @MainActor
    func testStabilityDelayIsClamped() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.stabilityDelay = 2
        XCTAssertEqual(preferences.stabilityDelay, 0.8)
        preferences.stabilityDelay = 0
        XCTAssertEqual(preferences.stabilityDelay, 0.1)

        preferences.candidateSpacing = 30
        XCTAssertEqual(preferences.candidateSpacing, 24)
        preferences.candidateSpacing = -1
        XCTAssertEqual(preferences.candidateSpacing, 0)

        preferences.hudOpacity = 2
        XCTAssertEqual(preferences.hudOpacity, 1)
        preferences.hudOpacity = 0
        XCTAssertEqual(preferences.hudOpacity, 0.4)
    }
}
