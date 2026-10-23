import Foundation

public enum CandidateClassifier {
    private static let sentenceMarks = CharacterSet(
        charactersIn: "。！？!?；;…\n"
    )
    private static let sentenceCues: Set<String> = [
        "吗", "呢", "吧", "呀", "嘛",
        "什么", "怎么", "为什么", "如何", "哪", "谁",
        "是否", "多少", "几时", "多久",
        "这个", "那个", "这些", "那些",
        "可以", "需要", "应该", "已经", "正在", "还是",
        "因为", "所以", "如果", "但是", "而且", "然后",
        "请", "帮我", "一下",
    ]

    public static func classify(_ text: String) -> CandidateKind {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .unknown }

        if text.unicodeScalars.contains(where: {
            Self.sentenceMarks.contains($0)
        }) {
            return .sentence
        }

        if Self.sentenceCues.contains(where: text.contains) {
            return .sentence
        }
        if text.contains(where: \.isWhitespace) {
            return .sentence
        }
        if text.count >= 5 {
            return .sentence
        }
        if text.count >= 2 {
            return .phrase
        }
        return .word
    }
}
