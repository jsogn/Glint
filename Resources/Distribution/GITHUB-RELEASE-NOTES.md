# Glint 0.6.0

## 更新

- 最低支持系统扩展至 macOS 15，继续仅支持 Apple Silicon。
- 为 macOS 15 重建内置 OPUS-MT 原生运行库。
- 新增原生运行库的可复现构建、版本固定和完整性校验。
- 统一发布文件为 `Glint-<version>-macOS-arm64` 命名，并让 PKG 明确校验最低系统版本。

> 首次打开如遇 macOS 安全提示，请在“系统设置 → 隐私与安全性”中允许 Glint 打开。

## 安装

推荐下载 `Glint-*-macOS-arm64.pkg`，双击并按安装器提示完成安装。
也可以下载 DMG，将 Glint 拖入“应用程序”文件夹。

首次启动后，请在“系统设置 → 隐私与安全性 → 辅助功能”中授权 Glint。

## 系统要求

- macOS 15 或更高版本
- Apple Silicon Mac
