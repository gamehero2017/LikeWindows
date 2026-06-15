//
//  DockTarget.swift
//  likeWindows
//

import AppKit

struct DockTarget: Equatable {
    let app: NSRunningApplication
    let iconRect: CGRect

    var processIdentifier: pid_t {
        app.processIdentifier
    }

    static func == (lhs: DockTarget, rhs: DockTarget) -> Bool {
        lhs.app.processIdentifier == rhs.app.processIdentifier
            && lhs.iconRect == rhs.iconRect
    }
}

struct DockWindowInfo: Identifiable {
    let id: String
    let stableOrderKey: String
    let title: String
    let isMinimized: Bool
    let processIdentifier: pid_t
    let windowIndex: Int
    let canClose: Bool
    let canMinimize: Bool
    let canZoom: Bool
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

enum WindowControlAction {
    case close
    case minimize
    case zoom
}
