//
//  DockTarget.swift
//  likeWindows
//

import AppKit

/// Dock 上命中的应用图标及其屏幕坐标（CG 坐标系）。
struct DockTarget: Equatable {
    let app: NSRunningApplication
    /// 图标在屏幕上的矩形区域，用于定位悬停弹窗。
    let iconRect: CGRect

    var processIdentifier: pid_t {
        app.processIdentifier
    }

    static func == (lhs: DockTarget, rhs: DockTarget) -> Bool {
        lhs.app.processIdentifier == rhs.app.processIdentifier
            && lhs.iconRect == rhs.iconRect
    }
}

/// 弹窗列表中的单个窗口信息；`stableOrderKey` 用于跨刷新稳定身份。
struct DockWindowInfo: Identifiable {
    let id: String
    /// 窗口稳定身份键（指纹或 CG 窗口号派生），列表重排时保持一致。
    let stableOrderKey: String
    let title: String
    let isMinimized: Bool
    let processIdentifier: pid_t
    let windowIndex: Int
    let canClose: Bool
    let canMinimize: Bool
    let canZoom: Bool
    /// 对应的 CGWindow 编号（若已匹配）。
    let cgWindowNumber: Int?

    init(
        stableOrderKey: String,
        title: String,
        isMinimized: Bool,
        processIdentifier: pid_t,
        windowIndex: Int,
        canClose: Bool,
        canMinimize: Bool,
        canZoom: Bool,
        cgWindowNumber: Int? = nil
    ) {
        self.stableOrderKey = stableOrderKey
        self.id = stableOrderKey
        self.title = title
        self.isMinimized = isMinimized
        self.processIdentifier = processIdentifier
        self.windowIndex = windowIndex
        self.canClose = canClose
        self.canMinimize = canMinimize
        self.canZoom = canZoom
        self.cgWindowNumber = cgWindowNumber
    }
}

/// 弹窗行内窗口控制按钮动作。
enum WindowControlAction {
    case close
    case minimize
    case zoom
}
