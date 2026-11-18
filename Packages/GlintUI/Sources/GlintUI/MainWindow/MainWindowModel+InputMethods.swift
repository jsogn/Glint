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
            await refreshInputMethodSupportAction()
        isLoadingInputMethodSupport = false
    }

    public func installSquirrelSupport() async {
        guard !isUpdatingInputMethodSupport else { return }
        isUpdatingInputMethodSupport = true
        inputMethodSupportError = nil
        defer { isUpdatingInputMethodSupport = false }
        do {
            inputMethodSupportStatuses =
                try await installSquirrelSupportAction()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await refreshInputMethodSupportAction()
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
                try await uninstallSquirrelSupportAction()
        } catch {
            let message = error.localizedDescription
            inputMethodSupportStatuses =
                await refreshInputMethodSupportAction()
            inputMethodSupportError = message
        }
    }
}
