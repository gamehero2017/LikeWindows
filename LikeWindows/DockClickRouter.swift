//
//  DockClickRouter.swift
//  likeWindows
//

import AppKit

/// Dock 点击路由：决定「自己处理」还是「交给系统」。
///
/// ## 设计原则
/// - 仅对**单窗口**应用：在「已在前台且有可见窗口」时拦截点击并最小化。
/// - **多窗口**应用：不拦截 Dock 点击（交给系统）；逐窗操作走悬停弹窗。
/// - 后台点击不拦截，保留系统 Dock 原生动画（打开 / 恢复 / 前置）。
/// - Event Tap 侧：本方法返回 `true` → 吞掉事件；`false` → 放行给系统。
enum DockClickRouter {
    /// 处理一次 Dock 图标点击。
    /// - Parameters:
    ///   - target: 命中的 Dock 应用与图标矩形
    ///   - quickEnabled: 「快速显示/隐藏」开关
    ///   - popupEnabled: 「Dock 信息弹窗」开关（用于点击时关闭悬停弹窗）
    /// - Returns: 是否已消费该点击
    static func handleClick(on target: DockTarget, quickEnabled: Bool, popupEnabled: Bool) -> Bool {
        guard quickEnabled || popupEnabled else { return false }

        // 点击 Dock 时先关掉悬停弹窗，避免挡操作 / 焦点错乱
        if popupEnabled, DockInfoPopupService.shared.isPopupVisible {
            DockInfoPopupService.shared.dismissImmediately()
        }

        // 仅开了悬停弹窗、未开快显时：上面已关弹窗，其余交给系统
        guard quickEnabled else { return false }

        // 多窗口：不拦截，避免「一点 Dock 全部最小化」；由悬停弹窗做逐窗操作
        if AppWindowInspector.hasMultipleTrackableWindows(for: target.app) {
            return false
        }

        return handleSingleWindowHide(target)
    }

    /// 单窗口隐藏路径。
    ///
    /// 三个前置条件缺一不可，任一不满足则 `return false`（事件放行）：
    /// 1. 应用在前台 —— 否则应由系统激活/恢复
    /// 2. 有可见窗口 —— 无可隐藏目标
    /// 3. 通过防抖 —— 避免连点重复最小化
    private static func handleSingleWindowHide(_ target: DockTarget) -> Bool {
        guard QuickShowHideService.shared.isAppFrontmost(target.app) else { return false }
        guard AppWindowInspector.hasVisibleWindowFast(for: target.app) else { return false }
        guard QuickShowHideService.shared.shouldProcessClick(for: target.app) else { return false }

        return AppWindowInspector.hideActiveWindowIfVisible(for: target.app)
    }
}
