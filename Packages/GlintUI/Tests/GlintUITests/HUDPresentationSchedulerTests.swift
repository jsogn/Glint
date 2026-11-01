import Foundation
import XCTest
@testable import GlintUI

@MainActor
final class HUDPresentationSchedulerTests: XCTestCase {
    func testCoalescesRapidRequestsToLatestRevision() async {
        var revisions: [UInt64] = []
        let presented = expectation(description: "HUD presented")
        let scheduler = HUDPresentationScheduler(
            present: { request in
                revisions.append(request.revision ?? 0)
                presented.fulfill()
            },
            dimStaleContent: {}
        )

        scheduler.enqueue(request(revision: 1))
        scheduler.enqueue(request(revision: 2))
        await fulfillment(of: [presented], timeout: 1)

        XCTAssertEqual(revisions, [2])
    }

    func testCancellingQueuedRequestsPreventsPresentation() async {
        var presentationCount = 0
        let presented = expectation(description: "HUD presentation")
        presented.isInverted = true
        let scheduler = HUDPresentationScheduler(
            present: { _ in
                presentationCount += 1
                presented.fulfill()
            },
            dimStaleContent: {}
        )

        scheduler.enqueue(request(revision: 1))
        scheduler.cancelQueuedPresentations()
        await fulfillment(of: [presented], timeout: 0.2)

        XCTAssertEqual(presentationCount, 0)
    }

    func testSameRevisionUsesInPlaceContentPatch() {
        XCTAssertEqual(
            HUDPresentationScheduler.contentUpdate(
                displayedRevision: 42,
                incomingRevision: 42,
                isVisible: true
            ),
            .patch
        )
    }

    func testChangedRevisionUsesTransition() {
        XCTAssertEqual(
            HUDPresentationScheduler.contentUpdate(
                displayedRevision: 42,
                incomingRevision: 43,
                isVisible: true
            ),
            .transition
        )
    }

    func testHiddenHUDUsesEntryRegardlessOfRevision() {
        XCTAssertEqual(
            HUDPresentationScheduler.contentUpdate(
                displayedRevision: nil,
                incomingRevision: 42,
                isVisible: false
            ),
            .entry
        )
    }

    private func request(revision: UInt64) -> HUDPresentationRequest {
        HUDPresentationRequest(
            revision: revision,
            items: [HUDItem(id: 0, text: "test")],
            layoutStyle: .selectedTranslations,
            appearance: .default,
            screenRect: CGRect(x: 100, y: 100, width: 200, height: 30),
            inputCaretRect: nil,
            spacing: 8,
            opacity: 0.8
        )
    }
}
