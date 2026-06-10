# 如窗 (LikeWindows)

一款 macOS 效率工具，让 Dock 的操作体验更接近 Windows 任务栏。

## 功能

### 快速显示/隐藏

适用于**单窗口应用**。点击 Dock 图标可最小化当前窗口，再次点击恢复显示，类似 Windows 任务栏的切换行为。

### Dock 信息弹窗

适用于**多窗口应用**。鼠标悬停在 Dock 图标上时，显示该应用的全部窗口列表，并支持：

- 预览与切换窗口
- Windows 风格的窗口控制按钮（最小化 / 最大化 / 关闭）
- **系统窗口排序**：跟随系统当前窗口顺序
- **打开顺序排序**：按窗口打开顺序固定排列，不随焦点变化

### 其他

- 支持**登录时自动启动**
- 内置运行状态诊断与辅助功能权限引导

## 系统要求

- macOS 26.2 或更高版本
- 需要授予**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能）

## 从源码构建

1. 使用 Xcode 打开 `LikeWindows.xcodeproj`
2. 选择 **LikeWindows** scheme
3. 按 `⌘R` 运行

## 打包 DMG

项目提供一键脚本，会自动完成 Release 构建并生成 DMG。

### 前置要求

- 已安装 Xcode 与 Command Line Tools
- 可在终端执行 `xcodebuild`

### 一键打包

```bash
chmod +x scripts/build-dmg.sh   # 首次使用时赋予执行权限
./scripts/build-dmg.sh
```

脚本会依次执行：

1. 使用 `xcodebuild` 构建 Release 版 `LikeWindows.app`
2. 将 `.app` 与「应用程序」快捷方式放入 `build/dmg-staging/`
3. 用 `hdiutil` 生成 DMG 到 `build/export/LikeWindows-<版本号>.dmg`

例如当前版本会输出：`build/export/LikeWindows-1.0.dmg`

### 手动步骤（可选）

若不想用脚本，也可手动执行：

```bash
xcodebuild -project LikeWindows.xcodeproj -scheme LikeWindows \
  -configuration Release -derivedDataPath build/DerivedData build

rm -rf build/dmg-staging
mkdir -p build/dmg-staging
cp -R build/DerivedData/Build/Products/Release/LikeWindows.app build/dmg-staging/
ln -s /Applications build/dmg-staging/Applications

hdiutil create -volname "如窗" -srcfolder build/dmg-staging \
  -ov -format UDZO build/export/LikeWindows.dmg
```

### 发布到 GitHub Releases

将生成的 `.dmg` 上传到 [Releases](https://github.com/gamehero2017/LikeWindows/releases) 即可供用户下载。对外公开分发时，建议对应用进行签名与公证，避免其他 Mac 被 Gatekeeper 拦截。

## 使用说明

1. 启动应用后，在偏好设置中开启所需功能
2. 若提示权限不足，点击「打开辅助功能设置」并为如窗授权
3. 授权后功能即可在后台生效

| 场景 | 操作 |
|------|------|
| 单窗口应用 | 前台点击 Dock 图标隐藏窗口，再次点击恢复 |
| 多窗口应用 | 悬停 Dock 图标查看全部窗口，移开鼠标后弹窗消失 |

## 技术栈

- Swift / SwiftUI
- Accessibility API（AXUIElement）
- CGEventTap（Dock 点击拦截）

## 开发者

青藤

## 开发说明

本项目的代码由 **AI 辅助完成开发**，产品需求、功能设计与最终验收由开发者完成。

## License

暂未指定开源协议。
