//
//  AppDelegate.swift
//  LikeWindows
//

import AppKit

extension Notification.Name {
    static let likeWindowsShowPreferences = Notification.Name("LikeWindowsShowPreferences")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        guard let existing = otherInstances.first else { return }

        DistributedNotificationCenter.default().post(
            name: .likeWindowsShowPreferences,
            object: bundleID
        )
        existing.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowPreferencesRequest),
            name: .likeWindowsShowPreferences,
            object: nil
        )

        WindowOpenOrderStore.startObservingAppTermination()
        QuickShowHideService.shared.start()
        DockInfoPopupService.shared.start()
        PreferencesWindowController.shared.showWindow()
    }

    @objc private func handleShowPreferencesRequest() {
        PreferencesWindowController.shared.showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockInfoPopupService.shared.stop()
        QuickShowHideService.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            PreferencesWindowController.shared.showWindow()
        }
        return true
    }
}
