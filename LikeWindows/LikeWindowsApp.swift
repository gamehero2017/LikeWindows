//
//  LikeWindowsApp.swift
//  LikeWindows
//

import SwiftUI

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
