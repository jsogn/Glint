# Glint Distribution Plan

## 1. Current Status

Glint 当前是可稳定运行的开发版本，但还不是可分发包。

| 项目 | 当前状态 | 发行要求 |
| --- | --- | --- |
| Bundle ID | `com.local.glint` | 正式、唯一且长期不变的 Bundle ID |
| 签名身份 | ad-hoc | Developer ID Application |
| Team ID | 未配置 | 固定 Apple Developer Team |
| Hardened Runtime | 已启用 | 保持启用 |
| 公证 | 无 | Developer ID 签名后提交 Apple 公证 |
| 更新机制 | 无 | Sparkle 2 或等价方案 |
| 分发格式 | 源码构建 | 签名并公证的 DMG |

当前 `spctl` 拒绝 ad-hoc Debug App 属于预期行为，不影响本地开发。

## 2. Required Decisions

在邀请外部用户测试前，必须先确定：

1. 正式 Bundle ID。建议使用项目拥有或长期使用的反向域名，例如
   `io.github.jsogn.glint`，不再使用 `com.local.*`。
2. Apple Developer Team ID。
3. 分发范围：
   - 仅本机：继续使用当前开发签名；
   - 小范围测试：Developer ID + 公证 DMG；
   - 公开分发：再加 Sparkle 更新源和版本发布流程。

切换 Bundle ID 或签名身份会造成一次 TCC 权限身份变化，用户需要重新授权屏幕录制和
辅助功能。该切换应在外部 Beta 前完成，而不是发布后修改。

## 3. Signing Architecture

推荐直接下载分发，不启用 App Sandbox：

- `com.apple.security.app-sandbox`：不启用；
- Accessibility：继续通过用户 TCC 授权；不申请屏幕录制权限；
- Hardened Runtime：启用；
- 不使用 `disable-library-validation` 绕过动态库校验；
- 主 App、嵌套 dylib 和动态库必须使用同一个 Developer ID Team 签名。

OCR 和 ONNX Runtime 已从产品移除，主 App 不再携带
`libonnxruntime.1.dylib`。内置 OPUS-MT 使用的 CTranslate2、SentencePiece
和桥接动态库位于 `Contents/Resources/mt-opus-zh-en/bin`，必须与主 App 使用
同一 Developer ID Team 签名。其他可选模型的动态库仍需随对应插件清单校验
版本。归档阶段要枚举 App 实际包含的 dylib 和 framework，完成内层优先签名。
构建前必须运行 `scripts/prepare_opus_model.sh`，按 `model-lock.json` 转换或
校验内置 OPUS；模型权重和词表不得加入 Git。小体积 CT2 运行时由仓库提供，
并随主 App 一起签名。
开发构建完成后必须运行 `scripts/verify_app.sh`，检查 App 与全部嵌套 Mach-O
的最低系统版本、arm64 架构、必需资源和代码签名。

Release 构建不得使用 `CODE_SIGNING_ALLOWED=NO`。签名顺序应先内层动态库，后主 App，
全部使用 hardened runtime 和时间戳。

### 无 Developer ID 的内部测试包

当前没有 Developer ID 时，可运行 `scripts/package_test_dmg.sh` 生成 arm64
内部测试 DMG。脚本会：

- 构建 Release App；
- 逐个重签嵌套 Mach-O，再稳定重签主 App；
- 校验最低系统版本、必需资源、arm64 和签名完整性；
- 打入安装说明与一键诊断命令；
- 生成 SHA-256 校验文件。

这种包不能被 `spctl` 接受，也不能启用可用的 Hardened Runtime：ad-hoc 签名没有
Team ID，运行时库校验会拒绝嵌套动态库。它只适用于已知测试者的内部验证。

### 开发签名与 TCC

- `scripts/build.sh` 构建后使用 ad-hoc 签名，并把 designated requirement 固定为
  `identifier "com.local.glint"`；
- `scripts/test.sh` 必须使用独立的 `build-tests` DerivedData。测试构建会设置
  `CODE_SIGNING_ALLOWED=NO`，不得覆盖 `build/.../Glint.app`；
- 测试完成后必须从 LaunchServices 注销 `build-tests/.../Glint.app`，避免同名
  Bundle ID 与开发版并存；
- 可运行 App 与测试 App 不得共享同一个 Bundle 路径，否则 TCC 可能在稳定 identifier
  和测试构建 CDHash 之间反复切换，造成每次启动都要求重新授权；
- 切换 Bundle ID、签名 Team 或首次修复历史 TCC 记录后，需要一次性重新授权；
- 若后续取得 Apple Development 证书，开发构建应优先使用固定 Team 身份，不再
  依赖 ad-hoc 签名。

## 4. Release Pipeline

取得 Developer ID 后执行以下流程：

1. 设置固定 Bundle ID 和 Team ID；
2. archive Apple Silicon Release；
3. Developer ID 签名主 App 与所有嵌套二进制；
4. `codesign --verify --deep --strict`；
5. `spctl -a -vv` 通过；
6. 压缩或制作 DMG；
7. `notarytool` 提交并等待成功；
8. `stapler` 附加公证票据；
9. 再次执行 `spctl` 和离线启动验证；
10. 在干净的 macOS 用户环境中验证首次权限引导。

目标验证命令：

```bash
security find-identity -v -p codesigning
codesign --verify --deep --strict --verbose=2 Glint.app
spctl -a -vv Glint.app
xcrun notarytool submit Glint.zip --keychain-profile GlintNotary --wait
xcrun stapler staple Glint.app
```

## 5. Distribution And Updates

第一轮外部 Beta 建议只提供签名、公证的 arm64 DMG，不立即接入自动更新。确认安装和
TCC 流程稳定后，再接入 Sparkle 2：

- Appcast 使用 HTTPS；
- 更新包和 DMG 使用 EdDSA 签名；
- 私钥只存在发布者 Keychain 或 CI Secret；
- 更新前保留当前版本可回滚；
- 每个版本递增 `CFBundleVersion`；
- 更新不得替换 Bundle ID 或签名 Team。

## 6. Release Gate

发布前至少满足：

- 完整 `./scripts/test.sh` 通过；
- `run.sh` 连续三轮 readiness 握手通过；
- TextEdit、Safari、Chrome、微信真实输入通过；
- 密码框与安全输入不显示 HUD；
- 睡眠唤醒、多显示器、非蓝色高亮通过；
- 100–200 张真实候选截图回归；
- 干净用户环境首次授权通过；
- Gatekeeper、公证、staple 全部通过；
- 下载和卸载流程不会破坏用户词典与模型配置。
