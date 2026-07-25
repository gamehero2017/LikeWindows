//
//  LikeWindowsApp.swift
//  LikeWindows
//

import SwiftUI

/// 应用入口：偏好设置窗口由 AppDelegate / PreferencesWindowController 管理，
/// 此处仅挂接 AppDelegate，并抑制默认 Settings 场景弹出。
@main
struct LikeWindowsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)
    }
}
