import Foundation
import GlintCore

extension MainWindowModel {
    public func updateActiveInputMethod(
        _ identity: InputMethodIdentity?
    ) {
        let name = identity?.displayName ?? "输入法"
        guard activeInputMethodName != name else { return }
        activeInputMethodName = name
    }

    public func refreshInputMethodSupport() async {
        guard !isLoadingInputMethodSupport else { return }
        isLoadingInputMethodSupport = true
        inputMethodSupportError = nil
        inputMethodSupportStatuses =
            await actions.permissions.refreshInputMethodSupport()
        isLoadingInputMethodSupport = false
    }

    public func installSquirrelSupport() async {
        guard !isUpdatingInputMethodSupport else { return }
        isUpdatingInputMethodSupport = true
        inputMethodSupportError = nil
        defer { isUpdatingInputMethodSupport = false }
        do {
            inputMethodSupportStatuses =
                try await actions.permissions.installSquirrelSupport()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await actions.permissions.refreshInputMethodSupport()
            inputMethodSupportError = message
        }
    }

    public func uninstallSquirrelSupport() async {
        guard !isUpdatingInputMethodSupport else { return }
        isUpdatingInputMethodSupport = true
        inputMethodSupportError = nil
        defer { isUpdatingInputMethodSupport = false }
        do {
            inputMethodSupportStatuses =
                try await actions.permissions.uninstallSquirrelSupport()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await actions.permissions.refreshInputMethodSupport()
            inputMethodSupportError = message
        }
    }
}
