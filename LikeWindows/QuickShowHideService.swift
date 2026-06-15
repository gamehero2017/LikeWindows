//
//  QuickShowHideService.swift
//  LikeWindows
//

import AppKit
import ApplicationServices

private let clickDebounceInterval: TimeInterval = 0.15
private let finderBundleIdentifier = "com.apple.finder"

private let dockTitleBundleMap: [String: String] = [
    "访达": finderBundleIdentifier,
    "Finder": finderBundleIdentifier,
    "ファインダ": finderBundleIdentifier,
]

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

final class QuickShowHideService: NSObject, @unchecked Sendable {
    static let shared = QuickShowHideService()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var lastClickTime: TimeInterval = 0
    private var lastClickedPID: pid_t = 0
    private var frontmostPID: pid_t?
    private var isStarted = false
    private let stateLock = NSLock()
    private var preventAppNapActivity: NSObjectProtocol?
    private var dockTargetCache: (target: DockTarget, location: CGPoint, timestamp: Date)?
    private var regularAppsCache: ([NSRunningApplication], timestamp: Date)?
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

    func isClickLocationInDock(_ location: CGPoint) -> Bool {
        isMouseInDockRegion(location)
    }

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
              let app = resolveRunningApp(for: dockItem)
                ?? resolveRunningAppFromFrontmost(matching: dockItem),
              let iconRect = dockItemRect(dockItem) else {
            dockTargetCache = nil
            return nil
        }

        let target = DockTarget(app: app, iconRect: iconRect)
        dockTargetCache = (target, location, Date())
        return target
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

    func handleDockClick(at location: CGPoint) -> Bool {
        guard isAnyFeatureEnabled else { return false }
        guard AccessibilityHealth.isWorking() else { return false }
        guard Thread.isMainThread else { return false }

        return handleDockClickOnMain(at: location)
    }

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

private func isMouseInDockRegion(_ location: CGPoint) -> Bool {
    guard let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
    let cocoaPoint = NSPoint(x: location.x, y: primaryHeight - location.y)

    for screen in NSScreen.screens {
        guard NSPointInRect(cocoaPoint, screen.frame) else { continue }

        if NSPointInRect(cocoaPoint, screen.visibleFrame) {
            return false
        }

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
