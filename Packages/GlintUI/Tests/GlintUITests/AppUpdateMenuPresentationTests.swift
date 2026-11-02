import Foundation
import XCTest

@testable import GlintUI

final class AppUpdateMenuPresentationTests: XCTestCase {
    func testIdleMenuOffersManualUpdateCheck() {
        XCTAssertEqual(
            AppUpdateStatus.idle.menuPresentation,
            AppUpdateMenuPresentation(
                title: "检查更新…",
                isEnabled: true,
                destinationURL: nil
            )
        )
    }

    func testCheckingMenuIsDisabled() {
        XCTAssertEqual(
            AppUpdateStatus.checking.menuPresentation,
            AppUpdateMenuPresentation(
                title: "正在检查…",
                isEnabled: false,
                destinationURL: nil
            )
        )
    }

    func testUpToDateMenuCanRunAnotherCheck() {
        XCTAssertEqual(
            AppUpdateStatus.upToDate.menuPresentation,
            AppUpdateMenuPresentation(
                title: "检查更新…",
                isEnabled: true,
                destinationURL: nil
            )
        )
    }

    func testAvailableMenuOpensReleasePage() {
        let releaseURL = URL(
            string: "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
        )!

        XCTAssertEqual(
            AppUpdateStatus.available(
                AppRelease(version: "v0.8.0", pageURL: releaseURL)
            ).menuPresentation,
            AppUpdateMenuPresentation(
                title: "点击前往更新",
                isEnabled: true,
                destinationURL: releaseURL
            )
        )
    }

    func testFailedMenuCanRetryCheck() {
        XCTAssertEqual(
            AppUpdateStatus.failed.menuPresentation,
            AppUpdateMenuPresentation(
                title: "检查更新（暂时不可用）",
                isEnabled: true,
                destinationURL: nil
            )
        )
    }

    func testUpToDateResultShowsConfirmation() {
        XCTAssertEqual(
            AppUpdateStatus.upToDate.resultPresentation,
            AppUpdateResultPresentation(
                title: "软件更新",
                message: "您使用的就是最新版！",
                informativeText: "当前安装的 Glint 已是最新版本。",
                primaryButtonTitle: "好",
                secondaryButtonTitle: nil,
                destinationURL: nil
            )
        )
    }

    func testAvailableResultOffersDownload() {
        let releaseURL = URL(
            string: "https://github.com/jsogn/Glint/releases/tag/v0.8.0"
        )!
        XCTAssertEqual(
            AppUpdateStatus.available(
                AppRelease(version: "v0.8.0", pageURL: releaseURL)
            ).resultPresentation,
            AppUpdateResultPresentation(
                title: "软件更新",
                message: "发现新版本 0.8.0",
                informativeText: "请前往 GitHub 下载并安装最新版。",
                primaryButtonTitle: "前往下载",
                secondaryButtonTitle: "取消",
                destinationURL: releaseURL
            )
        )
    }

    func testFailedResultExplainsRetry() {
        XCTAssertEqual(
            AppUpdateStatus.failed.resultPresentation,
            AppUpdateResultPresentation(
                title: "软件更新",
                message: "暂时无法检查更新",
                informativeText: "请检查网络连接后重试。",
                primaryButtonTitle: "好",
                secondaryButtonTitle: nil,
                destinationURL: nil
            )
        )
    }
}
