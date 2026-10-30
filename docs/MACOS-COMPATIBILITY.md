# macOS 兼容性

- 运行时最低版本：macOS 15
- CPU 架构：Apple Silicon arm64
- 构建工具链：macOS 26、Xcode 26

## 构建约束

`project.yml`、App 内全部 Swift Package 和 Tools Package 的 deployment target
统一为 `15.0`。主 App、Rime helper、CTranslate2 bridge 和 SentencePiece
都必须满足 `arm64 / minos <= 15.0`。

`scripts/verify_app.sh` 会遍历最终 App 中的 Mach-O，拒绝任何低于目标架构或
高于最低系统版本的二进制。

## 原生翻译运行时

翻译运行库使用以下固定版本：

- CTranslate2 4.8.3
- SentencePiece 0.2.2
- SentencePiece 的 Abseil 依赖 revision `5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a`

使用以下命令重建：

```bash
./scripts/build_ctranslate2_runtime.sh
```

脚本会校验源码 revision、架构、最低系统版本、RPATH、导出符号和代码签名，
在签名前剥离本地符号，并更新 `runtime-lock.json` 中的二进制哈希。
`scripts/test.sh` 会运行
`scripts/test_macos15_compatibility.sh`，在构建前阻止版本或二进制漂移。

## 发布文件名

发布产物使用稳定的平台与架构命名：

```text
Glint-<version>-macOS-arm64.dmg
Glint-<version>-macOS-arm64.pkg
```

文件名不包含最低 macOS 小版本。系统要求由 App 的 `LSMinimumSystemVersion`、
PKG 的 `--min-os-version` 元数据、下载页和 Release Notes 表达，避免未来提高
最低版本时改变稳定下载路径。

## 验证边界

当前自动化验证在 macOS 26 主机上完成，覆盖：

- Debug、Release 和 arm64 构建
- 最终 App、helper 与全部动态库的 Mach-O 最低版本检查
- 在线 OPUS-MT 数据、SentencePiece、Bridge 的实际加载和翻译
- 全量单元测试与集成测试
- DMG/PKG 生成、校验和与应用签名验证

正式公开发布前仍需在真实 macOS 15 主机上完成以下运行矩阵：

- Apple 拼音及豆包、微信、搜狗、Rime 的候选读取
- HUD 定位、失焦、多显示器与缩放
- 权限、登录启动、安装和 Rime 候选读取支持安装
- 在线 OPUS-MT 与 MLX 模型首次加载和翻译

网站下载入口指向 GitHub Latest Release，不再单独维护安装包镜像。只有在新的
macOS arm64 安装包上传并验证后，才能同步更新下载页的系统要求文案，避免线上
说明超前于实际发布产物。
