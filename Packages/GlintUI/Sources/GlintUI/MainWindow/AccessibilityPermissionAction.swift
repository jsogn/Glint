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

    func perform() {
        if model.hasRequestedAccessibilityPermission {
            model.openAccessibilitySettings()
        } else {
            model.requestPermissions()
        }
    }
}
