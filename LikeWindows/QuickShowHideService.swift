//
//  QuickShowHideService.swift
//  LikeWindows
//

import AppKit
import ApplicationServices

/// Dock 点击防抖间隔，避免连点重复触发。
private let clickDebounceInterval: TimeInterval = 0.15
private let finderBundleIdentifier = "com.apple.finder"

/// Dock 图标标题到 Bundle ID 的兜底映射（本地化标题不一致时用）。
private let dockTitleBundleMap: [String: String] = [
    "访达": finderBundleIdentifier,
    "Finder": finderBundleIdentifier,
    "ファインダ": finderBundleIdentifier,
]

/// CGEventTap 回调（在主 RunLoop 上触发）。
///
/// ## 返回值约定
/// - `Unmanaged.passUnretained(event)`：放行，系统继续处理
/// - `nil`：吞掉事件，系统 Dock 收不到这次点击
///
/// ## 处理顺序
/// 1. Tap 被系统禁用 → 安排重启并放行
/// 2. 非左键按下 → 放行
/// 3. 点击不在 Dock 区域 → 放行（避免误拦桌面）
/// 4. `handleDockClick` 成功 → 吞掉；失败 → 放行
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<QuickShowHideService>.fromOpaque(userInfo).takeUnretainedValue()

    // 超时或用户输入导致 tap 被禁用时，必须重启，否则后续点击全部失效
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        service.scheduleEventTapRestart()
        return Unmanaged.passUnretained(event)
    }

    guard type == .leftMouseDown else {
        return Unmanaged.passUnretained(event)
    }

    guard service.isClickLocationInDock(event.location) else {
        return Unmanaged.passUnretained(event)
    }

    if service.handleDockClick(at: event.location) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

/// Dock 点击拦截与命中解析服务。
///
/// ## 架构位置
/// ```
/// CGEventTap → handleDockClick → dockTarget → DockClickRouter
///                                      ↘ 同时供悬停弹窗解析图标用
/// ```
///
/// ## 关键状态
/// - `eventTap` / `runLoopSource`：会话级鼠标监听
/// - `frontmostPID`：由激活通知维护，避免每次查 `frontmostApplication`
/// - `dockEntriesCache`：Dock 图标列表短时缓存，降低 AX 遍历频率
/// - `dockTargetCache`：按点击坐标短时复用命中结果
///
/// `@unchecked Sendable`：Event Tap 回调与主线程共享实例，可变状态靠 `stateLock` / 主线程约定保护。
final class QuickShowHideService: NSObject, @unchecked Sendable {
    static let shared = QuickShowHideService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var lastClickTime: TimeInterval = 0
    private var lastClickedPID: pid_t = 0
    /// 由 workspace 激活通知维护的前台 PID，供快速前台判断。
    private var frontmostPID: pid_t?
    private var isStarted = false
    private let stateLock = NSLock()
    private var preventAppNapActivity: NSObjectProtocol?
    private var dockTargetCache: (target: DockTarget, location: CGPoint, timestamp: Date)?
    private var regularAppsCache: ([NSRunningApplication], timestamp: Date)?
    /// Dock 图标列表短时缓存，减少悬停/点击时的 AX 遍历。
    private var dockEntriesCache: [CachedDockEntry]?
    private var dockEntriesCacheTimestamp: Date?

    private static let dockTargetCacheTTL: TimeInterval = 0.3
    private static let dockTargetCacheDistance: CGFloat = 8
    private static let regularAppsCacheTTL: TimeInterval = 1.0
    private static let dockEntriesCacheTTL: TimeInterval = 0.75

    private struct CachedDockEntry {
        let app: NSRunningApplication
        let iconRect: CGRect
    }

    private(set) var isEventTapActive = false

    private override init() {
        super.init()
    }

