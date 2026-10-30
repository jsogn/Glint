# Glint Agent Guide

本文件适用于整个仓库。修改代码前先阅读本文件和相关的 `docs/` 文档。

## 工作方式

- 架构讨论、产品询问、方案比较和探索性问题默认只讨论，不修改代码。
- 只有用户明确说“执行”“开始”“实现”“修改”等指令后才进入实施。
- 实施前先检查 `git status`，不回退或覆盖用户已有的改动。
- 优先做范围最小的修改，避免顺手重构无关模块。
- 完成后必须做与风险匹配的构建和测试，并报告真实结果。
- 不要声称无法直接验证的 UI、权限或运行状态。
- 用户未要求时，不创建新线程、不提交 PR、不推送远程仓库。

## 产品边界

Glint 是面向中文母语者的 macOS 英文学习工具，不替换输入法。

- 优先保证苹果拼音 `Pinyin - Simplified`；其他输入法只在提供可验证候选结构时
  做 best-effort 支持，不扫描普通 `AXList`，不接管键盘输入。
- 只读取当前蓝色高亮的输入法候选，不读取输入框正文。
- `AXSelectedTextRange` 非空且不位于 `AXTextInputMarkedRange` 内时，视为鼠标或键盘文字选区并跳过。
- 对当前高亮候选显示对应英文翻译，不显示词性、解释、例句或发音。
- 支持单词、短语和短句；短句应显示自然翻译。
- 默认全局生效；白名单、黑名单属于后续能力。
- 不做生词本、复习系统、学习统计、账号、云同步或付费系统。
- 安全输入场景必须完全跳过。
- 运行时错误静默隐藏翻译；只有缺少系统权限时可以弹窗。

## 平台与技术栈

- 最低系统：macOS 15。
- 第一版仅支持 Apple Silicon。
- 语言：Swift 6。
- 应用生命周期：AppKit `NSApplicationDelegate`。
- 主窗口：AppKit `NSWindow` + SwiftUI `NSHostingController`。
- HUD：AppKit `NSPanel` + SwiftUI。
- UI：系统 SwiftUI/AppKit 控件，不引入第三方 UI 组件库。
- 候选读取：Accessibility `InputMethodCandidateList`。
- 词典：SQLite 插件，当前包括 CC-CEDICT、ECDICT。
- 翻译：Apple Translation、CTranslate2 / MLX 本地模型。
- 日志：OSLog，默认脱敏。

## 目录职责

- `App/Glint/`：组合根、App 生命周期、菜单栏、主窗口和 HUD 协调。
- `Packages/GlintCore/`：领域模型、路由、偏好选择和纯 Swift 协议。
- `Packages/GlintMac/`：Accessibility、TIS、候选监控和 HUD 定位。
- `Packages/GlintDictionary/`：SQLite 词典、查询和排序。
- `Packages/GlintInference/`：CTranslate2 和 MLX 翻译运行时。
- `Packages/GlintPlugins/`：manifest、下载、镜像回退、校验和原子安装。
- `Packages/GlintUI/`：主窗口、设置页、HUD 视图和 UI 模型。
- `Tools/`：评测与模型实验，不进入 App 安装包。
- `docs/`：长期维护的架构、发布、AX 验证和词典来源说明。

## 构建、测试与运行

统一从仓库根目录执行：

```bash
./scripts/dev.sh
./scripts/build.sh
./scripts/test.sh
./scripts/run.sh
```

日常迭代优先使用快速路径：

```bash
./scripts/dev.sh
```

`dev.sh` 只在工程输入变化时重新生成 Xcode 工程，只在插件资源变化时重新安装
开发插件，然后执行增量 Debug 构建、稳定签名和单实例重启。仅构建不重启：

```bash
./scripts/dev.sh --build-only
```

SwiftUI 页面和 HUD 样式优先使用 Xcode Preview。业务逻辑优先运行受影响模块的
定向测试；完整 `./scripts/test.sh` 用于功能完成、跨模块改动或合并前，不要求每次
小改动都执行。

