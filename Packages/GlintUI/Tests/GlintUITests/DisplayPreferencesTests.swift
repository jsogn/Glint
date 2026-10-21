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
        first.candidateDwellDuration = 0.24
        first.candidateSpacing = 14
        first.hudOpacity = 0.72

        let second = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(second.position, .above)
        XCTAssertEqual(second.candidateDwellDuration, 0.24)
        XCTAssertEqual(second.candidateSpacing, 14)
        XCTAssertEqual(second.hudOpacity, 0.72)
        XCTAssertEqual(
            defaults.object(
                forKey: "display.candidateDwellDuration"
            ) as? Double,
            0.24
        )
    }

    @MainActor
    func testCandidateDwellDurationIsClamped() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        preferences.candidateDwellDuration = 2
        XCTAssertEqual(preferences.candidateDwellDuration, 0.3)
        preferences.candidateDwellDuration = 0
        XCTAssertEqual(preferences.candidateDwellDuration, 0.08)

        preferences.candidateSpacing = 30
        XCTAssertEqual(preferences.candidateSpacing, 24)
        preferences.candidateSpacing = -1
        XCTAssertEqual(preferences.candidateSpacing, 0)

        preferences.hudOpacity = 2
        XCTAssertEqual(preferences.hudOpacity, 1)
        preferences.hudOpacity = 0
        XCTAssertEqual(preferences.hudOpacity, 0.4)
    }

    @MainActor
    func testCandidateDwellDurationChangeNotifiesObserver() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = DisplayPreferences(defaults: defaults)
        XCTAssertEqual(
            preferences.candidateDwellDuration,
            0.12,
            accuracy: 0.001
        )

        var observed: [Double] = []
        preferences.candidateDwellDurationDidChange = {
            observed.append($0)
        }
        preferences.candidateDwellDuration = 2

        XCTAssertEqual(observed, [0.3])
    }

    @MainActor
    func testLegacyStabilityDelayIsIgnoredDuringDevelopment() throws {
        let suiteName = "GlintUITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(0.25, forKey: "display.stabilityDelay")
        let preferences = DisplayPreferences(defaults: defaults)

        XCTAssertEqual(
            preferences.candidateDwellDuration,
            0.12,
            accuracy: 0.001
        )
    }

}
