//
//  PreferencesWindowController.swift
//  LikeWindows
//

import AppKit
import SwiftUI

@MainActor
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private static let defaultSize = NSSize(width: 460, height: 520)
    private static let minimumSize = NSSize(width: 440, height: 300)

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func showWindow() {
        if let window {
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFrontRegardless()
            }
            NSApp.activate()
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
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        showInDock()
    }

    func windowWillClose(_ notification: Notification) {
        hideFromDock()
    }

    private func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func hideFromDock() {
        NSApp.setActivationPolicy(.accessory)
    }
}
