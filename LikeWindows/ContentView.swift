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
    @AppStorage("quickShowHideEnabled") private var quickShowHideEnabled = false
    @AppStorage("dockInfoPopupEnabled") private var dockInfoPopupEnabled = false
    @AppStorage(useSystemWindowOrderKey) private var useSystemWindowOrder = false
    @State private var accessibilityGranted = QuickShowHideService.shared.isAccessibilityGranted
    @State private var diagnosticText = QuickShowHideService.shared.diagnosticSummary
    @State private var showsAboutPopover = false
    @State private var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginPendingApproval = LaunchAtLoginService.needsApproval

    private let windowTitle = "如窗"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusCard
                settingsGroup

                if quickShowHideEnabled || dockInfoPopupEnabled {
                    usageCard

                    if !accessibilityGranted {
                        permissionCard
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 480, minHeight: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowTitleSetter(title: windowTitle))
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("偏好设置")
                    .font(.system(size: 24, weight: .bold))

                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .medium))
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

                Spacer(minLength: 0)
            }

            Text("像Windows一样的操作偏好，让Dock操作更接近Windows任务栏")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsGroup: some View {
        VStack(spacing: 0) {
            SettingToggleRow(
                title: "快速显示/隐藏",
                subtitle: "单窗口应用：点击 Dock 图标，窗口最小化，再次点击恢复窗口显示",
                systemImage: "arrow.up.arrow.down.circle.fill",
                tint: .blue,
                isOn: $quickShowHideEnabled
            ) { _ in
                handleToggleChange()
            }

            Divider()
                .padding(.leading, 52)

            SettingToggleRow(
                title: "Dock 信息弹窗",
                subtitle: "多窗口应用：悬停 Dock 图标显示全部窗口信息",
                systemImage: "macwindow.on.rectangle",
                tint: .purple,
                isOn: $dockInfoPopupEnabled
            ) { _ in
                handleToggleChange()
            }

            if dockInfoPopupEnabled {
                Divider()
                    .padding(.leading, 52)

                SettingToggleRow(
                    title: "系统窗口排序",
                    subtitle: "开启后 popup 列表跟随系统当前窗口顺序；关闭则按打开顺序固定排列",
                    systemImage: "arrow.up.arrow.down.square.fill",
                    tint: .teal,
                    isOn: $useSystemWindowOrder
                ) { _ in
                    DockInfoPopupService.shared.refreshCurrentPopup()
                }
            }

            Divider()
                .padding(.leading, 52)

            SettingToggleRow(
                title: "登录时打开",
                subtitle: launchAtLoginSubtitle,
                systemImage: "power.circle.fill",
                tint: .orange,
                isOn: $launchAtLoginEnabled
            ) { enabled in
                handleLaunchAtLoginChange(enabled)
            }
        }
        .background(cardBackground)
    }

    private var launchAtLoginSubtitle: String {
        if launchAtLoginPendingApproval {
            return "已请求加入登录项，请在系统设置中允许如窗登录时打开"
        }
        return "登录 Mac 时自动启动如窗"
    }

    private var usageCard: some View {
        InfoCard(
            title: "使用说明",
            systemImage: "info.circle.fill",
            tint: .secondary
        ) {
            VStack(alignment: .leading, spacing: 8) {
                UsageLine(
                    label: "单窗口",
                    detail: "前台点击隐藏，再次点击恢复窗口显示"
                )
                UsageLine(
                    label: "多窗口",
                    detail: "悬停显示全部窗口信息，鼠标离开弹窗消失"
                )
                UsageLine(
                    label: "窗口排序",
                    detail: useSystemWindowOrder
                        ? "已开启：popup 列表使用系统当前窗口顺序"
                        : "已关闭：popup 列表按窗口打开顺序固定排列，不随焦点变化"
                )
            }
        }
    }

    private var statusCard: some View {
        InfoCard(
            title: "运行状态",
            systemImage: accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            tint: accessibilityGranted ? .green : .orange
        ) {
            Text(diagnosticText)
                .font(.caption.monospaced())
                .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var permissionCard: some View {
        InfoCard(
            title: "需要辅助功能权限",
            systemImage: "hand.raised.fill",
            tint: .orange
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("请在系统设置中为如窗开启辅助功能权限，授权后功能即可生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    QuickShowHideService.shared.openAccessibilitySettings()
                } label: {
                    Label("打开辅助功能设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
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

private struct SettingToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Binding var isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct InfoCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

private struct UsageLine: View {
    let label: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, alignment: .leading)

            Text(detail)
                .font(.caption)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(appName)
                        .font(.title3.weight(.semibold))

                    Text("版本 \(versionText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("开发者", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(developerName)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("软件说明", systemImage: "doc.text")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

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
        .padding(20)
        .frame(width: 320)
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

#Preview {
    ContentView()
}
