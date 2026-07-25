//
//  DockInfoPopupService.swift
//  likeWindows
//

import AppKit
import SwiftUI

/// Dock 悬停信息弹窗服务。
///
/// ## 产品边界
/// - **多窗口展示**：自绘标题列表（不截图预览）
/// - **悬停 / 弹窗生命周期**：DockDoor 方式（`AXSelectedChildren` + 延迟显示 + 弹窗内保持）
/// - **快速显示/隐藏**：独立 Event Tap 路径，不受本服务影响
///
/// ## 展示条件
/// `popupSnapshot.shouldShow == true`（可追踪窗口数 > 1）才会弹出。
final class DockInfoPopupService: NSObject {
    static let shared = DockInfoPopupService()

    /// 活跃监测时的兜底轮询间隔（SelectedChildren 漏通知时补位）。
    private static let activeFallbackPollInterval: TimeInterval = 0.9
    /// 弹窗内容刷新最小间隔（非 force）。
    private static let popupRefreshInterval: TimeInterval = 0.4
    /// 鼠标移动距离小于此值则跳过处理（像素平方比较用）。
    private static let mouseMoveThreshold: CGFloat = 5.0
    /// 在不同 Dock 图标间快速滑动时的切换防抖。
    private static let dockSwitchDebounce: TimeInterval = 0.1
    /// 首次打开弹窗的悬停延迟（对齐 DockDoor `hoverWindowOpenDelay` 量级）。
    private static let hoverOpenDelay: TimeInterval = 0.2

    private enum MonitoringPhase {
        /// 无 Dock 选中：低负载。
        case idle
        /// 有选中或弹窗已显示。
        case active
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<DockInfoPopupView>?
    private var popupModel: DockInfoPopupModel?
    private var fallbackTimer: Timer?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var monitoringPhase: MonitoringPhase = .idle
    private var currentTargetPID: pid_t?
    private var currentIconRect: CGRect?
    private var cachedHoverTarget: DockTarget?
    private var lastMouseLocation: NSPoint?
    private var isPopupPresented = false
    private var isStarted = false
    private var isMouseNearDock = false
    /// 鼠标是否在自绘弹窗内（SelectedChildren 清空时据此保持展示）。
    private var mouseIsWithinPopup = false
    private var lastPopupRefreshTime: TimeInterval = 0
    private var lastWindowStateSignature: String?
    private var lastFrontmostState: Bool?
    private var lastPopupAnchor: CGRect?
    private var pendingPresentTarget: DockTarget?
    private var pendingShowWorkItem: DispatchWorkItem?
    private var lastDockSwitchTime: TimeInterval = 0

    /// DockDoor 式悬停探测。
    private let hoverProbe = DockAXHoverProbe()

    var isPopupVisible: Bool {
        isPopupPresented
    }

    private override init() {
        super.init()
    }

    /// 按当前开关与权限状态，重新启动或停止悬停监测。
    func refreshMonitoring() {
        runOnMain { [weak self] in
            self?.restartHoverMonitorIfNeeded()
        }
    }

    /// 关闭全部鼠标监听与轮询（功能关闭或深度休眠时调用）。
    func suspendMonitoring() {
        runOnMain { [weak self] in
            self?.stopAllMonitoring()
            self?.dismissImmediatelyOnMain()
        }
    }

    /// 启动悬停监测（受功能开关与辅助功能权限约束）。
    func start() {
        guard !isStarted else { return }
        isStarted = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        restartHoverMonitorIfNeeded()
    }

