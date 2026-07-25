//
//  DockAXHoverProbe.swift
//  LikeWindows
//
//  DockDoor 式悬停探测：订阅 Dock AXSelectedChildren。
//

import AppKit
import ApplicationServices

/// 监听 Dock 列表 `kAXSelectedChildrenChangedNotification`，解析当前悬停的应用图标。
///
/// 对齐 DockDoor `DockObserver`：用系统 SelectedChildren，而不是坐标扫图标矩形。
/// 仅供 `DockInfoPopupService` 悬停弹窗使用；快速显示/隐藏点击仍走坐标命中。
final class DockAXHoverProbe {
    /// 选中项变化（含变为空）时回调；始终在主线程。
    var onSelectionChanged: (() -> Void)?

    private var axObserver: AXObserver?
    private var subscribedDockList: AXUIElement?
    private var dockPID: pid_t?
    private var healthTimer: Timer?
    private var cachedTarget: DockTarget?
    private var isRunning = false

    /// 最近一次解析到的应用 Dock 目标（可能为 nil）。
    var currentTarget: DockTarget? {
        cachedTarget
    }

    /// 启动订阅；幂等。
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard !isRunning else { return }
        isRunning = true
        setupObserver()
        startHealthTimer()
        refreshFromDock()
    }

    /// 停止订阅并清空缓存。
    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        isRunning = false
        teardownObserver()
        stopHealthTimer()
        cachedTarget = nil
    }

    /// 主动再读一次 SelectedChildren（兜底轮询用）。
    @discardableResult
    func refreshFromDock() -> DockTarget? {
        let target = resolveSelectedApplicationTarget()
        let changed = !Self.sameTarget(cachedTarget, target)
        cachedTarget = target
        return target
    }

    // MARK: - Observer

    private func setupObserver() {
        teardownObserver()

        guard AXIsProcessTrusted() else { return }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }

        dockPID = dockApp.processIdentifier
        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)

        guard let dockList = findDockList(in: dockElement) else { return }

        var observer: AXObserver?
        let createStatus = AXObserverCreate(
            dockApp.processIdentifier,
            dockAXHoverProbeCallback,
            &observer
        )
        guard createStatus == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addStatus = AXObserverAddNotification(
            observer,
            dockList,
            kAXSelectedChildrenChangedNotification as CFString,
            refcon
        )
        guard addStatus == .success else { return }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )

        axObserver = observer
        subscribedDockList = dockList
    }

    private func teardownObserver() {
        if let observer = axObserver {
            if let list = subscribedDockList {
                AXObserverRemoveNotification(
                    observer,
                    list,
                    kAXSelectedChildrenChangedNotification as CFString
                )
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }
        axObserver = nil
        subscribedDockList = nil
        dockPID = nil
    }

    private func startHealthTimer() {
        stopHealthTimer()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.performHealthCheck()
        }
        if let healthTimer {
            RunLoop.main.add(healthTimer, forMode: .common)
        }
    }

    private func stopHealthTimer() {
        healthTimer?.invalidate()
        healthTimer = nil
    }

    private func performHealthCheck() {
        guard isRunning else { return }

        let liveDock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        if liveDock?.processIdentifier != dockPID {
            setupObserver()
            refreshFromDock()
            notifySelectionChanged()
            return
        }

        if let list = subscribedDockList {
            var role: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(list, kAXRoleAttribute as CFString, &role)
            if status != .success {
                setupObserver()
                refreshFromDock()
                notifySelectionChanged()
            }
        } else {
            setupObserver()
        }
    }

    fileprivate func handleObserverNotification() {
        guard isRunning else { return }
        let previous = cachedTarget
        refreshFromDock()
        // 仅在目标变化时通知，避免同图标重复触发 processHover / UI 刷新
        guard !Self.sameTarget(previous, cachedTarget) else { return }
        notifySelectionChanged()
    }

    private func notifySelectionChanged() {
        onSelectionChanged?()
    }

    // MARK: - Resolve

    private func resolveSelectedApplicationTarget() -> DockTarget? {
        guard let item = selectedDockItem(),
              isApplicationDockItem(item) else {
            return nil
        }
        return QuickShowHideService.shared.dockTarget(fromDockItem: item)
    }

    private func selectedDockItem() -> AXUIElement? {
        guard let dockPID,
              let dockApp = NSRunningApplication(processIdentifier: dockPID) else {
            guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
                return nil
            }
            let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
            return selectedChild(in: dockElement)
        }

        let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
        if let list = subscribedDockList {
            return selectedChild(fromList: list) ?? selectedChild(in: dockElement)
        }
        return selectedChild(in: dockElement)
    }

    private func selectedChild(in dockElement: AXUIElement) -> AXUIElement? {
        guard let list = findDockList(in: dockElement) else { return nil }
        return selectedChild(fromList: list)
    }

    private func selectedChild(fromList list: AXUIElement) -> AXUIElement? {
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            list,
            kAXSelectedChildrenAttribute as CFString,
            &selectedRef
        ) == .success,
              let selected = selectedRef as? [AXUIElement],
              let first = selected.first else {
            return nil
        }
        return first
    }

    private func findDockList(in dockElement: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            dockElement,
            kAXChildrenAttribute as CFString,
            &childrenRef
        ) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                  let role = roleRef as? String else {
                continue
            }
            if role == kAXListRole as String || role == "AXList" {
                return child
            }
        }
        return children.first
    }

    private func isApplicationDockItem(_ item: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole == "AXApplicationDockItem" {
            return true
        }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == "AXDockItem" {
            // 排除废纸篓等：需能解析出运行中的 App
            return QuickShowHideService.shared.dockTarget(fromDockItem: item) != nil
        }
        return false
    }

    private static func sameTarget(_ lhs: DockTarget?, _ rhs: DockTarget?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.processIdentifier == r.processIdentifier
                && abs(l.iconRect.origin.x - r.iconRect.origin.x) < 1
                && abs(l.iconRect.origin.y - r.iconRect.origin.y) < 1
        default:
            return false
        }
    }
}

private func dockAXHoverProbeCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let probe = Unmanaged<DockAXHoverProbe>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        probe.handleObserverNotification()
    }
}
