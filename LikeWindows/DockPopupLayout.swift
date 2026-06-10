//
//  DockPopupLayout.swift
//  likeWindows
//

import AppKit

struct DockPopupLayout {
    enum Density {
        case standard
        case compact
    }

    let width: CGFloat
    let listHeight: CGFloat
    let totalHeight: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let density: Density
    let needsScroll: Bool
    let rowHeights: [CGFloat]

    private static let minWidth: CGFloat = 220
    private static let dockGap: CGFloat = 0
    private static let headerHeight: CGFloat = 72
    private static let sectionPadding: CGFloat = 20
    private static let emptyStateHeight: CGFloat = 52
    /// 单行窗口行左右留白：分区边距 + 行内边距 + 图标 + 间距 + 控制按钮区
    private static let singleRowChrome: CGFloat = 180

    var rowSpacing: CGFloat {
        density == .compact ? 4 : 6
    }

    var titleLineLimit: Int { 1 }

    var showsRowSubtitle: Bool { true }

    var iconSize: CGFloat {
        density == .compact ? 26 : 30
    }

    static func calculate(
        appName: String,
        windows: [DockWindowInfo],
        anchor: CGRect
    ) -> DockPopupLayout {
        let screen = screenContaining(anchor: anchor)
        let maxWidth = screen.frame.width / 3
        let maxHeight = screen.frame.height / 3

        let width = calculateWidth(
            appName: appName,
            windows: windows,
            maxWidth: maxWidth
        )

        let availableListHeight = max(
            maxHeight - headerHeight - sectionPadding,
            emptyStateHeight
        )

        guard !windows.isEmpty else {
            let listHeight = min(emptyStateHeight, availableListHeight)
            return DockPopupLayout(
                width: width,
                listHeight: listHeight,
                totalHeight: headerHeight + sectionPadding + listHeight,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                density: .standard,
                needsScroll: false,
                rowHeights: []
            )
        }

        let candidates: [(Density, Bool)] = [
            (.standard, false),
            (.compact, false),
            (.compact, true),
        ]

        for (density, allowScroll) in candidates {
            if let layout = makeLayout(
                windows: windows,
                width: width,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                availableListHeight: availableListHeight,
                density: density,
                allowScroll: allowScroll
            ) {
                return layout
            }
        }

        return makeLayout(
            windows: windows,
            width: width,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            availableListHeight: availableListHeight,
            density: .compact,
            allowScroll: true
        )!
    }

    func frame(anchor: CGRect) -> NSRect {
        let screen = Self.screenContaining(anchor: anchor)

        var x = anchor.midX - width / 2
        let minX = screen.frame.minX + 8
        let maxX = screen.frame.maxX - width - 8
        x = min(max(x, minX), maxX)

        return NSRect(
            x: x,
            y: Self.popupBottomY(on: screen, anchor: anchor),
            width: width,
            height: totalHeight
        )
    }

    /// popup 底边对齐 Dock 栏上沿（visibleFrame 边界），而非图标矩形
    private static func popupBottomY(on screen: NSScreen, anchor: CGRect) -> CGFloat {
        let frame = screen.frame
        let visible = screen.visibleFrame

        // Dock 在屏幕底部：visibleFrame.minY 即 Dock 栏上沿（AppKit 坐标）
        if visible.minY > frame.minY + 1 {
            return visible.minY + dockGap
        }

        // 其他 Dock 位置（顶部/侧边）回退到图标锚点
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? frame.height
        return primaryHeight - anchor.minY + dockGap
    }

    private static func makeLayout(
        windows: [DockWindowInfo],
        width: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        availableListHeight: CGFloat,
        density: Density,
        allowScroll: Bool
    ) -> DockPopupLayout? {
        let cellWidth = width - 20
        let rowHeights = windows.map { rowHeight(title: $0.title, cellWidth: cellWidth, density: density) }
        let spacing = density == .compact ? 4.0 : 6.0
        let naturalListHeight = listHeight(rowHeights: rowHeights, spacing: spacing)

        if naturalListHeight <= availableListHeight + 0.5 {
            let totalHeight = min(
                headerHeight + sectionPadding + naturalListHeight,
                maxHeight
            )
            return DockPopupLayout(
                width: width,
                listHeight: naturalListHeight,
                totalHeight: totalHeight,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                density: density,
                needsScroll: false,
                rowHeights: rowHeights
            )
        }

        guard allowScroll else { return nil }

        return DockPopupLayout(
            width: width,
            listHeight: availableListHeight,
            totalHeight: maxHeight,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            density: density,
            needsScroll: true,
            rowHeights: rowHeights
        )
    }

    private static func calculateWidth(
        appName: String,
        windows: [DockWindowInfo],
        maxWidth: CGFloat
    ) -> CGFloat {
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let nameFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

        let nameWidth = textWidth(appName, font: nameFont)
        let headerWidth = 28 + 40 + 12 + nameWidth + 80

        let longestTitle = windows.map { textWidth($0.title, font: titleFont) }.max() ?? 120
        let contentWidth = max(headerWidth, singleRowChrome + longestTitle)

        return min(max(contentWidth, minWidth), maxWidth)
    }

    private static func rowHeight(title: String, cellWidth: CGFloat, density: Density) -> CGFloat {
        let textWidth = max(cellWidth - rowTextInset(density: density), 40)
        let titleFont = NSFont.systemFont(
            ofSize: density == .compact ? 12 : 13,
            weight: .medium
        )
        let titleHeight = textHeight(title, font: titleFont, width: textWidth, maxLines: 1)
        let subtitleHeight: CGFloat = 13
        let textBlock = titleHeight + subtitleHeight + (density == .compact ? 0 : 2)
        let iconSize = density == .compact ? 26.0 : 30.0
        let verticalPadding = density == .compact ? 10.0 : 14.0
        return max(iconSize, textBlock) + verticalPadding
    }

    private static func rowTextInset(density: Density) -> CGFloat {
        let rowPadding = density == .compact ? 12.0 : 16.0
        let iconSize = density == .compact ? 26.0 : 30.0
        let innerSpacing = density == .compact ? 8.0 : 10.0
        let hstackSpacing = density == .compact ? 4.0 : 6.0
        let controlsWidth = density == .compact ? 86.0 : 98.0
        return rowPadding + iconSize + innerSpacing + hstackSpacing + controlsWidth
    }

    private static func listHeight(rowHeights: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !rowHeights.isEmpty else { return 4 }
        return rowHeights.reduce(0, +)
            + CGFloat(max(rowHeights.count - 1, 0)) * spacing
            + 4
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    private static func textHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat,
        maxLines: Int
    ) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle,
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let maxHeight = lineHeight * CGFloat(maxLines)
        return min(ceil(bounds.height), maxHeight)
    }

    private static func screenContaining(anchor: CGRect) -> NSScreen {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let screenHeight = primary?.frame.height ?? 0
        let cocoaPoint = NSPoint(x: anchor.midX, y: screenHeight - anchor.midY)

        return NSScreen.screens.first { NSPointInRect(cocoaPoint, $0.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
