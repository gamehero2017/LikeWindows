//
//  StatusItemController.swift
//  LikeWindows
//

import AppKit

/// 菜单栏常驻入口：后台运行时通过状态栏图标打开偏好设置或退出应用。
///
/// ## 为什么用菜单栏而不是「系统设置」侧栏
/// macOS Ventura 及以后的「系统设置」左侧栏仅收录系统 / Apple 扩展，
/// 第三方应用无法正式注册侧栏项。后台工具的标准做法是菜单栏 Status Item。
///
/// 是否显示由偏好设置 `AppSettings.menuBarIconVisible` 控制。
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
    }

    /// 按当前偏好安装或移除菜单栏图标。
    func applyPreference() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyPreference()
            }
            return
        }

        if AppSettings.isMenuBarIconVisible {
            install()
        } else {
            remove()
        }
    }

    /// 安装菜单栏图标与下拉菜单（幂等，可重复调用）。
    func install() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.install()
            }
            return
        }

        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            if let image = NSImage(named: "MenuBarIcon") {
                image.isTemplate = true
                button.image = image
            } else {
                // 资源缺失时的兜底，保证入口仍可见
                button.title = "如窗"
            }
            button.toolTip = "如窗"
            button.imagePosition = .imageOnly
        }

        item.menu = buildMenu()
    }

    /// 移除状态项（偏好关闭或应用退出时调用）。
    func remove() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.remove()
            }
            return
        }

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "打开偏好设置",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        openItem.target = self
        openItem.keyEquivalentModifierMask = [.command]
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出如窗",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)

        return menu
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