    /// 停止监测并关闭弹窗。
    func stop() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.stopAllMonitoring()
            self.dismissImmediatelyOnMain()
            self.isStarted = false
        }
    }

    @objc private func userDefaultsDidChange() {
        runOnMain { [weak self] in
            self?.restartHoverMonitorIfNeeded()
            if !UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey) {
                self?.dismissImmediatelyOnMain()
            }
        }
    }

    private var isMonitoringEnabled: Bool {
        isStarted
            && UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey)
            && QuickShowHideService.shared.isAccessibilityGranted
    }

    private func restartHoverMonitorIfNeeded() {
        guard Thread.isMainThread else {
            runOnMain { [weak self] in
                self?.restartHoverMonitorIfNeeded()
            }
            return
        }

        guard isMonitoringEnabled else {
            stopAllMonitoring()
            if !UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey) {
                dismissImmediatelyOnMain()
            }
            return
        }

        ensureHoverProbe()
        ensureMouseMonitor()

        let mouse = NSEvent.mouseLocation
        let target = hoverProbe.refreshFromDock()
        isMouseNearDock = (target != nil)

        if isPopupPresented || target != nil {
            enterActiveMonitoring()
            processHover(at: mouse)
        } else {
            enterIdleMonitoring()
        }
    }

    private func stopAllMonitoring() {
        hoverProbe.onSelectionChanged = nil
        hoverProbe.stop()
        cancelPendingShow()
        removeMouseMonitor()
        stopFallbackPoll()
        monitoringPhase = .idle
        cachedHoverTarget = nil
        isMouseNearDock = false
        mouseIsWithinPopup = false
        lastMouseLocation = nil
    }

    private func ensureHoverProbe() {
        hoverProbe.onSelectionChanged = { [weak self] in
            self?.handleProbeSelectionChanged()
        }
        hoverProbe.start()
    }

    private func handleProbeSelectionChanged() {
        guard isMonitoringEnabled else { return }
        let mouse = NSEvent.mouseLocation
        mouseIsWithinPopup = isMouseOverPanel(mouse)
        // 鼠标移向弹窗时 SelectedChildren 常会清空，不能据此关窗
        if isPopupPresented, mouseIsWithinPopup, hoverProbe.currentTarget == nil {
            return
        }
        processHover(at: mouse)
    }

    private func ensureMouseMonitor() {
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] _ in
                self?.handleMouseMoved()
            }
        }

        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
            ) { [weak self] event in
                self?.handleMouseMoved()
                return event
            }
        }
    }

    private func removeMouseMonitor() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }

    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation
        mouseIsWithinPopup = isPopupPresented && isMouseOverPanel(mouse)

        if mouseIsWithinPopup {
            return
        }

        switch monitoringPhase {
        case .idle:
            guard isMonitoringEnabled, !isPopupPresented else { return }
            if hoverProbe.refreshFromDock() != nil {
                isMouseNearDock = true
                enterActiveMonitoring()
                lastMouseLocation = mouse
                processHover(at: mouse)
            }

        case .active:
            guard !shouldSkipMouseMove(to: mouse) else { return }
            lastMouseLocation = mouse
            if isPopupPresented {
                processHover(at: mouse)
            }
        }
    }

    private func scheduleFallbackPoll(interval: TimeInterval) {
        guard fallbackTimer == nil else { return }

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.fallbackTimer = nil
            self.pollMouseHover()
        }
        if let fallbackTimer {
            RunLoop.main.add(fallbackTimer, forMode: .common)
        }
    }

    private func stopFallbackPoll() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func enterIdleMonitoring() {
        monitoringPhase = .idle
        stopFallbackPoll()
        ensureMouseMonitor()
    }

    private func enterActiveMonitoring() {
        monitoringPhase = .active
        ensureHoverProbe()
        ensureMouseMonitor()
        scheduleFallbackPoll(interval: Self.activeFallbackPollInterval)
    }

    private func shouldSkipMouseMove(to mouse: NSPoint) -> Bool {
        guard let last = lastMouseLocation else { return false }
        let dx = mouse.x - last.x
        let dy = mouse.y - last.y
        return (dx * dx + dy * dy) < Self.mouseMoveThreshold * Self.mouseMoveThreshold
    }

    /// 排队展示悬停弹窗（DockDoor：首次延迟，已显示则立即切换）。
    private func presentOnMain(_ target: DockTarget) {
        guard UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey) else { return }

        if isPopupPresented {
            cancelPendingShow()
            pendingPresentTarget = nil
            presentTargetImmediately(target)
            return
        }

        pendingPresentTarget = target
        cancelPendingShow()

        let expectedPID = target.processIdentifier
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil

            // 延迟结束后仍须悬停在同一图标上
            let current = self.hoverProbe.refreshFromDock()
            guard let current,
                  current.processIdentifier == expectedPID,
                  let pending = self.pendingPresentTarget,
                  pending.processIdentifier == expectedPID else {
                return
            }

            // 鼠标已进弹窗且目标 App 不同时，不抢切（对齐 DockDoor）
            if self.mouseIsWithinPopup,
               let shownPID = self.currentTargetPID,
               shownPID != expectedPID {
                return
            }

            self.pendingPresentTarget = nil
            self.presentTargetImmediately(current)
        }

        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: workItem)
    }

    private func cancelPendingShow() {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
    }

    /// 真正创建/更新弹窗：快照窗口列表 → 算布局 → 写入 model → orderFront。
    /// `shouldShow == false`（≤1 个窗口）时不展示。
    private func presentTargetImmediately(_ target: DockTarget) {
        if currentTargetPID != target.processIdentifier {
            AppWindowInspector.invalidateWindowCache(for: target.processIdentifier)
        }

        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: true)
        guard snapshot.shouldShow else { return }

        currentTargetPID = target.processIdentifier
        currentIconRect = target.iconRect
        cachedHoverTarget = target

        let appName = target.app.localizedName ?? "未知应用"
        let layout = DockPopupLayout.calculate(
            appName: appName,
            windows: snapshot.windows,
            anchor: target.iconRect
        )

        lastWindowStateSignature = Self.windowsStateSignature(snapshot.windows)
        lastFrontmostState = QuickShowHideService.shared.isAppFrontmost(target.app)
        lastPopupRefreshTime = Date().timeIntervalSince1970

        applyPopupContent(
            appName: appName,
            appIcon: target.app.icon,
            isFrontmost: lastFrontmostState ?? false,
            windows: snapshot.windows,
            layout: layout,
            anchor: target.iconRect
        )
    }

    private func applyPopupContent(
        appName: String,
        appIcon: NSImage?,
        isFrontmost: Bool,
        windows: [DockWindowInfo],
        layout: DockPopupLayout,
        anchor: CGRect
    ) {
        let panel = ensurePanel()
        guard let model = popupModel else { return }

        let layoutChanged = layoutNeedsUpdate(current: model.layout, new: layout)
        let shouldMovePanel = layoutChanged || anchorNeedsFrameUpdate(anchor)

        model.appName = appName
        model.appIcon = appIcon
        model.isFrontmost = isFrontmost
        model.layout = layout
        model.windows = windows

        if shouldMovePanel {
            panel.setFrame(layout.frame(anchor: anchor), display: false)
            lastPopupAnchor = anchor
        }

        panel.hasShadow = false
        panel.invalidateShadow()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isPopupPresented = true
    }

    private func layoutNeedsUpdate(current: DockPopupLayout, new: DockPopupLayout) -> Bool {
        current.width != new.width
            || current.listHeight != new.listHeight
            || current.totalHeight != new.totalHeight
            || current.needsScroll != new.needsScroll
            || current.density != new.density
            || current.rowHeights.count != new.rowHeights.count
            || current.rowHeights != new.rowHeights
    }

    private func anchorNeedsFrameUpdate(_ anchor: CGRect) -> Bool {
        guard let lastPopupAnchor else { return true }
        let tolerance: CGFloat = 0.5
        return abs(lastPopupAnchor.midX - anchor.midX) > tolerance
            || abs(lastPopupAnchor.minY - anchor.minY) > tolerance
            || abs(lastPopupAnchor.width - anchor.width) > tolerance
    }

    /// 强制刷新当前弹窗的窗口列表与布局。
    func refreshCurrentPopup() {
        runOnMain { [weak self] in
            self?.refreshCurrentPopupOnMain(force: true)
        }
    }

    /// 刷新弹窗内容；非 force 时受刷新间隔与「窗口状态签名」节流。
    /// 签名未变且前台状态未变则跳过 UI 更新，减少 SwiftUI 抖动。
    private func refreshCurrentPopupOnMain(force: Bool = false) {
        guard isPopupPresented,
              let pid = currentTargetPID,
              let iconRect = currentIconRect,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }

        if force {
            AppWindowInspector.invalidateWindowCache(for: pid)
        }

        let now = Date().timeIntervalSince1970
        if !force, now - lastPopupRefreshTime < Self.popupRefreshInterval {
            return
        }

        let snapshot = AppWindowInspector.popupSnapshot(for: app, useCache: !force)
        guard snapshot.shouldShow else {
            dismissImmediatelyOnMain()
            return
        }

        let isFrontmost = QuickShowHideService.shared.isAppFrontmost(app)
        let signature = Self.windowsStateSignature(snapshot.windows)
        if !force,
           signature == lastWindowStateSignature,
           isFrontmost == lastFrontmostState {
            return
        }

        lastPopupRefreshTime = now
        lastWindowStateSignature = signature
        lastFrontmostState = isFrontmost

        let appName = app.localizedName ?? "未知应用"
        let layout = DockPopupLayout.calculate(
            appName: appName,
            windows: snapshot.windows,
            anchor: iconRect
        )

        applyPopupContent(
            appName: appName,
            appIcon: app.icon,
            isFrontmost: isFrontmost,
            windows: snapshot.windows,
            layout: layout,
            anchor: iconRect
        )
    }

    /// 立即关闭弹窗并清理当前目标状态。
    func dismissImmediately() {
        runOnMain { [weak self] in
            self?.dismissImmediatelyOnMain()
        }
    }

    private func dismissImmediatelyOnMain() {
        cancelPendingShow()
        pendingPresentTarget = nil

        guard isPopupPresented else { return }

        if let pid = currentTargetPID {
            AppWindowInspector.invalidateWindowCache(for: pid)
        }

        panel?.orderOut(nil)
        isPopupPresented = false
        mouseIsWithinPopup = false
        currentTargetPID = nil
        currentIconRect = nil
        cachedHoverTarget = nil
        lastWindowStateSignature = nil
        lastFrontmostState = nil
        lastPopupAnchor = nil
        lastPopupRefreshTime = 0
    }

    private func pollMouseHover() {
        // 兜底轮询强制重读 SelectedChildren，补漏通知
        _ = hoverProbe.refreshFromDock()
        processHover(at: NSEvent.mouseLocation)
    }

    /// DockDoor 式悬停决策：SelectedChildren 驱动；弹窗内保持；无选中则关。
    private func processHover(at mouse: NSPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.processHover(at: mouse)
            }
            return
        }

        mouseIsWithinPopup = isPopupPresented && isMouseOverPanel(mouse)

        defer {
            if isMonitoringEnabled {
                if isPopupPresented || isMouseNearDock {
                    enterActiveMonitoring()
                } else {
                    enterIdleMonitoring()
                }
            } else {
                stopAllMonitoring()
            }
        }

        guard isMonitoringEnabled else { return }

        if mouseIsWithinPopup {
            // 弹窗内只节流刷新内容，不重复扫 Dock AX
            refreshCurrentPopupOnMain(force: false)
            return
        }

        // Probe 已缓存则直接用；仅缓存为空时再读 AX（漏通知由 fallback 强制刷新）
        let target = hoverProbe.currentTarget ?? hoverProbe.refreshFromDock()
        isMouseNearDock = (target != nil)
        cachedHoverTarget = target

        if let target {
            if isPopupPresented {
                pollWhilePopupVisible(target: target)
            } else {
                pollWhilePopupHidden(target: target)
            }
            return
        }

        // 离开 Dock 且不在弹窗上：取消延迟展示并关闭
        cancelPendingShow()
        pendingPresentTarget = nil
        if isPopupPresented {
            dismissImmediatelyOnMain()
        }
    }

    /// 弹窗已显示：仍悬停当前图标则刷新；换到另一多窗 App 则切换；否则关闭。
    private func pollWhilePopupVisible(target: DockTarget) {
        if target.processIdentifier == currentTargetPID {
            currentIconRect = target.iconRect
            refreshCurrentPopupOnMain(force: false)
            return
        }

        let now = Date().timeIntervalSince1970
        guard now - lastDockSwitchTime >= Self.dockSwitchDebounce else { return }
        lastDockSwitchTime = now

        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: true)
        guard snapshot.shouldShow else {
            dismissImmediatelyOnMain()
            return
        }

        presentOnMain(target)
    }

    /// 弹窗未显示：命中多窗口 Dock 图标则 present。
    private func pollWhilePopupHidden(target: DockTarget) {
        if let currentPID = currentTargetPID, target.processIdentifier == currentPID, isPopupPresented {
            return
        }

        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: true)
        guard snapshot.shouldShow else { return }

        presentOnMain(target)
    }

    private func isMouseOverPanel(_ mouse: NSPoint) -> Bool {
        guard isPopupPresented, let panel else { return false }
        return panel.frame.insetBy(dx: -2, dy: -2).contains(mouse)
    }

    private static func windowsStateSignature(_ windows: [DockWindowInfo]) -> String {
        windows.map { window in
            [
                window.stableOrderKey,
                window.title,
                window.isMinimized ? "1" : "0",
                window.canClose ? "1" : "0",
                window.canMinimize ? "1" : "0",
                window.canZoom ? "1" : "0",
            ].joined(separator: ":")
        }.joined(separator: "|")
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    /// 懒创建无边框非激活面板，承载 SwiftUI 弹窗内容。
    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let placeholderLayout = DockPopupLayout.calculate(
            appName: "",
            windows: [],
            anchor: .zero
        )
        let model = DockInfoPopupModel(layout: placeholderLayout)
        popupModel = model

        let hosting = NSHostingView(rootView: DockInfoPopupView(model: model))
        hostingView = hosting
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.shadowOpacity = 0
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        self.panel = panel
        return panel
    }
}
