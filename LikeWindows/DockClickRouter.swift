//
//  DockClickRouter.swift
//  likeWindows
//

import AppKit

/// Dock 点击：前台可见时快速隐藏；其余情况交给系统处理（打开/恢复）
enum DockClickRouter {
    static func handleClick(on target: DockTarget, quickEnabled: Bool, popupEnabled: Bool) -> Bool {
        guard quickEnabled || popupEnabled else { return false }

        if popupEnabled, DockInfoPopupService.shared.isPopupVisible {
            DockInfoPopupService.shared.dismissImmediately()
        }

        guard quickEnabled else { return false }

        let isMultiWindow = AppWindowInspector.hasMultipleTrackableWindows(for: target.app)
        if isMultiWindow {
            return handleMultiWindowHide(target)
        }

        return handleSingleWindowHide(target)
    }

    private static func handleSingleWindowHide(_ target: DockTarget) -> Bool {
        guard QuickShowHideService.shared.isAppFrontmost(target.app) else { return false }
        guard AppWindowInspector.hasVisibleWindowFast(for: target.app) else { return false }
        guard QuickShowHideService.shared.shouldProcessClick(for: target.app) else { return true }

        return AppWindowInspector.hideActiveWindowIfVisible(for: target.app)
    }

    private static func handleMultiWindowHide(_ target: DockTarget) -> Bool {
        guard QuickShowHideService.shared.isAppFrontmost(target.app) else { return false }
        guard AppWindowInspector.hasVisibleWindowFast(for: target.app) else { return false }
        guard QuickShowHideService.shared.shouldProcessClick(for: target.app) else { return true }

        return AppWindowInspector.minimizeAllVisibleWindows(for: target.app)
    }
}
