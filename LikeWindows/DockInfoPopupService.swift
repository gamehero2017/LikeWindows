//
//  DockInfoPopupService.swift
//  likeWindows
//

import AppKit
import SwiftUI

let dockInfoPopupEnabledKey = "dockInfoPopupEnabled"
let useSystemWindowOrderKey = "useSystemWindowOrderEnabled"

final class DockInfoPopupService: NSObject {
    static let shared = DockInfoPopupService()

    private static let activeFallbackPollInterval: TimeInterval = 0.5
    private static let popupRefreshInterval: TimeInterval = 0.4
    private static let idleFallbackPollInterval: TimeInterval = 1.0
    private static let mouseMoveThreshold: CGFloat = 2.0

    private var panel: NSPanel?
    private var hostingView: NSHostingView<DockInfoPopupView>?
    private var popupModel: DockInfoPopupModel?
    private var hoverTimer: Timer?
    private var idleMouseMonitor: Any?
    private var activeMouseMonitor: Any?
    private var currentTargetPID: pid_t?
    private var currentIconRect: CGRect?
    private var cachedHoverTarget: DockTarget?
    private var lastMouseLocation: NSPoint?
    private var isPopupPresented = false
    private var isStarted = false
    private var isMouseNearDock = false
    private var lastPopupRefreshTime: TimeInterval = 0
    private var lastWindowStateSignature: String?

    var isPopupVisible: Bool {
        isPopupPresented
    }

    private override init() {
        super.init()
    }

    func refreshMonitoring() {
        runOnMain { [weak self] in
            self?.restartHoverMonitorIfNeeded()
        }
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

        restartHoverMonitorIfNeeded()
    }

    func stop() {
        runOnMain { [weak self] in
            guard let self else { return }
            self.enterIdleMonitoring()
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

    private func restartHoverMonitorIfNeeded() {
        guard Thread.isMainThread else {
            runOnMain { [weak self] in
                self?.restartHoverMonitorIfNeeded()
            }
            return
        }

        enterIdleMonitoring()

        guard isStarted,
              UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey),
              QuickShowHideService.shared.isAccessibilityGranted else {
            return
        }

        let mouse = NSEvent.mouseLocation
        let nearDock = QuickShowHideService.shared.isMouseOverDock(cocoaPoint: mouse)
        isMouseNearDock = nearDock

        if isPopupPresented || nearDock {
            enterActiveMonitoring()
            processHover(at: mouse)
        }
    }

    private func scheduleHoverTimer(interval: TimeInterval) {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.pollMouseHover()
        }
        if let hoverTimer {
            RunLoop.main.add(hoverTimer, forMode: .common)
        }
    }

