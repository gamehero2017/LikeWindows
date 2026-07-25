//
//  AppDelegate.swift
//  LikeWindows
//

import AppKit

extension Notification.Name {
    /// 跨进程通知：已有实例应打开偏好设置（二次启动时由新进程发出）。
    static let likeWindowsShowPreferences = Notification.Name("LikeWindowsShowPreferences")
}

/// 应用生命周期协调中心。
///
/// ## 职责
/// 1. 单实例：Release 下二次启动通知已有实例并退出；Debug 下保留最新进程便于反复 Run
/// 2. 启动后台服务：窗口顺序存储、Event Tap（快显）、悬停弹窗监测
/// 3. 常驻：关偏好设置不退出；菜单栏图标 / Dock / 启动台可再次打开偏好设置
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Release：检测到已有实例后，在 `didFinishLaunching` 里退出自身。
    private var shouldExitAfterLaunch = false

    /// 尽早检测多开。Debug 故意不在此处退出，交给 `claimSingleInstanceLeadership`。
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        guard !otherInstances.isEmpty else { return }

        #if DEBUG
        return
        #else
        // 通知已有实例打开偏好设置，并激活它；本进程稍后退出
        if let existing = otherInstances.first {
            DistributedNotificationCenter.default().post(
                name: .likeWindowsShowPreferences,
                object: bundleID
            )
            existing.activate(options: [.activateAllWindows])
        }
        shouldExitAfterLaunch = true
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Xcode 反复 Run 时可能残留旧进程：只保留 PID 最新的一个
        if !claimSingleInstanceLeadership() {
            NSApp.terminate(nil)
            return
        }
        #endif

        if shouldExitAfterLaunch {
            shouldExitAfterLaunch = false
            NSApp.terminate(nil)
            return
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowPreferencesRequest),
            name: .likeWindowsShowPreferences,
            object: nil
        )

        // 后台能力：窗口身份缓存清理 + Dock 点击 + 悬停弹窗 + 菜单栏入口
        AppSettings.registerDefaults()
        WindowOpenOrderStore.startObservingAppTermination()
        QuickShowHideService.shared.start()
        DockInfoPopupService.shared.start()
        StatusItemController.shared.applyPreference()
        PreferencesWindowController.shared.showWindow()
    }

    #if DEBUG
    /// Debug 单实例：若存在更「新」的同 bundle 进程则本进程退出；否则杀掉旧实例。
    private func claimSingleInstanceLeadership() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }

        let myPID = ProcessInfo.processInfo.processIdentifier
        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != myPID
        }

        guard !otherInstances.isEmpty else { return true }

        let newestPID = ([myPID] + otherInstances.map(\.processIdentifier)).max() ?? myPID
        guard myPID == newestPID else { return false }

        for app in otherInstances {
            app.terminate()
        }
        return true
    }
    #endif

    @objc private func handleShowPreferencesRequest() {
        PreferencesWindowController.shared.showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        StatusItemController.shared.remove()
        DockInfoPopupService.shared.stop()
        QuickShowHideService.shared.stop()
    }

    /// 关偏好设置窗口后不退出，配合 `.accessory` 实现后台常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 用户从 Dock / 启动台再次点开应用图标时，若无可见窗口则重新显示偏好设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            PreferencesWindowController.shared.showWindow()
        }
        return true
    }
}