    /// 启动权限轮询、前台监听与（按需）Event Tap。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        if let frontApp = NSWorkspace.shared.frontmostApplication {
            frontmostPID = frontApp.processIdentifier
        }

        applyRuntimeState()
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
            return
        }
        isStarted = false
        enterDeepSleep()
    }

    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.applyRuntimeState()
        }
    }

    @objc private func workspaceDidWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.applyRuntimeState()
        }
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.frontmostPID = app.processIdentifier
        }
    }

    /// 按功能开关与权限，启停 Event Tap 与悬停监测。
    ///
    /// - 两个功能都关 → `enterDeepSleep`（停 tap、停权限轮询、挂起悬停）
    /// - 任一功能开 → 启动权限定时器，并尝试重建 Event Tap
    private func applyRuntimeState() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.applyRuntimeState()
            }
            return
        }

        guard isStarted else { return }

        guard isAnyFeatureEnabled else {
            enterDeepSleep()
            return
        }

        ensurePermissionTimerRunning()
        restartEventTapIfNeeded()
    }

    /// 功能全关或进程停止时的深度休眠：释放监听资源，降低空闲占用。
    private func enterDeepSleep() {
        stopPermissionTimer()
        stopEventTap()
        endPreventAppNapIfNeeded()
        DockInfoPopupService.shared.suspendMonitoring()
    }

    private func stopPermissionTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func ensurePermissionTimerRunning() {
        guard isAnyFeatureEnabled else {
            stopPermissionTimer()
            return
        }

        guard permissionTimer == nil else { return }

        schedulePermissionTimer()
    }

    private func schedulePermissionTimer() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.schedulePermissionTimer()
            }
            return
        }

        guard isAnyFeatureEnabled else {
            stopPermissionTimer()
            return
        }

        permissionTimer?.invalidate()

        let interval = permissionTimerInterval()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restartEventTapIfNeeded()
            if self.isAnyFeatureEnabled {
                self.schedulePermissionTimer()
            }
        }
        if let permissionTimer {
            RunLoop.main.add(permissionTimer, forMode: .common)
        }
    }

    /// 权限稳定且 tap 已运行时用较长间隔（30s）；否则 5s 重试，便于用户授权后快速恢复。
    private func permissionTimerInterval() -> TimeInterval {
        if AXIsProcessTrusted(), isEventTapActive {
            return 30.0
        }
        return 5.0
    }

    func scheduleEventTapRestart() {
        DispatchQueue.main.async { [weak self] in
            self?.restartEventTapIfNeeded()
        }
    }

    /// 根据「授权 + AX 可用」决定是否运行 Event Tap，并同步悬停监测。
    ///
    /// `working` 判定：已信任，且（tap 已在跑 **或** AccessibilityHealth 探测通过）。
    /// tap 已在跑时跳过探测，避免热路径反复 probe。
    func restartEventTapIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.restartEventTapIfNeeded()
            }
            return
        }

        guard isStarted else { return }

        guard isAnyFeatureEnabled else {
            enterDeepSleep()
            return
        }

        let trusted = AXIsProcessTrusted()
        stateLock.lock()
        let tapRunning = isEventTapActive
        stateLock.unlock()

        let working = trusted && (tapRunning || AccessibilityHealth.isWorking())
        let shouldRunTap = working

        if shouldRunTap {
            if !tapRunning {
                startEventTap()
            }
            DockInfoPopupService.shared.refreshMonitoring()
        } else {
            stopEventTap()
            DockInfoPopupService.shared.suspendMonitoring()
        }

        updatePreventAppNapIfNeeded()
    }

    /// 静默检查权限，不弹出系统对话框
    func refreshAccessibilityStatus() {
        _ = AXIsProcessTrusted()
        AccessibilityHealth.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.applyRuntimeState()
        }
    }

    /// 打开系统设置，不触发权限弹窗
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// 是否已授予辅助功能权限（AXIsProcessTrusted）。
    var isAccessibilityGranted: Bool {
        guard AXIsProcessTrusted() else { return false }
        stateLock.lock()
        let tapRunning = isEventTapActive
        stateLock.unlock()
        if tapRunning { return true }
        return AccessibilityHealth.isWorking()
    }

    var isAnyFeatureEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.quickShowHideEnabled)
            || UserDefaults.standard.bool(forKey: AppSettings.dockInfoPopupEnabled)
    }

    /// 偏好设置页展示的运行状态摘要文案。
    var diagnosticSummary: String {
        let trusted = AXIsProcessTrusted()
        let working = trusted && AccessibilityHealth.isWorking()
        let quickEnabled = UserDefaults.standard.bool(forKey: AppSettings.quickShowHideEnabled)
        let popupEnabled = UserDefaults.standard.bool(forKey: AppSettings.dockInfoPopupEnabled)
        stateLock.lock()
        let tap = isEventTapActive
        stateLock.unlock()
        return "快显:\(quickEnabled ? "开" : "关") 弹窗:\(popupEnabled ? "开" : "关") 授权:\(trusted ? "是" : "否") 可用:\(working ? "是" : "否") 监听:\(tap ? "运行中" : "未运行")"
    }

    /// 判断 CG 坐标是否落在 Dock 热区内（含自动隐藏边缘）。
    func isClickLocationInDock(_ location: CGPoint) -> Bool {
        isMouseInDockRegion(location)
    }

    /// 将屏幕坐标解析为命中的 Dock 应用图标。
    ///
    /// 查找顺序（由快到慢）：
    /// 1. 坐标邻近的短时 `dockTargetCache`
    /// 2. 预建的 `dockEntriesCache` 矩形命中
    /// 3. 实时 AX 遍历 Dock 树 + 解析 running app
    func dockTarget(at location: CGPoint) -> DockTarget? {
        if let cached = dockTargetCache,
           Date().timeIntervalSince(cached.timestamp) < Self.dockTargetCacheTTL {
            let dx = cached.location.x - location.x
            let dy = cached.location.y - location.y
            if (dx * dx + dy * dy) <= Self.dockTargetCacheDistance * Self.dockTargetCacheDistance {
                return cached.target
            }
        }

        if let target = dockTargetFromEntriesCache(at: location) {
            dockTargetCache = (target, location, Date())
            return target
        }

        guard let dockItem = dockItem(at: location),
              let target = dockTarget(fromDockItem: dockItem) else {
            dockTargetCache = nil
            return nil
        }

        dockTargetCache = (target, location, Date())
        return target
    }

    /// 由 Dock AX 图标元素解析 `DockTarget`（悬停 SelectedChildren POC / 点击命中共用）。
    func dockTarget(fromDockItem item: AXUIElement) -> DockTarget? {
        guard let app = resolveRunningApp(for: item) ?? resolveRunningAppFromFrontmost(matching: item),
              let iconRect = dockItemRect(item) else {
            return nil
        }
        return DockTarget(app: app, iconRect: iconRect)
    }

    func prefetchDockEntriesCache() {
        ensureDockEntriesCache(force: true)
    }

    func invalidateDockTargetCache() {
        dockTargetCache = nil
        dockEntriesCache = nil
        dockEntriesCacheTimestamp = nil
    }

    func cgPointFromCocoa(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight() - point.y)
    }

    func isMouseOverDock(cocoaPoint: NSPoint) -> Bool {
        isMouseInDockRegion(cgPointFromCocoa(cocoaPoint))
    }

    func primaryScreenHeight() -> CGFloat {
        Self.primaryScreenHeightValue()
    }

    func isAppFrontmost(_ app: NSRunningApplication) -> Bool {
        isAppFrontmostInternal(app)
    }

    /// 在主 RunLoop 上创建会话级左键 Event Tap（`.cgSessionEventTap` + `.headInsertEventTap`）。
    /// 需辅助功能权限；创建失败时静默返回，由权限定时器稍后重试。
    private func startEventTap() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.startEventTap()
            }
            return
        }

        stopEventTap()

        let eventMask = 1 << CGEventType.leftMouseDown.rawValue
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: selfPointer
        ) else {
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }

        stateLock.lock()
        eventTap = tap
        runLoopSource = source
        isEventTapActive = true
        stateLock.unlock()

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.stopEventTap()
            }
            return
        }

        stateLock.lock()
        let tap = eventTap
        let source = runLoopSource
        eventTap = nil
        runLoopSource = nil
        isEventTapActive = false
        stateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
    }

    /// 处理 Dock 点击；返回 true 表示已消费事件。
    ///
    /// 前置：功能开启 + AccessibilityHealth 可用 + 必须在主线程。
    /// 非主线程直接返回 false（放行），避免在 tap 回调里跨线程同步阻塞。
    func handleDockClick(at location: CGPoint) -> Bool {
        guard isAnyFeatureEnabled else { return false }
        guard AccessibilityHealth.isWorking() else { return false }
        guard Thread.isMainThread else { return false }

        return handleDockClickOnMain(at: location)
    }

    /// 解析点击位置对应的 Dock 图标，并交给 `DockClickRouter`。
    /// 每次点击前失效图标缓存，避免 Dock 布局变化后命中旧矩形。
    private func handleDockClickOnMain(at location: CGPoint) -> Bool {
        guard isClickLocationInDock(location) else { return false }
        invalidateDockTargetCache()
        guard let target = dockTarget(at: location) else { return false }

        let popupEnabled = UserDefaults.standard.bool(forKey: AppSettings.dockInfoPopupEnabled)
        let quickEnabled = UserDefaults.standard.bool(forKey: AppSettings.quickShowHideEnabled)

        return DockClickRouter.handleClick(
            on: target,
            quickEnabled: quickEnabled,
            popupEnabled: popupEnabled
        )
    }

    func recordClick(on app: NSRunningApplication) {
        lastClickTime = Date().timeIntervalSince1970
        lastClickedPID = app.processIdentifier
    }

    /// 同 App 在 `clickDebounceInterval` 内的重复点击返回 false。
    /// 注意：当前在「允许处理」时即 `recordClick`，若后续隐藏失败，短时间内再点会被防抖挡住。
    func shouldProcessClick(for app: NSRunningApplication) -> Bool {
        let now = Date().timeIntervalSince1970
        if app.processIdentifier == lastClickedPID,
           now - lastClickTime < clickDebounceInterval {
            return false
        }
        recordClick(on: app)
        return true
    }

    private func updatePreventAppNapIfNeeded() {
        stateLock.lock()
        let tapRunning = isEventTapActive
        stateLock.unlock()

        // 仅在 EventTap 实际运行时短暂防止 App Nap，避免全功能开启但空闲时持续占资源
        if tapRunning {
            if preventAppNapActivity == nil {
                preventAppNapActivity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiated,
                    reason: "Keep Dock event tap responsive"
                )
            }
        } else {
            endPreventAppNapIfNeeded()
        }
    }

    private func endPreventAppNapIfNeeded() {
        if let activity = preventAppNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            preventAppNapActivity = nil
        }
    }

}

