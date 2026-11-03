# Glint Distribution Plan

## 当前状态

| 项目 | 当前既定方案 | 可选升级 |
| --- | --- | --- |
| Bundle ID | `com.local.glint` | 仅在明确规划 TCC 迁移时更换 |
| 签名 | ad-hoc，无 Developer ID | Developer ID Application |
| Team ID | 不需要 | 可选固定 Apple Developer Team |
| Hardened Runtime | 当前渠道不启用 | Developer ID 渠道启用 |
| 公证 | 不使用 | 可选 Apple notarization + staple |
| 更新 | 菜单栏与“关于”页手动检查并跳转 GitHub | Sparkle 2 或等价方案 |
| 分发 | GitHub Releases 无签名 PKG/DMG | 可选的签名、公证 PKG/DMG |
| Homebrew | `jsogn/homebrew-glint` | 保持当前 Tap；未来可评估官方 Cask |

Glint 的公开发布渠道是 GitHub Releases，采用无 Developer ID 签名、未公证的
ad-hoc PKG/DMG。`spctl` 拒绝 ad-hoc App 是这种分发方式的预期行为，不代表安装包
损坏或项目不能公开发布。README 与 Release Notes 必须提供一次性的系统允许说明。

## 发行决策

当前发行方案已经确定：

1. 通过 GitHub Releases 公开分发自签 ad-hoc PKG/DMG。
2. 不要求发布者在发布前持有 Developer ID 或完成 Apple 公证。
3. Bundle ID 保持 `com.local.glint`，除非明确决定迁移签名身份和 TCC 授权。

Developer ID、Hardened Runtime 和公证是可选升级，不是版本发布门禁。如果未来切换，
必须同时规划 Bundle ID、签名 Team 和辅助功能 TCC 授权迁移。

## GitHub 无签名发布

当前公开发布使用：

- `scripts/package_test_dmg.sh`：生成 arm64 DMG、安装说明、诊断命令和 SHA256。
- `scripts/package_test_pkg.sh`：生成标准 macOS Installer PKG；安装后校验、注册
  并尝试启动 App。
- `scripts/package_test_distributions.sh`：只构建、签名和验证一次 Release App，
  再生成 DMG 与 PKG，发布流程优先使用该入口。

三个入口都会从头构建 Release App、重签嵌套 Mach-O、稳定重签主 App，并校验
arm64、最低系统、必需资源、签名完整性和 SHA256。脚本名中的 `test` 是历史命名，
其产物就是当前 GitHub 无签名发行输入。

Release 构建启用 `-Osize`、Dead Code Stripping 和部署后处理剥离，并保留 dSYM
用于崩溃符号化。打包脚本还会拒绝超过 24 MB 的主程序，防止完整符号表重新进入
发布包。DMG 使用 `ULMO` 压缩，生成后必须通过 `hdiutil verify`。

ad-hoc 包不能直接通过 Gatekeeper，也不能启用可用的 Hardened Runtime。这是已知且
接受的发行成本。优先提供 PKG；通过 PKG 或 DMG 首次安装时，用户需要在
“隐私与安全性”中允许一次。Homebrew 渠道的 quarantine 处理见下一节。

## Homebrew 实验性渠道

项目维护的 Tap 位于 `jsogn/homebrew-glint`，是当前无签名发行渠道的一部分：

- Cask 当前只支持 arm64 和 macOS 15+。
- 每次 Tag Release 发布并验证 DMG 后，同步更新 Cask 的 `version` 和 SHA256。
- Cask 使用 `postflight_steps` 移除 `com.apple.quarantine`，使当前无签名发布包
  可以直接启动。该操作不是代码签名，也不会提供 Developer ID 身份或 Apple
  公证。
- 不自动移除整个 Tap 或其他 App 的属性；命令只作用于 Cask 安装的
  `Glint.app`。
- Tap 由项目控制，不开放仓库写权限。外部贡献通过 Pull Request 提交，不设置
  定时发布或直接推送 `main` 的自动更新工作流。

每次 Cask 更新至少执行：

1. 对照 Release 资产更新 `version`、URL 和 SHA256。
2. 运行 `brew style --cask`、`brew audit --cask --online` 和
   `brew livecheck --cask`。
