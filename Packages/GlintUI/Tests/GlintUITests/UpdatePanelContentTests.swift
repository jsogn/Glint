import AppKit
import XCTest

@testable import GlintUI

@MainActor
final class UpdatePanelContentTests: XCTestCase {
    func testInstallingResultReplacesProgressContent() {
        let container = NSView()
        let progressContent = NSView()
        let resultContent = NSView()
        container.addSubview(progressContent)

        UpdatePanelContent.install(resultContent, in: container)

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews.first === resultContent)
        XCTAssertNil(progressContent.superview)
    }

    func testUpdatePanelViewsProvideDeterministicPanelSize() {
        XCTAssertEqual(
            AppUpdatePanelView.panelSize(for: .checking),
            CGSize(width: 320, height: 188)
        )
        XCTAssertEqual(
            AppUpdatePanelView.panelSize(
                for: .result(
                    AppUpdateResultPresentation(
                        title: "软件更新",
                        message: "您使用的就是最新版！",
                        informativeText: "当前安装的 Glint 已是最新版本。",
                        primaryButtonTitle: "好",
                        secondaryButtonTitle: nil,
                        destinationURL: nil
                    )
                )
            ),
            CGSize(width: 320, height: 240)
        )
    }
}
