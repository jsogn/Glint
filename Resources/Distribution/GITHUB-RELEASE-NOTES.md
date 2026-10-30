# Glint 0.7.0

## 重点更新

- 大幅精简 App 与 DMG 安装包体积，DMG 下载体积约 13 MB。
- CC-CEDICT 与 ECDICT 改用更紧凑的 SQLite 结构，保留完整简繁查询和排序数据。
- App 升级时会自动原子替换旧版、不兼容的核心词典缓存。
- 候选停留默认缩短为 80ms，可调范围调整为 50–300ms。
- 移除不再随 App 分发的 Wiktionary 数据，减少安装占用。
- OPUS-MT 继续作为按需下载模型，不进入主安装包。

> 首次打开如遇 macOS 安全提示，请在“系统设置 → 隐私与安全性”中允许 Glint 打开。

## 安装

推荐下载 `Glint-*-macOS-arm64.pkg`，双击并按安装器提示完成安装。
也可以下载 DMG，将 Glint 拖入“应用程序”文件夹。

首次启动后，请在“系统设置 → 隐私与安全性 → 辅助功能”中授权 Glint。

## 系统要求

- macOS 15 或更高版本
- Apple Silicon Mac
