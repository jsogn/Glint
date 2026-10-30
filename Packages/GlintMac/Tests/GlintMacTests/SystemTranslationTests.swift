import GlintCore
import Translation
import XCTest
@testable import GlintMac

@MainActor
final class SystemTranslationCoordinatorTests: XCTestCase {
    func testPreparationMarksLanguagePackInstalled() async throws {
        let availability = LockedAvailability(.available)
        let driver = FakeSystemTranslationDriver()
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()

        await coordinator.refreshAvailability()
        XCTAssertEqual(coordinator.availability, .available)
        try await coordinator.prepareLanguagePack()

        XCTAssertEqual(driver.prepareCalls, 1)
        XCTAssertEqual(coordinator.availability, .installed)
        XCTAssertNotNil(coordinator.configuration)

        coordinator.shutdown()
        await hostTask.value
    }

    func testTranslationsRunSerially() async throws {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver(
            translationDelay: .milliseconds(10)
        )
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        await coordinator.refreshAvailability()
        try await coordinator.prepareLanguagePack()

        async let first = coordinator.translate("first")
        async let second = coordinator.translate("second")
        let results = try await [first, second]

        XCTAssertEqual(results, ["EN:first", "EN:second"])
        XCTAssertEqual(driver.maximumConcurrentTranslations, 1)

        coordinator.shutdown()
        await hostTask.value
    }

