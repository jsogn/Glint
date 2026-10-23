import Foundation

enum OverviewFormatting {
    static func dwellDuration(_ seconds: Double) -> String {
        String(format: "%.0f ms", seconds * 1_000)
    }

    static func appearance(
        hudOpacity: Double,
        hudFontSize: Double,
        candidateSpacing: Double
    ) -> String {
        String(
            format: "背景不透明度 %.0f%% · 字号 %.0f pt · 间距 %.0f pt",
            hudOpacity * 100,
            hudFontSize,
            candidateSpacing
        )
    }

    static func dictionaryCount(_ count: Int) -> String {
        "\(count) 个"
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
}
