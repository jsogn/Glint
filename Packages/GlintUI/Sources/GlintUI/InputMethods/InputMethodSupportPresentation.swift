import Foundation

struct InputMethodSupportPresentation: Equatable, Sendable {
    let statusTitle: String
    let headline: String
    let description: String
    let primaryActionTitle: String?
}

extension InputMethodSupportStatus {
    var presentation: InputMethodSupportPresentation {
        switch state {
        case .native:
            InputMethodSupportPresentation(
                statusTitle: "原生支持",
                headline: "候选读取支持",
                description: detail,
                primaryActionTitle: nil
            )
        case .available:
            InputMethodSupportPresentation(
                statusTitle: "未安装",
                headline: "候选读取支持",
                description:
                    "安装后即可读取 Rime 当前高亮的候选内容。",
                primaryActionTitle: "安装支持"
            )
        case .installed:
            InputMethodSupportPresentation(
                statusTitle: "已安装",
                headline: "候选读取支持",
                description:
                    "用于读取 Rime 当前高亮的候选内容。",
                primaryActionTitle: "重新安装"
            )
        case .repairRequired:
            InputMethodSupportPresentation(
                statusTitle: "需要重新安装",
                headline: "候选读取支持",
                description:
                    "当前安装与 Rime 配置不匹配，需要重新安装。",
                primaryActionTitle: "重新安装"
            )
        case .manualSetupRequired:
            InputMethodSupportPresentation(
                statusTitle: "需要手动配置",
                headline: "候选读取支持",
                description: detail,
                primaryActionTitle: nil
            )
        case .unavailable:
            InputMethodSupportPresentation(
                statusTitle: "不可用",
                headline: "候选读取支持",
                description: detail,
                primaryActionTitle: nil
            )
        }
    }
}
