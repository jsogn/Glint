import XCTest

@testable import GlintUI

@MainActor
final class TranslationAutoSpeechSchedulerTests: XCTestCase {
    func testSpeaksSelectedTranslationAfterDelay() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        scheduler.updateTranslations(
            [0: "First", 1: "Second"],
            revision: 1,
            selectedIndex: 1
        )
        await scheduler.waitForPendingTimer()

        XCTAssertEqual(spoken, ["Second"])
    }

    func testWaitsForTranslationWhenDelayElapsesFirst() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        await scheduler.waitForPendingTimer()
        XCTAssertTrue(spoken.isEmpty)

        scheduler.updateTranslations(
            [0: "Hello"],
            revision: 1,
            selectedIndex: 0
        )

        XCTAssertEqual(spoken, ["Hello"])
    }

    func testSelectionChangeChoosesCurrentRow() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        scheduler.updateTranslations(
            [0: "First", 1: "Second"],
            revision: 1,
            selectedIndex: 0
        )
        scheduler.selectionChanged(
            index: 1,
            revision: 1,
            delay: 1.2
        )
        await scheduler.waitForPendingTimer()

        XCTAssertEqual(spoken, ["Second"])
    }

    func testStaleRevisionCannotSpeak() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        scheduler.candidateChanged(revision: 2, delay: 1.2)
        scheduler.updateTranslations([0: "Old"], revision: 1)
        await scheduler.waitForPendingTimer()

        XCTAssertTrue(spoken.isEmpty)
    }

    func testDoesNotGuessSelectionWithoutCandidateEvidence() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        await scheduler.waitForPendingTimer()
        scheduler.updateTranslations([0: "Hello"], revision: 1)

        XCTAssertTrue(spoken.isEmpty)
    }

    func testOnlySpeaksOncePerRevision() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        await scheduler.waitForPendingTimer()
        scheduler.updateTranslations(
            [0: "Hello"],
            revision: 1,
            selectedIndex: 0
        )
        scheduler.selectionChanged(
            index: 1,
            revision: 1,
            delay: 1.2
        )
        scheduler.updateTranslations(
            [0: "Hello", 1: "Again"],
            revision: 1
        )

        XCTAssertEqual(spoken, ["Hello"])
    }

    func testManualSpeechSuppressesOnlyCurrentRevision() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        scheduler.manualSpeechStarted()
        scheduler.updateTranslations(
            [0: "Manual"],
            revision: 1,
            selectedIndex: 0
        )
        XCTAssertTrue(spoken.isEmpty)

        scheduler.candidateChanged(revision: 2, delay: 1.2)
        scheduler.updateTranslations(
            [0: "Automatic"],
            revision: 2,
            selectedIndex: 0
        )
        await scheduler.waitForPendingTimer()

        XCTAssertEqual(spoken, ["Automatic"])
    }

    func testCancelledCandidateDoesNotSpeak() async {
        let scheduler = makeScheduler()
        var spoken: [String] = []
        scheduler.onSpeak = { spoken.append($0) }

        scheduler.candidateChanged(revision: 1, delay: 1.2)
        scheduler.updateTranslations(
            [0: "Hello"],
            revision: 1,
            selectedIndex: 0
        )
        scheduler.cancel()

        XCTAssertTrue(spoken.isEmpty)
    }

    private func makeScheduler() -> TranslationAutoSpeechScheduler {
        TranslationAutoSpeechScheduler { _ in }
    }
}
