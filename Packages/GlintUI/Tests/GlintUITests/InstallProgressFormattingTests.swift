import GlintPlugins
import XCTest
@testable import GlintUI

final class InstallProgressFormattingTests: XCTestCase {
    func testDownloadingShowsSizeAndSpeed() {
        let description = InstallProgressFormatting.description(
            for: PluginInstallProgress(
                fraction: 0.4,
                phase: .downloading,
                completedBytes: 400_000_000,
                totalBytes: 1_000_000_000,
                bytesPerSecond: 5_000_000
            )
        )

        XCTAssertTrue(description.contains("正在下载"))
        XCTAssertTrue(description.contains("/"))
        XCTAssertTrue(description.contains("/s"))
    }

    func testPreparingShowsDownloadHost() {
        XCTAssertEqual(
            InstallProgressFormatting.description(
                for: PluginInstallProgress(
                    fraction: 0,
                    phase: .preparing,
                    sourceHost: "hf-mirror.com"
                )
            ),
            "正在连接 hf-mirror.com…"
        )
    }

    func testPostDownloadPhasesHaveDistinctStatus() {
        XCTAssertEqual(
            InstallProgressFormatting.description(
                for: PluginInstallProgress(
                    fraction: 0.92,
                    phase: .verifying
                )
            ),
            "正在校验模型…"
        )
        XCTAssertEqual(
            InstallProgressFormatting.description(
                for: PluginInstallProgress(
                    fraction: 0.98,
                    phase: .installing
                )
            ),
            "正在安装模型…"
        )
    }
}