    private func stopActivePolling() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    private func enterIdleMonitoring() {
        exitActiveMonitoring()
        stopActivePolling()
        cachedHoverTarget = nil

        guard idleMouseMonitor == nil else { return }

        idleMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.wakeFromIdleIfNearDock()
            }
        }

        if idleMouseMonitor == nil {
            scheduleHoverTimer(interval: Self.idleFallbackPollInterval)
        }
    }

    private func exitIdleMonitoring() {
        if let idleMouseMonitor {
            NSEvent.removeMonitor(idleMouseMonitor)
            self.idleMouseMonitor = nil
        }
    }

    private func enterActiveMonitoring() {
        exitIdleMonitoring()
        installActiveMouseMonitorIfNeeded()
        scheduleHoverTimer(interval: Self.activeFallbackPollInterval)
    }

    private func exitActiveMonitoring() {
        stopActivePolling()
        if let activeMouseMonitor {
            NSEvent.removeMonitor(activeMouseMonitor)
            self.activeMouseMonitor = nil
        }
        lastMouseLocation = nil
    }

    private func installActiveMouseMonitorIfNeeded() {
        guard activeMouseMonitor == nil else { return }

        activeMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleActiveMouseEvent()
            }
        }
    }

    private func handleActiveMouseEvent() {
        let mouse = NSEvent.mouseLocation
        guard !shouldSkipMouseMove(to: mouse) else { return }
        lastMouseLocation = mouse
        processHover(at: mouse)
    }

    private func shouldSkipMouseMove(to mouse: NSPoint) -> Bool {
        guard let last = lastMouseLocation else { return false }
        let dx = mouse.x - last.x
        let dy = mouse.y - last.y
        return (dx * dx + dy * dy) < Self.mouseMoveThreshold * Self.mouseMoveThreshold
    }

    private func wakeFromIdleIfNearDock() {
        guard isStarted,
              UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey),
              !isPopupPresented else {
            return
        }

        let mouse = NSEvent.mouseLocation
        guard QuickShowHideService.shared.isMouseOverDock(cocoaPoint: mouse) else {
            return
        }

        isMouseNearDock = true
        enterActiveMonitoring()
        processHover(at: mouse)
    }

    private func presentOnMain(_ target: DockTarget) {
        guard UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey) else { return }

        AppWindowInspector.invalidateWindowCache(for: target.processIdentifier)
        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: false)
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
        lastPopupRefreshTime = Date().timeIntervalSince1970

        applyPopupContent(
            appName: appName,
            appIcon: target.app.icon,
            isFrontmost: QuickShowHideService.shared.isAppFrontmost(target.app),
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

        model.appName = appName
        model.appIcon = appIcon
        model.isFrontmost = isFrontmost
        model.windows = windows

        if layoutNeedsUpdate(current: model.layout, new: layout) {
            model.layout = layout
            panel.setFrame(layout.frame(anchor: anchor), display: false)
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
            || current.rowHeights != new.rowHeights
    }

    func refreshCurrentPopup() {
        runOnMain { [weak self] in
            self?.refreshCurrentPopupOnMain(force: true)
        }
    }

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

        let signature = Self.windowsStateSignature(snapshot.windows)
        if !force, signature == lastWindowStateSignature {
            return
        }

        lastPopupRefreshTime = now
        lastWindowStateSignature = signature

        let appName = app.localizedName ?? "未知应用"
        let layout = DockPopupLayout.calculate(
            appName: appName,
            windows: snapshot.windows,
            anchor: iconRect
        )

        applyPopupContent(
            appName: appName,
            appIcon: app.icon,
            isFrontmost: QuickShowHideService.shared.isAppFrontmost(app),
            windows: snapshot.windows,
            layout: layout,
            anchor: iconRect
        )
    }

    func dismissImmediately() {
        runOnMain { [weak self] in
            self?.dismissImmediatelyOnMain()
        }
    }

    private func dismissImmediatelyOnMain() {
        guard isPopupPresented else { return }

        if let pid = currentTargetPID {
            AppWindowInspector.invalidateWindowCache(for: pid)
        }

        panel?.orderOut(nil)
        isPopupPresented = false
        currentTargetPID = nil
        currentIconRect = nil
        cachedHoverTarget = nil
        lastWindowStateSignature = nil
        lastPopupRefreshTime = 0
    }

    private func pollMouseHover() {
        processHover(at: NSEvent.mouseLocation)
    }

    private func processHover(at mouse: NSPoint) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.processHover(at: mouse)
            }
            return
        }

        defer {
            if isPopupPresented || isMouseNearDock {
                enterActiveMonitoring()
            } else {
                enterIdleMonitoring()
            }
        }

        guard UserDefaults.standard.bool(forKey: dockInfoPopupEnabledKey) else { return }

        let nearDock = QuickShowHideService.shared.isMouseOverDock(cocoaPoint: mouse)
        isMouseNearDock = nearDock

        if !nearDock && !isPopupPresented {
            cachedHoverTarget = nil
            return
        }

        if isPopupPresented {
            pollWhilePopupVisible(mouse: mouse, nearDock: nearDock)
        } else if nearDock {
            pollWhilePopupHidden(mouse: mouse)
        }
    }

    private func pollWhilePopupVisible(mouse: NSPoint, nearDock: Bool) {
        if isMouseOverPanel(mouse) {
            return
        }

        if isMouseOverCurrentIcon(mouse) {
            refreshCurrentPopupOnMain(force: false)
            return
        }

        guard nearDock,
              let target = dockTargetUnderMouse(mouse) else {
            dismissImmediatelyOnMain()
            return
        }

        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: true)
        guard snapshot.shouldShow else {
            dismissImmediatelyOnMain()
            return
        }

        if target.processIdentifier != currentTargetPID {
            presentOnMain(target)
            return
        }

        dismissImmediatelyOnMain()
    }

    private func pollWhilePopupHidden(mouse: NSPoint) {
        guard let target = dockTargetUnderMouse(mouse) else { return }

        let snapshot = AppWindowInspector.popupSnapshot(for: target.app, useCache: true)
        guard snapshot.shouldShow else { return }

        presentOnMain(target)
    }

    private func isMouseOverPanel(_ mouse: NSPoint) -> Bool {
        guard isPopupPresented, let panel else { return false }
        return panel.frame.insetBy(dx: -2, dy: -2).contains(mouse)
    }

    private func isMouseOverCurrentIcon(_ mouse: NSPoint) -> Bool {
        guard currentTargetPID != nil else { return false }
        guard let target = dockTargetUnderMouse(mouse),
              target.processIdentifier == currentTargetPID else {
            return false
        }
        currentIconRect = target.iconRect
        return true
    }

    private func dockTargetUnderMouse(_ mouse: NSPoint) -> DockTarget? {
        if let cached = cachedHoverTarget {
            let cgMouse = QuickShowHideService.shared.cgPointFromCocoa(mouse)
            let hitRect = cached.iconRect.insetBy(dx: -4, dy: -4)
            if hitRect.contains(cgMouse) {
                return cached
            }
        }

        let cgPoint = QuickShowHideService.shared.cgPointFromCocoa(mouse)
        guard let target = QuickShowHideService.shared.dockTarget(at: cgPoint) else {
            cachedHoverTarget = nil
            return nil
        }

        cachedHoverTarget = target
        return target
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
