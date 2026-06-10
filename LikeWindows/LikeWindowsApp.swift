//
//  likeWindowsApp.swift
//  likeWindows
//
//  Created by 青藤 on 2026/6/9.
//

import SwiftUI

@main
struct LikeWindowsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 500, height: 680)
    }
}
