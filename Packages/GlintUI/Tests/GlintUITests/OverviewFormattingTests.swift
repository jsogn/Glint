import XCTest

@testable import GlintUI

final class OverviewFormattingTests: XCTestCase {
    func testDwellDurationUsesMilliseconds() {
        XCTAssertEqual(OverviewFormatting.dwellDuration(0.08), "80 ms")
        XCTAssertEqual(OverviewFormatting.dwellDuration(0.3), "300 ms")
    }

    func testAppearanceSummarizesOpacitySizeAndSpacing() {
        XCTAssertEqual(
            OverviewFormatting.appearance(
                hudOpacity: 0.8,
                hudFontSize: 15,
                candidateSpacing: 5
            ),
            "背景不透明度 80% · 字号 15 pt · 间距 5 pt"
        )
        XCTAssertEqual(
            OverviewFormatting.appearance(
                hudOpacity: 1,
                hudFontSize: 13,
                candidateSpacing: 0
            ),
            "背景不透明度 100% · 字号 13 pt · 间距 0 pt"
        )
    }

    func testDictionaryCountUsesChineseCounter() {
        XCTAssertEqual(OverviewFormatting.dictionaryCount(3), "3 个")
    }

    func testCompactModelNameDropsRedundantLanguagePair() {
        XCTAssertEqual(
            OverviewFormatting.compactModelName(
                "OPUS-MT Chinese-English"
            ),
            "OPUS-MT"
        )
        XCTAssertEqual(
            OverviewFormatting.compactModelName("Qwen3 0.6B"),
            "Qwen3 0.6B"
        )
        XCTAssertEqual(
            OverviewFormatting.compactModelName("Index-Translate 2B"),
            "Index-Translate"
        )
        XCTAssertEqual(
            OverviewFormatting.compactModelName("未安装"),
            "未安装"
        )
    }
}
