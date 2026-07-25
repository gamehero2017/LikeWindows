//
//  AppWindowInspector.swift
//  likeWindows
//

import AppKit
import ApplicationServices

/// 通过 Accessibility / CGWindow 枚举与操作应用窗口。
///
/// ## 主要用途
/// - 悬停弹窗：构建/刷新 `DockWindowInfo` 列表
/// - 快显隐藏：判断多窗、隐藏主窗 / 全部可见窗
/// - 弹窗交互：激活、最小化、关闭、缩放指定窗口
///
/// ## 线程约定
/// 写窗口状态（激活/最小化等）须在主线程；读列表可在主线程热路径调用。
///
/// ## 缓存
/// `popupWindowCache` 按 pid 短时缓存列表（约 0.6s），命中后用
/// `refreshLiveWindowStatesLight` 只更新标题/最小化/按钮状态，避免全量重建。
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

    /// 清空窗口列表缓存；传入 pid 只清该进程，否则全清。
    /// 窗口状态变更（最小化/激活/关闭）后应调用，避免弹窗显示过期数据。
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

    /// 点击路径判断是否「多窗口」：AX 可追踪窗口数 > 1，计数到 2 即停。
    ///
    /// 注意：与 `popupWindows` 的 fingerprint 去重口径可能不完全一致——
    /// 同标题同尺寸窗口在列表里可能被合并，但此处仍可能判为多窗。
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

    /// 枚举应用可追踪窗口列表；`useCache` 为 true 时命中短时缓存并轻量刷新状态。
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

    /// popup 路径：一次 AX 枚举后按 orderKey/指纹更新已有列表项的实时状态。
    /// 数量变化时退回全量 `buildPopupWindowsLight`，避免错位。
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

    /// 快速判断是否有未最小化的可追踪窗口。
    /// 优先读 focused / main（O(1) 属性），没有再扫 `kAXWindowsAttribute`。
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

    /// 轻量构建弹窗窗口列表：一次 AX 枚举 + 指纹登记。
    ///
    /// - `seenOrderKeys`：同 fingerprint 映射到同一 orderKey 时去重（可能丢掉同尺寸同标题的第二窗）
    /// - 排序：系统 Z 序 或 `WindowOpenOrderStore` 打开顺序
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

    /// 激活弹窗中选中的窗口（须在主线程）。
    ///
    /// 流程：解析 AX → 前置应用 → 若最小化则恢复 → focus。
    /// 若首次 focus 失败，0.15s 后异步重试一次（部分 App 激活有延迟）。
    /// 注意：异步重试不影响本次返回值。
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

    /// 弹窗列表行点击：若该窗口已是前台焦点窗则最小化；否则激活/恢复。
    ///
    /// - Returns: `true` 表示已最小化；`false` 表示走了激活路径（或失败）。
    ///
    /// 同应用已在前台时只 Raise 目标窗，**不**走 `activateWindow` /
    /// `activateAllWindows`，避免 Chrome 多标题切换闪烁；也不改动 Dock
    /// 「快速显示/隐藏」所用的隐藏路径。
    @discardableResult
    static func activateOrMinimizeFromPopup(_ window: DockWindowInfo) -> Bool {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                _ = activateOrMinimizeFromPopup(window)
            }
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: window.processIdentifier) else {
            return false
        }
        guard let resolvedWindow = axWindow(for: window) else { return false }

        let currentlyMinimized = window.isMinimized || isMinimized(resolvedWindow)
        if !currentlyMinimized, isFrontmostVisibleWindow(resolvedWindow, app: app) {
            invalidateWindowCache(for: app.processIdentifier)
            return animatedMinimize(resolvedWindow)
        }

        // 应用已在前台且目标窗可见：仅切换该窗，避免整应用抬窗闪烁
        if !currentlyMinimized, app.isActive, !app.isHidden {
            invalidateWindowCache(for: app.processIdentifier)
            let focused = focusWindowOnly(resolvedWindow, app: app)
            if !focused || !isWindowFocused(resolvedWindow, app: app) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let target = axWindow(for: window) ?? resolvedWindow
                    _ = focusWindowOnly(target, app: app)
                }
            }
            return false
        }

        // 后台应用 / 最小化窗口：仍走完整激活（含 activateAllWindows），保证恢复可靠
        _ = activateWindow(window)
        return false
    }

    /// 该 AX 窗口是否为前台应用当前正在展示的主/焦点窗（用于弹窗行点击切换最小化）。
    private static func isFrontmostVisibleWindow(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard app.isActive, !isMinimized(window) else { return false }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = copyWindowAttribute(kAXFocusedWindowAttribute as CFString, from: appRef),
           CFEqual(window, focused) {
            return true
        }
        if let main = copyWindowAttribute(kAXMainWindowAttribute as CFString, from: appRef),
           CFEqual(window, main) {
            return true
        }
        return false
    }

    private static func isWindowFocused(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard app.isActive else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused = copyWindowAttribute(kAXFocusedWindowAttribute as CFString, from: appRef) else {
            return false
        }
        return CFEqual(window, focused)
    }

    /// 执行弹窗行内控制：关闭 / 最小化 / 缩放（须在主线程）。
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

    /// 单窗口前台可见时隐藏主窗口。
    ///
    /// 解析顺序：focused → main → 第一个可追踪窗。
    /// 成功调用 `animatedMinimize` 后当前直接 `return true`（未再读回 `isMinimized`）。
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

    /// 恢复已最小化窗口：先写 AXMinimized=false，再试最小化按钮，再 Raise。
    /// 不同 App 对三种方式的支持不一，故串行 fallback。
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

    /// 仅切换主/焦点窗并 Raise 一次；不前置整应用（弹窗同 App 切窗专用，减少闪烁）。
    @discardableResult
    private static func focusWindowOnly(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var succeeded = false

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

    /// 将 DockWindowInfo 解析回 AX 窗口。
    ///
    /// 匹配优先级：
    /// 1. `stableOrderKey` / 历史指纹
    /// 2. 最小化专用匹配（CG 标题 / 标题）
    /// 3. `cgWindowNumber` + 矩形相交
    /// 4. 标题 + 最小化状态兜底
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

    /// 窗口指纹：标题 + 尺寸，用于稳定身份配对。
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

    /// 取应用主窗口：focused → main → 第一个可追踪窗口。
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
    /// 优先按最小化按钮（系统动画），失败则直接写 `AXMinimized`。
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

    /// 是否计入列表 / 快显逻辑。
    /// 排除全屏；subrole 仅保留 Standard / Dialog / Document / Floating。
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
