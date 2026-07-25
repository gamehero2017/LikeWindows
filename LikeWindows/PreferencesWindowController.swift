//
//  PreferencesWindowController.swift
//  LikeWindows
//

import AppKit
import SwiftUI

/// 偏好设置窗口控制器。
///
/// ## Dock 图标策略
/// - 打开偏好设置 → `.regular`：在 Dock 显示图标，方便用户找到
/// - 关闭偏好设置 → `.accessory`：隐藏 Dock 图标，进程继续跑 Event Tap / 悬停
///
/// 窗口 `isReleasedWhenClosed = false`，关闭后可再次 `showWindow` 复用同一实例。
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private static let defaultSize = NSSize(width: 460, height: 520)
    private static let minimumSize = NSSize(width: 440, height: 300)

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    /// 展示偏好设置；窗口已存在则前置，否则创建并嵌入 `ContentView`。
    func showWindow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in
                showWindow()
            }
            return
        }

        if let window {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            showInDock()
            return
        }

        let hostingController = NSHostingController(rootView: ContentView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "如窗"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.defaultSize)
        window.minSize = Self.minimumSize
        window.center()
        window.delegate = self
        // 关闭后保留窗口对象，避免反复创建 SwiftUI 宿主
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        showInDock()
    }

    func windowWillClose(_ notification: Notification) {
        hideFromDock()
    }

    /// 偏好设置打开时显示 Dock 图标并激活应用。
    private func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// 偏好设置关闭后隐藏 Dock 图标；Event Tap 等后台能力不受影响。
    private func hideFromDock() {
        NSApp.setActivationPolicy(.accessory)
    }
}
