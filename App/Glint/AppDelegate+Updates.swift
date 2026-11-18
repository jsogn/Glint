import AppKit
import GlintUI
import SwiftUI

@MainActor
final class GlintUpdatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

extension AppDelegate {
    @objc func checkForUpdates() {
        let presentation = appUpdateModel.status.menuPresentation
        if let destinationURL = presentation.destinationURL {
            NSWorkspace.shared.open(destinationURL)
            return
        }

        performUpdateCheck()
    }

    func performUpdateCheck() {
        guard !appUpdateModel.isChecking else { return }

        updateMenuItem.title =
            AppUpdateStatus.checking.menuPresentation.title
        updateMenuItem.isEnabled = false
        showUpdateProgress()
        Task { [weak self] in
            guard let self else { return }
            await appUpdateModel.checkForUpdates()
            updateAppUpdateMenuItem()
            showUpdateResult()
        }
    }

    func scheduleAutomaticAppUpdateCheck() {
        automaticAppUpdateCheckTask?.cancel()
        automaticAppUpdateCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await appUpdateModel.automaticallyCheckForUpdates()
            guard !Task.isCancelled else { return }
            updateAppUpdateMenuItem()
            automaticAppUpdateCheckTask = nil
        }
    }

    func showUpdateProgress() {
        dismissUpdatePanel()

        let panel = makeUpdatePanel()
        updatePanel = panel
        let content = AppUpdatePanelContent.checking
        installUpdatePanelContent(
            AppUpdatePanelView(content: content),
            size: AppUpdatePanelView.panelSize(for: content),
            in: panel
        )
    }

    func showUpdateResult() {
        guard let presentation = appUpdateModel.status.resultPresentation else {
            dismissUpdatePanel()
            return
        }

        presentUpdateResult(presentation)
    }

    func presentUpdateResult(
        _ presentation: AppUpdateResultPresentation
    ) {
        guard let panel = updatePanel else { return }
        pendingUpdateURL = presentation.destinationURL
        let content = AppUpdatePanelContent.result(presentation)

        installUpdatePanelContent(
            AppUpdatePanelView(
                content: content,
                onPrimaryAction: { [weak self] in
                    guard let self else { return }
                    if presentation.destinationURL == nil {
                        dismissUpdatePanel()
                    } else {
                        openUpdateDownload()
                    }
                },
                onSecondaryAction: { [weak self] in
                    self?.dismissUpdatePanel()
                }
            ),
            size: AppUpdatePanelView.panelSize(for: content),
            in: panel
        )
    }

    func makeUpdatePanel() -> GlintUpdatePanel {
        let panel = GlintUpdatePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true

        let contentView = NSView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = contentView
        return panel
    }

    func installUpdatePanelContent<Content: View>(
        _ content: Content,
        size: CGSize,
        in panel: NSPanel
    ) {
        let hostingView = NSHostingView(rootView: content)
        hostingView.sizingOptions = []
        panel.setContentSize(size)

        guard let contentView = panel.contentView else { return }
        UpdatePanelContent.install(hostingView, in: contentView)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.center()
        panel.orderFrontRegardless()
    }

    @objc func openUpdateDownload() {
        if let pendingUpdateURL {
            NSWorkspace.shared.open(pendingUpdateURL)
        }
        dismissUpdatePanel()
    }

    @objc func dismissUpdatePanel() {
        updatePanel?.orderOut(nil)
        updatePanel = nil
        pendingUpdateURL = nil
    }
}
