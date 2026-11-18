import AppKit

extension AppDelegate {
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        updateStatusItem(isMonitoring: false)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("显示主界面", action: #selector(openMainWindow)))
        monitoringMenuItem = item(
            "开启翻译显示",
            action: #selector(toggleMonitoring)
        )
        menu.addItem(monitoringMenuItem)
        menu.addItem(NSMenuItem.separator())
        updateMenuItem = item("检查更新…", action: #selector(checkForUpdates))
        menu.addItem(updateMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(item("退出", action: #selector(quit)))
        menu.delegate = self
        statusItem.menu = menu
        statusItem.isVisible =
            !windowModel.generalPreferences.isMenuBarIconHidden
        updateAppUpdateMenuItem()
    }

    func updateStatusItemVisibility() {
        guard statusItem != nil else { return }
        statusItem.isVisible =
            !windowModel.generalPreferences.isMenuBarIconHidden
    }

    func updateActivationPolicy() {
        let policy =
            windowModel.generalPreferences.applicationActivationPolicy
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.setActivationPolicy(policy) else {
            appLogger.error(
                "failed to update activation policy=\(policy.rawValue, privacy: .public)"
            )
            return
        }
    }

    func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Glint")
        let hideItem = NSMenuItem(
            title: "隐藏 Glint",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hideItem.target = NSApp
        appMenu.addItem(hideItem)
        appMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(
            title: "退出 Glint",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem(
            title: "Glint",
            action: nil,
            keyEquivalent: ""
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenu = NSMenu(title: "窗口")
        let closeItem = NSMenuItem(
            title: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(closeItem)

        let windowMenuItem = NSMenuItem(
            title: "窗口",
            action: nil,
            keyEquivalent: ""
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func updateStatusItem(isMonitoring: Bool) {
        guard let button = statusItem.button else { return }
        button.image = brandMarkImage(isMonitoring: isMonitoring)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.toolTip =
            windowModel.isPreparingMonitoring
            ? "Glint · 正在准备翻译模型"
            : (isMonitoring ? "Glint · 翻译显示已开启" : "Glint · 翻译显示已关闭")
        button.setAccessibilityLabel(
            isMonitoring ? "Glint，翻译显示已开启" : "Glint，翻译显示已关闭"
        )
    }

    func brandMarkImage(isMonitoring: Bool) -> NSImage? {
        let resourceName = isMonitoring ? "BrandMark" : "BrandMarkOff"
        guard let image = NSImage(named: resourceName)?.copy() as? NSImage else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    func updateMonitoringMenuItem() {
        guard let monitoringMenuItem else { return }
        if windowModel.isPreparingMonitoring {
            monitoringMenuItem.title = "正在准备翻译模型…"
            monitoringMenuItem.isEnabled = false
            return
        }
        switch sessionState {
        case .idle:
            monitoringMenuItem.title = "开启翻译显示"
            monitoringMenuItem.isEnabled = true
        case .starting:
            monitoringMenuItem.title = "正在开启…"
            monitoringMenuItem.isEnabled = false
        case .running:
            monitoringMenuItem.title = "关闭翻译显示"
            monitoringMenuItem.isEnabled = true
        case .stopping:
            monitoringMenuItem.title = "正在关闭…"
            monitoringMenuItem.isEnabled = false
        }
    }

    func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        updateAppUpdateMenuItem()
    }

    func updateAppUpdateMenuItem() {
        guard let updateMenuItem else { return }
        let presentation = appUpdateModel.status.menuPresentation
        updateMenuItem.title = presentation.title
        updateMenuItem.isEnabled = presentation.isEnabled
    }

    @objc func openMainWindow() {
        showMainWindow()
    }

    func showMainWindow() {
        refreshActiveInputMethodName()
        NSApp.unhide(nil)
        mainWindowController.show()
    }

    @objc func toggleMonitoring() {
        if windowModel.isPreparingMonitoring { return }
        switch sessionState {
        case .idle:
            startMonitoring()
        case .running:
            stopMonitoring()
        case .starting, .stopping:
            break
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
