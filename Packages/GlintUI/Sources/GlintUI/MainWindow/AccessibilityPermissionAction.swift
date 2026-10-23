@MainActor
struct AccessibilityPermissionAction {
    let model: MainWindowModel

    var title: String {
        model.hasRequestedAccessibilityPermission
            ? "打开辅助功能设置"
            : "授权辅助功能"
    }

    var symbol: String {
        model.hasRequestedAccessibilityPermission
            ? "gearshape"
            : "lock.open"
    }

    var guidance: String {
        model.hasRequestedAccessibilityPermission
            ? "在系统设置中开启 Glint，返回后会自动更新状态。"
            : "macOS 会请求你允许 Glint 使用辅助功能。"
    }

    func perform() {
        if model.hasRequestedAccessibilityPermission {
            model.openAccessibilitySettings()
        } else {
            model.requestPermissions()
        }
    }
}
