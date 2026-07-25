//
//  AppSettings.swift
//  LikeWindows
//

import Foundation

/// UserDefaults 键名集中定义，避免各处硬编码字符串。
enum AppSettings {
    /// 快速显示/隐藏（Dock 点击隐藏前台窗口）
    static let quickShowHideEnabled = "quickShowHideEnabled"
    /// Dock 悬停信息弹窗
    static let dockInfoPopupEnabled = "dockInfoPopupEnabled"
    /// 弹窗窗口列表使用系统 Z 序（关闭则按打开顺序）
    static let useSystemWindowOrder = "useSystemWindowOrderEnabled"
    /// 是否在菜单栏显示如窗图标（默认开启）
    static let menuBarIconVisible = "menuBarIconVisible"

    /// 注册缺省值；未写入过的键按此取值（例如 `bool(forKey:)` 对缺失键会得到 false）。
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            menuBarIconVisible: true
        ])
    }

    /// 菜单栏图标是否应显示（缺省为 true）。
    static var isMenuBarIconVisible: Bool {
        if UserDefaults.standard.object(forKey: menuBarIconVisible) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: menuBarIconVisible)
    }
}

/// 兼容旧代码的别名
let dockInfoPopupEnabledKey = AppSettings.dockInfoPopupEnabled
let useSystemWindowOrderKey = AppSettings.useSystemWindowOrder
