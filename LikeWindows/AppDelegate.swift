//
//  AppDelegate.swift
//  LikeWindows
//

import AppKit

extension Notification.Name {
    static let likeWindowsShowPreferences = Notification.Name("LikeWindowsShowPreferences")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shouldExitAfterLaunch = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }

        let otherInstances = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        guard !otherInstances.isEmpty else { return }

        #if DEBUG
        return
        #else
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

        WindowOpenOrderStore.startObservingAppTermination()
        QuickShowHideService.shared.start()
        DockInfoPopupService.shared.start()
        PreferencesWindowController.shared.showWindow()
    }

    #if DEBUG
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
