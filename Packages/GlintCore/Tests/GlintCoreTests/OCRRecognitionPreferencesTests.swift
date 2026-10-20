import XCTest
@testable import GlintCore

final class OCRRecognitionPreferencesTests: XCTestCase {
    private var suiteName = ""

    func testDefaultsToVisionPrimaryAndPPOCRBackup() throws {
        let defaults = try makeDefaults()
        defer { removeDefaults(defaults) }

        let preferences = OCRRecognitionPreferences.load(from: defaults)
        XCTAssertEqual(
            preferences.primaryModelID,
            OCRRecognitionPreferences.visionModelID
        )
        XCTAssertEqual(
            preferences.backupModelID,
            OCRRecognitionPreferences.defaultBackupModelID
        )
        XCTAssertEqual(preferences.strategy, .automaticFallback)
    }

    func testPreferencesPersist() throws {
        let defaults = try makeDefaults()
        defer { removeDefaults(defaults) }

        OCRRecognitionPreferences(
            primaryModelID: "ocr-ppocrv6-small",
            backupModelID: "ocr-ppocrv6-medium",
            strategy: .dualVerification
        ).save(to: defaults)

        XCTAssertEqual(
            OCRRecognitionPreferences.load(from: defaults),
            OCRRecognitionPreferences(
                primaryModelID: "ocr-ppocrv6-small",
                backupModelID: "ocr-ppocrv6-medium",
                strategy: .dualVerification
            )
        )
    }

    func testLegacySettingsMigrate() throws {
        let defaults = try makeDefaults()
        defer { removeDefaults(defaults) }
        defaults.set("builtin.vision", forKey: "ocr.engineID")
        defaults.set("always", forKey: "ocr.enhancementMode")

        let preferences = OCRRecognitionPreferences.load(from: defaults)
        XCTAssertEqual(
            preferences.primaryModelID,
            OCRRecognitionPreferences.visionModelID
        )
        XCTAssertEqual(
            preferences.backupModelID,
            OCRRecognitionPreferences.defaultBackupModelID
        )
        XCTAssertEqual(preferences.strategy, .dualVerification)
    }

    func testExplicitlyDisabledBackupStaysDisabled() throws {
        let defaults = try makeDefaults()
        defer { removeDefaults(defaults) }

        OCRRecognitionPreferences(
            primaryModelID: OCRRecognitionPreferences.visionModelID,
            backupModelID: nil,
            strategy: .automaticFallback
        ).save(to: defaults)

        XCTAssertNil(
            OCRRecognitionPreferences.load(from: defaults).backupModelID
        )
    }

    func testPrimaryAndBackupCannotBeTheSameModel() {
        let preferences = OCRRecognitionPreferences(
            primaryModelID: "ocr-ppocrv6-small",
            backupModelID: "ocr-ppocrv6-small",
            strategy: .dualVerification
        )
        XCTAssertNil(preferences.backupModelID)
    }

    private func makeDefaults() throws -> UserDefaults {
        suiteName = "OCRRecognitionPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return defaults
    }

    private func removeDefaults(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