完整回归：

```bash
./scripts/test.sh
```

Release 验证：

```bash
release_derived_data="$(mktemp -d /tmp/glint-release.XXXXXX)"
xcodebuild \
  -workspace Glint.xcworkspace \
  -scheme Glint \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$release_derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Release 产物只用于命令行验证或性能测试，不应通过 Finder 或 `open` 运行。

运行规则：

- 使用 `./scripts/run.sh`，它会先构建，成功后再退出旧实例并启动唯一新实例。
- 日常代码迭代使用 `./scripts/dev.sh`；`run.sh` 保留给需要完整安装开发插件并
  重新构建的开发启动。
- `launch.sh` 只负责单实例退出、稳定注册、readiness token 和启动。
- `run.sh` 必须等待旧进程完全退出，并在启动后确认只有一个新进程；不能 `killall` 后立即 `open`。
- `run.sh` 必须通过一次性 readiness token 确认 App 已完成模型准备并启动监控，不能只检查进程存在。
- 禁止使用 `open -n`。它会创建重复 App 实例，导致窗口和监控循环分属不同进程。
- 开发版唯一可运行产物是 `build/Build/Products/Debug/Glint.app`。
- `scripts/build.sh` 会为开发版建立稳定的 codesign designated requirement；不要绕过它直接启动 Xcode 的未稳定签名产物。
- Release 验证产物不能与 Debug 版同时注册或打开。
- 构建失败时不要退出用户正在运行的 App。
- 测试结束不要把 App 关闭；保持最新版本运行，方便用户继续测试。
- 原生 App 不支持二进制热更新，代码重建后必须重启一次才能加载新代码。
- 同一时间只允许一个 Glint 进程。
- 监控只能在翻译运行时准备完成后启动，不能在异步初始化进行中提前启动。
- Release 必须启用 Dead Code Stripping、部署后处理剥离和 `-Osize`；DMG 使用
  `ULMO`，不得退回包含完整符号表的默认 Release 配置。

## 测试要求

- 修改 `GlintCore`：运行 `swift test --package-path Packages/GlintCore`。
- 修改 Accessibility、TIS 或候选监控：运行 `swift test --package-path Packages/GlintMac`。
- 修改词典：运行 `swift test --package-path Packages/GlintDictionary`。
- 修改翻译运行时：运行 `swift test --package-path Packages/GlintInference`。
- 修改插件系统：运行 `swift test --package-path Packages/GlintPlugins`。
- 修改 UI 或设置模型：运行 `swift test --package-path Packages/GlintUI`。
- 跨模块或发布前修改：运行完整 `./scripts/test.sh`。
- UI 修改要启动真实 App 并检查浅色/深色、窗口缩放和空状态。
- UI 样式可先用 Preview 快速迭代，但涉及 AppKit 生命周期、TCC、AX、输入法或
  NSPanel 行为时必须启动真实 App 验证。

## 翻译与插件规则

- 翻译优先来源只允许“智能融合”“词典优先”和“模型优先”三种模式。
- 两个来源必须互为失败回退，不因候选类型不同而阻断回退。
- HUD 由候选停留证据触发，不得在翻译完成后再追加固定等待。
- 连续快速输入时不得启动大模型；只有停留候选可以进入词典/模型路由。
- 精确翻译结果只允许使用有容量上限的内存 LRU，并必须按模型、prompt 和插件版本隔离。
- 每个候选 revision 只允许当前结果进入 HUD；候选变化时取消旧任务并让旧译文进入淡化占位，不得关闭组合会话中的 HUD。
- 只有候选栏结束、提交、失焦、切换输入法或安全输入时才关闭 HUD。
- 权限状态检查必须节流，不得在每次候选轮询中重复访问 TCC。
- CC-CEDICT 与 ECDICT 是随 App 提供的只读核心词典能力。
  OPUS-MT 是 Glint 托管的可选在线模型数据，由 `PluginManager` 安装和卸载。
- Apple Translation 是默认翻译模型；旧版选中的内置 OPUS-MT 在升级后一次性
  迁移为 Apple Translation，用户之后仍可主动下载并重新选择 OPUS-MT。
- 插件是数据包，不允许执行任意第三方代码。
- 下载/本地导入插件只允许 MLX、SQLite 或经过限制的 `ctranslate2-data`
  runtime。`ctranslate2-data` 只允许固定 ID `mt-opus-zh-en`，且下载包
  不得包含动态库、脚本、命令、链接或其他可执行内容。
- 下载必须校验 SHA256；优先国内镜像，失败后回退官方源。
- OPUS-MT 权重不进入 Git 或主 App 安装包。CTranslate2/SentencePiece
  运行库随签名 App 提供，模型数据由固定发布资产按需下载。
- 不支持用户添加的远程翻译接口；翻译结果必须来自 App 内置、经校验下载或
  本地导入的受支持模型。
- 不要在 UI 文案中写某台机器上的实测速度或开发备注；只描述用途和相对档位。

## UI 规范

- 遵循 macOS 原生设置界面，不复制 iOS 全屏式布局。
- 主窗口使用侧栏 + 内容区；标题显示在窗口顶部栏。
- 设置内容使用系统自适应颜色和材质，支持浅色/深色。
- 卡片内控件必须有稳定列对齐，不要依赖偶然的内容宽度。
- 控件组需要紧凑时优先使用系统 `controlSize`，不要随意缩字号。
- HUD 与原生候选栏高度接近，保持单行；默认间距 6pt，间距和透明度由用户调整。
- HUD 必须复用单一 `NSPanel` 和持久 `NSHostingView`，不得在每个结果到来时重建内容根视图。
- HUD 显隐使用 80ms 内淡入、60ms 内淡出和最多 2pt 位移；不得使用弹簧、缩放或循环动效。
- 新结果在淡出期间到达时必须取消旧的隐藏完成回调，并原位更新文字。
- 动画必须遵循 macOS Reduce Motion；开启时取消位移和文字过渡。
- “候选停留”使用 `display.candidateDwellDuration`，表示候选稳定多久后触发翻译，
  默认 100ms、范围 50–300ms；不得重新解释为翻译后的额外延迟。
- 不在运行时弹大卡片、Toast 或错误对话框；权限问题除外。
- 权限页必须主动调用辅助功能 Prompt API；不能只打开系统设置。
- 首次启动在主窗口可见后自动请求一次权限；用户拒绝后不再自动重复，保留页面内手动重试。
- 用户拒绝权限后，系统设置入口作为备用路径。
- UI 文案简洁、中文优先，避免开发者术语和内部算法名。

## 隐私与安全

- 不安装键盘事件监听。
- 不保存候选文本、翻译结果或输入历史。
- 不读取选中文字内容；只使用选区长度判断是否应跳过。
- 不截图、不读取输入框正文。
- 本地模型推理不得联网。
- 密码框、终端安全输入和其他 Secure Input 场景必须跳过。
- 日志不得包含候选原文、翻译原文或其他敏感数据。

## Swift 代码规范

- 保持 Swift 6 并发安全，不随意添加 `@unchecked Sendable`。
- UI 状态和 AppKit 对象保持在 `@MainActor`。
- 跨 actor 数据必须满足 `Sendable`。
- 优先使用值类型和小接口，避免全局可变状态。
- 不把网络下载、推理和 UI 状态混在同一模块。
- 新增设置时先明确归属：通用、翻译、识别、显示与触发、插件与模型、权限与隐私。
- 新增用户偏好必须有默认值、边界校验和测试；只有已发布版本需要承接旧数据时，
  才保留迁移逻辑。

## 文档与提交

- 行为、架构或性能结论变化时同步更新对应 `docs/` 文件。
- README 只保留用户需要的产品介绍、功能、安装和隐私说明。
- 提交前执行 `git diff --check`。
- Commit 使用清晰的英文祈使句，例如 `Fix plugin card alignment`。
- 用户要求交付或推送时，再执行 commit 和 `git push origin main`。
