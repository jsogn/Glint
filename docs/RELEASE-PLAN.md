# Glint Distribution Plan

## 当前状态

| 项目 | 当前 | 正式发行目标 |
| --- | --- | --- |
| Bundle ID | `com.local.glint` | 长期固定的正式 Bundle ID |
| 签名 | ad-hoc | Developer ID Application |
| Team ID | 未配置 | 固定 Apple Developer Team |
| Hardened Runtime | 正式签名需要；ad-hoc 测试包不可用 | 启用 |
| 公证 | 无 | Apple notarization + staple |
| 更新 | 未接入 | Sparkle 2 或等价方案 |
| 分发 | 源码或 ad-hoc PKG/DMG | 签名、公证的 PKG/DMG |

当前包面向开发和已知测试者。`spctl` 拒绝 ad-hoc App 是预期行为，不代表本地运行
失败。

## 必选决策

邀请外部用户前必须先确定：

1. 正式 Bundle ID，建议使用项目长期持有的反向域名，而非 `com.local.*`。
2. Apple Developer Team ID。
3. 分发范围：本机开发、小范围测试或公开分发。

切换 Bundle ID、签名 Team 或首次修复历史 TCC 记录会改变辅助功能授权身份。该
切换应在外部 Beta 前完成，避免发布后要求用户重新授权。

## Ad-hoc 测试发布

没有 Developer ID 时可以使用：

- `scripts/package_test_dmg.sh`：生成 arm64 DMG、安装说明、诊断命令和 SHA256。
- `scripts/package_test_pkg.sh`：生成标准 macOS Installer PKG；安装后校验、注册
  并尝试启动 App。
- `scripts/package_test_distributions.sh`：只构建、签名和验证一次 Release App，
  再生成 DMG 与 PKG，发布流程优先使用该入口。

三个入口都会从头构建 Release App、重签嵌套 Mach-O、稳定重签主 App，并校验
arm64、最低系统、必需资源、签名完整性和 SHA256。

ad-hoc 包不能通过 Gatekeeper，也不能启用可用的 Hardened Runtime。面向普通测试
用户时优先使用 PKG；首次安装仍可能需要在“隐私与安全性”中允许一次。

## 正式签名与公证

直接下载分发不启用 App Sandbox：

- 继续通过用户 TCC 授权 Accessibility，不申请屏幕录制权限。
- 主 App、嵌套 dylib 和 framework 使用同一个 Developer ID Team，内层优先签名。
- 不使用 `disable-library-validation` 绕过动态库校验。
- 内置 CTranslate2、SentencePiece 和 OPUS-MT 必须与主 App 同源签名。
- 构建前运行 `scripts/prepare_opus_model.sh`；模型权重和词表不进入 Git。
- 开发构建完成后运行 `scripts/verify_app.sh`。

取得 Developer ID 后执行：

1. 固定 Bundle ID 和 Team ID，archive arm64 Release。
2. 使用 hardened runtime 和时间戳完成内层优先签名。
3. 运行 `codesign --verify --deep --strict` 和 `spctl -a -vv`。
4. 生成 DMG，使用 `notarytool` 提交并等待成功。
5. 使用 `stapler` 附加票据，再次运行 `spctl` 和离线启动验证。
6. 在干净用户环境验证首次授权、安装、更新与卸载。

目标校验命令：

```bash
security find-identity -v -p codesigning
codesign --verify --deep --strict --verbose=2 Glint.app
spctl -a -vv Glint.app
xcrun notarytool submit Glint.zip --keychain-profile GlintNotary --wait
xcrun stapler staple Glint.app
```

## GitHub 自动发布

- `.github/workflows/ci.yml`：在 `main` push 和 Pull Request 中执行 Swift
  格式严格检查、完整测试和 Python 工具测试。
- `.github/workflows/release.yml`：推送 `v*` 标签后重复质量门禁，生成 ad-hoc
  PKG、DMG 和校验文件，并创建 GitHub Latest 发布。

标签版本必须与 `project.yml` 的 `MARKETING_VERSION` 一致。例如 `0.4.1` 对应
`v0.4.1`；每个发布递增 `CFBundleVersion`。CI 当前使用 `macos-26`。

## TCC 与本地测试

- `scripts/build.sh` 使用固定的 ad-hoc designated requirement。
- `scripts/test.sh` 使用独立 `build-tests` DerivedData，不覆盖可运行的 Debug App。
- 测试后注销 `build-tests` 和临时 Release/DMG 中的 App 注册，避免同 Bundle ID
  的多个路径争用 TCC 身份。
- 不通过 `open -n` 启动重复实例；运行入口必须等待 readiness token 和单实例确认。
- 构建失败时保留用户正在运行的 App；测试完成后保持最新 Debug App 运行。

## 更新策略

第一轮外部 Beta 只提供签名、公证的 arm64 安装包，不立即启用自动更新。安装和
TCC 流程稳定后再接入 Sparkle 2：

- Appcast 使用 HTTPS，更新包使用 EdDSA 签名。
- 私钥只保存在发布者 Keychain 或 CI Secret。
- 每个版本递增 build，更新不得替换 Bundle ID 或签名 Team。
- 更新前保留可回滚版本。

## 公开版门禁

面向普通用户发布前至少满足：

- 完整 `./scripts/test.sh`、Swift 格式检查、Python 工具测试和 Release arm64
  构建通过。
- `run.sh` 连续三轮 readiness 握手和单实例检查通过。
- TextEdit、Safari、Chrome 和微信真实输入通过。
- 密码框、Secure Input、睡眠唤醒、多显示器、全屏和不同缩放完成验证。
- AX fixture 回归不保存候选截图或原文。
- 干净用户环境的首次授权、安装、更新和卸载通过。
- 登录项的启用、系统审批撤销、禁用和实际重新登录启动通过。
- Gatekeeper、公证、staple 和离线启动全部通过。
- 下载、更新或卸载不会破坏用户词典与模型配置。
