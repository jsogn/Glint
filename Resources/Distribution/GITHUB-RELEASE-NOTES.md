## Glint 测试版

系统要求：

- macOS 26 或更高版本
- Apple Silicon Mac

下载 `Glint-*-macOS26-arm64.dmg` 和同名 `.sha256` 文件后，在下载目录执行：

```bash
shasum -a 256 -c Glint-*-macOS26-arm64.dmg.sha256
```

当前包使用 ad-hoc 签名，没有 Developer ID，也没有经过 Apple 公证。首次打开时，
macOS 可能要求在“系统设置 > 隐私与安全性”中手动允许运行。该版本仅用于测试。

安装后请将 Glint 移入“应用程序”文件夹，再授予辅助功能权限。
