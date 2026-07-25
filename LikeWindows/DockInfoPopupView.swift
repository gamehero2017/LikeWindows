//
//  DockInfoPopupView.swift
//  likeWindows
//

import AppKit
import Observation
import SwiftUI

/// 悬停弹窗的可变数据模型，供 SwiftUI 视图绑定刷新。
@Observable
final class DockInfoPopupModel {
    var appName: String
    var appIcon: NSImage?
    var isFrontmost: Bool
    var windows: [DockWindowInfo]
    var layout: DockPopupLayout

    init(
        appName: String = "",
        appIcon: NSImage? = nil,
        isFrontmost: Bool = false,
        windows: [DockWindowInfo] = [],
        layout: DockPopupLayout
    ) {
        self.appName = appName
        self.appIcon = appIcon
        self.isFrontmost = isFrontmost
        self.windows = windows
        self.layout = layout
    }
}

/// Dock 悬停信息弹窗 UI：应用头、窗口列表与最小化/最大化/关闭按钮。
struct DockInfoPopupView: View {
    @Bindable var model: DockInfoPopupModel

    private let cornerRadius: CGFloat = 14

    private var layout: DockPopupLayout { model.layout }

    var body: some View {
        popupCard
            .frame(width: layout.width)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var popupCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()
                .opacity(0.3)
                .padding(.horizontal, 12)

            windowSection
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
        }
        .frame(width: layout.width)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let appIcon = model.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.appName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    StatusBadge(text: model.isFrontmost ? "前台" : "后台", isActive: model.isFrontmost)
                    Text("\(model.windows.count) 个窗口")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var windowSection: some View {
        if model.windows.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "macwindow.badge.plus")
                    .foregroundStyle(.tertiary)
                Text("暂无活动窗口")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 6)
        } else if layout.needsScroll {
            ScrollView(.vertical, showsIndicators: true) {
                windowList
            }
            .frame(height: layout.listHeight)
        } else {
            windowList
                .frame(height: layout.listHeight, alignment: .top)
        }
    }

    private var windowList: some View {
        WindowListView(windows: model.windows, layout: layout)
    }
}

private struct WindowListView: View {
    let windows: [DockWindowInfo]
    let layout: DockPopupLayout

    /// 列表级互斥高亮（对齐 DockDoor `currIndex`）：进入新行直接覆盖，不依赖上一行 ended。
    @State private var hoveredWindowID: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                if index > 0 {
                    Divider()
                        .opacity(0.22)
                        .padding(.leading, 52)
                }

                WindowRow(
                    window: window,
                    index: index + 1,
                    layout: layout,
                    rowHeight: layout.rowHeight(at: index),
                    isHovered: hoveredWindowID == window.id,
                    onHoverChange: { hovering in
                        if hovering {
                            hoveredWindowID = window.id
                        } else if hoveredWindowID == window.id {
                            hoveredWindowID = nil
                        }
                    }
                )
            }
        }
        .animation(nil, value: hoveredWindowID)
    }
}

private struct PopupPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct StatusBadge: View {
    let text: String
    let isActive: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isActive ? .green : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(isActive ? Color.green.opacity(0.14) : Color.secondary.opacity(0.1))
            }
    }
}

private struct WindowRow: View {
    let window: DockWindowInfo
    let index: Int
    let layout: DockPopupLayout
    let rowHeight: CGFloat
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void

    private var isCompact: Bool {
        layout.density == .compact
    }

    var body: some View {
        HStack(alignment: .center, spacing: isCompact ? 4 : 6) {
            Button(action: openWindow) {
                HStack(alignment: .top, spacing: isCompact ? 8 : 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: isCompact ? 7 : 8, style: .continuous)
                            .fill(window.isMinimized ? Color.orange.opacity(0.12) : Color.accentColor.opacity(0.1))
                            .frame(width: layout.iconSize, height: layout.iconSize)

                        Image(systemName: window.isMinimized ? "minus.circle.fill" : "macwindow")
                            .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                            .foregroundStyle(window.isMinimized ? .orange : .accentColor)
                    }

                    VStack(alignment: .leading, spacing: isCompact ? 0 : 2) {
                        Text(window.title)
                            .font(.system(size: isCompact ? 12 : 13, weight: .medium))
                            .foregroundStyle(window.isMinimized ? .secondary : .primary)
                            .lineLimit(layout.titleLineLimit)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if layout.showsRowSubtitle {
                            Text(window.isMinimized ? "已最小化" : "窗口 \(index)")
                                .font(.caption2)
                                .foregroundStyle(window.isMinimized ? Color.orange : Color.secondary.opacity(0.75))
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopupPlainButtonStyle())
            .focusable(false)
            .focusEffectDisabled()
            .accessibilityLabel(window.isMinimized ? "恢复窗口：\(window.title)" : "切换窗口：\(window.title)")

            WindowsWindowControls(window: window, isCompact: isCompact)
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 5 : 7)
        .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: isCompact ? 8 : 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
    }

    /// 点击行：已是前台焦点窗则最小化并刷新列表；否则关闭弹窗并激活该窗口。
    private func openWindow() {
        let didMinimize = AppWindowInspector.activateOrMinimizeFromPopup(window)
        if didMinimize {
            DockInfoPopupService.shared.refreshCurrentPopup()
        } else {
            DockInfoPopupService.shared.dismissImmediately()
        }
    }
}

/// 仿 Windows 风格的最小化 / 最大化 / 关闭按钮组。
private struct WindowsWindowControls: View {
    let window: DockWindowInfo
    let isCompact: Bool

    private var buttonSize: CGSize {
        isCompact ? CGSize(width: 28, height: 24) : CGSize(width: 32, height: 28)
    }

    var body: some View {
        HStack(spacing: 1) {
            WindowsControlButton(
                systemImage: "minus",
                style: .minimize,
                size: buttonSize,
                enabled: window.canMinimize,
                accessibilityLabel: "最小化窗口"
            ) {
                perform(.minimize)
            }

            WindowsControlButton(
                systemImage: "square",
                style: .maximize,
                size: buttonSize,
                enabled: window.canZoom,
                accessibilityLabel: "最大化窗口"
            ) {
                perform(.zoom)
            }

            WindowsControlButton(
                systemImage: "xmark",
                style: .close,
                size: buttonSize,
                enabled: window.canClose,
                accessibilityLabel: "关闭窗口"
            ) {
                perform(.close)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private func perform(_ action: WindowControlAction) {
        _ = AppWindowInspector.perform(action, window: window)
        DockInfoPopupService.shared.refreshCurrentPopup()
    }
}

private struct WindowsControlButton: View {
    enum Style {
        case minimize
        case maximize
        case close
    }

    let systemImage: String
    let style: Style
    let size: CGSize
    let enabled: Bool
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size.height > 25 ? 11 : 10, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(width: size.width, height: size.height)
                .background(backgroundColor)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopupPlainButtonStyle())
        .focusable(false)
        .focusEffectDisabled()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(accessibilityLabel)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        guard enabled else {
            return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        }

        switch style {
        case .close:
            return isHovered
                ? Color(red: 0.9, green: 0.15, blue: 0.2)
                : Color(nsColor: .controlBackgroundColor)
        case .minimize, .maximize:
            return isHovered
                ? Color.primary.opacity(0.1)
                : Color(nsColor: .controlBackgroundColor)
        }
    }

    private var foregroundColor: Color {
        guard enabled else { return .secondary }

        if style == .close, isHovered {
            return .white
        }
        return .primary.opacity(0.8)
    }
}
