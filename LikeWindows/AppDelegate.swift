//
//  AppDelegate.swift
//  LikeWindows
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowOpenOrderStore.startObservingAppTermination()
        QuickShowHideService.shared.start()
        DockInfoPopupService.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockInfoPopupService.shared.stop()
        QuickShowHideService.shared.stop()
    }
}
