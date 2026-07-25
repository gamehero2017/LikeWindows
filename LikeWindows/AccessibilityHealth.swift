//
//  AccessibilityHealth.swift
//  LikeWindows
//

import AppKit
import ApplicationServices

/// 辅助功能「真实可用性」探测。
///
/// ## 为什么不只看 `AXIsProcessTrusted()`
/// 系统开关打开后，AX API 偶发仍不可用（权限传播延迟、TCC 异常等）。
/// Dock 点击 / 悬停依赖 AX，若此时强行开 Event Tap，会出现「点了没反应」。
/// 因此除信任标志外，再对 Dock 与系统级 AX 做一次轻量探测。
///
/// ## 缓存
/// 探测有成本，结果缓存约 10 秒；授权状态变化时应调用 `invalidate()`。
enum AccessibilityHealth {
    private static let cacheTTL: TimeInterval = 10
    private static var cachedWorking: Bool?
    private static var cacheTimestamp: Date?
    private static let lock = NSLock()

    /// 清除探测缓存（例如用户刚从系统设置返回、偏好页刷新状态时）。
    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cachedWorking = nil
        cacheTimestamp = nil
    }

    /// 辅助功能当前是否可用。
    /// - Parameter forceRefresh: 为 true 时跳过缓存强制重测
    static func isWorking(forceRefresh: Bool = false) -> Bool {
        // 未授权则直接失败，并清缓存，避免「曾可用」的脏数据
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

    /// 两步探测（都成功才视为可用）：
    /// 1. 能读到 Dock 的 AX 子节点 —— 说明能访问 Dock 进程树（点击命中依赖此）
    /// 2. 能在屏幕中心取到元素 —— 说明系统级 AX 命中可用
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
        let screen = NSScreen.main ?? NSScreen.screens.first
        let probePoint = screen.map { NSPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? NSPoint(x: 100, y: 100)
        // Cocoa Y 原点在左下，AX/CG 原点在左上，需翻转
        let screenHeight = screen?.frame.height ?? probePoint.y * 2
        let cgPoint = CGPoint(x: probePoint.x, y: screenHeight - probePoint.y)

        var probe: AXUIElement?
        return AXUIElementCopyElementAtPosition(
            systemWide,
            Float(cgPoint.x),
            Float(cgPoint.y),
            &probe
        ) == .success
    }
}
