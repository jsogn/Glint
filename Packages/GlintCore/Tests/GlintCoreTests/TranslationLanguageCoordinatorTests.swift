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

    func testManualStopDuringPreparationPreventsAutomaticResume()
        async throws
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .installed
        harness.system.prepareDelay = .milliseconds(30)
        harness.wasMonitoring = true

        let switchTask = Task {
            await harness.coordinator.switchTarget(to: .japanese)
        }
        try await Task.sleep(for: .milliseconds(5))
        harness.coordinator.cancelPendingResume()

        let readiness = await switchTask.value

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(harness.resumeCalls, 0)
    }

    func testRapidSwitchPreservesResumeIntentFromFirstTarget()
        async throws
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .installed
        harness.system.prepareDelay = .milliseconds(30)
        harness.wasMonitoring = true

        let firstSwitch = Task {
            await harness.coordinator.switchTarget(to: .japanese)
        }
        try await Task.sleep(for: .milliseconds(5))
        let secondSwitch = Task {
            await harness.coordinator.switchTarget(to: .english)
        }

        let firstReadiness = await firstSwitch.value
        let secondReadiness = await secondSwitch.value

        XCTAssertEqual(firstReadiness, .superseded)
        XCTAssertEqual(secondReadiness, .ready(.english))
        XCTAssertEqual(harness.store.selectedTarget, .english)
        XCTAssertEqual(harness.resumeCalls, 1)
    }

    func testPrepareCurrentConfigurationUsesDeclaredLocalDirection()
        async
    {
        let harness = CoordinatorHarness()
        harness.store.selectModel("local-japanese", for: .japanese)
        harness.store.selectedTarget = .japanese
        harness.system.availabilityValue = .unsupported

        let readiness =
            await harness.coordinator.prepareCurrentConfiguration()

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(
            harness.system.refreshDirections,
            [.simplifiedChineseToJapanese]
        )
    }

    func testPrepareCurrentConfigurationReportsUnsupportedAppleDirection()
        async
    {
        let harness = CoordinatorHarness()
        harness.store.selectedTarget = .japanese
        harness.system.availabilityValue = .unsupported

        let readiness =
            await harness.coordinator.prepareCurrentConfiguration()

        XCTAssertEqual(readiness, .unsupported(.japanese))
    }

    func testTargetSwitchSupersedesEarlierCurrentConfigurationPreparation()
        async throws
    {
        let harness = CoordinatorHarness()
        harness.system.availabilityValue = .installed
        harness.system.prepareDelay = .milliseconds(30)

        let startupPreparation = Task {
            await harness.coordinator.prepareCurrentConfiguration()
        }
        try await Task.sleep(for: .milliseconds(5))
        let targetSwitch = Task {
            await harness.coordinator.switchTarget(to: .japanese)
        }

        let startupReadiness = await startupPreparation.value
        let switchReadiness = await targetSwitch.value

        XCTAssertEqual(startupReadiness, .superseded)
        XCTAssertEqual(switchReadiness, .ready(.japanese))
        XCTAssertEqual(harness.store.selectedTarget, .japanese)
    }

    func testApplePreparationActivatesTranslationRuntime()
        async
    {
        let harness = CoordinatorHarness()
        harness.store.selectedTarget = .japanese
        harness.system.availabilityValue = .installed

        let readiness =
            await harness.coordinator.prepareCurrentConfiguration()

        XCTAssertEqual(readiness, .ready(.japanese))
        XCTAssertEqual(
            harness.languageRuntime.prepareDirections,
            [.simplifiedChineseToJapanese]
        )
    }

    func testApplePreparationSupportsEveryTarget() async {
        for target in TranslationTarget.allCases {
            let harness = CoordinatorHarness()
            harness.store.selectedTarget = target
            harness.system.availabilityValue = .installed

            let readiness =
                await harness.coordinator.prepareCurrentConfiguration()

            XCTAssertEqual(readiness, .ready(target))
            XCTAssertEqual(
                harness.languageRuntime.prepareDirections,
                [TranslationDirection(target: target)]
            )
        }
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
            self?.wasMonitoring = false
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
    var prepareDirections: [TranslationDirection] = []

    func prepare(
        modelID: String,
        direction: TranslationDirection
    ) async -> String? {
        prepareDirections.append(direction)
        return prepareResult
    }

    func releaseResources(for modelID: String) async {}
}

@MainActor
private final class StubSystemTranslationProvider:
    SystemTranslationLanguageProviding
{
    var availabilityValue: SystemTranslationAvailability?
    var prepareDelay: Duration = .zero
    var refreshDirections: [TranslationDirection] = []

    var availability: SystemTranslationAvailability? {
        availabilityValue
    }

    func refreshAvailability(
        for direction: TranslationDirection
    ) async {
        refreshDirections.append(direction)
    }

    func prepareInstalledSessionIfAvailable(
        for direction: TranslationDirection
    ) async -> Bool {
        if prepareDelay > .zero {
            try? await Task.sleep(for: prepareDelay)
        }
        return availabilityValue?.canSelect == true
    }
}
