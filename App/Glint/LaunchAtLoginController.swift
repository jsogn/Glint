import AppKit
import Carbon
import GlintUI
import ServiceManagement

@MainActor
final class LaunchAtLoginController {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        switch (enabled, service.status) {
        case (true, .notRegistered), (true, .notFound):
            try service.register()
        case (false, .enabled), (false, .requiresApproval):
            try service.unregister()
        default:
            break
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
enum LoginLaunchDetector {
    static func wasLaunchedAtLogin() -> Bool {
        guard
            let event = NSAppleEventManager.shared().currentAppleEvent
        else {
            return false
        }
        return event.paramDescriptor(
            forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
        ) != nil
    }
}