// MARK: - Dock Click Handling

private extension QuickShowHideService {
    func dockItem(at location: CGPoint) -> AXUIElement? {
        if let item = dockItemFromDockList(at: location) {
            return item
        }
        return dockItemAtPosition(location)
    }

    func cachedRegularRunningApplications() -> [NSRunningApplication] {
        if let cache = regularAppsCache,
           Date().timeIntervalSince(cache.timestamp) < Self.regularAppsCacheTTL {
            return cache.0
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        regularAppsCache = (apps, Date())
        return apps
    }

    func dockItemAtPosition(_ location: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(location.x),
            Float(location.y),
            &element
        ) == .success,
            let target = element else {
            return nil
        }
        return findDockItem(startingAt: target)
    }

    func findDockItem(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let item = current else { break }
            if elementRole(item) == "AXDockItem" {
                return item
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else {
                break
            }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    func dockItemFromDockList(at clickPoint: CGPoint) -> AXUIElement? {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return nil
        }

        let dockRef = AXUIElementCreateApplication(dockApp.processIdentifier)
        for item in collectAllDockItems(from: dockRef) {
            guard let rect = dockItemRect(item),
                  rectContainsClickPoint(rect, clickPoint) else {
                continue
            }
            return item
        }
        return nil
    }

    func ensureDockEntriesCache(force: Bool = false) {
        if !force,
           let timestamp = dockEntriesCacheTimestamp,
           Date().timeIntervalSince(timestamp) < Self.dockEntriesCacheTTL {
            return
        }
        rebuildDockEntriesCache()
    }

    func dockTargetFromEntriesCache(at location: CGPoint) -> DockTarget? {
        ensureDockEntriesCache()
        guard let entries = dockEntriesCache else { return nil }

        for entry in entries {
            if rectContainsClickPoint(entry.iconRect, location) {
                return DockTarget(app: entry.app, iconRect: entry.iconRect)
            }
        }
        return nil
    }

    func rebuildDockEntriesCache() {
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            dockEntriesCache = []
            dockEntriesCacheTimestamp = Date()
            return
        }

        let dockRef = AXUIElementCreateApplication(dockApp.processIdentifier)
        let items = collectAllDockItems(from: dockRef)
        var entries: [CachedDockEntry] = []
        entries.reserveCapacity(items.count)

        for item in items {
            guard let rect = dockItemRect(item),
                  let app = resolveRunningApp(for: item)
                    ?? resolveRunningAppFromFrontmost(matching: item) else {
                continue
            }
            entries.append(CachedDockEntry(app: app, iconRect: rect))
        }

        dockEntriesCache = entries
        dockEntriesCacheTimestamp = Date()
    }