    func testTranslationWithoutSessionFailsImmediately() async {
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                .available
            }
        )

        do {
            _ = try await coordinator.translate("missing session")
            XCTFail("Missing session must not queue a request")
        } catch let error as SystemTranslationError {
            XCTAssertEqual(error, .sessionUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreparationFailureIsVisibleInAvailability() async {
        let availability = LockedAvailability(.available)
        let driver = FakeSystemTranslationDriver()
        driver.prepareError = TestPreparationError.failed
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()

        do {
            try await coordinator.prepareLanguagePack()
            XCTFail("Preparation should fail")
        } catch {
            XCTAssertEqual(
                coordinator.availability,
                .failed("Preparation failed")
            )
        }

        coordinator.shutdown()
        await hostTask.value
    }

    func testCancelledPreparationReturnsToAvailable() async {
        let availability = LockedAvailability(.available)
        let driver = FakeSystemTranslationDriver()
        driver.prepareError = CancellationError()
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()

        do {
            try await coordinator.prepareLanguagePack()
            XCTFail("Preparation should be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(coordinator.availability, .available)
        coordinator.shutdown()
        await hostTask.value
    }

    @available(macOS 26.0, *)
    func testAppleCancelledPreparationReturnsToAvailable() async {
        let availability = LockedAvailability(.available)
        let driver = FakeSystemTranslationDriver()
        driver.prepareError = TranslationError.alreadyCancelled
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()

        do {
            try await coordinator.prepareLanguagePack()
            XCTFail("Preparation should be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(coordinator.availability, .available)
        coordinator.shutdown()
        await hostTask.value
    }

    func testInstalledSessionPreparationTimesOutWithoutHost() async {
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                .installed
            },
            driverReadyTimeout: .milliseconds(20)
        )

        let isReady =
            await coordinator.prepareInstalledSessionIfAvailable()

        XCTAssertFalse(isReady)
        XCTAssertEqual(coordinator.availability, .installed)
    }

    func testInstalledSessionPreparationWaitsForLateHost() async {
        let availability = LockedAvailability(.installed)
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            },
            driverReadyTimeout: .milliseconds(100)
        )
        let hostTask = Task {
            try? await Task.sleep(for: .milliseconds(10))
            await coordinator.run(
                driver: FakeSystemTranslationDriver()
            )
        }

        let isReady =
            await coordinator.prepareInstalledSessionIfAvailable()

        XCTAssertTrue(isReady)
        XCTAssertEqual(coordinator.availability, .installed)
        coordinator.shutdown()
        await hostTask.value
    }

    func testPendingQueueIsBounded() async {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver(
            translationDelay: .milliseconds(30)
        )
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        try? await coordinator.prepareLanguagePack()
        var queuedTasks: [Task<String, any Error>] = []
        for index in 0..<8 {
            queuedTasks.append(
                Task {
                    try await coordinator.translate("queued-\(index)")
                }
            )
        }
        let activeTask = Task {
            try await coordinator.translate("active")
        }
        await Task.yield()

        do {
            _ = try await coordinator.translate("overflow")
            XCTFail("The tenth request must fail")
        } catch let error as SystemTranslationError {
            XCTAssertEqual(error, .tooManyPendingRequests)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        for task in queuedTasks + [activeTask] {
            task.cancel()
        }
        for task in queuedTasks + [activeTask] {
            _ = await task.result
        }
        coordinator.shutdown()
        await hostTask.value
    }

    func testCancelledQueuedTranslationThrowsCancellation() async throws {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver(
            translationDelay: .milliseconds(30)
        )
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        try await coordinator.prepareLanguagePack()
        let activeTask = Task {
            try await coordinator.translate("active")
        }
        await Task.yield()
        let queuedTask = Task {
            try await coordinator.translate("cancelled")
        }
        await Task.yield()
        queuedTask.cancel()

        do {
            _ = try await queuedTask.value
            XCTFail("Cancelled request must not return a translation")
        } catch is CancellationError {
            // Expected.
        }

        _ = await activeTask.result
        coordinator.shutdown()
        await hostTask.value
    }

    func testShutdownDuringTranslationReturnsCancellation() async throws {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver(
            translationDelay: .milliseconds(20)
        )
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        try await coordinator.prepareLanguagePack()

        let request = Task {
            try await coordinator.translate("shutdown")
        }
        await Task.yield()
        coordinator.shutdown()

        do {
            _ = try await request.value
            XCTFail("Shutdown must cancel the active request")
        } catch is CancellationError {
            // Expected.
        }
        await hostTask.value
    }

    func testEngineMapsSystemResponseToSingleResult() async throws {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver()
        driver.onPrepare = {
            availability.value = .installed
        }
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        try await coordinator.prepareLanguagePack()
        let engine = SystemTranslationEngine(
            coordinator: coordinator
        )

        let result = try await engine.translate(
            Candidate(text: "你好", kind: .word)
        )

        XCTAssertEqual(result?.options.count, 1)
        XCTAssertEqual(result?.text, "EN:你好")

        coordinator.shutdown()
        await hostTask.value
    }

    func testEngineFailureKeepsLanguagePackInstalled() async throws {
        let availability = LockedAvailability(.installed)
        let driver = FakeSystemTranslationDriver()
        driver.onPrepare = {
            availability.value = .installed
        }
        driver.translationError = TestPreparationError.failed
        let coordinator = SystemTranslationCoordinator(
            availabilityProvider: {
                availability.value
            }
        )
        let hostTask = Task {
            await coordinator.run(driver: driver)
        }
        await Task.yield()
        try await coordinator.prepareLanguagePack()
        let engine = SystemTranslationEngine(
            coordinator: coordinator
        )

        do {
            _ = try await engine.translate(
                Candidate(text: "你好", kind: .word)
            )
            XCTFail("Translation should fail")
        } catch {
            XCTAssertEqual(
                coordinator.availability,
                .installed
            )
        }

        coordinator.shutdown()
        await hostTask.value
    }
}

@MainActor
private final class FakeSystemTranslationDriver:
    SystemTranslationSessionDriving
{
    let translationDelay: Duration
    var onPrepare: (() -> Void)?
    var prepareError: (any Error)?
    var translationError: (any Error)?
    private(set) var prepareCalls = 0
    private(set) var activeTranslations = 0
    private(set) var maximumConcurrentTranslations = 0

    init(translationDelay: Duration = .zero) {
        self.translationDelay = translationDelay
    }

    func prepareTranslation() async throws {
        prepareCalls += 1
        if let prepareError {
            throw prepareError
        }
        onPrepare?()
    }

    func translate(_ text: String) async throws -> String {
        if let translationError {
            throw translationError
        }
        activeTranslations += 1
        maximumConcurrentTranslations = max(
            maximumConcurrentTranslations,
            activeTranslations
        )
        defer { activeTranslations -= 1 }
        if translationDelay > .zero {
            try await Task.sleep(for: translationDelay)
        }
        return "EN:\(text)"
    }
}

private enum TestPreparationError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Preparation failed"
    }
}

private final class LockedAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SystemTranslationAvailability

    init(_ value: SystemTranslationAvailability) {
        stored = value
    }

    var value: SystemTranslationAvailability {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
