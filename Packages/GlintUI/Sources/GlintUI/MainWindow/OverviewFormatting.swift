import Foundation
import GlintCore

enum OverviewFormatting {
    static func dwellDuration(_ seconds: Double) -> String {
        String(format: "%.0f ms", seconds * 1_000)
    }

    static func appearance(
        backgroundStyle: HUDBackgroundStyle = .frostedGlass,
        hudOpacity: Double,
        hudFontSize: Double,
        candidateSpacing: Double
    ) -> String {
        if backgroundStyle != .solid {
            return "\(backgroundStyle.title) · "
                + String(
                    format: "字号 %.0f pt · 间距 %.0f pt",
                    hudFontSize,
                    candidateSpacing
                )
        }
        return String(
            format: "背景不透明度 %.0f%% · 字号 %.0f pt · 间距 %.0f pt",
            hudOpacity * 100,
            hudFontSize,
            candidateSpacing
        )
    }

    static let dictionaryCoverage = "基础释义 · 词频排序 · 扩展词条"

    static func shortcutHint(
        insertionShortcut: TranslationInsertionShortcut?,
        speechShortcut: TranslationInsertionShortcut?,
        maximumTranslationCount: Int
    ) -> String {
        let count = min(max(maximumTranslationCount, 1), 9)
        var actions: [String] = []
        if let insertionShortcut {
            actions.append(
                "\(shortcutRange(insertionShortcut, count: count)) 插入译文"
            )
        }
        if let speechShortcut {
            actions.append(
                "\(shortcutRange(speechShortcut, count: count)) 朗读译文"
            )
        }
        guard !actions.isEmpty else {
            return "在“通用配置”中设置译文快捷键"
        }
        return "按 " + actions.joined(separator: " · ")
    }

    /// Keeps the flow stage on one line; the full name stays in the card.
    static func compactModelName(
        _ name: String,
        maxLength: Int = 16
    ) -> String {
        let words = name.split(separator: " ")
        guard words.count > 1 else { return name }

        var result = String(words[0])
        for word in words.dropFirst() {
            let candidate = result + " " + word
            guard candidate.count <= maxLength else { break }
            result = candidate
        }
        return result
    }

    private static func shortcutRange(
        _ shortcut: TranslationInsertionShortcut,
        count: Int
    ) -> String {
        let trigger = shortcut.displayText.filter { !$0.isWhitespace }
        guard count > 1 else { return "\(trigger)1" }
        return "\(trigger)1–\(trigger)\(count)"
    }
}