    func collectAllDockItems(from root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack: [AXUIElement] = [root]

        while let element = stack.popLast() {
            if elementRole(element) == "AXDockItem" {
                result.append(element)
                continue
            }

            var childrenValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement],
                  !children.isEmpty else {
                continue
            }
            stack.append(contentsOf: children.reversed())
        }

        return result
    }

    /// 前台判断：`isActive` → 缓存的 `frontmostPID` → 实时 `frontmostApplication`。
    /// 多层兜底是因为激活通知与 `isActive` 在某些切换瞬间可能短暂不一致。
    func isAppFrontmostInternal(_ app: NSRunningApplication) -> Bool {
        if app.isActive { return true }
        if let frontmostPID, frontmostPID == app.processIdentifier { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    func resolveRunningApp(for element: AXUIElement) -> NSRunningApplication? {
        if let url = dockItemURL(element) {
            if let bundleID = Bundle(url: url)?.bundleIdentifier,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                return app
            }

            let targetPath = normalizedAppPath(url)
            if targetPath.hasSuffix("Finder.app"),
               let finder = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleIdentifier).first {
                return finder
            }

            let matches = cachedRegularRunningApplications().filter {
                if let bundleURL = $0.bundleURL, normalizedAppPath(bundleURL) == targetPath {
                    return true
                }
                if let executableURL = $0.executableURL, normalizedAppPath(executableURL) == targetPath {
                    return true
                }
                return false
            }
            if let app = matches.first {
                return app
            }
        }

        guard let rawTitle = dockItemTitle(element) else { return nil }

        if let bundleID = dockTitleBundleMap[rawTitle],
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }

        let running = cachedRegularRunningApplications()

        if let exact = running.first(where: { $0.localizedName == rawTitle }) {
            return exact
        }

        if let insensitive = running.first(where: {
            ($0.localizedName?.caseInsensitiveCompare(rawTitle) == .orderedSame)
        }) {
            return insensitive
        }

        if let bundleMatch = running.first(where: {
            guard let bundleURL = $0.bundleURL else { return false }
            let bundleName = bundleURL.deletingPathExtension().lastPathComponent
            return bundleName.caseInsensitiveCompare(rawTitle) == .orderedSame
        }) {
            return bundleMatch
        }

        return nil
    }

    func resolveRunningAppFromFrontmost(matching element: AXUIElement) -> NSRunningApplication? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.activationPolicy == .regular else {
            return nil
        }
        guard let title = dockItemTitle(element) else { return nil }
        return appMatchesTitle(frontApp, title) ? frontApp : nil
    }

    func dockItemTitle(_ element: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String,
              !title.isEmpty else {
            return nil
        }
        return title
    }

    func dockItemURL(_ element: AXUIElement) -> URL? {
        var urlRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success else {
            return nil
        }
        return urlRef as? URL
    }

    func appMatchesTitle(_ app: NSRunningApplication, _ title: String) -> Bool {
        if app.localizedName == title { return true }
        if app.localizedName?.caseInsensitiveCompare(title) == .orderedSame { return true }
        if let bundleURL = app.bundleURL {
            let bundleName = bundleURL.deletingPathExtension().lastPathComponent
            if bundleName.caseInsensitiveCompare(title) == .orderedSame { return true }
        }
        if let bundleID = app.bundleIdentifier,
           dockTitleBundleMap[title] == bundleID {
            return true
        }
        return false
    }
}

