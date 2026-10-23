import GlintCore

extension TranslationMode {
    var title: String {
        switch self {
        case .dictionaryFirst:
            "词典优先"
        case .modelFirst:
            "模型优先"
        }
    }

    var explanation: String {
        switch self {
        case .dictionaryFirst:
            "先查词典，未命中或失败时自动使用当前翻译模型。"
        case .modelFirst:
            "先使用当前翻译模型，失败或无结果时自动查词典。"
        }
    }
}

extension CandidateTranslationScope {
    var title: String {
        switch self {
        case .selected:
            "选中"
        case .row:
            "一栏"
        }
    }

    var explanation: String {
        switch self {
        case .selected:
            "只显示当前高亮候选的对应英文翻译，展开更多候选后隐藏。"
        case .row:
            "仅在单行候选栏显示首栏候选的对应英文翻译，展开更多候选后隐藏。"
        }
    }
}
