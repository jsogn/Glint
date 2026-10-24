# Glint 0.3.5

## 更新

- 飞书、Chrome、微信、网易云等常见应用可直接显示翻译。
- 苹果拼音、微信输入法和搜狗拼音支持更稳定，更多第三方输入法可自动适配。
- 修复 Glint 自身窗口导致的偶发崩溃。
- 优化翻译栏高度和间距，在笔记本屏幕上更紧凑。
- 模型安装显示实时进度和速度，并优先使用国内下载源。
- 新增一键安装 PKG，同时保留 DMG。

> 当前发布包使用 ad-hoc 签名，没有经过 Apple 公证，只适合开发和已知测试者。
> 首次打开如果被 macOS 阻止，请在“系统设置 → 隐私与安全性”中允许一次。

## 安装

推荐下载 `Glint-*-Installer-macOS26-arm64.pkg`，双击并按安装器提示完成安装。
也可以下载 DMG，将 Glint 拖入“应用程序”文件夹。

首次启动后，请在“系统设置 → 隐私与安全性 → 辅助功能”中授权 Glint。

## 系统要求

- macOS 26 或更高版本
- Apple Silicon Mac

下载后可校验安装包：

```bash
shasum -a 256 -c Glint-*-Installer-macOS26-arm64.pkg.sha256
shasum -a 256 -c Glint-*-macOS26-arm64.dmg.sha256
```
