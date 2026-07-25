//
//  LaunchAtLoginService.swift
//  likeWindows
//

import AppKit
import ServiceManagement

/// 登录项（开机启动）开关，基于 SMAppService。
enum LaunchAtLoginService {
    /// 已启用或等待用户在系统设置中批准时视为开启。
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    /// 是否需要用户在「登录项」设置中手动批准。
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// 注册 / 注销登录项；若需批准则打开系统设置页。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if needsApproval {
                    openLoginItemsSettings()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// 打开系统设置中的登录项页面（兼容新旧 URL）。
    static func openLoginItemsSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.users?LoginItems",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
