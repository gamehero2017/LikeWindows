//
//  ContentView.swift
//  LikeWindows
//
//  Created by 青藤 on 2026/6/9.
//

import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @AppStorage(AppSettings.quickShowHideEnabled) private var quickShowHideEnabled = false
    @AppStorage(AppSettings.dockInfoPopupEnabled) private var dockInfoPopupEnabled = false
    @AppStorage(AppSettings.useSystemWindowOrder) private var useSystemWindowOrder = false
    @State private var accessibilityGranted = QuickShowHideService.shared.isAccessibilityGranted
    @State private var diagnosticText = QuickShowHideService.shared.diagnosticSummary
    @State private var showsAboutPopover = false
    @State private var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginPendingApproval = LaunchAtLoginService.needsApproval

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusBanner

                if (quickShowHideEnabled || dockInfoPopupEnabled) && !accessibilityGranted {
                    permissionSection
                }

                settingsSection

                if quickShowHideEnabled || dockInfoPopupEnabled {
                    usageSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 440, minHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            QuickShowHideService.shared.refreshAccessibilityStatus()
            refreshLaunchAtLoginState()
            refreshStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("偏好设置")
                .font(.system(size: 20, weight: .bold))

            HStack(spacing: 5) {
                Text("让 Dock 操作更接近 Windows 任务栏")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showsAboutPopover.toggle()
                    }
                    .popover(isPresented: $showsAboutPopover, arrowEdge: .top) {
                        AboutPopoverView()
                    }
                    .help("关于如窗")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("关于如窗")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accessibilityGranted ? .green : .orange)

            Text(diagnosticText)
                .font(.caption.monospaced())
                .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(cardBackground)
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "操作")

            VStack(spacing: 0) {
                SettingToggleRow(
                    title: "快速显示/隐藏",
                    subtitle: "单窗口：点击 Dock 图标隐藏，再次点击恢复",
                    systemImage: "arrow.up.arrow.down.circle.fill",
                    tint: .blue,
                    style: .primary,
                    isOn: $quickShowHideEnabled
                ) { _ in
                    handleToggleChange()
                }

                sectionDivider

                dockPopupGroup

                sectionDivider

                SettingToggleRow(
                    title: "登录时打开",
                    subtitle: launchAtLoginSubtitle,
                    systemImage: "power.circle.fill",
                    tint: .orange,
                    style: .primary,
                    isOn: $launchAtLoginEnabled
                ) { enabled in
                    handleLaunchAtLoginChange(enabled)
                }
            }
            .background(cardBackground)
        }
    }

    private var dockPopupGroup: some View {
        VStack(spacing: 0) {
            SettingToggleRow(
                title: "Dock 信息弹窗",
                subtitle: "多窗口：悬停 Dock 图标显示全部窗口",
                systemImage: "macwindow.on.rectangle",
                tint: .purple,
                style: .primary,
                isOn: $dockInfoPopupEnabled
            ) { _ in
                handleToggleChange()
            }

            if dockInfoPopupEnabled {
                NestedSettingsGroup(tint: .purple) {
                    SettingToggleRow(
                        title: "系统窗口排序",
                        subtitle: "跟随系统顺序；关闭则按打开顺序固定排列",
                        systemImage: "arrow.up.arrow.down.square.fill",
                        tint: .teal,
                        style: .nested,
                        isOn: $useSystemWindowOrder
                    ) { _ in
                        DockInfoPopupService.shared.refreshCurrentPopup()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: dockInfoPopupEnabled)
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "使用说明")

            VStack(alignment: .leading, spacing: 6) {
                UsageLine(
                    label: "后台运行",
                    detail: "关闭本窗口后如窗继续在后台运行并隐藏 Dock 图标；再次从启动台或应用程序打开即可"
                )
                if quickShowHideEnabled {
                    UsageLine(label: "单窗口", detail: "点击 Dock 图标切换显示/隐藏")
                }
                if dockInfoPopupEnabled {
                    UsageLine(label: "多窗口", detail: "悬停 Dock 图标查看窗口，移开即关闭")
                    UsageLine(
                        label: "排序",
                        detail: useSystemWindowOrder
                            ? "跟随系统当前窗口顺序"
                            : "按打开顺序固定排列"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private var permissionSection: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)

            Text("需要辅助功能权限，授权后功能方可生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("去授权") {
                QuickShowHideService.shared.openAccessibilitySettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
    }

    private var sectionDivider: some View {
        Divider().padding(.leading, 48)
    }

    private var launchAtLoginSubtitle: String {
        if launchAtLoginPendingApproval {
            return "请在系统设置中允许如窗登录时打开"
        }
        return "登录 Mac 时自动启动"
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            }
    }

    private func handleToggleChange() {
        QuickShowHideService.shared.refreshAccessibilityStatus()
        refreshStatus()
    }

    private func handleLaunchAtLoginChange(_ enabled: Bool) {
        if !LaunchAtLoginService.setEnabled(enabled) {
            refreshLaunchAtLoginState()
            return
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginEnabled = LaunchAtLoginService.isEnabled
        launchAtLoginPendingApproval = LaunchAtLoginService.needsApproval
    }

    private func refreshStatus() {
        refreshLaunchAtLoginState()
        let granted = QuickShowHideService.shared.isAccessibilityGranted
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            if granted {
                QuickShowHideService.shared.restartEventTapIfNeeded()
                DockInfoPopupService.shared.refreshMonitoring()
            }
        }
        diagnosticText = QuickShowHideService.shared.diagnosticSummary
    }
}

// MARK: - Components

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }
}

private enum SettingRowStyle {
    case primary
    case nested
}

private struct SettingToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let style: SettingRowStyle
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: style == .primary ? 10 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: style == .primary ? 17 : 14, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: style == .primary ? 24 : 20, height: style == .primary ? 24 : 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(style == .primary ? .subheadline.weight(.semibold) : .caption.weight(.semibold))

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle(
                "",
                isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        isOn = newValue
                        onChange(newValue)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, style == .primary ? 12 : 10)
        .padding(.vertical, style == .primary ? 10 : 8)
    }
}

private struct NestedSettingsGroup<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(tint.opacity(0.35))
                .frame(width: 2)
                .padding(.leading, 22)
                .padding(.vertical, 4)

            VStack(spacing: 0) {
                content
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint.opacity(0.06))
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
    }
}

private struct UsageLine: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .leading)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AboutPopoverView: View {
    private let appName = "如窗"
    private let developerName = "青藤"

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(appName)
                        .font(.headline)

                    Text("版本 \(versionText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("开发者", systemImage: "person.crop.circle")
                    .font(.caption.weight(.semibold))

                Text(developerName)
                    .font(.subheadline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("软件说明", systemImage: "doc.text")
                    .font(.caption.weight(.semibold))

                Text(
                    "如窗是一款 macOS 效率工具，让 Dock 的操作体验更接近 Windows 任务栏。"
                    + "支持单窗口应用的快速显示/隐藏，以及多窗口应用的悬停信息弹窗、窗口排序与窗口控制。"
                    + "使用前需在系统设置中授予辅助功能权限。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

#Preview {
    ContentView()
}
