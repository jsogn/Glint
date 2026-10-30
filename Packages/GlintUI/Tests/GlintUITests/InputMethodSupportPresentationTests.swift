import XCTest
@testable import GlintUI

final class InputMethodSupportPresentationTests: XCTestCase {
    func testInstalledStateDescribesCandidateReaderPlugin() {
        let status = makeStatus(
            state: .installed,
            detail: "适配器安装状态"
        )

        XCTAssertEqual(
            status.presentation.headline,
            "候选读取支持"
        )
        XCTAssertEqual(
            status.presentation.description,
            "用于读取 Rime 当前高亮的候选内容。"
        )
        XCTAssertEqual(
            status.presentation.primaryActionTitle,
            "重新安装"
        )
        XCTAssertEqual(
            status.presentation.statusTitle,
            "已安装"
        )
    }

    func testAvailableStateExplainsWhatInstallingAdds() {
        let status = makeStatus(
            state: .available,
            detail: "适配器未安装"
        )

        XCTAssertEqual(
            status.presentation.headline,
            "候选读取支持"
        )
        XCTAssertEqual(
            status.presentation.description,
            "安装后即可读取 Rime 当前高亮的候选内容。"
        )
        XCTAssertEqual(
            status.presentation.primaryActionTitle,
            "安装支持"
        )
        XCTAssertEqual(
            status.presentation.statusTitle,
            "未安装"
        )
    }

    func testRepairStateExplainsReinstallationInsteadOfConnection() {
        let status = makeStatus(
            state: .repairRequired,
            detail: "适配器安装不完整"
        )

        XCTAssertEqual(
            status.presentation.headline,
            "候选读取支持"
        )
        XCTAssertEqual(
            status.presentation.description,
            "当前安装与 Rime 配置不匹配，需要重新安装。"
        )
        XCTAssertEqual(
            status.presentation.primaryActionTitle,
            "重新安装"
        )
        XCTAssertEqual(
            status.presentation.statusTitle,
            "需要重新安装"
        )
    }

    func testHeadlineAndActionOmitRedundantRimeNameInsideRimeCard() {
        let states: [InputMethodSupportState] = [
            .available,
            .installed,
            .repairRequired,
        ]

        for state in states {
            let presentation = makeStatus(
                state: state,
                detail: "适配器状态"
            ).presentation
            XCTAssertFalse(presentation.headline.contains("Rime"))
            XCTAssertFalse(
                presentation.primaryActionTitle?.contains("Rime")
                    == true
            )
        }
    }

    func testPluginDescriptionDoesNotDescribeOverallTranslationFeature() {
        let states: [InputMethodSupportState] = [
            .available,
            .installed,
            .repairRequired,
        ]

        for state in states {
            let description = makeStatus(
                state: state,
                detail: "适配器状态"
            ).presentation.description
            XCTAssertFalse(description.contains("英文翻译"))
            XCTAssertFalse(description.contains("Glint"))
        }
    }

    func testInstalledDiagnosticsDoNotRepeatStatusBadge() {
        let status = makeStatus(
            state: .installed,
            detail: "候选读取支持已安装"
        )

        XCTAssertFalse(status.showsDiagnosticStatus)
    }

    private func makeStatus(
        state: InputMethodSupportState,
        detail: String,
        schemaIDs: [String] = ["luna_pinyin"],
        protocolVersion: Int? = 3
    ) -> InputMethodSupportStatus {
        InputMethodSupportStatus(
            id: "squirrel",
            name: "Rime",
            detail: detail,
            state: state,
            schemaIDs: schemaIDs,
            protocolVersion: protocolVersion,
            isExperimental: true
        )
    }
}