3. 在干净安装目录执行一次 `brew install`，确认版本、架构、最低系统和
   quarantine 清除行为；再执行 `brew upgrade` 或 `brew reinstall` 验证升级路径。
4. 运行 `brew uninstall --cask`，确认只会移除 App，不删除词典、模型和设置。

如果未来明确切换到 Developer ID 签名、Hardened Runtime 和 Apple 公证，应删除
`postflight_steps` quarantine 处理及对应 caveat，确认 Gatekeeper 直接通过，再
重新评估官方 `homebrew/cask`。签名和公证不能通过 `xattr` 或重新进行 ad-hoc
签名替代。

## 可选 Developer ID 升级

本节不是当前发布前置条件。只有明确决定升级发行身份时才执行。

直接下载分发不启用 App Sandbox：

- 继续通过用户 TCC 授权 Accessibility，不申请屏幕录制权限。
- 主 App、嵌套 dylib 和 framework 使用同一个 Developer ID Team，内层优先签名。
- 不使用 `disable-library-validation` 绕过动态库校验。
- App 内置的 CTranslate2、SentencePiece 动态库必须与主 App 同源签名。
- OPUS-MT 权重和词表不进入 Git 或 App；使用
  `scripts/package_opus_model_data.sh` 生成并校验在线数据包。
- 开发构建完成后运行 `scripts/verify_app.sh`。

取得 Developer ID 并决定升级后执行：

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
  PKG、DMG 和校验文件，并创建 GitHub Latest 发布。发布说明必须位于
  `Resources/Distribution/Release-Notes/<tag>.md`；缺少对应文件时发布失败。
- 发布产物使用 `Glint-<version>-macOS-arm64.dmg` 和
  `Glint-<version>-macOS-arm64.pkg`；文件名不包含最低 macOS 小版本。
- 系统要求由 App、PKG 元数据、下载页和 Release Notes 共同表达。网站下载入口
  指向 GitHub Latest Release，只有新安装包上传并验证后才能更新下载页文案。

标签版本必须与 `project.yml` 的 `MARKETING_VERSION` 一致。例如 `0.4.1` 对应
`v0.4.1`；每个发布递增 `CFBundleVersion`。CI 当前使用 `macos-26`。

## 托管模型发布

OPUS-MT 模型数据与 App 分开发布：

1. 运行 `scripts/package_opus_model_data.sh`，生成固定 SHA256 的模型包。
2. 将模型包上传到 `model-opus-v0.1.0` Release。
3. 确认 `Resources/catalog.json` 的大小与 SHA256 和归档一致。
4. App 安装包只包含 `CTranslate2Runtime` 动态库，不包含 OPUS-MT 数据。

模型包不得包含动态库、可执行文件、脚本或符号链接。

## TCC 与本地测试

- `scripts/build.sh` 使用固定的 ad-hoc designated requirement。
- `scripts/test.sh` 使用独立 `build-tests` DerivedData，不覆盖可运行的 Debug App。
- 测试后注销 `build-tests` 和临时 Release/DMG 中的 App 注册，避免同 Bundle ID
  的多个路径争用 TCC 身份。
- 不通过 `open -n` 启动重复实例；运行入口必须等待 readiness token 和单实例确认。
- 构建失败时保留用户正在运行的 App；测试完成后保持最新 Debug App 运行。

## 更新策略

App 启动约 30 秒后自动请求 GitHub Latest Release，成功或失败均记录尝试时间，
24 小时内不重复。自动检查失败保持静默；发现新版本时只在菜单栏、概览和“关于”
页显示被动提示，不弹窗。用户可随时手动检查并绕过冷却，手动检查失败会显示轻量
结果。所有检查都只读取版本和发布页地址，不下载或替换 App。

当前版本只提供 GitHub 无签名 arm64 安装包，由用户手动跳转 GitHub 下载更新。
安装和 TCC 流程稳定后，再评估 Sparkle 2 或其他更新机制：

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
- GitHub 无签名 PKG/DMG 的 ad-hoc 签名、SHA256、挂载、安装和首次允许流程通过。
- Homebrew Cask 指向对应的 GitHub 无签名资产，并正确执行当前 Tap 的安装策略。
- 下载、更新或卸载不会破坏用户词典与模型配置。
