//
//  AccessibilityHealth.swift
//  LikeWindows
//

import AppKit
import ApplicationServices

enum AccessibilityHealth {
    private static let cacheTTL: TimeInterval = 10
    private static var cachedWorking: Bool?
    private static var cacheTimestamp: Date?
    private static let lock = NSLock()

    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedWorking = nil
        cacheTimestamp = nil
    }

    static func isWorking(forceRefresh: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else {
            invalidate()
            return false
        }

        lock.lock()
        if !forceRefresh,
           let cachedWorking,
           let cacheTimestamp,
           Date().timeIntervalSince(cacheTimestamp) < cacheTTL {
            let value = cachedWorking
            lock.unlock()
            return value
        }
        lock.unlock()

        let working = probeAccessibility()

        lock.lock()
        cachedWorking = working
        cacheTimestamp = Date()
        lock.unlock()

        return working
    }

    private static func probeAccessibility() -> Bool {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }

        let dockRef = AXUIElementCreateApplication(dockApp.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(dockRef, kAXChildrenAttribute as CFString, &value) == .success else {
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var probe: AXUIElement?
        return AXUIElementCopyElementAtPosition(systemWide, 0, 0, &probe) == .success
    }
}
