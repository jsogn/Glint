import Foundation
import XCTest

@testable import GlintCore

@MainActor
final class TranslationLanguageCoordinatorTests: XCTestCase {
    func testSwitchPersistsTargetAndRestoresMonitoringWhenReady()
        async
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .installed
        harness.wasMonitoring = true

        let readiness = await harness.coordinator.switchTarget(
            to: .japanese
        )

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(harness.store.selectedTarget, .japanese)
        XCTAssertEqual(harness.stopCalls, 1)
        XCTAssertEqual(harness.resumeCalls, 1)
    }

    func testNeedsLanguagePackKeepsJapaneseAndDoesNotResume()
        async
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .available
        harness.wasMonitoring = true

        let readiness = await harness.coordinator.switchTarget(
            to: .japanese
        )

        XCTAssertEqual(
            readiness,
            .needsSetup(.japanese, "需要安装 Apple 翻译语言包")
        )
        XCTAssertEqual(harness.store.selectedTarget, .japanese)
        XCTAssertEqual(harness.resumeCalls, 0)
    }

    func testRetryAfterLanguagePackInstallationRestoresPendingMonitoring()
        async
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .available
        harness.wasMonitoring = true
        _ = await harness.coordinator.switchTarget(to: .japanese)
        harness.system.availabilityValue = .installed

        let readiness =
            await harness.coordinator.retryCurrentConfiguration()

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(harness.resumeCalls, 1)
    }

    func testManualStopCancelsPendingResume() async {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .available
        harness.wasMonitoring = true
        _ = await harness.coordinator.switchTarget(to: .japanese)
        harness.system.availabilityValue = .installed

        harness.coordinator.cancelPendingResume()
        harness.wasMonitoring = false
        _ = await harness.coordinator.retryCurrentConfiguration()

        XCTAssertEqual(harness.resumeCalls, 0)
    }
}

@MainActor
private final class CoordinatorHarness {
    let store: TranslationSelectionStore
    let languageRuntime = StubLanguageRuntime()
    let system = StubSystemTranslationProvider()
    let coordinator: TranslationLanguageCoordinator
    var wasMonitoring = false
    var stopCalls = 0
    var resumeCalls = 0

    init() {
        let suite = "GlintCoordinator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        store = TranslationSelectionStore(defaults: defaults)
        store.migrateIfNeeded()
        coordinator = TranslationLanguageCoordinator(
            store: store,
            languageRuntime: languageRuntime,
            system: system
        )
        coordinator.wasMonitoring = { [weak self] in
            self?.wasMonitoring ?? false
        }
        coordinator.stopActiveOutput = { [weak self] in
            self?.stopCalls += 1
        }
        coordinator.resumeMonitoring = { [weak self] in
            self?.resumeCalls += 1
        }
    }
}

@MainActor
private final class StubLanguageRuntime:
    TranslationLanguageRuntimeProviding
{
    var prepareResult: String?

    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        prepareResult
    }

    func releaseResources(for modelID: String) async {}
}

@MainActor
private final class StubSystemTranslationProvider:
    SystemTranslationLanguageProviding
{
    var availabilityValue: SystemTranslationAvailability?

    var availability: SystemTranslationAvailability? {
        availabilityValue
    }

    func setDirection(_ direction: TranslationDirection) async {}

    func refreshAvailability(
        for direction: TranslationDirection
    ) async {}

    func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool {
        availabilityValue?.canSelect == true
    }
}
