import GlintCore
import XCTest

@testable import GlintUI

final class OverviewFormattingTests: XCTestCase {
    func testDwellDurationUsesMilliseconds() {
        XCTAssertEqual(OverviewFormatting.dwellDuration(0.08), "80 ms")
        XCTAssertEqual(OverviewFormatting.dwellDuration(0.3), "300 ms")
    }

    func testAppearanceUsesSystemGlassWithoutCustomOpacity() {
        XCTAssertEqual(
            OverviewFormatting.appearance(
                backgroundStyle: .darkGlass,
                hudOpacity: 0.8,
                hudFontSize: 15,
                candidateSpacing: 5
            ),
            "系统玻璃 · 字号 15 pt · 间距 5 pt"
        )
    }

    func testAppearanceUsesFrostedGlassWithoutCustomOpacity() {
        XCTAssertEqual(
            OverviewFormatting.appearance(
                backgroundStyle: .frostedGlass,
                hudOpacity: 0.92,
                hudFontSize: 15,
                candidateSpacing: 5
            ),
            "磨砂玻璃 · 字号 15 pt · 间距 5 pt"
        )
    }

    func testAppearanceSummarizesSolidOpacitySizeAndSpacing() {
        XCTAssertEqual(
            OverviewFormatting.appearance(
                backgroundStyle: .solid,
                hudOpacity: 0.8,
                hudFontSize: 15,
                candidateSpacing: 5
            ),
            "背景不透明度 80% · 字号 15 pt · 间距 5 pt"
        )
        XCTAssertEqual(
            OverviewFormatting.appearance(
                backgroundStyle: .solid,
                hudOpacity: 1,
                hudFontSize: 13,
                candidateSpacing: 0
            ),
            "背景不透明度 100% · 字号 13 pt · 间距 0 pt"
        )
    }

    func testDictionaryCoverageDescribesCoreRoles() {
        XCTAssertEqual(
            OverviewFormatting.dictionaryCoverage,
            "基础释义 · 词频排序 · 扩展词条"
        )
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

    func testShortcutHintShowsInsertionAndSpeechRanges() {
        XCTAssertEqual(
            OverviewFormatting.shortcutHint(
                insertionShortcut:
                    TranslationInsertionShortcut(modifiers: [.option]),
                speechShortcut:
                    TranslationInsertionShortcut(modifiers: [.command]),
                maximumTranslationCount: 4
            ),
            "按 ⌥1–⌥4 插入译文 · ⌘1–⌘4 朗读译文"
        )
    }

    func testShortcutHintUsesSingleNumberForSingleTranslation() {
        XCTAssertEqual(
            OverviewFormatting.shortcutHint(
                insertionShortcut:
                    TranslationInsertionShortcut(modifiers: [.option]),
                speechShortcut: nil,
                maximumTranslationCount: 1
            ),
            "按 ⌥1 插入译文"
        )
    }

    func testShortcutHintShowsOnlyEnabledAction() {
        XCTAssertEqual(
            OverviewFormatting.shortcutHint(
                insertionShortcut: nil,
                speechShortcut:
                    TranslationInsertionShortcut(modifiers: [.command]),
                maximumTranslationCount: 3
            ),
            "按 ⌘1–⌘3 朗读译文"
        )
    }

    func testShortcutHintPromptsForConfigurationWhenDisabled() {
        XCTAssertEqual(
            OverviewFormatting.shortcutHint(
                insertionShortcut: nil,
                speechShortcut: nil,
                maximumTranslationCount: 4
            ),
            "在“通用配置”中设置译文快捷键"
        )
    }
}
