//
//  AppWindowInspector.swift
//  likeWindows
//

import AppKit
import ApplicationServices

enum AppWindowInspector {
    private static let popupWindowCacheTTL: TimeInterval = 0.6
    private static let maxCacheEntries = 20

    private struct WindowListCache {
        let windows: [DockWindowInfo]
        let timestamp: Date
    }

    private static var popupWindowCache: [pid_t: WindowListCache] = [:]
    private static var cacheAccessOrder: [pid_t] = []
    private static let cacheLock = NSLock()

    static func invalidateWindowCache(for processIdentifier: pid_t? = nil) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let processIdentifier {
            popupWindowCache.removeValue(forKey: processIdentifier)
            cacheAccessOrder.removeAll { $0 == processIdentifier }
        } else {
            popupWindowCache.removeAll()
            cacheAccessOrder.removeAll()
        }
    }

    /// 点击路径判断多窗口，计数到 2 即停止，避免全量枚举
    static func hasMultipleTrackableWindows(for app: NSRunningApplication) -> Bool {
        countTrackableAXWindows(for: app) > 1
    }

    private static func windowsInSystemOrder(_ windows: [DockWindowInfo]) -> [DockWindowInfo] {
        windows.enumerated().map { index, info in
            DockWindowInfo(
                stableOrderKey: info.stableOrderKey,
                title: info.title,
                isMinimized: info.isMinimized,
                processIdentifier: info.processIdentifier,
                windowIndex: index,
                canClose: info.canClose,
                canMinimize: info.canMinimize,
                canZoom: info.canZoom,
                cgWindowNumber: info.cgWindowNumber
            )
        }
    }

    /// popup 快照：一次枚举，供悬停/展示复用
    static func popupSnapshot(for app: NSRunningApplication, useCache: Bool = true) -> (windows: [DockWindowInfo], shouldShow: Bool) {
        let windows = popupWindows(for: app, useCache: useCache)
        return (windows, windows.count > 1)
    }

    static func popupWindows(for app: NSRunningApplication, useCache: Bool = false) -> [DockWindowInfo] {
        let pid = app.processIdentifier

        if useCache, let cached = cachedPopupWindows(for: pid) {
            let refreshed = refreshLiveWindowStatesLight(cached, for: app)
            if refreshed.map(\.stableOrderKey) != cached.map(\.stableOrderKey) {
                storePopupCache(pid, windows: refreshed)
            }
            return refreshed
        }

        let built = buildPopupWindowsLight(for: app)
        if useCache {
            storePopupCache(pid, windows: built)
        }
        return built
    }

    /// popup 路径：一次 AX 枚举 + 内存匹配，不逐窗 axWindow(for:)
    private static func refreshLiveWindowStatesLight(
        _ windows: [DockWindowInfo],
        for app: NSRunningApplication
    ) -> [DockWindowInfo] {
        let axWindows = trackableAXWindows(for: app)
        guard !axWindows.isEmpty else { return windows }

        if axWindows.count != windows.count {
            return buildPopupWindowsLight(for: app)
        }

        var axByOrderKey: [String: AXUIElement] = [:]
        var axByFingerprint: [String: AXUIElement] = [:]

        for axWindow in axWindows {
            let fingerprint = axWindowFingerprint(axWindow)
            axByFingerprint[fingerprint] = axWindow
            if let orderKey = WindowOpenOrderStore.lookupKey(
                processIdentifier: app.processIdentifier,
                fingerprint: fingerprint
            ) {
                axByOrderKey[orderKey] = axWindow
            }
        }

        return windows.map { info in
            let axWindow = axByOrderKey[info.stableOrderKey]
                ?? knownFingerprintMatch(for: info, in: axByFingerprint)

            guard let axWindow else { return info }

            return DockWindowInfo(
                stableOrderKey: info.stableOrderKey,
                title: displayTitleLight(for: axWindow),
                isMinimized: isMinimized(axWindow),
                processIdentifier: info.processIdentifier,
                windowIndex: info.windowIndex,
                canClose: hasEnabledButton(axWindow, kAXCloseButtonAttribute as CFString),
                canMinimize: hasEnabledButton(axWindow, kAXMinimizeButtonAttribute as CFString),
                canZoom: hasEnabledButton(axWindow, kAXZoomButtonAttribute as CFString),
                cgWindowNumber: info.cgWindowNumber
            )
        }
    }

    private static func knownFingerprintMatch(
        for info: DockWindowInfo,
        in axByFingerprint: [String: AXUIElement]
    ) -> AXUIElement? {
        for fingerprint in WindowOpenOrderStore.knownFingerprints(for: info.stableOrderKey) {
            if let axWindow = axByFingerprint[fingerprint] {
                return axWindow
            }
        }
        return nil
    }

    static func hasVisibleWindowFast(for app: NSRunningApplication) -> Bool {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        if let focused = copyWindowAttribute(kAXFocusedWindowAttribute as CFString, from: appRef),
           isTrackableWindow(focused),
           !isMinimized(focused) {
            return true
        }

        if let main = copyWindowAttribute(kAXMainWindowAttribute as CFString, from: appRef),
           isTrackableWindow(main),
           !isMinimized(main) {
            return true
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return false
        }

        return axWindows.contains {
            isTrackableWindow($0) && !isMinimized($0)
        }
    }

    @discardableResult
    static func minimizeAllVisibleWindows(for app: NSRunningApplication) -> Bool {
        invalidateWindowCache(for: app.processIdentifier)

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return false
        }

        let visible = axWindows.filter {
            isTrackableWindow($0)
                && !isMinimized($0)
                && !isFullscreen($0)
        }
        guard !visible.isEmpty else { return false }

        var didMinimizeAny = false
        for window in visible {
            if animatedMinimize(window) {
                didMinimizeAny = true
            }
        }
        return didMinimizeAny
    }

    private static func cachedPopupWindows(for pid: pid_t) -> [DockWindowInfo]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let cached = popupWindowCache[pid],
              Date().timeIntervalSince(cached.timestamp) < popupWindowCacheTTL else {
            return nil
        }

        touchCacheEntryLocked(pid)
        return cached.windows
    }

    private static func storePopupCache(_ pid: pid_t, windows: [DockWindowInfo]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        popupWindowCache[pid] = WindowListCache(windows: windows, timestamp: Date())
        touchCacheEntryLocked(pid)
        evictCacheIfNeededLocked()
    }

    private static func touchCacheEntryLocked(_ pid: pid_t) {
        cacheAccessOrder.removeAll { $0 == pid }
        cacheAccessOrder.append(pid)
    }

    private static func evictCacheIfNeededLocked() {
        while cacheAccessOrder.count > maxCacheEntries {
            let evicted = cacheAccessOrder.removeFirst()
            popupWindowCache.removeValue(forKey: evicted)
        }
    }

    private static func buildPopupWindowsLight(for app: NSRunningApplication) -> [DockWindowInfo] {
        let axWindows = trackableAXWindows(for: app)
        var seenOrderKeys = Set<String>()

        let raw = axWindows.compactMap { window -> DockWindowInfo? in
            let title = displayTitleLight(for: window)
            let fingerprint = axWindowFingerprint(window)
            let orderKey = WindowOpenOrderStore.orderKey(
                processIdentifier: app.processIdentifier,
                cgWindowNumber: nil,
                fingerprint: fingerprint
            )
            WindowOpenOrderStore.registerFingerprint(orderKey, fingerprint: fingerprint)

            guard seenOrderKeys.insert(orderKey).inserted else {
                return nil
            }

            return DockWindowInfo(
                stableOrderKey: orderKey,
                title: title,
                isMinimized: isMinimized(window),
                processIdentifier: app.processIdentifier,
                windowIndex: 0,
                canClose: hasEnabledButton(window, kAXCloseButtonAttribute as CFString),
                canMinimize: hasEnabledButton(window, kAXMinimizeButtonAttribute as CFString),
                canZoom: hasEnabledButton(window, kAXZoomButtonAttribute as CFString),
                cgWindowNumber: nil
            )
        }

        if UserDefaults.standard.bool(forKey: AppSettings.useSystemWindowOrder) {
            return windowsInSystemOrder(raw)
        }
        return WindowOpenOrderStore.sortedWindows(raw, for: app.processIdentifier)
    }

    private static func displayTitleLight(for axWindow: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let raw = titleRef as? String,
           !raw.isEmpty {
            return raw
        }
        return "默认"
    }

    /// 激活并打开 popup 中选中的窗口（须在主线程调用）
    @discardableResult
    static func activateWindow(_ window: DockWindowInfo) -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                _ = activateWindow(window)
            }
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier) else {
            return false
        }
        guard let resolvedWindow = axWindow(for: window) else { return false }

        bringApplicationToFront(app)

        if window.isMinimized || isMinimized(resolvedWindow) {
            _ = restoreMinimizedWindow(resolvedWindow, app: app)
        }

        invalidateWindowCache(for: app.processIdentifier)
        let focused = focusWindow(resolvedWindow, app: app)

        if !focused || !isWindowFocused(resolvedWindow, app: app) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                bringApplicationToFront(app)
                let target = axWindow(for: window) ?? resolvedWindow
                if isMinimized(target) {
                    _ = restoreMinimizedWindow(target, app: app)
                }
                _ = focusWindow(target, app: app)
            }
        }

        return focused
    }

    private static func isWindowFocused(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard app.isActive else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyWindowAttribute(kAXFocusedWindowAttribute as CFString, from: appRef) else {
            return false
        }
        return CFEqual(window, focused)
    }

    @discardableResult
    static func perform(_ action: WindowControlAction, window: DockWindowInfo) -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                _ = perform(action, window: window)
            }
            return false
        }

        guard let axWindow = axWindow(for: window) else { return false }
        invalidateWindowCache(for: window.processIdentifier)

        switch action {
        case .close:
            return pressButton(axWindow, kAXCloseButtonAttribute as CFString)
        case .minimize:
            return animatedMinimize(axWindow)
        case .zoom:
            return pressButton(axWindow, kAXZoomButtonAttribute as CFString)
        }
    }

    /// 单窗口前台可见时隐藏；其余情况交给系统处理以保留原生动画（须在主线程调用）
    static func hideActiveWindowIfVisible(for app: NSRunningApplication) -> Bool {
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return hideSelfWindowIfVisibleOnMain()
        }

        guard hasVisibleWindowFast(for: app) else { return false }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = resolvePrimaryWindow(in: appRef), !isMinimized(window) else {
            return false
        }

        invalidateWindowCache(for: app.processIdentifier)
        animatedMinimize(window)
        return true
    }

    private static func bringApplicationToFront(_ app: NSRunningApplication) {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        if app.isHidden {
            _ = AXUIElementSetAttributeValue(appRef, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        }

        app.activate(options: [.activateAllWindows])
    }

    @discardableResult
    private static func restoreMinimizedWindow(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard isMinimized(window) else { return true }

        bringApplicationToFront(app)

        if AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success,
           !isMinimized(window) {
            return true
        }

        if pressButton(window, kAXMinimizeButtonAttribute as CFString),
           !isMinimized(window) {
            return true
        }

        if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success,
           !isMinimized(window) {
            return true
        }

        _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        return !isMinimized(window)
    }

    @discardableResult
    private static func focusWindow(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        if isMinimized(window) {
            _ = restoreMinimizedWindow(window, app: app)
        }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var succeeded = false

        if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            succeeded = true
        }
        if AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue) == .success {
            succeeded = true
        }
        if AXUIElementSetAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, window) == .success {
            succeeded = true
        }
        if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            succeeded = true
        }

        return succeeded
    }

    @discardableResult
    private static func hideSelfWindowIfVisibleOnMain() -> Bool {
        guard NSApp.isActive else { return false }
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isMiniaturized }) else {
            return false
        }
        window.miniaturize(nil)
        return true
    }

    private static func axWindow(for window: DockWindowInfo) -> AXUIElement? {
        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier) else {
            return nil
        }

        let windows = trackableAXWindows(for: app)
        let cgEntries = cgWindowEntries(for: app)

        if let matched = axWindowByStableOrderKey(window, in: windows) {
            return matched
        }

        if window.isMinimized,
           let matched = axWindowForMinimized(window, in: windows, cgEntries: cgEntries) {
            return matched
        }

        if let number = window.cgWindowNumber {
            if let cgEntry = cgEntries.first(where: { $0.number == number }),
               let matched = bestMatchingAXWindow(for: cgEntry, in: windows) {
                return matched
            }

            if let matched = windows.first(where: { matchedCGNumber($0, number: number, in: cgEntries) }) {
                return matched
            }
        }

        return windows.first { windowMatches($0, info: window) }
    }

    private static func axWindowByStableOrderKey(_ window: DockWindowInfo, in windows: [AXUIElement]) -> AXUIElement? {
        let knownFingerprints = WindowOpenOrderStore.knownFingerprints(for: window.stableOrderKey)
        if !knownFingerprints.isEmpty {
            for axWindow in windows {
                if knownFingerprints.contains(axWindowFingerprint(axWindow)) {
                    return axWindow
                }
            }
        }

        for axWindow in windows {
            let fingerprint = axWindowFingerprint(axWindow)
            if WindowOpenOrderStore.lookupKey(
                processIdentifier: window.processIdentifier,
                fingerprint: fingerprint
            ) == window.stableOrderKey {
                return axWindow
            }
        }

        return nil
    }

    private static func axWindowForMinimized(
        _ window: DockWindowInfo,
        in windows: [AXUIElement],
        cgEntries: [CGWindowEntry]
    ) -> AXUIElement? {
        let minimized = windows.filter { isMinimized($0) }
        guard !minimized.isEmpty else { return nil }

        if let number = window.cgWindowNumber,
           let cgEntry = cgEntries.first(where: { $0.number == number }) {
            if !cgEntry.title.isEmpty,
               let matched = minimized.first(where: { axTitle($0) == cgEntry.title }) {
                return matched
            }
        }

        let matches = minimized.filter { windowMatches($0, info: window) }
        if matches.count == 1 {
            return matches[0]
        }

        return matches.first
    }

    private static func axTitle(_ window: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let raw = titleRef as? String else {
            return ""
        }
        return raw
    }

    private static func axWindowFingerprint(_ window: AXUIElement) -> String {
        let title = axTitle(window)
        if let frame = axWindowFrame(window) {
            return "\(title)|\(Int(frame.width))x\(Int(frame.height))"
        }
        return title.isEmpty ? "untitled" : title
    }

    private static func bestMatchingAXWindow(for cgEntry: CGWindowEntry, in windows: [AXUIElement]) -> AXUIElement? {
        if let exact = windows.first(where: { axWindow in
            guard let frame = axWindowFrame(axWindow) else { return false }
            return framesMatch(frame, cgEntry.bounds)
        }) {
            return exact
        }

        guard let best = windows.max(by: { lhs, rhs in
            let lhsArea = axWindowFrame(lhs).map { frameIntersectionArea($0, cgEntry.bounds) } ?? 0
            let rhsArea = axWindowFrame(rhs).map { frameIntersectionArea($0, cgEntry.bounds) } ?? 0
            return lhsArea < rhsArea
        }),
            let frame = axWindowFrame(best),
            frameIntersectionArea(frame, cgEntry.bounds) > 0 else {
            return nil
        }
        return best
    }

    private static func frameIntersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func windowMatches(_ axWindow: AXUIElement, info: DockWindowInfo) -> Bool {
        guard isMinimized(axWindow) == info.isMinimized else { return false }

        var titleRef: CFTypeRef?
        let axTitle: String
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let raw = titleRef as? String,
           !raw.isEmpty {
            axTitle = raw
        } else {
            axTitle = ""
        }

        if info.title == "默认" {
            return axTitle.isEmpty
        }

        return axTitle == info.title
    }

    private static func matchedCGNumber(_ axWindow: AXUIElement, number: Int, in entries: [CGWindowEntry]) -> Bool {
        guard let frame = axWindowFrame(axWindow) else { return false }
        return entries.contains { entry in
            entry.number == number && framesMatch(frame, entry.bounds)
        }
    }

    private static func countTrackableAXWindows(for app: NSRunningApplication) -> Int {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return 0
        }

        var count = 0
        for window in axWindows {
            if isTrackableWindow(window) {
                count += 1
                if count > 1 {
                    return count
                }
            }
        }
        return count
    }

    private static func trackableAXWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return axWindows.filter { isTrackableWindow($0) }
    }

    private static func resolvePrimaryWindow(in appRef: AXUIElement) -> AXUIElement? {
        if let focused = copyWindowAttribute(kAXFocusedWindowAttribute as CFString, from: appRef),
           isTrackableWindow(focused) {
            return focused
        }
        if let main = copyWindowAttribute(kAXMainWindowAttribute as CFString, from: appRef),
           isTrackableWindow(main) {
            return main
        }
        return trackableAXWindows(from: appRef).first
    }

    private static func trackableAXWindows(from appRef: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            return []
        }
        return axWindows.filter { isTrackableWindow($0) }
    }

    private struct CGWindowEntry {
        let number: Int
        let title: String
        let bounds: CGRect
    }

    private static func cgWindowEntries(for app: NSRunningApplication) -> [CGWindowEntry] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return infoList.compactMap { entry in
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == app.processIdentifier,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = cgRect(from: boundsDict) else {
                return nil
            }

            let title = entry[kCGWindowName as String] as? String ?? ""
            return CGWindowEntry(number: number, title: title, bounds: bounds)
        }
    }

    private static func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posVal = positionValue,
              let sizeVal = sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func cgRect(from dict: [String: Any]) -> CGRect? {
        guard let x = dict["X"] as? CGFloat,
              let y = dict["Y"] as? CGFloat,
              let width = dict["Width"] as? CGFloat,
              let height = dict["Height"] as? CGFloat else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 8
        return abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    @discardableResult
    private static func animatedMinimize(_ window: AXUIElement) -> Bool {
        if pressButton(window, kAXMinimizeButtonAttribute as CFString) {
            return true
        }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
    }

    @discardableResult
    private static func pressButton(_ window: AXUIElement, _ attribute: CFString) -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &buttonRef) == .success,
              let button = buttonRef else {
            return false
        }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    private static func hasEnabledButton(_ window: AXUIElement, _ attribute: CFString) -> Bool {
        var buttonRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &buttonRef) == .success,
              let button = buttonRef else {
            return false
        }

        var enabledRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button as! AXUIElement, kAXEnabledAttribute as CFString, &enabledRef) == .success,
              let enabled = enabledRef as? Bool else {
            return true
        }
        return enabled
    }

    private static func copyWindowAttribute(_ attribute: CFString, from appRef: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, attribute, &value) == .success,
              let window = value else {
            return nil
        }
        return (window as! AXUIElement)
    }

    private static func isTrackableWindow(_ window: AXUIElement) -> Bool {
        if isFullscreen(window) { return false }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String {
            let standard = subrole == (kAXStandardWindowSubrole as String)
            let dialog = subrole == (kAXDialogSubrole as String)
            let document = subrole == "AXDocumentWindow"
            let floating = subrole == "AXFloatingWindow"

            if !(standard || dialog || document || floating) {
                return false
            }
        }

        return true
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success,
              let minimized = value as? Bool else {
            return false
        }
        return minimized
    }

    private static func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value) == .success,
              let isFullscreen = value as? Bool else {
            return false
        }
        return isFullscreen
    }
}