// MARK: - Dock Geometry

private func normalizedAppPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
}

/// 判断 CG 坐标是否落在「屏幕可见区之外」的 Dock 条带（底部/侧边 Dock）。
/// 菜单栏附近（frame.maxY - 30）排除，避免与菜单栏点击混淆。
private func isMouseInDockRegion(_ location: CGPoint) -> Bool {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
    let cocoaPoint = NSPoint(x: location.x, y: primaryHeight - location.y)

    for screen in NSScreen.screens {
        guard NSPointInRect(cocoaPoint, screen.frame) else { continue }

        // 落在可见内容区 → 不是 Dock
        if NSPointInRect(cocoaPoint, screen.visibleFrame) {
            return false
        }

        // 靠近屏幕顶部菜单栏区域 → 不是 Dock
        if cocoaPoint.y > screen.frame.maxY - 30 {
            return false
        }

        return true
    }
    return false
}

private extension QuickShowHideService {
    private static var cachedPrimaryScreenHeight: CGFloat?
    private static var cachedPrimaryScreenHeightTime: Date?
    private static let primaryScreenHeightCacheTTL: TimeInterval = 2.0

    static func primaryScreenHeightValue() -> CGFloat {
        if let cached = cachedPrimaryScreenHeight,
           let time = cachedPrimaryScreenHeightTime,
           Date().timeIntervalSince(time) < primaryScreenHeightCacheTTL {
            return cached
        }

        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main ?? NSScreen.screens.first
        let height = primary?.frame.height ?? 0
        cachedPrimaryScreenHeight = height
        cachedPrimaryScreenHeightTime = Date()
        return height
    }
}

private func dockItemRect(_ item: AXUIElement) -> CGRect? {
    var positionValue: AnyObject?
    var sizeValue: AnyObject?

    guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue) == .success,
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

private func rectContainsClickPoint(_ rect: CGRect, _ clickPoint: CGPoint) -> Bool {
    let expanded = rect.insetBy(dx: -6, dy: -6)
    if expanded.contains(clickPoint) {
        return true
    }

    let height = QuickShowHideService.primaryScreenHeightValue()
    guard height > 0 else { return false }

    let flipped = CGPoint(x: clickPoint.x, y: height - clickPoint.y)
    if expanded.contains(flipped) {
        return true
    }

    return false
}

private func elementRole(_ element: AXUIElement) -> String? {
    var roleRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
        return nil
    }
    return roleRef as? String
}
